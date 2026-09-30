#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C   # awk float formatting must stay dot-decimal regardless of locale

state_dir="${XDG_RUNTIME_DIR:-/tmp}"
[[ "${1:-}" == "--selftest" ]] && state_dir="$(mktemp -d)"
cpu_state="$state_dir/eww-vitals-cpu.state"
hist_cpu_f="$state_dir/eww-vitals-cpu.hist"
hist_tmp_f="$state_dir/eww-vitals-temp.hist"

if ! read -r tot idle < <(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat 2>/dev/null); then
  tot=0; idle=0
fi
[[ "$tot" =~ ^[0-9]+$ && "$idle" =~ ^[0-9]+$ ]] || { tot=0; idle=0; }
if [[ -r "$cpu_state" ]] && read -r ptot pidle < "$cpu_state" 2>/dev/null; then :; else ptot=0; pidle=0; fi
[[ "$ptot" =~ ^[0-9]+$ && "$pidle" =~ ^[0-9]+$ ]] || { ptot=0; pidle=0; }
printf '%s %s\n' "$tot" "$idle" > "$cpu_state"
dt=$(( tot - ptot )); di=$(( idle - pidle ))
cpu_pct=$(( dt > 0 ? (100 * (dt - di)) / dt : 0 ))
(( cpu_pct < 0 )) && cpu_pct=0; (( cpu_pct > 100 )) && cpu_pct=100

if ! read -r mem_pct mem_used_gib < <(awk '
  /^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
  END{ if (t>0) printf "%d %.1f\n", (t-a)*100/t, (t-a)/1048576 }' /proc/meminfo 2>/dev/null); then
  mem_pct=0; mem_used_gib=0
fi
[[ "$mem_pct" =~ ^[0-9]+$ ]] || mem_pct=0
[[ "$mem_used_gib" =~ ^[0-9]+(\.[0-9]+)?$ ]] || mem_used_gib=0

load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || true)
[[ "$load1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || load1=0

temp_cpu_c=0
for d in /sys/class/hwmon/hwmon*; do
  [[ "$(cat "$d/name" 2>/dev/null || true)" == "coretemp" ]] || continue
  for f in "$d"/temp*_input; do
    v=$(cat "$f" 2>/dev/null || true)
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    c=$(( v / 1000 )); (( c > temp_cpu_c )) && temp_cpu_c=$c
  done
  break
done
temp_max_c=$temp_cpu_c
for f in /sys/class/thermal/thermal_zone*/temp; do
  [[ -r "$f" ]] || continue
  raw=$(cat "$f" 2>/dev/null || true); [[ "$raw" =~ ^[0-9]+$ ]] || continue
  v=$(( raw / 1000 )); (( v > temp_max_c )) && temp_max_c=$v
done
(( temp_cpu_c == 0 )) && temp_cpu_c=$temp_max_c

append_hist() {
  echo "$2" >> "$1"
  tail -n 60 "$1" > "$1.t" 2>/dev/null && mv "$1.t" "$1"
  paste -sd, "$1"
}
hist_cpu=$(append_hist "$hist_cpu_f" "$cpu_pct")
hist_temp=$(append_hist "$hist_tmp_f" "$temp_cpu_c")

out=$(jq -nc \
  --argjson cpu_pct "$cpu_pct" --argjson mem_pct "$mem_pct" \
  --argjson mem_used_gib "$mem_used_gib" --argjson load1 "$load1" \
  --argjson temp_cpu_c "$temp_cpu_c" --argjson temp_max_c "$temp_max_c" \
  --arg hist_cpu "$hist_cpu" --arg hist_temp "$hist_temp" \
  '{cpu_pct:$cpu_pct,mem_pct:$mem_pct,mem_used_gib:$mem_used_gib,load1:$load1,
    temp_cpu_c:$temp_cpu_c,temp_max_c:$temp_max_c,hist_cpu:$hist_cpu,hist_temp:$hist_temp}')

printf '%s\n' "$out"
[[ "${1:-}" == "--selftest" ]] || printf '%s\n' "$out" > "$state_dir/eww-vitals.json"
