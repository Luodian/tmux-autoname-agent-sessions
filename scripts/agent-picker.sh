#!/usr/bin/env bash
# Interactive fzf picker for coding agents in tmux panes.
# Supports:
#   --list [mode]            Print formatted fzf input
#   --toggle-mode <file>     Toggle live filter mode for fzf reload
#   --toggle-density <file>  Toggle list density for fzf reload
#   --density <mode>         compact | comfy
#   --query <text>           Start interactive picker with a preset query
#   default                  Launch interactive picker and switch to selected pane

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_Q=$(printf '%q' "$SCRIPT_DIR/agent-picker.sh")

fzf_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/,/\\,/g'
}

print_empty_message() {
  tmux display-message "No coding agents detected in tmux panes"
}

pins_file() {
  local ctx key dir
  ctx=$(tmux display-message -p $'#{socket_path}\t#{pid}\t#{start_time}' 2>/dev/null || true)
  [[ -n "$ctx" ]] || return 1
  dir="${TMPDIR:-/tmp}/tmux-agent-scan-$(id -u)"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  key=$(printf '%s' "$ctx" | cksum | awk '{print $1}')
  printf '%s/pins-%s.txt\n' "$dir" "$key"
}

recent_file() {
  local ctx key dir
  ctx=$(tmux display-message -p $'#{socket_path}\t#{pid}\t#{start_time}' 2>/dev/null || true)
  [[ -n "$ctx" ]] || return 1
  dir="${TMPDIR:-/tmp}/tmux-agent-scan-$(id -u)"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  key=$(printf '%s' "$ctx" | cksum | awk '{print $1}')
  printf '%s/recent-%s.tsv\n' "$dir" "$key"
}

toggle_mode() {
  local state_file="$1"
  local current_mode="all"
  local next_mode
  [[ -f "$state_file" ]] && current_mode=$(<"$state_file")
  if [[ "$current_mode" == "active" ]]; then
    next_mode="all"
  else
    next_mode="active"
  fi
  printf '%s' "$next_mode" > "$state_file"
  printf 'reload(bash %s --list %s)+change-prompt(󰚩 %s > )' "$SELF_Q" "$next_mode" "$next_mode"
}

toggle_density() {
  local state_file="$1"
  local mode="${2:-all}"
  local current_density="compact"
  local next_density preview_window
  [[ -f "$state_file" ]] && current_density=$(<"$state_file")
  if [[ "$current_density" == "comfy" ]]; then
    next_density="compact"
    preview_window='right,54%,border-left,wrap'
  else
    next_density="comfy"
    preview_window='right,48%,border-left,wrap'
  fi
  printf '%s' "$next_density" > "$state_file"
  printf 'reload(bash %s --list %s --density %s)+change-preview-window(%s)' \
    "$SELF_Q" "$mode" "$next_density" "$preview_window"
}

recent_age_for_pane() {
  local pane_id="$1"
  local recent_path="$2"
  local now_ts="$3"
  local ts
  if [[ -n "$recent_path" && -f "$recent_path" ]]; then
    ts=$(awk -F'\t' -v pane="$pane_id" '$1 == pane {print $2; exit}' "$recent_path")
  else
    ts=""
  fi
  case "$ts" in
    ''|*[!0-9]*)
      printf '9999999999'
      ;;
    *)
      if (( ts > now_ts )); then
        printf '0000000000'
      else
        printf '%010d' "$((now_ts - ts))"
      fi
      ;;
  esac
}

