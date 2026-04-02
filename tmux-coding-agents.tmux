#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmux_opt() {
  local option="$1"
  local default_value="$2"
  local value
  value="$(tmux show-option -gqv "$option" 2>/dev/null)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default_value"
  fi
}

normalize_key() {
  case "$1" in
    ''|off|none|disabled|disable)
      printf '\n'
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

bind_popup() {
  local key="$1"
  local width="$2"
  local height="$3"
  local command="$4"
  [[ -n "$key" ]] || return 0
  tmux bind-key "$key" display-popup -E -w "$width" -h "$height" "$command"
}

rebind_popup() {
  local option_name="$1"
  local state_name="$2"
  local default_key="$3"
  local width="$4"
  local height="$5"
  local command="$6"
  local key old_key

  key="$(normalize_key "$(tmux_opt "$option_name" "$default_key")")"
  old_key="$(tmux show-option -gqv "$state_name" 2>/dev/null)"

  if [[ -n "$old_key" && "$old_key" != "$key" ]]; then
    tmux unbind-key "$old_key" 2>/dev/null || true
  fi

  bind_popup "$key" "$width" "$height" "$command"
  tmux set-option -gq "$state_name" "$key"
}

prepend_status_segment() {
  local segment="$1"
  local current
  current="$(tmux show-option -gqv status-right 2>/dev/null)"
  if [[ "$current" == *"$CURRENT_DIR/scripts/coding-agents.sh"* ]]; then
    return 0
  fi
  if [[ -n "$current" ]]; then
    tmux set-option -gq status-right "$segment $current"
  else
    tmux set-option -gq status-right "$segment"
  fi
}

printf -v live_cmd "bash %q" "$CURRENT_DIR/scripts/agent-picker.sh"
printf -v history_cmd "bash %q" "$CURRENT_DIR/scripts/agent-history.sh"
printf -v help_cmd "bash %q" "$CURRENT_DIR/scripts/agent-help.sh"
printf -v status_segment "#(bash %q)" "$CURRENT_DIR/scripts/coding-agents.sh"

live_w="$(tmux_opt '@coding_agents_popup_live_width' '90%')"
live_h="$(tmux_opt '@coding_agents_popup_live_height' '84%')"
history_w="$(tmux_opt '@coding_agents_popup_history_width' '94%')"
history_h="$(tmux_opt '@coding_agents_popup_history_height' '88%')"
help_w="$(tmux_opt '@coding_agents_popup_help_width' '72%')"
help_h="$(tmux_opt '@coding_agents_popup_help_height' '70%')"

rebind_popup '@coding_agents_bind_live' '@coding_agents_bound_live' 'a' "$live_w" "$live_h" "$live_cmd"
rebind_popup '@coding_agents_bind_history' '@coding_agents_bound_history' 'A' "$history_w" "$history_h" "$history_cmd"
rebind_popup '@coding_agents_bind_help' '@coding_agents_bound_help' 'i' "$help_w" "$help_h" "$help_cmd"

tmux set-option -gq '@coding_agents_status_command' "$status_segment"

if [[ "$(tmux_opt '@coding_agents_status_enable' 'off')" == "on" ]]; then
  prepend_status_segment "$status_segment"
fi
