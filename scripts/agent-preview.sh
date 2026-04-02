#!/usr/bin/env bash
# Preview helper for agent-picker.
# Receives PANE_ID as argv[1], then shows metadata and pane output.

pane_id="$1"
[[ -z "$pane_id" ]] && exit 0

fmt=$'#{pane_id}\t#{session_name}:#{window_index}.#{pane_index}\t#{?pane_active,active,inactive}\t#{pane_current_command}\t#{pane_current_path}'
meta=$(tmux display-message -p -t "$pane_id" "$fmt" 2>/dev/null)

if [[ -n "$meta" ]]; then
  IFS=$'\t' read -r pid target active_state current_cmd current_path <<< "$meta"
  printf '  Pane     %s\n' "$pid"
  printf '  Target   %s\n' "$target"
  printf '  State    %s\n' "$active_state"
  printf '  Command  %s\n' "$current_cmd"
  printf '  Path     %s\n\n' "$current_path"
fi

printf '  Recent pane output\n\n'
exec tmux capture-pane -ep -t "$pane_id" -S -60 2>&1
