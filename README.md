# tmux-coding-agents

A tmux plugin for finding AI coding sessions fast.

It gives you:

- **Auto-rename** — windows running Claude Code or Codex are renamed to an LLM-generated short title derived from the first user prompt
- A live pane picker for Claude, Codex, Aider, and OpenCode running inside tmux
- A history picker that reads local Claude Code and Codex session history
- Prompt-aware history search, so you can find a session by remembered user text
- A compact status-bar segment with per-session agent presence
- Small UX niceties like pinning, recent-pane weighting, preview panes, and dense or comfy layouts

The plugin is built for `tmux + fzf + python3`, and works best on tmux `3.2+` because it relies on `display-popup`.

## Features

- Auto-rename:
  - Detects Claude Code and Codex windows via the process tree
  - Reads the first user prompt from the Claude Code session JSONL
  - Calls an LLM (OpenRouter, configurable model) to generate a 3-6 word title
  - Caches titles per session so each session triggers at most one API call
  - Windows show `cc|Fix auth middleware` for Claude, `cx|codex` for Codex
  - Falls back to truncated prompt text when no API key is set
  - Restores `automatic-rename` when the AI session exits
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
- `jq` and `curl` (for auto-rename with LLM titles)
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
- `prefix + R` for manual AI rename refresh

Window auto-rename is enabled by default. If you have an [OpenRouter](https://openrouter.ai/) API key, titles are LLM-generated. Otherwise they fall back to the first few words of your prompt.

```bash
export OPENROUTER_API_KEY="sk-or-..."
```

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

### Auto-rename

```tmux
# Disable window auto-rename (default: on)
set -g @coding_agents_rename_enable 'off'

# OpenRouter model for title generation (default: openai/gpt-5.4-nano)
set -g @coding_agents_rename_model 'openai/gpt-4.1-nano'

# API key via tmux option (alternative to OPENROUTER_API_KEY env var)
set -g @coding_agents_rename_api_key 'sk-or-...'
```

### Keybindings

```tmux
set -g @coding_agents_bind_live 'a'
set -g @coding_agents_bind_history 'A'
set -g @coding_agents_bind_help 'i'
set -g @coding_agents_bind_rename 'R'
```

Set any of them to `off` to disable that binding.

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

### Auto-rename

Works automatically once the plugin is loaded. When you open Claude Code or Codex in a tmux window, the window title updates to a short description of the task:

```
1:cc|Fix Auth Middleware  2:cc|Add User Tests  3:zsh
```

- `prefix + R` refreshes all window names manually
- Titles are cached in `~/.cache/tmux-ai-rename/` (one file per session)
- Run `scripts/agent-rename.sh --clear` to purge the cache

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
