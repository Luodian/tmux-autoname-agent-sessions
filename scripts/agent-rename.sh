#!/usr/bin/env bash
# Auto-rename tmux windows running Claude Code or Codex to show an
# LLM-generated short title derived from the first user prompt.
#
# Uses a configurable OpenRouter model for one-shot summarisation,
# cached locally so each session triggers at most one API call.
#
# Usage:
#   agent-rename.sh              # scan all windows
#   agent-rename.sh --current    # scan only the current window (fast, for hooks)
#   agent-rename.sh --clear      # clear title cache

set -euo pipefail

CLAUDE_SESSIONS="${HOME}/.claude/sessions"
CLAUDE_PROJECTS="${HOME}/.claude/projects"
CACHE_DIR="${HOME}/.cache/tmux-ai-rename"
FALLBACK_MAX=12

mkdir -p "$CACHE_DIR"

# ── config from tmux options ────────────────────────────────

tmux_opt() {
  tmux show-option -gqv "$1" 2>/dev/null || true
}

RENAME_MODEL=$(tmux_opt '@coding_agents_rename_model')
: "${RENAME_MODEL:=openai/gpt-5.4-nano}"

API_KEY="${OPENROUTER_API_KEY:-$(tmux_opt '@coding_agents_rename_api_key')}"

# ── process tree helpers ────────────────────────────────────

PS_SNAPSHOT=$(ps -axo pid,ppid,comm 2>/dev/null)

child_by_name() {
  echo "$PS_SNAPSHOT" \
    | awk -v ppid="$1" -v name="$2" '$2 == ppid && $3 == name { print $1; exit }'
}

# ── Claude session reading ──────────────────────────────────

get_session_id() {
  local session_file="${CLAUDE_SESSIONS}/${1}.json"
  [[ -f "$session_file" ]] || return 1
  jq -r '.sessionId' "$session_file" 2>/dev/null
}

get_cwd_short() {
  local session_file="${CLAUDE_SESSIONS}/${1}.json"
  [[ -f "$session_file" ]] || return 1
  jq -r '.cwd | split("/") | last' "$session_file" 2>/dev/null
}

# Extract the first user message from a Claude session JSONL file.
get_raw_prompt() {
  local claude_pid="$1"
  local session_file="${CLAUDE_SESSIONS}/${claude_pid}.json"
  [[ -f "$session_file" ]] || return 1

  local session_id cwd project_dir jsonl
  session_id=$(jq -r '.sessionId' "$session_file" 2>/dev/null) || return 1
  cwd=$(jq -r '.cwd' "$session_file" 2>/dev/null) || return 1

  project_dir=$(echo "$cwd" | tr '/.' '--')
  jsonl="${CLAUDE_PROJECTS}/${project_dir}/${session_id}.jsonl"
  if [[ ! -f "$jsonl" ]]; then
    jsonl=$(find "$CLAUDE_PROJECTS" -name "${session_id}.jsonl" 2>/dev/null | head -1)
    [[ -n "$jsonl" ]] || return 1
  fi

  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        try:
            entry = json.loads(line)
        except Exception:
            continue
        if entry.get('type') != 'user':
            continue
        content = entry.get('message', {}).get('content', '')
        if isinstance(content, list):
            for item in content:
                if isinstance(item, dict) and item.get('type') == 'text':
                    content = item['text']
                    break
        if isinstance(content, str) and content.strip():
            print(content.strip()[:200])
            sys.exit(0)
sys.exit(1)
" "$jsonl" 2>/dev/null
}

# ── title generation ────────────────────────────────────────

