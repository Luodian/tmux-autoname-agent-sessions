#!/usr/bin/env python3
"""
Aggregate Claude Code and Codex session history from local files.

Usage:
  agent-history-data.py list [hours]     — tab-delimited session list
  agent-history-data.py detail <id>      — show prompts for one session
  agent-history-data.py meta <id>        — tab-delimited agent + project path + hint
"""

import json, sys, os
from datetime import datetime, timezone
from collections import defaultdict
from pathlib import Path

HOME = Path.home()


def env_path(name, default):
    value = os.environ.get(name)
    return Path(value).expanduser() if value else default


CLAUDE_HISTORY = env_path("TMUX_AUTONAME_CLAUDE_HISTORY", HOME / ".claude" / "history.jsonl")
CLAUDE_SESSIONS = env_path("TMUX_AUTONAME_CLAUDE_SESSIONS", HOME / ".claude" / "sessions")
CODEX_INDEX = env_path("TMUX_AUTONAME_CODEX_INDEX", HOME / ".codex" / "session_index.jsonl")
CODEX_HISTORY = env_path("TMUX_AUTONAME_CODEX_HISTORY", HOME / ".codex" / "history.jsonl")
PREVIEW_LIMIT = 14
SEARCH_PROMPT_HEAD = 6
SEARCH_PROMPT_TAIL = 14
SEARCH_TEXT_LIMIT = 2200


def time_ago(ts):
    diff = datetime.now(timezone.utc).timestamp() - ts
    if diff < 60:     return f"{int(diff)}s ago"
    if diff < 3600:   return f"{int(diff // 60)}m ago"
    if diff < 86400:  return f"{int(diff // 3600)}h ago"
    return f"{int(diff // 86400)}d ago"


def load_active_session_ids():
    ids = set()
    if CLAUDE_SESSIONS.exists():
        for f in CLAUDE_SESSIONS.glob("*.json"):
            try:
                ids.add(json.loads(f.read_text()).get("sessionId", ""))
            except Exception:
                pass
    return ids


def safe_lines(path):
    if not path.exists():
        return
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    pass


def inline_text(text, max_len=110):
    cleaned = " ".join((text or "").replace("\t", " ").split())
    if not cleaned:
        return "\u2014"
    return cleaned[: max_len - 3] + "..." if len(cleaned) > max_len else cleaned


def normalize_summary(text, agent=""):
    cleaned = " ".join((text or "").replace("\t", " ").split())
    if agent == "codex":
        for prefix in (
            "Codex Companion Task: ",
            "Codex Companion Task - ",
            "Codex Task: ",
        ):
            if cleaned.startswith(prefix):
                cleaned = cleaned[len(prefix) :]
                break
    return cleaned


def is_low_signal(text):
    stripped = (text or "").strip()
    compact = " ".join(stripped.split())
    if not stripped:
        return True
    if compact.isdigit():
        return True
    if stripped.startswith("[Pasted text"):
        return True
    if stripped.startswith("<task-notification>"):
        return True
    if stripped.startswith("/"):
        return True
    return False


def pick_summary(prompts):
    if not prompts:
        return "\u2014"
    for prompt in reversed(prompts):
        if not is_low_signal(prompt):
            return inline_text(prompt, 96)
    return inline_text(prompts[-1], 96)


def preview_entries(entries):
    meaningful = [(ts, text) for ts, text in entries if not is_low_signal(text)]
    chosen = meaningful or entries
    return list(reversed(chosen[-PREVIEW_LIMIT:])), bool(meaningful)


