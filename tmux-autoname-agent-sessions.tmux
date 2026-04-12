#!/usr/bin/env bash
# TPM entry point for tmux-autoname-agent-sessions.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmux_opt() {
  local value
  value="$(tmux show-option -gqv "$1" 2>/dev/null)"
  printf '%s\n' "${value:-$2}"
}

normalize_key() {
  case "$1" in
    ''|off|none|disabled|disable) printf '\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# ── Window auto-rename (AI session → short title) ──────────

printf -v rename_cmd "bash %q" "$CURRENT_DIR/scripts/agent-rename.sh"
printf -v rename_current_cmd "bash %q --current" "$CURRENT_DIR/scripts/agent-rename.sh"

rename_enable="$(tmux_opt '@autoname_enable' 'on')"

if [[ "$rename_enable" == "on" ]]; then
  # Full scan on session switch; fast --current scan on window/pane switch.
  # Explicit [9] indices keep reloads idempotent (won't duplicate).
  tmux set-hook -g 'client-session-changed[9]' "run-shell -b \"$rename_cmd\""
  tmux set-hook -g 'after-new-window[9]'       "run-shell -b \"$rename_current_cmd\""
  tmux set-hook -g 'after-select-window[9]'    "run-shell -b \"$rename_current_cmd\""
  tmux set-hook -g 'after-select-pane[9]'      "run-shell -b \"$rename_current_cmd\""

  # Manual refresh: prefix + R
  rename_key="$(normalize_key "$(tmux_opt '@autoname_bind_rename' 'R')")"
  if [[ -n "$rename_key" ]]; then
    tmux bind-key "$rename_key" run-shell "$rename_cmd" \; display "AI window names refreshed"
  fi
else
  tmux set-hook -gu 'client-session-changed[9]' 2>/dev/null || true
  tmux set-hook -gu 'after-new-window[9]' 2>/dev/null || true
  tmux set-hook -gu 'after-select-window[9]' 2>/dev/null || true
  tmux set-hook -gu 'after-select-pane[9]' 2>/dev/null || true
fi
