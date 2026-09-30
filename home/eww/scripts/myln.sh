#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

state_dir="${XDG_RUNTIME_DIR:-/tmp}"
[[ "${1:-}" == "--selftest" ]] && state_dir="$(mktemp -d)"

status_file="/var/lib/myln/reports/status"
available=false
count=0
if [[ -r "$status_file" ]]; then
  available=true
  count=$(tr -d '[:space:]' < "$status_file")
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
fi

out=$(jq -nc --argjson available "$available" --argjson count "$count" \
  '{available:$available, count:$count}')
printf '%s\n' "$out"
[[ "${1:-}" == "--selftest" ]] || printf '%s\n' "$out" > "$state_dir/eww-myln.json"