print_list() {
  local mode="${1:-all}"
  local density="${2:-compact}"
  local scan
  local current_session current_pane pins_path pins_blob recent_path now_ts
  local sorted prev_agent="" prev_scope=""
  if ! scan=$(python3 "${SCRIPT_DIR}/agent-scan.py" 2>/dev/null) || [[ -z "$scan" ]]; then
    return 1
  fi

  current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
  current_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)
  pins_path=$(pins_file 2>/dev/null || true)
  if [[ -n "$pins_path" && -f "$pins_path" ]]; then
    pins_blob=$'\n'"$(tr -d '\r' < "$pins_path" 2>/dev/null)"$'\n'
  else
    pins_blob=$'\n'
  fi
  recent_path=$(recent_file 2>/dev/null || true)
  now_ts=$(date +%s 2>/dev/null)
  [[ -n "$now_ts" ]] || now_ts=0

  sorted=$(
    while IFS=$'\t' read -r pane_id session window pane_idx agent state cwd wname; do
      local target sort_key recent_rank
      local pin_rank state_rank session_rank pane_rank
      local project_label scope_label
      target="${session}:${window}.${pane_idx}"

      [[ "$mode" == "active" && "$state" != "active" ]] && continue

      if [[ "$pins_blob" == *$'\n'"$pane_id"$'\n'* ]]; then
        pin_rank="0"
      else
        pin_rank="1"
      fi

      if [[ "$state" == "active" ]]; then
        state_rank="0"
      else
        state_rank="1"
      fi

      if [[ "$session" == "$current_session" ]]; then
        session_rank="0"
      else
        session_rank="1"
      fi

      if [[ "$pane_id" == "$current_pane" ]]; then
        pane_rank="0"
      else
        pane_rank="1"
      fi

      recent_rank=$(recent_age_for_pane "$pane_id" "$recent_path" "$now_ts")

      project_label="${cwd##*/}"
      [[ -n "$project_label" ]] || project_label="$cwd"
      [[ "$cwd" == "~" ]] && project_label="~"
      if [[ -n "$wname" && "$wname" != "$project_label" && "$wname" != "$session" ]]; then
        scope_label="${wname} · ${project_label}"
      else
        scope_label="${project_label:-$wname}"
      fi
      [[ -n "$scope_label" ]] || scope_label="$session"

      sort_key="${pin_rank}:${pane_rank}:${state_rank}:${recent_rank}:${session_rank}:${session}:${window}:${pane_idx}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$sort_key" "$pane_id" "$agent" "$state" "$target" "$scope_label" "$cwd" "$recent_rank"
    done <<< "$scan" | sort -t$'\t' -k1,1 -k2,2
  )

  [[ -n "$sorted" ]] || return 0

  while IFS=$'\t' read -r _ pane_id agent state target scope_label cwd recent_rank; do
    local icon c_i c_t c_a c_scope c_path display
    local marker pin_mark recent_mark c_m c_pn c_recent
    local agent_label scope_display path_display
    local recent_age

    if [[ "$pins_blob" == *$'\n'"$pane_id"$'\n'* ]]; then
      pin_mark='★'
      c_pn='\033[38;5;220m'
    else
      pin_mark=' '
      c_pn='\033[90m'
    fi

    recent_age=$((10#${recent_rank:-9999999999}))
    if (( recent_age <= 43200 )); then
      recent_mark='↺'
      c_recent='\033[38;5;214m'
    elif (( recent_age <= 259200 )); then
      recent_mark='•'
      c_recent='\033[38;5;109m'
    else
      recent_mark=' '
      c_recent='\033[90m'
    fi

    if [[ "$state" == "active" ]]; then
      icon='●'
      c_i='\033[32m'
      c_t='\033[36m'
      c_a='\033[33m'
      c_scope='\033[96m'
      c_path='\033[38;5;152m'
    else
      icon='○'
      c_i='\033[38;5;109m'
      c_t='\033[38;5;109m'
      c_a='\033[38;5;109m'
      c_scope='\033[38;5;145m'
      c_path='\033[38;5;66m'
    fi

    if [[ "$pane_id" == "$current_pane" ]]; then
      marker='›'
      c_m='\033[38;5;220m'
    else
      marker=' '
      c_m='\033[90m'
    fi

    agent_label="$agent $icon"
    scope_display="$scope_label"
    path_display="$cwd"

    if [[ "$agent" == "$prev_agent" && "$scope_label" == "$prev_scope" ]]; then
      agent_label="· $icon"
      scope_display='·'
      [[ "$density" == "compact" ]] && path_display='·'
    fi

    if [[ "$density" == "comfy" ]]; then
      display=$(printf "${c_m}%s\033[0m ${c_pn}%s\033[0m ${c_recent}%s\033[0m ${c_t}%-19s\033[0m \033[90m│\033[0m ${c_a}%-10s\033[0m \033[90m│\033[0m ${c_scope}%-20s\033[0m \033[90m│\033[0m ${c_path}%s\033[0m" \
        "$marker" "$pin_mark" "$recent_mark" "$target" "$agent_label" "$scope_display" "$path_display")
    else
      display=$(printf "${c_m}%s\033[0m ${c_pn}%s\033[0m ${c_recent}%s\033[0m ${c_t}%-19s\033[0m \033[90m│\033[0m ${c_a}%-10s\033[0m \033[90m│\033[0m ${c_scope}%s\033[0m" \
        "$marker" "$pin_mark" "$recent_mark" "$target" "$agent_label" "$scope_display")
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$pane_id" "$agent" "$state" "$target" "$scope_label" "$cwd" "$display"

    prev_agent="$agent"
    prev_scope="$scope_label"
  done <<< "$sorted"
}

command_mode="interactive"
list_mode="all"
toggle_file=""
density_file=""
list_density="compact"
initial_query=""

while (($#)); do
  case "$1" in
    --list)
      command_mode="list"
      if [[ $# -ge 2 && "${2:-}" != --* ]]; then
        list_mode="$2"
        shift 2
      else
        shift
      fi
      ;;
    --toggle-mode)
      command_mode="toggle"
      toggle_file="${2:-}"
      shift 2
      ;;
    --toggle-density)
      command_mode="toggle-density"
      density_file="${2:-}"
      if [[ $# -ge 3 && "${3:-}" != --* ]]; then
        list_mode="$3"
        shift 3
      else
        shift 2
      fi
      ;;
    --density)
      list_density="${2:-compact}"
      shift 2
      ;;
    --query)
      initial_query="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$command_mode" == "list" ]]; then
  print_list "$list_mode" "$list_density"
  exit $?
