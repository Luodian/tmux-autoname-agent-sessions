#!/usr/bin/env bash
# Interactive fzf picker for historical coding-agent sessions.
# Reads local Claude Code + Codex history files. No API calls.
#
# Modes:
#   --lines <hours>                 print formatted fzf lines
#   --cmd <query> [range-file]      parse typed range command for fzf transform
#   --toggle-density <file> <hrs>   toggle list density for fzf reload

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$SCRIPT_DIR/agent-history.sh"
SELF_Q=$(printf '%q' "$SELF")

fzf_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/,/\\,/g'
}

toggle_density() {
  local state_file="$1"
  local hours="${2:-168}"
  local current_density="compact"
  local next_density preview_window
  [[ -f "$state_file" ]] && current_density=$(<"$state_file")
  if [[ "$current_density" == "comfy" ]]; then
    next_density="compact"
    preview_window='right,52%,border-left,wrap'
  else
    next_density="comfy"
    preview_window='right,46%,border-left,wrap'
  fi
  printf '%s' "$next_density" > "$state_file"
  printf 'reload(bash %s --lines %s --density %s)+change-preview-window(%s)' \
    "$SELF_Q" "$hours" "$next_density" "$preview_window"
}

print_lines() {
  local hours="${1:-168}"
  local density="${2:-compact}"
  local project_hint="${TMUX_AGENT_HISTORY_PROJECT_HINT:-}"
  local idx=0
  local sorted prev_agent="" prev_proj="" prev_summary=""

  sorted=$(
    python3 "$SCRIPT_DIR/agent-history-data.py" list "$hours" 2>/dev/null | \
    while IFS=$'\t' read -r sid agent tago proj summary turns status search_blob; do
      local project_rank status_rank sort_key
      idx=$((idx + 1))

      if [[ -n "$project_hint" && "$proj" == "$project_hint" ]]; then
        project_rank="0"
      else
        project_rank="1"
      fi

      if [[ "$status" == "live" ]]; then
        status_rank="0"
      else
        status_rank="1"
      fi

      sort_key="${project_rank}:${status_rank}:$(printf '%06d' "$idx")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$sort_key" "$sid" "$agent" "$tago" "$proj" "$turns" "$status" "$summary" "$search_blob"
    done | sort -t$'\t' -k1,1
  )

  [[ -n "$sorted" ]] || return 0

  while IFS=$'\t' read -r _ sid agent tago proj turns status summary search_blob; do
    local icon c_i c_t c_a c_p c_s c_repeat c_group c_turn display time_label
    local agent_label project_label summary_label turns_label group_prefix

    if [[ "$status" == "live" ]]; then
      icon='●'
      c_i='\033[32m'
      c_t='\033[32m'
      c_a='\033[33m'
      c_p='\033[96m'
      c_s='\033[37m'
      c_repeat='\033[38;5;66m'
      c_turn='\033[38;5;121m'
    else
      icon='○'
      c_i='\033[38;5;109m'
      c_t='\033[38;5;109m'
      c_a='\033[38;5;109m'
      c_p='\033[38;5;145m'
      c_s='\033[37m'
      c_repeat='\033[38;5;66m'
      c_turn='\033[38;5;66m'
    fi

    if [[ -n "$project_hint" && "$proj" == "$project_hint" ]]; then
      c_p='\033[96m'
    fi

    agent_label="$agent"
    group_prefix='▸'
    project_label="$proj"
    summary_label="$summary"
    turns_label="$turns"
    c_group='\033[38;5;220m'

    if [[ "$proj" == "$prev_proj" ]]; then
      group_prefix='·'
      project_label=''
      c_group="$c_repeat"
    fi

    if [[ "$agent" == "$prev_agent" && "$proj" == "$prev_proj" ]]; then
      agent_label='·'
      if [[ "$summary" == "$prev_summary" ]]; then
        summary_label='↳ same thread'
        c_s="$c_repeat"
      fi
      [[ "$density" == "compact" ]] && turns_label='·'
    fi

    time_label="${tago% ago}"
    if [[ "$density" == "comfy" ]]; then
      display=$(printf "${c_i}%s ${c_t}%-7s\033[0m  ${c_a}%-7s\033[0m  ${c_group}%s\033[0m ${c_p}%-14s\033[0m  ${c_turn}%4s\033[0m  ${c_s}%s\033[0m" \
        "$icon" "$time_label" "$agent_label" "$group_prefix" "$project_label" "$turns_label" "$summary_label")
    else
      display=$(printf "${c_i}%s ${c_t}%-7s\033[0m  ${c_a}%-7s\033[0m  ${c_group}%s\033[0m ${c_p}%-14s\033[0m  ${c_s}%s\033[0m" \
        "$icon" "$time_label" "$agent_label" "$group_prefix" "$project_label" "$summary_label")
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sid" "$agent" "$tago" "$proj" "$turns" "$status" "$summary" "$search_blob" "$display"

    prev_agent="$agent"
    prev_proj="$proj"
    prev_summary="$summary"
  done <<< "$sorted"
}

