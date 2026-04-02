#!/usr/bin/env python3
"""Shared tmux coding-agent scanner and status renderer.

Two outputs are supported:
  1. Default TSV rows for the picker:
     PANE_ID  SESSION  WINDOW  PANE_IDX  AGENT  STATE  CWD  WNAME
  2. --status renders the tmux status-bar segment.

Detection walks each pane's descendant process tree top-down. State is pane-local:
we track changes in cursor/history metadata over time and label panes as
"active"/"quiet" instead of claiming the agent is truly "running"/"idle".
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import subprocess
import sys
import time
from collections import defaultdict, deque
from pathlib import Path

ACTIVITY_THRESHOLD = 5
CACHE_VERSION = 1
HOME = os.environ.get("HOME", "")
STATUS_AGENT_ORDER = ("claude", "codex", "aider", "opencode")

DENY_SUBSTRINGS = tuple(
    token.lower()
    for token in (
        "mcp-server",
        "mcp server",
        "Claude.app",
        "shell-snapshots",
        "chrome-native-host",
        "coding-agents",
        "agent-picker",
        "agent-scan",
        "agent-history",
    )
)

BASENAME_MAP = {
    "claude": "claude",
    "codex": "codex",
    "aider": "aider",
    "opencode": "opencode",
}

PACKAGE_MAP = {
    "@anthropic-ai/claude-code": "claude",
    "@openai/codex": "codex",
    "aider-chat": "aider",
}

PATH_PATTERNS = (
    ("claude-code/", "claude"),
    ("@anthropic-ai/claude-code", "claude"),
    ("@openai/codex", "codex"),
    ("codex-cli/", "codex"),
    ("aider-chat/", "aider"),
)

SHELL_WRAPPERS = {"bash", "zsh", "sh", "fish"}
GENERIC_WRAPPERS = {
    "command",
    "direnv",
    "env",
    "nohup",
    "setsid",
    "sudo",
}
PACKAGE_WRAPPERS = {
    "bun",
    "bunx",
    "npm",
    "npx",
    "pnpm",
    "uv",
    "uvx",
    "yarn",
}
RUNTIME_WRAPPERS = {"node", "nodejs"}


def run_command(argv: list[str], timeout: int = 5) -> str:
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""
    return proc.stdout if proc.returncode == 0 else ""


def get_tmux_context() -> dict[str, str]:
    out = run_command(
        ["tmux", "display-message", "-p", "#{socket_path}\t#{pid}\t#{start_time}"]
    ).strip()
    parts = out.split("\t")
    if len(parts) != 3:
        return {"socket_path": "", "pid": "0", "start_time": "0"}
    return {"socket_path": parts[0], "pid": parts[1], "start_time": parts[2]}


def get_cache_path(name: str, context: dict[str, str]) -> Path:
    key_src = "\0".join(
        (
            context.get("socket_path", ""),
            context.get("pid", "0"),
            context.get("start_time", "0"),
            name,
        )
    )
    digest = hashlib.sha1(key_src.encode("utf-8")).hexdigest()[:16]
    cache_dir = Path(os.environ.get("TMPDIR") or "/tmp") / f"tmux-agent-scan-{os.getuid()}"
    cache_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    return cache_dir / f"{name}-{digest}.json"


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def write_json_atomic(path: Path, payload: dict) -> None:
    tmp_path = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    with tmp_path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"))
    os.replace(tmp_path, path)


def tmux_panes() -> list[dict[str, object]]:
    fmt = (
        "#{pane_id}\t#{pane_pid}\t#{session_name}\t#{window_index}\t#{pane_index}"
        "\t#{pane_current_path}\t#{window_name}\t#{cursor_x}\t#{cursor_y}"
        "\t#{history_size}\t#{alternate_on}\t#{pane_current_command}"
    )
    out = run_command(["tmux", "list-panes", "-a", "-F", fmt])
    if not out:
        return []

    panes: list[dict[str, object]] = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 12:
            continue
        panes.append(
            {
                "pane_id": parts[0],
                "pane_pid": int(parts[1]) if parts[1].isdigit() else 0,
                "session": parts[2],
                "window": parts[3],
                "pane_idx": parts[4],
                "cwd": parts[5],
                "wname": parts[6],
                "cursor_x": int(parts[7]) if parts[7].isdigit() else 0,
                "cursor_y": int(parts[8]) if parts[8].isdigit() else 0,
                "history_size": int(parts[9]) if parts[9].isdigit() else 0,
                "alternate_on": parts[10] == "1",
                "current_command": parts[11],
            }
        )
    return panes


def ps_tree() -> tuple[dict[int, list[int]], dict[int, str]]:
    out = run_command(["ps", "-ww", "-Ao", "pid=,ppid=,args="])
    if not out:
        return {}, {}

    children: dict[int, list[int]] = {}
    args_map: dict[int, str] = {}
    for line in out.splitlines():
        parts = line.lstrip().split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        args_map[pid] = parts[2] if len(parts) > 2 else ""
        children.setdefault(ppid, []).append(pid)
    return children, args_map


def parse_tokens(command: str) -> list[str]:
    try:
        return shlex.split(command, posix=True)
    except ValueError:
        return command.split()


def is_env_assignment(token: str) -> bool:
    if "=" not in token or token.startswith("="):
        return False
    key, _value = token.split("=", 1)
    if not key or key[0].isdigit():
        return False
    return all(ch.isalnum() or ch == "_" for ch in key)


def normalize_package(token: str) -> str:
    normalized = token.lower().strip()
    if normalized.startswith("@") and normalized.count("@") >= 2:
        normalized = normalized.rsplit("@", 1)[0]
    return normalized


def agent_from_token(token: str) -> str | None:
    normalized = normalize_package(token)
    basename = os.path.basename(normalized)
    if basename in BASENAME_MAP:
        return BASENAME_MAP[basename]
    if normalized in PACKAGE_MAP:
        return PACKAGE_MAP[normalized]
    for pattern, agent in PATH_PATTERNS:
        if pattern in normalized:
            return agent
    return None


def classify_tokens(tokens: list[str], depth: int = 0) -> str | None:
    if not tokens or depth > 3:
        return None

    idx = 0
    while idx < len(tokens) and is_env_assignment(tokens[idx]):
        idx += 1
    if idx >= len(tokens):
        return None

    token = tokens[idx]
    basename = os.path.basename(token).lower()
    direct = agent_from_token(token)
    if direct is not None:
        return direct

    if basename == "env":
        idx += 1
        while idx < len(tokens) and (
            tokens[idx].startswith("-") or is_env_assignment(tokens[idx])
        ):
            idx += 1
        return classify_tokens(tokens[idx:], depth + 1)

    if basename in {"nice", "chrt"}:
        idx += 1
        while idx < len(tokens) and (
            tokens[idx].startswith("-") or tokens[idx].lstrip("+-").isdigit()
        ):
            idx += 1
        return classify_tokens(tokens[idx:], depth + 1)

    if basename in {"stdbuf", "unbuffer"}:
        idx += 1
        while idx < len(tokens) and tokens[idx].startswith("-"):
            idx += 1
        return classify_tokens(tokens[idx:], depth + 1)

    if basename in GENERIC_WRAPPERS:
        tail = tokens[idx + 1 :]
        if basename == "direnv" and tail[:1] == ["exec"]:
            tail = tail[1:]
            if tail and not tail[0].startswith("-"):
                tail = tail[1:]
        while tail and tail[0].startswith("-"):
            tail = tail[1:]
        return classify_tokens(tail, depth + 1)

    if basename in {"npx", "bunx", "uvx"}:
        tail = tokens[idx + 1 :]
        while tail and tail[0].startswith("-"):
            tail = tail[1:]
        return classify_tokens(tail, depth + 1)

    if basename in {"npm", "pnpm", "yarn", "bun", "uv"}:
        tail = tokens[idx + 1 :]
        while tail and tail[0].startswith("-"):
            tail = tail[1:]
        if tail[:1] and tail[0] in {"exec", "dlx", "x", "tool", "run"}:
            return classify_tokens(tail[1:], depth + 1)

    if basename.startswith("python"):
        tail = tokens[idx + 1 :]
        for pos, value in enumerate(tail[:-1]):
            if value == "-m":
                module_name = tail[pos + 1].lower()
                if module_name == "aider" or module_name.startswith("aider."):
                    return "aider"
                if module_name == "opencode" or module_name.startswith("opencode."):
                    return "opencode"
        while tail and tail[0].startswith("-"):
            if tail[0] == "-m" and len(tail) > 1:
                break
            tail = tail[1:]
        return classify_tokens(tail, depth + 1)

    if basename in RUNTIME_WRAPPERS:
        return classify_tokens(tokens[idx + 1 :], depth + 1)

    if basename in SHELL_WRAPPERS:
        tail = tokens[idx + 1 :]
        for pos, value in enumerate(tail[:-1]):
            if value.startswith("-") and "c" in value:
                return classify(tail[pos + 1], depth + 1)

    if basename in PACKAGE_WRAPPERS and idx + 1 < len(tokens):
        next_agent = agent_from_token(tokens[idx + 1])
        if next_agent is not None:
            return next_agent

    return None


def classify(command: str, depth: int = 0) -> str | None:
    lowered = command.lower()
    if any(token in lowered for token in DENY_SUBSTRINGS):
        return None

    tokens = parse_tokens(command)
    agent = classify_tokens(tokens, depth)
    if agent is not None:
        return agent

    for pattern, agent_type in PATH_PATTERNS:
        if pattern in lowered:
            return agent_type
    return None


def pane_signature(pane: dict[str, object]) -> str:
    return "|".join(
        (
            str(pane["cursor_x"]),
            str(pane["cursor_y"]),
            str(pane["history_size"]),
            "1" if pane["alternate_on"] else "0",
            str(pane["current_command"]),
        )
    )


def pane_states(
    panes: list[dict[str, object]], context: dict[str, str], now: float
) -> dict[str, str]:
    cache_path = get_cache_path("state", context)
    cached = load_json(cache_path)
    prev_panes = cached.get("panes", {}) if cached.get("version") == CACHE_VERSION else {}
    next_panes: dict[str, dict[str, object]] = {}
    states: dict[str, str] = {}

    for pane in panes:
        pane_id = str(pane["pane_id"])
        signature = pane_signature(pane)
        previous = prev_panes.get(pane_id, {})

        if previous.get("signature") == signature:
            changed_at = float(previous.get("changed_at", 0.0))
        elif previous:
            changed_at = now
        else:
            changed_at = 0.0

        states[pane_id] = (
            "active" if changed_at and (now - changed_at) < ACTIVITY_THRESHOLD else "quiet"
        )
        next_panes[pane_id] = {"signature": signature, "changed_at": changed_at}

    try:
        write_json_atomic(cache_path, {"version": CACHE_VERSION, "panes": next_panes})
    except OSError:
        pass

    return states


def scan_rows() -> list[dict[str, str]]:
    now = time.time()
    context = get_tmux_context()
    panes = tmux_panes()
    if not panes:
        return []

    children, args_map = ps_tree()
    if not args_map:
        return []

    states = pane_states(panes, context, now)
    seen: set[tuple[str, str]] = set()
    rows: list[dict[str, str]] = []

    for pane in panes:
        pane_pid = int(pane["pane_pid"])
        if pane_pid <= 0:
            continue

        queue: deque[int] = deque(children.get(pane_pid, []))
        visited = {pane_pid}

        while queue:
            pid = queue.popleft()
            if pid in visited:
                continue
            visited.add(pid)

            command = args_map.get(pid, "")
            agent = classify(command)
            if agent is not None:
                key = (str(pane["pane_id"]), agent)
                if key not in seen:
                    seen.add(key)
                    cwd = str(pane["cwd"])
                    if HOME and cwd.startswith(HOME):
                        cwd = "~" + cwd[len(HOME) :]
                    rows.append(
                        {
                            "pane_id": str(pane["pane_id"]),
                            "session": str(pane["session"]),
                            "window": str(pane["window"]),
                            "pane_idx": str(pane["pane_idx"]),
                            "agent": agent,
                            "state": states.get(str(pane["pane_id"]), "quiet"),
                            "cwd": cwd,
                            "wname": str(pane["wname"]).strip(),
                        }
                    )
                continue

            queue.extend(children.get(pid, []))

    agent_rank = {name: idx for idx, name in enumerate(STATUS_AGENT_ORDER)}
    rows.sort(
        key=lambda row: (
            row["session"],
            int(row["window"]) if row["window"].isdigit() else row["window"],
            int(row["pane_idx"]) if row["pane_idx"].isdigit() else row["pane_idx"],
            agent_rank.get(row["agent"], 99),
        )
    )
    return rows


def render_tsv(rows: list[dict[str, str]]) -> str:
    return "\n".join(
        "\t".join(
            (
                row["pane_id"],
                row["session"],
                row["window"],
                row["pane_idx"],
                row["agent"],
                row["state"],
                row["cwd"],
                row["wname"],
            )
        )
        for row in rows
    )


def render_status(rows: list[dict[str, str]]) -> str:
    if not rows:
        return ""

    counts: dict[tuple[str, str], dict[str, int]] = defaultdict(
        lambda: {"active": 0, "quiet": 0}
    )
    sessions_seen: set[str] = set()

    for row in rows:
        session = row["session"]
        sessions_seen.add(session)
        counts[(session, row["agent"])][row["state"]] += 1

    current_session = run_command(["tmux", "display-message", "-p", "#{session_name}"]).strip()

    def session_sort_key(session: str) -> tuple[int, int, str]:
        has_active = any(counts[(session, agent)]["active"] > 0 for agent in STATUS_AGENT_ORDER)
        return (
            0 if session == current_session else 1,
            0 if has_active else 1,
            session,
        )

    session_order = sorted(sessions_seen, key=session_sort_key)

    rendered_sessions: list[str] = []
    for session in session_order:
        pieces: list[str] = []
        for agent in STATUS_AGENT_ORDER:
            active = counts[(session, agent)]["active"]
            quiet = counts[(session, agent)]["quiet"]
            if active == 0 and quiet == 0:
                continue

            name_color = "#ff9d00" if active else "#3d6b84"
            fragment = f"#[fg={name_color}]{agent}"
            if active:
                fragment += f" #[fg=#ff9d00]●{'' if active == 1 else active}"
            if quiet:
                fragment += f" #[fg=#3d6b84]○{'' if quiet == 1 else quiet}"
            pieces.append(fragment)

        if pieces:
            rendered_sessions.append(
                f"#[fg=#9effff]{session}#[fg=#3d6b84]: "
                + " #[fg=#3d6b84]· ".join(pieces)
            )

    if not rendered_sessions:
        return ""
    return f"#[fg=#ffc600]󰚩#[default] {' '.join(rendered_sessions)} #[fg=#2a5470]│"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--status",
        action="store_true",
        help="render the tmux status-bar segment instead of TSV rows",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    rows = scan_rows()

    if args.status:
        sys.stdout.write(render_status(rows))
    else:
        output = render_tsv(rows)
        if output:
            sys.stdout.write(output + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