fi

if [[ "$command_mode" == "toggle" ]]; then
  toggle_mode "$toggle_file"
  exit 0
fi

if [[ "$command_mode" == "toggle-density" ]]; then
  toggle_density "$density_file" "$list_mode"
  exit 0
fi

tmpdir=$(mktemp -d 2>/dev/null) || exit 1
trap 'rm -rf "$tmpdir"' EXIT
mode_file="$tmpdir/live_mode"
density_file="$tmpdir/live_density"
printf 'all' > "$mode_file"
printf 'compact' > "$density_file"

input=$(print_list "all" "compact")
if [[ -z "$input" ]]; then
  print_empty_message
  exit 0
fi

current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
current_session=${current_session:-}
current_session_bind=$(fzf_escape "$current_session")
preview_q=$(printf '%q' "$SCRIPT_DIR/agent-preview.sh")
header_q=$(printf '%q' "$SCRIPT_DIR/agent-picker-header.sh")
history_q=$(printf '%q' "$SCRIPT_DIR/agent-history.sh")
actions_q=$(printf '%q' "$SCRIPT_DIR/agent-actions.sh")

selected=$(printf '%s\n' "$input" | fzf --reverse \
  --ansi \
  --no-sort \
  --delimiter=$'\t' \
  --nth=2,3,4,5,6 \
  --with-nth=7 \
  --accept-nth=1 \
  --layout=reverse-list \
  --info=inline-right \
  --cycle \
  --keep-right \
  --scroll-off=2 \
  --header-border=bottom \
  --border-label=' Coding Agents ' \
  --border-label-pos=3 \
  --footer=' enter jump · ctrl-h history · ctrl-p pin · ctrl-t active · ctrl-o density · ctrl-/ preview · ★ pinned · ↺ recent ' \
  --footer-border=top \
  --footer-label=' Quick Keys ' \
  --footer-label-pos=3 \
  --preview-label=' Live Pane ' \
  --preview-label-pos=3 \
  --preview="bash $preview_q {1}" \
  --preview-window='right,54%,border-left,wrap' \
  --bind="start:transform-header(bash $header_q all compact {2} {3} {4} {5} {6})" \
  --bind="focus:transform-header(bash $header_q \$(cat $mode_file) \$(cat $density_file) {2} {3} {4} {5} {6})" \
  --bind="ctrl-h:become(bash $history_q)" \
  --bind="ctrl-r:reload(bash $SELF_Q --list \$(cat $mode_file) --density \$(cat $density_file))" \
  --bind="ctrl-t:transform(bash $SELF_Q --toggle-mode $mode_file)" \
  --bind="ctrl-o:transform(bash $SELF_Q --toggle-density $density_file \$(cat $mode_file))" \
  --bind="ctrl-p:execute-silent(bash $actions_q toggle-live-pin {1})+reload(bash $SELF_Q --list \$(cat $mode_file) --density \$(cat $density_file))" \
  --bind='ctrl-/:toggle-preview' \
  --bind="ctrl-y:execute-silent(bash $actions_q copy-live {1})" \
  --bind="ctrl-e:execute-silent(bash $actions_q open-live-cwd {1})" \
  --bind="alt-s:change-query(${current_session_bind})" \
  --bind='alt-c:change-query(claude)' \
  --bind='alt-x:change-query(codex)' \
  --bind='alt-a:change-query(aider)' \
  --bind='alt-o:change-query(opencode)' \
  --bind='alt-0:clear-query' \
  --bind='alt-j:preview-down,alt-k:preview-up,alt-d:preview-half-page-down,alt-u:preview-half-page-up' \
  --color='bg:#193549,fg:#ffffff,hl:#ffc600,fg+:#ffffff,bg+:#15506f,hl+:#ffd454,info:#4a7a96,prompt:#ffc600,pointer:#ffd454,marker:#ffd454,spinner:#4a7a96,header:#78b7d6,border:#2f6484' \
  --border=rounded \
  --prompt='󰚩 all > ' \
  --query="$initial_query" \
  --pointer='▶' \
  --margin=1)

[[ -z "$selected" ]] && exit 0

exec bash "$SCRIPT_DIR/agent-actions.sh" jump-live "$selected"