def build_search_blob(prompts, agent="", extra_text=""):
    cleaned = []
    seen = set()

    if extra_text:
        lead = normalize_summary(extra_text, agent)
        lead = " ".join(lead.replace("\t", " ").split())
        if lead and not is_low_signal(lead):
            cleaned.append(lead)
            seen.add(lead)

    for prompt in prompts:
        value = normalize_summary(prompt, agent)
        value = " ".join(value.replace("\t", " ").split())
        if not value or is_low_signal(value) or value in seen:
            continue
        cleaned.append(value)
        seen.add(value)

    if len(cleaned) > SEARCH_PROMPT_HEAD + SEARCH_PROMPT_TAIL:
        cleaned = cleaned[:SEARCH_PROMPT_HEAD] + cleaned[-SEARCH_PROMPT_TAIL:]

    parts = []
    total = 0
    for value in cleaned:
        added = len(value) + (1 if parts else 0)
        if total + added > SEARCH_TEXT_LIMIT:
            break
        parts.append(value)
        total += added
    return " ".join(parts)


# ── list ──────────────────────────────────────────────────────

def cmd_list(max_hours=168):
    now_ts = datetime.now(timezone.utc).timestamp()
    cutoff = now_ts - max_hours * 3600
    active = load_active_session_ids()

    # Claude Code
    claude = defaultdict(lambda: dict(
        first=float("inf"), last=0, project="", prompts=[]
    ))
    for e in safe_lines(CLAUDE_HISTORY):
        ts = e.get("timestamp", 0) / 1000
        if ts < cutoff:
            continue
        sid = e.get("sessionId", "")
        if not sid:
            continue
        s = claude[sid]
        s["first"] = min(s["first"], ts)
        s["last"]  = max(s["last"],  ts)
        s["project"] = e.get("project", "")
        d = e.get("display", "")
        if d:
            s["prompts"].append(d)

    # Codex — index
    codex_idx = {}
    for e in safe_lines(CODEX_INDEX):
        ua = e.get("updated_at", "")
        if not ua:
            continue
        try:
            dt = datetime.fromisoformat(ua.replace("Z", "+00:00"))
            ts = dt.timestamp()
        except (ValueError, AttributeError):
            continue
        if ts < cutoff:
            continue
        codex_idx[e["id"]] = dict(last=ts, name=e.get("thread_name", ""))

    # Codex — history prompts
    codex_hist = defaultdict(lambda: dict(first=float("inf"), last=0, prompts=[]))
    for e in safe_lines(CODEX_HISTORY):
        ts = e.get("ts", 0)
        if ts < cutoff:
            continue
        sid = e.get("session_id", "")
        if not sid:
            continue
        h = codex_hist[sid]
        h["first"] = min(h["first"], ts)
        h["last"]  = max(h["last"],  ts)
        t = e.get("text", "")
        if t:
            h["prompts"].append(t)

    # Merge
    rows = []

    for sid, s in claude.items():
        proj = s["project"].replace(str(HOME), "~")
        proj_short = proj.rsplit("/", 1)[-1] if proj else "\u2014"
        summary = inline_text(normalize_summary(pick_summary(s["prompts"]), "claude"), 96)
        search_blob = build_search_blob(s["prompts"], "claude", proj_short)
        status = "live" if sid in active else "done"
        rows.append((s["last"], sid, "claude", time_ago(s["last"]),
                      proj_short, summary, str(len(s["prompts"])), status, search_blob))

    for sid, ci in codex_idx.items():
        h = codex_hist.get(sid, dict(prompts=[]))
        name = inline_text(
            normalize_summary(ci["name"] or pick_summary(h.get("prompts", [])), "codex"),
            96,
        )
        search_blob = build_search_blob(h.get("prompts", []), "codex", ci["name"])
        pc = len(h.get("prompts", []))
        last = max(ci["last"], h.get("last", 0))
        rows.append((last, sid, "codex", time_ago(last),
                      "codex", name, str(pc) if pc else "\u2014", "done", search_blob))

    rows.sort(key=lambda r: r[0], reverse=True)

    for _, sid, agent, tago, proj, summary, turns, status, search_blob in rows:
        print(f"{sid}\t{agent}\t{tago}\t{proj}\t{summary}\t{turns}\t{status}\t{search_blob}")


