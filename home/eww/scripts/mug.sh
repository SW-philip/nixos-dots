#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

state_dir="${XDG_RUNTIME_DIR:-/tmp}"
[[ "${1:-}" == "--selftest" ]] && state_dir="$(mktemp -d)"

cache="${XDG_CACHE_HOME:-$HOME/.cache}/waybar/ember-mug/status.json"
available=false; temp_c=0; target_c=0; battery_pct=0; liquid_state=Unknown

if [[ -r "$cache" ]]; then
  raw=$(jq -r '[ (.ok // false), (now - (.fetched_at // 0)), (.current_temp // 0), (.target_temp // 0), (.battery_pct // 0), (.liquid_state // "Unknown") ] | @tsv' "$cache" 2>/dev/null || true)
  IFS=$'\t' read -r ok age f_cur f_tgt bat liq <<<"$raw" || true
  if [[ "${ok:-false}" == "true" ]] && awk -v a="${age:-9999}" 'BEGIN { exit !(a <= 150) }'; then
    available=true
    temp_c=$(awk   -v f="${f_cur:-0}" 'BEGIN { printf "%.1f", (f - 32) * 5 / 9 }')
    target_c=$(awk -v f="${f_tgt:-0}" 'BEGIN { printf "%.1f", (f - 32) * 5 / 9 }')
    liquid_state=${liq:-Unknown}
    battery_pct=$(awk -v b="${bat:-0}" 'BEGIN { printf "%d", b }')
  fi
fi
[[ "$temp_c" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || temp_c=0
[[ "$target_c" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || target_c=0
[[ "$battery_pct" =~ ^[0-9]+$ ]] || battery_pct=0

out=$(jq -nc --argjson available "$available" --argjson temp_c "$temp_c" \
  --argjson target_c "$target_c" --argjson battery_pct "$battery_pct" --arg liquid_state "$liquid_state" \
  '{available:$available, temp_c:$temp_c, target_c:$target_c, battery_pct:$battery_pct, liquid_state:$liquid_state}')
printf '%s\n' "$out"
[[ "${1:-}" == "--selftest" ]] || printf '%s\n' "$out" > "$state_dir/eww-mug.json"
