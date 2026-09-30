#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C   # awk float formatting must stay dot-decimal regardless of locale

state_dir="${XDG_RUNTIME_DIR:-/tmp}"
[[ "${1:-}" == "--selftest" ]] && state_dir="$(mktemp -d)"

uptime_s=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)
uptime_h=$(awk '{printf "%d", $1/3600}' /proc/uptime 2>/dev/null || echo 0)
[[ "$uptime_h" =~ ^[0-9]+$ ]] || uptime_h=0

# procps (uptime) isn't on the eww daemon's PATH — derive both from /proc/uptime.
uptime_str=$(awk '{
  s=int($1); d=int(s/86400); h=int(s%86400/3600); m=int(s%3600/60); o=""
  if (d) o=o d " day" (d>1?"s":"")
  if (h) o=o (o?", ":"") h " hour" (h>1?"s":"")
  if (m || !o) o=o (o?", ":"") m " minute" (m==1?"":"s")
  print o }' /proc/uptime 2>/dev/null || echo "unknown")
[[ -n "$uptime_str" ]] || uptime_str="unknown"

booted=$(date -d "@$(( $(date +%s) - uptime_s ))" '+%F %T' 2>/dev/null || echo "unknown")
[[ -n "$booted" ]] || booted="unknown"

kernel=$(uname -r 2>/dev/null || echo "unknown")
[[ -n "$kernel" ]] || kernel="unknown"

built=$(stat -c %Y /run/current-system 2>/dev/null || echo 0)
[[ "$built" =~ ^[0-9]+$ ]] || built=0
now=$(date +%s 2>/dev/null || echo 0)
[[ "$now" =~ ^[0-9]+$ ]] || now=0

if (( built > 0 && now > built )); then
  rebuild_age_h=$(( (now - built) / 3600 ))
  days=$(( rebuild_age_h / 24 ))
  if   (( days >= 14 ));         then rebuild_state="stale"
  elif (( days >= 7 ));          then rebuild_state="aging"
  elif (( rebuild_age_h >= 24 )); then rebuild_state="ok"
  else                               rebuild_state="fresh"
  fi
  age_arg="$rebuild_age_h"
else
  rebuild_state="unknown"
  age_arg="null"
fi

sleep_drain_pct="null"
sleep_hours="null"
sd_dir="${XDG_CACHE_HOME:-$HOME/.cache}/sleep-drain"
if [[ -r "$sd_dir/pre" && -r "$sd_dir/post" ]]; then
  pe=$(sed -n 1p "$sd_dir/pre"); pt=$(sed -n 2p "$sd_dir/pre")
  qe=$(sed -n 1p "$sd_dir/post"); qt=$(sed -n 2p "$sd_dir/post")
  ef=$(cat /sys/class/power_supply/BAT*/energy_full 2>/dev/null | head -1 || echo 0)
  if [[ "$pe" =~ ^[0-9]+$ && "$pt" =~ ^[0-9]+$ && "$qe" =~ ^[0-9]+$ \
     && "$qt" =~ ^[0-9]+$ && "$ef" =~ ^[0-9]+$ ]] \
     && (( ef > 0 && qt > pt && qt - pt >= 300 )); then
    # clamp: battery can gain charge across a suspend, which would print negative
    sleep_drain_pct=$(awk -v d="$((pe - qe))" -v f="$ef" 'BEGIN { x = d * 100 / f; printf "%.1f", (x < 0 ? 0 : x) }')
    sleep_hours=$(awk -v s="$((qt - pt))" 'BEGIN { printf "%.1f", s / 3600 }')
  fi
fi

cur=$(readlink -f /run/current-system 2>/dev/null || echo cur)
boo=$(readlink -f /run/booted-system 2>/dev/null || echo boo)
[[ -n "$cur" ]] || cur=cur
[[ -n "$boo" ]] || boo=boo
gen_drift=false; [[ "$cur" != "$boo" ]] && gen_drift=true

out=$(jq -nc \
  --argjson uptime_h "$uptime_h" --arg uptime_str "$uptime_str" \
  --arg booted "$booted" --arg kernel "$kernel" \
  --argjson rebuild_age_h "$age_arg" --arg rebuild_state "$rebuild_state" \
  --argjson gen_drift "$gen_drift" \
  --argjson sleep_drain_pct "$sleep_drain_pct" --argjson sleep_hours "$sleep_hours" \
  '{uptime_h:$uptime_h,uptime_str:$uptime_str,booted:$booted,kernel:$kernel,
    rebuild_age_h:$rebuild_age_h,rebuild_state:$rebuild_state,gen_drift:$gen_drift,
    sleep_drain_pct:$sleep_drain_pct,sleep_hours:$sleep_hours}')

printf '%s\n' "$out"
[[ "${1:-}" == "--selftest" ]] || printf '%s\n' "$out" > "$state_dir/eww-boot.json"