get_title() {
  local claude_pid="$1"
  local session_id
  session_id=$(get_session_id "$claude_pid") || return 1

  # Return cached title if available.
  local cache_file="${CACHE_DIR}/${session_id}"
  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return 0
  fi

  local raw
  raw=$(get_raw_prompt "$claude_pid") || return 1
  [[ -n "$raw" ]] || return 1

  # Without an API key, fall back to truncated prompt text.
  if [[ -z "$API_KEY" ]]; then
    echo "${raw:0:$FALLBACK_MAX}" | tee "$cache_file"
    return 0
  fi

  local escaped_prompt
  escaped_prompt=$(printf '%s' "$raw" \
    | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")

  local response
  response=$(curl -s --max-time 5 https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$RENAME_MODEL\",
      \"max_tokens\": 24,
      \"temperature\": 0,
      \"messages\": [
        {\"role\": \"system\", \"content\": \"Generate a 3-6 word English window title for this task. Rules: always English regardless of input language, include key nouns and action, no quotes, no punctuation, max 35 characters.\"},
        {\"role\": \"user\", \"content\": $escaped_prompt}
      ]
    }" 2>/dev/null) || true

  local title
  title=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

  if [[ -n "$title" ]]; then
    echo "$title" | tee "$cache_file"
  else
    echo "${raw:0:$FALLBACK_MAX}" | tee "$cache_file"
  fi
}

# ── window labelling ────────────────────────────────────────

label_window() {
  local window_id="$1" prefix="$2" desc="$3" ai_pid="$4"
  # Skip if this window is already labelled for the same PID.
  local current
  current=$(tmux show-options -wv -t "$window_id" @ai_pid 2>/dev/null || true)
  [[ "$current" != "$ai_pid" ]] || return 0

  tmux set-option -w -t "$window_id" automatic-rename off 2>/dev/null || true
  tmux set-option -w -t "$window_id" @ai_pid "$ai_pid" 2>/dev/null || true
  local name="$desc"
  [[ -z "$prefix" ]] || name="${prefix} ${desc}"
  tmux rename-window -t "$window_id" "$name" 2>/dev/null || true
}

unlabel_window() {
  local window_id="$1"
  local was_ai
  was_ai=$(tmux show-options -wv -t "$window_id" @ai_pid 2>/dev/null || true)
  [[ -n "$was_ai" ]] || return 0
  tmux set-option -wu -t "$window_id" @ai_pid 2>/dev/null || true
  tmux set-option -w -t "$window_id" automatic-rename on 2>/dev/null || true
}

# ── main ────────────────────────────────────────────────────

if [[ "${1:-}" == "--clear" ]]; then
  rm -rf "${CACHE_DIR:?}/"*
  echo "Title cache cleared."
  exit 0
fi

if [[ "${1:-}" == "--current" ]]; then
  pane_list=$(tmux list-panes -F '#{pane_pid} #{window_id}' 2>/dev/null)
  window_list=$(tmux display-message -p '#{window_id}')
else
  pane_list=$(tmux list-panes -a -F '#{pane_pid} #{window_id}' 2>/dev/null)
  window_list=$(tmux list-windows -a -F '#{window_id}' 2>/dev/null)
fi

process_window() {
  local target_wid="$1"
  local ai_type="" ai_pid=""

  while read -r pane_pid wid; do
    [[ "$wid" == "$target_wid" ]] || continue
    local child
    child=$(child_by_name "$pane_pid" "claude")
    if [[ -n "$child" ]]; then
      ai_type="claude"; ai_pid="$child"; break
    fi
    child=$(child_by_name "$pane_pid" "codex")
    if [[ -n "$child" ]]; then
      ai_type="codex"; ai_pid="$child"; break
    fi
  done <<< "$pane_list"

  if [[ -n "$ai_pid" ]]; then
    if [[ "$ai_type" == "claude" ]]; then
      local title
      title=$(get_title "$ai_pid" || true)
      label_window "$target_wid" "" "cc|${title:-?}" "$ai_pid"
    else
      label_window "$target_wid" "" "cx|codex" "$ai_pid"
    fi
  else
    unlabel_window "$target_wid"
  fi
}

while read -r wid; do
  [[ -n "$wid" ]] || continue
  process_window "$wid"
done <<< "$window_list"
