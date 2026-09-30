#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C   # awk float formatting must stay dot-decimal regardless of locale

rt="${XDG_RUNTIME_DIR:-/tmp}"

cache_get() { local f="$rt/$1"; [[ -r "$f" ]] && jq -r "$2 // empty" "$f" 2>/dev/null || true; }

hour=$(date +%-H)

uptime_h=$(cache_get eww-boot.json '.uptime_h')
[[ -n "${uptime_h:-}" ]] || uptime_h=$(awk '{printf "%d", $1/3600}' /proc/uptime)

disk_pct=$(cache_get eww-storage.json '[.mounts[]?.pct] | max')
[[ -n "${disk_pct:-}" && "$disk_pct" != "null" ]] || \
  disk_pct=$(df --output=pcent / | awk 'NR==2{gsub(/[ %]/,""); print}')

temp_max_c=$(cache_get eww-vitals.json '.temp_max_c')
if [[ -z "${temp_max_c:-}" || "$temp_max_c" == "null" ]]; then
  temp_max_c=0
  for f in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$f" ]] || continue
    v=$(( $(cat "$f") / 1000 )); (( v > temp_max_c )) && temp_max_c=$v
  done
fi

battery_state="none"
for d in /sys/class/power_supply/BAT*; do
  [[ -r "$d/capacity" ]] || continue
  cap=$(cat "$d/capacity"); st=$(cat "$d/status" 2>/dev/null || echo Unknown)
  if [[ "$st" == "Discharging" && "$cap" -lt 10 ]]; then battery_state="critical"
  elif [[ "$st" == "Discharging" && "$cap" -lt 25 ]]; then battery_state="low"
  else battery_state="normal"; fi
  break
done

jq -nc \
  --argjson hour "$hour" \
  --argjson uptime_h "${uptime_h:-0}" \
  --argjson disk_pct "${disk_pct:-0}" \
  --argjson temp_max_c "${temp_max_c:-0}" \
  --arg battery_state "$battery_state" \
  '{hour:$hour, uptime_h:$uptime_h, disk_pct:$disk_pct, temp_max_c:$temp_max_c, battery_state:$battery_state}'