range_label_for_hours() {
  local hours="${1:-168}"
  if (( hours <= 24 )); then
    printf '24h'
  elif (( hours <= 168 )); then
    printf '7d'
  elif (( hours == 720 )); then
    printf '30d'
  elif (( hours == 8760 )); then
    printf '1y'
  elif (( hours >= 87600 )); then
    printf 'all'
  else
    printf '%sh' "$hours"
  fi
}

command_mode="interactive"
MAX_HOURS="168"
list_density="compact"
density_file=""

while (($#)); do
  case "$1" in
    --lines)
      command_mode="lines"
      MAX_HOURS="${2:-168}"
      shift 2
      ;;
    --toggle-density)
      command_mode="toggle-density"
      density_file="${2:-}"
      MAX_HOURS="${3:-168}"
      shift 3
      ;;
    --density)
      list_density="${2:-compact}"
      shift 2
      ;;
    --cmd)
      command_mode="cmd"
      break
      ;;
    *)
      if [[ "$command_mode" == "interactive" && "$1" != --* ]]; then
        MAX_HOURS="$1"
      fi
      shift
      ;;
  esac
done

if [[ "$command_mode" == "lines" ]]; then
  print_lines "$MAX_HOURS" "$list_density"
  exit 0
fi

if [[ "$command_mode" == "toggle-density" ]]; then
  toggle_density "$density_file" "$MAX_HOURS"
  exit 0
fi

if [[ "$command_mode" == "cmd" && "${1:-}" == "--cmd" ]]; then
  q="${2:-}"
  state_file="${3:-}"
  density_file="${4:-}"
  state_action=""
  density_arg=""
  if [[ -n "$density_file" && -f "$density_file" ]]; then
    density_arg=" --density $(<"$density_file")"
  fi
  case "$q" in
    :[0-9]*h)
      n="${q#:}"
      n="${n%h}"
      if [[ -n "$state_file" ]]; then
        state_action="+execute-silent(printf '%s' $n > $(printf '%q' "$state_file"))"
      fi
      echo "reload(bash $SELF --lines $n${density_arg})${state_action}+change-prompt(󰋚 ${n}h > )+clear-query" ;;
    :[0-9]*d)
      n="${q#:}"
      n="${n%d}"
      h=$((n * 24))
      if [[ -n "$state_file" ]]; then
        state_action="+execute-silent(printf '%s' $h > $(printf '%q' "$state_file"))"
      fi
      echo "reload(bash $SELF --lines $h${density_arg})${state_action}+change-prompt(󰋚 ${n}d > )+clear-query" ;;
    :[0-9]*w)
      n="${q#:}"
      n="${n%w}"
      h=$((n * 168))
      if [[ -n "$state_file" ]]; then
        state_action="+execute-silent(printf '%s' $h > $(printf '%q' "$state_file"))"
      fi
      echo "reload(bash $SELF --lines $h${density_arg})${state_action}+change-prompt(󰋚 ${n}w > )+clear-query" ;;
    :[0-9]*m)
      n="${q#:}"
      n="${n%m}"
      h=$((n * 720))
      if [[ -n "$state_file" ]]; then
        state_action="+execute-silent(printf '%s' $h > $(printf '%q' "$state_file"))"
      fi
      echo "reload(bash $SELF --lines $h${density_arg})${state_action}+change-prompt(󰋚 ${n}m > )+clear-query" ;;
    :[0-9]*y)
      n="${q#:}"
      n="${n%y}"
      h=$((n * 8760))
      if [[ -n "$state_file" ]]; then
        state_action="+execute-silent(printf '%s' $h > $(printf '%q' "$state_file"))"
      fi
      echo "reload(bash $SELF --lines $h${density_arg})${state_action}+change-prompt(󰋚 ${n}y > )+clear-query" ;;
    :all)
      if [[ -n "$state_file" ]]; then
        state_action="+execute-silent(printf '%s' 87600 > $(printf '%q' "$state_file"))"
      fi
      echo "reload(bash $SELF --lines 87600${density_arg})${state_action}+change-prompt(󰋚 all > )+clear-query" ;;
    :today)
      if [[ -n "$state_file" ]]; then
        state_action="+execute-silent(printf '%s' 24 > $(printf '%q' "$state_file"))"
      fi
      echo "reload(bash $SELF --lines 24${density_arg})${state_action}+change-prompt(󰋚 today > )+clear-query" ;;
    :week)
      if [[ -n "$state_file" ]]; then
        state_action="+execute-silent(printf '%s' 168 > $(printf '%q' "$state_file"))"
      fi
      echo "reload(bash $SELF --lines 168${density_arg})${state_action}+change-prompt(󰋚 week > )+clear-query" ;;
    :month)
      if [[ -n "$state_file" ]]; then
        state_action="+execute-silent(printf '%s' 720 > $(printf '%q' "$state_file"))"
      fi
      echo "reload(bash $SELF --lines 720${density_arg})${state_action}+change-prompt(󰋚 month > )+clear-query" ;;
  esac
  exit 0
