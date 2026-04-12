#!/usr/bin/env bash
# Quick help for tmux coding-agent workflows.

tmux_opt() {
  tmux show-option -gqv "$1" 2>/dev/null
}

live_key=$(tmux_opt '@autoname_bind_live')
history_key=$(tmux_opt '@autoname_bind_history')
help_key=$(tmux_opt '@autoname_bind_help')

live_key=${live_key:-a}
history_key=${history_key:-A}
help_key=${help_key:-i}

cat <<'EOF'
Coding Agents in tmux

Core shortcuts
EOF

printf '  prefix + %s   Live agent picker\n' "$live_key"
printf '  prefix + %s   Agent history / old records\n' "$history_key"
printf '  prefix + %s   This help\n' "$help_key"

cat <<'EOF'
  prefix + r   Reload tmux config

Live agent picker
  Type text to fuzzy search by pane, agent, window, or cwd.
  Enter        Jump to the selected pane
  Ctrl-H       Switch to history picker
  Ctrl-P       Pin / unpin the selected pane
  Ctrl-R       Reload live scan
  Ctrl-T       Toggle all agents / active-only
  Ctrl-O       Toggle compact / comfy density
  Ctrl-Y       Copy pane target + cwd
  Ctrl-E       Open a new tmux window at the pane cwd
  Ctrl-/       Toggle preview
  Alt-S        Filter to current session
  Alt-C/X/A/O  Filter to claude / codex / aider / opencode
  Alt-0        Clear quick filter
  Alt-J / K    Scroll preview down / up
  Alt-D / U    Half-page preview down / up

History / old records
  Type text to fuzzy search old sessions by summary, project, agent, or remembered prompt text.
  Enter        Resume the selected Claude or Codex session in a new tmux window
  Ctrl-G       Jump to a matching live pane, or open live picker with a smart filter
  Ctrl-L       Switch back to live picker
  Ctrl-R       Reload current history range
  Ctrl-O       Toggle compact / comfy density
  Ctrl-Y       Copy session id
  Ctrl-E       Open stored project path in a new tmux window (when available)
  Ctrl-/       Toggle preview
  Alt-S        Filter to current repo name
  Alt-C/X      Filter to claude / codex
  Alt-0        Clear quick filter
  Alt-J / K    Scroll preview down / up
  Alt-D / U    Half-page preview down / up

History range commands
  :24h         Last 24 hours
  :7d          Last 7 days
  :30d         Last 30 days
  :1y          Last year
  :all         All local history
  :today       Today
  :week        This week-sized range
  :month       This month-sized range

What gets searched
  Live picker searches coding-agent tmux panes.
  History searches local Claude Code and Codex session history files, including recent prompt text inside each session.

Tips
  If you only remember a repo name, type it in history search.
  If you only remember part of the prompt, type a distinctive phrase.
  Use Ctrl-P in live picker to pin a pane; pinned panes float to the top.
  Live picker also remembers recently jumped panes and nudges them upward automatically.
  Use Ctrl-O in either picker to switch between compact and comfy layouts.
  In live picker, `★` marks pinned panes and `↺` marks recently visited ones.
  In live picker, `·` reuses the agent/scope from the row above so your eye can scan targets faster.
  In history, `▸` marks the start of a project block, `·` reuses the agent/project from the row above, and `↳ same thread` marks repeated summaries.
EOF

printf '  Use prefix + %s for "where is the agent now", prefix + %s for "what did I work on before".\n' "$live_key" "$history_key"