# ── detail ────────────────────────────────────────────────────

def cmd_detail(session_id):
    # Claude
    prompts, project = [], ""
    for e in safe_lines(CLAUDE_HISTORY):
        if e.get("sessionId") != session_id:
            continue
        ts = e.get("timestamp", 0) / 1000
        d = e.get("display", "")
        project = e.get("project", "")
        if d:
            prompts.append((ts, d))

    if prompts:
        prompts.sort()
        proj = project.replace(str(HOME), "~")
        first = datetime.fromtimestamp(prompts[0][0], tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")
        last  = datetime.fromtimestamp(prompts[-1][0], tz=timezone.utc).astimezone().strftime("%H:%M")
        recent, used_meaningful = preview_entries(prompts)
        print("  Agent    claude")
        print(f"  Project  {proj}")
        print(f"  Time     {first} \u2014 {last}")
        print(f"  Turns    {len(prompts)}")
        print(f"  Latest   {inline_text(normalize_summary(pick_summary([text for _, text in prompts]), 'claude'), 180)}")
        print(f"  {'─' * 56}")
        print(f"  Recent {'meaningful turns' if used_meaningful else 'activity'}")
        for ts, text in recent:
            t = datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().strftime("%H:%M")
            print(f"  [{t}] {inline_text(normalize_summary(text, 'claude'), 180)}")
        if len(recent) < len(prompts):
            print(f"  {'─' * 56}")
            print(f"  Showing {len(recent)} of {len(prompts)} turns")
        return

    # Codex
    thread_name = ""
    for e in safe_lines(CODEX_INDEX):
        if e.get("id") == session_id:
            thread_name = e.get("thread_name", "")
            break

    for e in safe_lines(CODEX_HISTORY):
        if e.get("session_id") != session_id:
            continue
        ts = e.get("ts", 0)
        t = e.get("text", "")
        if t:
            prompts.append((ts, t))

    if prompts:
        prompts.sort()
        first = datetime.fromtimestamp(prompts[0][0], tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")
        last = datetime.fromtimestamp(prompts[-1][0], tz=timezone.utc).astimezone().strftime("%H:%M")
        recent, used_meaningful = preview_entries(prompts)
        print("  Agent    codex")
        print(f"  Thread   {inline_text(normalize_summary(thread_name, 'codex'), 120)}")
        print(f"  Time     {first} \u2014 {last}")
        print(f"  Turns    {len(prompts)}")
        print(f"  Latest   {inline_text(normalize_summary(pick_summary([text for _, text in prompts]), 'codex'), 180)}")
        print(f"  {'─' * 56}")
        print(f"  Recent {'meaningful turns' if used_meaningful else 'activity'}")
        for ts, text in recent:
            dt = datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().strftime("%H:%M")
            print(f"  [{dt}] {inline_text(normalize_summary(text, 'codex'), 180)}")
        if len(recent) < len(prompts):
            print(f"  {'─' * 56}")
            print(f"  Showing {len(recent)} of {len(prompts)} turns")
        return

    print(f"  No data found for session {session_id}")


def cmd_meta(session_id):
    project = ""
    for e in safe_lines(CLAUDE_HISTORY):
        if e.get("sessionId") != session_id:
            continue
        project = e.get("project", "")
        print(f"claude\t{project}\t{Path(project).name if project else ''}")
        return

    for e in safe_lines(CODEX_INDEX):
        if e.get("id") == session_id:
            print(f"codex\t\t{e.get('thread_name', '')}")
            return

    print("\t\t")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        cmd_list(int(sys.argv[2]) if len(sys.argv) > 2 else 168)
    elif cmd == "detail" and len(sys.argv) > 2:
        cmd_detail(sys.argv[2])
    elif cmd == "meta" and len(sys.argv) > 2:
        cmd_meta(sys.argv[2])
    else:
        cmd_list()
