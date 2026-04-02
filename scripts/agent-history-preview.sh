#!/usr/bin/env bash
# Preview helper for agent-history picker.
# Receives session ID as argv[1], shows prompts and session detail.

sid="$1"
[[ -z "$sid" ]] && exit 0
exec python3 "$(dirname "$0")/agent-history-data.py" detail "$sid"
