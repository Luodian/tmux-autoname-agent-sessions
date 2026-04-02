# tmux-coding-agents

A tmux plugin for finding AI coding sessions fast.

It gives you:

- A live pane picker for Claude, Codex, Aider, and OpenCode running inside tmux
- A history picker that reads local Claude Code and Codex session history
- Prompt-aware history search, so you can find a session by remembered user text
- A compact status-bar segment with per-session agent presence
- Small UX niceties like pinning, recent-pane weighting, preview panes, and dense or comfy layouts

The plugin is built for `tmux + fzf + python3`, and works best on tmux `3.2+` because it relies on `display-popup`.

## Features

- Live picker:
  - Detects agent panes from the tmux process tree
  - Marks panes as `active` or `quiet`
  - Supports pinning with `Ctrl-P`
  - Remembers recently jumped panes and floats them upward
  - Supports `compact` and `comfy` density with `Ctrl-O`
- History picker:
  - Reads `~/.claude/history.jsonl`, `~/.claude/sessions`, `~/.codex/session_index.jsonl`, and `~/.codex/history.jsonl`
  - Searches summary, repo, agent name, and recent prompt text inside each session
  - Shows a structured preview with meaningful recent turns
  - Supports quick range filters like `:24h`, `:7d`, `:30d`, `:1y`, `:all`
- Status segment:
  - Optional tmux status-right integration
  - Renders a concise multi-session summary

## Requirements

- tmux `>= 3.2`
- `fzf`
- `python3`
- A Nerd Font is recommended for the icons, but not required

## Install with TPM

Add this to your `.tmux.conf`:

```tmux
set -g @plugin 'Luodian/tmux-coding-agents'
```

Then reload tmux and install plugins with `prefix + I`.

By default the plugin binds:

- `prefix + a` for the live picker
- `prefix + A` for history
- `prefix + i` for help

## Optional status bar integration

If you want the plugin to prepend its segment to `status-right`, add:

```tmux
set -g @coding_agents_status_enable 'on'
```

If you prefer manual control, use the generated command stored at:

```tmux
tmux show -gv @coding_agents_status_command
```

and insert that `#(...)` segment wherever you want in `status-right`.

## Configuration

All options are optional.

### Keybindings

```tmux
set -g @coding_agents_bind_live 'a'
set -g @coding_agents_bind_history 'A'
set -g @coding_agents_bind_help 'i'
```

Set any of them to `off` to disable that popup binding.

### Popup sizes

```tmux
set -g @coding_agents_popup_live_width '90%'
set -g @coding_agents_popup_live_height '84%'

set -g @coding_agents_popup_history_width '94%'
set -g @coding_agents_popup_history_height '88%'

set -g @coding_agents_popup_help_width '72%'
set -g @coding_agents_popup_help_height '70%'
```

### History path overrides

If your local history files live somewhere else, you can override them with environment variables before tmux starts:

```bash
export TMUX_CODING_AGENTS_CLAUDE_HISTORY="$HOME/.claude/history.jsonl"
export TMUX_CODING_AGENTS_CLAUDE_SESSIONS="$HOME/.claude/sessions"
export TMUX_CODING_AGENTS_CODEX_INDEX="$HOME/.codex/session_index.jsonl"
export TMUX_CODING_AGENTS_CODEX_HISTORY="$HOME/.codex/history.jsonl"
```

## Usage

### Live picker

- `Enter`: jump to the selected pane
- `Ctrl-H`: switch to history
- `Ctrl-P`: pin or unpin the selected pane
- `Ctrl-R`: reload the live scan
- `Ctrl-T`: toggle `all` and `active-only`
- `Ctrl-O`: toggle `compact` and `comfy`
- `Ctrl-Y`: copy `session:window.pane + cwd`
- `Ctrl-E`: open a new tmux window at that pane's cwd
- `Ctrl-/`: toggle preview
- `Alt-S`: filter to current session
- `Alt-C`, `Alt-X`, `Alt-A`, `Alt-O`: filter to `claude`, `codex`, `aider`, `opencode`
- `Alt-0`: clear the quick filter

### History picker

- Type any remembered prompt phrase to find a session by user text
- `Enter`: resume the selected Claude or Codex session
- `Ctrl-G`: jump to a matching live pane, or bridge into the live picker
- `Ctrl-L`: switch back to the live picker
- `Ctrl-R`: reload the current time range
- `Ctrl-O`: toggle `compact` and `comfy`
- `Ctrl-Y`: copy the session id
- `Ctrl-E`: open the stored project path in a new tmux window
- `Ctrl-/`: toggle preview
- `:24h`, `:7d`, `:30d`, `:1y`, `:all`: switch history range

## Lint

```bash
make lint
```

## Notes

- Live pane detection is heuristic. It walks each pane's descendant process tree.
- `active` and `quiet` are pane-local activity hints, not ground-truth model execution states.
- History search is prompt-aware, but still intentionally bounded so the picker stays fast.

## License

MIT
