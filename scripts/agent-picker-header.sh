#!/usr/bin/env bash
# Render a dynamic header for the live agent picker.

mode="${1:-all}"
density="${2:-compact}"
agent="${3:-agent}"
state="${4:-quiet}"
target="${5:-—}"
window_name="${6:-—}"
cwd="${7:-—}"

cat <<EOF
  Live (${mode} · ${density})
  Selected: ${target}  ·  ${agent}  ·  ${state}  ·  ${window_name}  ·  ${cwd}
EOF