fi

tmpdir=$(mktemp -d 2>/dev/null) || exit 1
trap 'rm -rf "$tmpdir"' EXIT
range_file="$tmpdir/range_hours"
density_file="$tmpdir/density"
printf '%s' "$MAX_HOURS" > "$range_file"
printf '%s' "$list_density" > "$density_file"
current_project=$(tmux display-message -p '#{b:pane_current_path}' 2>/dev/null || true)
current_project=${current_project:-}
current_project_bind=$(fzf_escape "$current_project")
export TMUX_AGENT_HISTORY_PROJECT_HINT="$current_project"
input=$(print_lines "$MAX_HOURS" "$list_density")
preview_q=$(printf '%q' "$SCRIPT_DIR/agent-history-preview.sh")
header_q=$(printf '%q' "$SCRIPT_DIR/agent-history-header.sh")
actions_q=$(printf '%q' "$SCRIPT_DIR/agent-actions.sh")
picker_q=$(printf '%q' "$SCRIPT_DIR/agent-picker.sh")

if [[ -z "$input" ]]; then
  tmux display-message "No agent sessions found in the last ${MAX_HOURS}h"
  exit 0
fi

range_label=$(range_label_for_hours "$MAX_HOURS")
total=$(printf '%s\n' "$input" | wc -l | tr -d ' ')

selected=$(
  printf '%s\n' "$input" | fzf --reverse \
    --ansi \
    --no-sort \
    --delimiter=$'\t' \
    --nth=2,3,4,7,8 \
    --with-nth=9 \
    --accept-nth=1,2 \
    --layout=reverse-list \
    --info=inline-right \
    --cycle \
    --keep-right \
    --scroll-off=2 \
    --border=rounded \
    --header-border=bottom \
    --border-label=' Agent History ' \
    --border-label-pos=3 \
    --footer=' enter resume · ctrl-g live · ctrl-l picker · ctrl-o density · :24h/:7d/:30d/:all ranges · ▸ project start ' \
    --footer-border=top \
    --footer-label=' Quick Keys ' \
    --footer-label-pos=3 \
    --preview-label=' Recent Turns ' \
    --preview-label-pos=3 \
    --preview="bash $preview_q {1}" \
    --preview-window='right,52%,border-left,wrap' \
    --bind="start:transform-header(bash $header_q $range_label $list_density {2} {3} {4} {5} {6} {7})" \
    --bind="focus:transform-header(bash $header_q \$(cat $range_file) \$(cat $density_file) {2} {3} {4} {5} {6} {7})" \
    --bind "change:transform:bash $SELF_Q --cmd {q} $range_file $density_file" \
    --bind="ctrl-g:become(bash $actions_q jump-history-live {1} {2})" \
    --bind="ctrl-l:become(bash $picker_q)" \
    --bind "ctrl-r:reload(bash $SELF_Q --lines \$(cat $range_file) --density \$(cat $density_file))" \
    --bind "ctrl-o:transform(bash $SELF_Q --toggle-density $density_file \$(cat $range_file))" \
    --bind 'ctrl-/:toggle-preview' \
    --bind="ctrl-y:execute-silent(bash $actions_q copy-history {1})" \
    --bind="ctrl-e:execute-silent(bash $actions_q open-history-project {1})" \
    --bind='alt-c:change-query(claude)' \
    --bind='alt-x:change-query(codex)' \
    --bind="alt-s:change-query(${current_project_bind})" \
    --bind='alt-0:clear-query' \
    --bind 'alt-j:preview-down,alt-k:preview-up,alt-d:preview-half-page-down,alt-u:preview-half-page-up' \
    --color='bg:#193549,fg:#ffffff,hl:#ffc600,fg+:#ffffff,bg+:#15506f,hl+:#ffd454,info:#4a7a96,prompt:#ffc600,pointer:#ffd454,marker:#ffd454,spinner:#4a7a96,header:#78b7d6,border:#2f6484' \
    --prompt="󰋚 ${range_label} > " \
    --pointer='▶' \
    --margin=1
)

[[ -z "$selected" ]] && exit 0

sid=$(printf '%s' "$selected" | cut -f1)
agent=$(printf '%s' "$selected" | cut -f2)

if [[ "$agent" == "claude" ]]; then
  tmux new-window -n "󰚩 resume" "claude --session-id '$sid' --dangerously-skip-permissions --effort max; exec bash"
elif [[ "$agent" == "codex" ]]; then
  tmux new-window -n "󰅩 resume" "codex --session '$sid'; exec bash"
else
  tmux display-message "Unsupported agent history entry: $agent"
fi
