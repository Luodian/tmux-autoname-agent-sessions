#!/usr/bin/env bash
# Render a dynamic header for the history picker.

range_label="${1:-7d}"
density="${2:-compact}"
agent="${3:-agent}"
time_ago="${4:-—}"
project="${5:-—}"
turns="${6:-—}"
status="${7:-done}"
summary="${8:-—}"

case "$range_label" in
  24) range_label='24h' ;;
  168) range_label='7d' ;;
  720) range_label='30d' ;;
  8760) range_label='1y' ;;
  87600) range_label='all' ;;
esac

cat <<EOF
  History (${range_label} · ${density})
  Selected: ${project}  ·  ${agent}  ·  ${time_ago}  ·  ${status}  ·  ${turns} turns  ·  ${summary}
EOF
