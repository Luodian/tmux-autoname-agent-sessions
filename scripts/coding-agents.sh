#!/usr/bin/env bash
# Detect coding agents in tmux panes via the shared scanner.
# Output: tmux-formatted status segment (Cobalt2 theme).

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

server_key=$(
  tmux display-message -p '#{socket_path}:#{pid}:#{start_time}' 2>/dev/null \
    | tr -cs 'A-Za-z0-9._-' '_'
)
CACHE="${TMPDIR:-/tmp}/.tmux-agents-${server_key:-default}-$(id -u)"
CACHE_TTL=3

if [[ -f "$CACHE" ]]; then
  age=$(( $(date +%s) - $(stat -f%m "$CACHE" 2>/dev/null || echo 0) ))
  if (( age < CACHE_TTL )); then
    cat "$CACHE"
    exit 0
  fi
fi

rendered=$(python3 "$SCRIPT_DIR/agent-scan.py" --status 2>/dev/null) || {
  [[ -f "$CACHE" ]] && cat "$CACHE"
  exit 0
}

tmp_cache="${CACHE}.tmp.$$"
printf '%s' "$rendered" > "$tmp_cache" && mv "$tmp_cache" "$CACHE"
printf '%s' "$rendered"
