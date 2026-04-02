#!/usr/bin/env bash
# Small actions used by tmux coding-agent pickers.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cache_dir() {
  local dir="${TMPDIR:-/tmp}/tmux-agent-scan-$(id -u)"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

tmux_context_key() {
  local ctx
  ctx=$(tmux display-message -p $'#{socket_path}\t#{pid}\t#{start_time}' 2>/dev/null)
  [[ -n "$ctx" ]] || return 1
  printf '%s' "$ctx" | cksum | awk '{print $1}'
}

pins_file() {
  local key
  key=$(tmux_context_key) || return 1
  printf '%s/pins-%s.txt\n' "$(cache_dir)" "$key"
}

recent_file() {
  local key
  key=$(tmux_context_key) || return 1
  printf '%s/recent-%s.tsv\n' "$(cache_dir)" "$key"
}

dedupe_lines() {
  local path="$1"
  local tmp="${path}.tmp.$$"
  [[ -f "$path" ]] || return 0
  awk 'NF && !seen[$0]++' "$path" > "$tmp" && mv "$tmp" "$path"
  rm -f "$tmp"
}

pane_target() {
  tmux display-message -p -t "$1" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null
}

record_recent_pane() {
  local pane_id="$1"
  local file now tmp
  [[ -n "$pane_id" ]] || return 1
  file=$(recent_file) || return 1
  now=$(date +%s 2>/dev/null)
  [[ -n "$now" ]] || now=0
  tmp="${file}.tmp.$$"
  {
    printf '%s\t%s\n' "$pane_id" "$now"
    [[ -f "$file" ]] && awk -F'\t' -v pane="$pane_id" 'NF && $1 != pane' "$file"
  } > "$tmp"
  mv "$tmp" "$file"
}

expand_home() {
  local value="$1"
  if [[ "$value" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ "$value" == "~/"* ]]; then
    printf '%s\n' "${HOME}/${value:2}"
  else
    printf '%s\n' "$value"
  fi
}

jump_to_live_pane() {
  local pane_id="$1"
  local target_window
  target_window=$(tmux display-message -p -t "$pane_id" '#{session_name}:#{window_index}' 2>/dev/null)
  if [[ -z "$target_window" ]]; then
    tmux display-message "Pane no longer exists: $pane_id"
    return 1
  fi
  record_recent_pane "$pane_id" >/dev/null 2>&1 || true
  tmux switch-client -t "$target_window" 2>/dev/null \
    && tmux select-pane -t "$pane_id" 2>/dev/null \
    || tmux display-message "Unable to jump to $pane_id"
}

copy_text() {
  local text="$1"
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$text" | pbcopy
  else
    tmux set-buffer -- "$text"
  fi
}

copy_live() {
  local pane_id="$1"
  local target cwd payload
  target=$(pane_target "$pane_id")
  cwd=$(tmux display-message -p -t "$pane_id" '#{pane_current_path}' 2>/dev/null)
  [[ -z "$target" ]] && { tmux display-message "Pane no longer exists: $pane_id"; return 1; }
  payload="${target}  ${cwd}"
  copy_text "$payload"
  tmux display-message "Copied ${target}"
}

open_live_cwd() {
  local pane_id="$1"
  local cwd
  cwd=$(tmux display-message -p -t "$pane_id" '#{pane_current_path}' 2>/dev/null)
  [[ -z "$cwd" ]] && { tmux display-message "Pane no longer exists: $pane_id"; return 1; }
  tmux new-window -c "$cwd"
}

toggle_live_pin() {
  local pane_id="$1"
  local target file tmp
  target=$(pane_target "$pane_id")
  [[ -z "$target" ]] && { tmux display-message "Pane no longer exists: $pane_id"; return 1; }
  file=$(pins_file) || { tmux display-message "Unable to access pin cache"; return 1; }
  touch "$file"
  dedupe_lines "$file"
  if grep -Fxq "$pane_id" "$file"; then
    tmp="${file}.tmp.$$"
    grep -Fxv "$pane_id" "$file" > "$tmp" || true
    mv "$tmp" "$file"
    tmux display-message "Unpinned ${target}"
  else
    printf '%s\n' "$pane_id" >> "$file"
    dedupe_lines "$file"
    tmux display-message "Pinned ${target}"
  fi
}

jump_live() {
  local pane_id="$1"
  [[ -n "$pane_id" ]] || return 1
  jump_to_live_pane "$pane_id"
}

