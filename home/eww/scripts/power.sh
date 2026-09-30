#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

state_dir="${XDG_RUNTIME_DIR:-/tmp}"
[[ "${1:-}" == "--selftest" ]] && state_dir="$(mktemp -d)"

present=false; pct=0; state="AC"; draw_w=0

for d in /sys/class/power_supply/BAT*; do
  [[ -r "$d/capacity" ]] || continue
  present=true
  pct=$(cat "$d/capacity" 2>/dev/null || echo 0)
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  state=$(cat "$d/status" 2>/dev/null || echo Unknown)
  [[ -n "$state" ]] || state="Unknown"
  pw=$(cat "$d/power_now" 2>/dev/null || echo 0)
  [[ "$pw" =~ ^[0-9]+$ ]] || pw=0
  draw_w=$(awk -v p="$pw" 'BEGIN { printf "%.1f", p / 1000000 }')   # µW -> W
  break
done
[[ "$draw_w" =~ ^[0-9]+(\.[0-9]+)?$ ]] || draw_w=0

out=$(jq -nc --argjson present "$present" --argjson pct "$pct" \
  --arg state "$state" --argjson draw_w "$draw_w" \
  '{present:$present, pct:$pct, state:$state, draw_w:$draw_w}')
printf '%s\n' "$out"
[[ "${1:-}" == "--selftest" ]] || printf '%s\n' "$out" > "$state_dir/eww-power.json"
