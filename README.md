# tmux-autoname-agent-sessions

A tmux plugin that auto-renames windows running AI coding agents (Claude Code, Codex) to short, LLM-generated task descriptions.

```
1:cc|Fix Auth Middleware  2:cc|Add User Tests  3:zsh
```

## How it works

1. Tmux hooks detect when you switch windows or open new ones
2. The plugin walks the process tree to find `claude` or `codex` child processes
3. For Claude Code, it reads the first user prompt from the session JSONL
4. An LLM generates a 3-6 word English title via [OpenRouter](https://openrouter.ai/)
5. The window is renamed to `cc|<title>` or `cx|codex`
6. Titles are cached per session — each session triggers at most one API call
7. When the agent exits, `automatic-rename` is restored

Without an API key, titles fall back to the first few words of the prompt.

## Requirements

- tmux `>= 3.2`
- `python3`, `jq`, `curl`

## Install

### Human

Add to your `.tmux.conf`:

```tmux
set -g @plugin 'Luodian/tmux-autoname-agent-sessions'
```

Reload tmux and install with `prefix + I`.

Set your OpenRouter API key (optional, enables LLM-generated titles):

```bash
export OPENROUTER_API_KEY="sk-or-..."
```

### Agent

Add this to your project's `CLAUDE.md` or `AGENTS.md`:

```markdown
## tmux window auto-rename

This project uses [tmux-autoname-agent-sessions](https://github.com/Luodian/tmux-autoname-agent-sessions)
to auto-rename tmux windows based on the first user prompt in each AI session.

The plugin is installed via TPM. No action needed from agents — window titles
update automatically when Claude Code or Codex sessions start.

If window names look stale, run `prefix + R` or:

    ~/.tmux/plugins/tmux-autoname-agent-sessions/scripts/agent-rename.sh --clear
```

## Configuration

All options are optional.

```tmux
# Disable auto-rename (default: on)
set -g @autoname_enable 'off'

# Override the keybinding for manual refresh (default: R)
set -g @autoname_bind_rename 'R'

# OpenRouter model (default: openai/gpt-5.4-nano)
set -g @autoname_model 'openai/gpt-4.1-nano'

# API key via tmux option (alternative to OPENROUTER_API_KEY env var)
set -g @autoname_api_key 'sk-or-...'
```

## Usage

- Windows are renamed automatically — no manual action needed
- `prefix + R` refreshes all window names
- Titles are cached in `~/.cache/tmux-ai-rename/`
- `scripts/agent-rename.sh --clear` purges the cache

## License

MIT