copy_history() {
  local session_id="$1"
  [[ -z "$session_id" ]] && return 1
  copy_text "$session_id"
  tmux display-message "Copied session id"
}

open_history_project() {
  local session_id="$1"
  local meta agent project
  meta=$(python3 "$SCRIPT_DIR/agent-history-data.py" meta "$session_id" 2>/dev/null) || meta=""
  agent=$(printf '%s' "$meta" | cut -f1)
  project=$(printf '%s' "$meta" | cut -f2)
  if [[ -z "$project" || ! -d "$project" ]]; then
    tmux display-message "No local project path stored for ${agent:-session}"
    return 1
  fi
  tmux new-window -c "$project"
}

resolve_history_live() {
  local session_id="$1"
  local agent_hint="$2"
  local meta agent project query_hint scan
  local current_session pane_id session window pane_idx live_agent state cwd wname abs_cwd
  local match_count=0 lone_match="" best_id="" best_score=-1 score

  meta=$(python3 "$SCRIPT_DIR/agent-history-data.py" meta "$session_id" 2>/dev/null) || meta=""
  agent=$(printf '%s' "$meta" | cut -f1)
  project=$(printf '%s' "$meta" | cut -f2)
  query_hint=$(printf '%s' "$meta" | cut -f3-)
  [[ -n "$agent_hint" ]] && agent="$agent_hint"

  if [[ -z "$agent" ]]; then
    echo $'error\tNo history metadata for session'
    return 1
  fi

  if [[ -z "$project" ]]; then
    query_hint="$agent"
  fi

  scan=$(python3 "$SCRIPT_DIR/agent-scan.py" 2>/dev/null) || scan=""
  if [[ -z "$scan" ]]; then
    printf 'query\t%s\n' "${query_hint:-$agent}"
    return 0
  fi

  current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)

  if [[ -n "$project" ]]; then
    while IFS=$'\t' read -r pane_id session window pane_idx live_agent state cwd wname; do
      [[ "$live_agent" == "$agent" ]] || continue
      abs_cwd=$(expand_home "$cwd")
      if [[ "$abs_cwd" == "$project" ]]; then
        score=100
      elif [[ "$abs_cwd" == "$project/"* ]]; then
        score=90
      else
        continue
      fi
      [[ "$state" == "active" ]] && score=$((score + 10))
      [[ "$session" == "$current_session" ]] && score=$((score + 5))
      if (( score > best_score )); then
        best_score=$score
        best_id="$pane_id"
      fi
    done <<< "$scan"

    if [[ -n "$best_id" ]]; then
      printf 'pane\t%s\n' "$best_id"
      return 0
    fi

    query_hint=$(basename "$project")
  fi

  while IFS=$'\t' read -r pane_id session window pane_idx live_agent state cwd wname; do
    [[ "$live_agent" == "$agent" ]] || continue
    match_count=$((match_count + 1))
    lone_match="$pane_id"
  done <<< "$scan"

  if (( match_count == 1 )); then
    printf 'pane\t%s\n' "$lone_match"
    return 0
  fi

  printf 'query\t%s\n' "${query_hint:-$agent}"
}

jump_history_live() {
  local session_id="$1"
  local agent_hint="$2"
  local resolution kind value

  resolution=$(resolve_history_live "$session_id" "$agent_hint") || {
    tmux display-message "${resolution#*$'\t'}"
    return 1
  }
  kind=$(printf '%s' "$resolution" | cut -f1)
  value=$(printf '%s' "$resolution" | cut -f2-)

  case "$kind" in
    pane)
      jump_to_live_pane "$value"
      ;;
    query)
      exec bash "$SCRIPT_DIR/agent-picker.sh" --query "$value"
      ;;
    *)
      tmux display-message "Unable to bridge history to live pane"
      return 1
      ;;
  esac
}

case "${1:-}" in
  copy-live) shift; copy_live "$@" ;;
  jump-live) shift; jump_live "$@" ;;
  open-live-cwd) shift; open_live_cwd "$@" ;;
  toggle-live-pin) shift; toggle_live_pin "$@" ;;
  copy-history) shift; copy_history "$@" ;;
  open-history-project) shift; open_history_project "$@" ;;
  resolve-history-live) shift; resolve_history_live "$@" ;;
  jump-history-live) shift; jump_history_live "$@" ;;
  *)
    echo "usage: $0 {copy-live|jump-live|open-live-cwd|toggle-live-pin|copy-history|open-history-project|resolve-history-live|jump-history-live} <id>" >&2
    exit 1
    ;;
esac
