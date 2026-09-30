#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C   # awk float formatting must stay dot-decimal regardless of locale

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pool="${SNARK_POOL:-$HOME/.local/share/eww/status-snark.json}"
state_dir="${SNARK_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}}"
last_file="$state_dir/eww-snark.last"

emit_fallback() { printf '%s\n' '{"line":"Words fail. So does the snark file."}'; exit 0; }

[[ -r "$pool" ]] || emit_fallback
jq -e . "$pool" >/dev/null 2>&1 || emit_fallback

if [[ -n "${SNARK_HOUR:-}" && -n "${SNARK_UPTIME_H:-}" && -n "${SNARK_DISK_PCT:-}" \
   && -n "${SNARK_TEMP_MAX_C:-}" && -n "${SNARK_BATTERY_STATE:-}" ]]; then
  ctx=$(jq -nc \
    --argjson hour "$SNARK_HOUR" --argjson uptime_h "$SNARK_UPTIME_H" \
    --argjson disk_pct "$SNARK_DISK_PCT" --argjson temp_max_c "$SNARK_TEMP_MAX_C" \
    --arg battery_state "$SNARK_BATTERY_STATE" \
    '{hour:$hour,uptime_h:$uptime_h,disk_pct:$disk_pct,temp_max_c:$temp_max_c,battery_state:$battery_state}')
else
  ctx=$(bash "$here/context.sh")
fi

rotate=$(jq -r '.rotateSeconds // 45' "$pool")
[[ "$rotate" =~ ^[1-9][0-9]*$ ]] || rotate=45

# Model-C seam: mood (from a future mood.sh) becomes another --argjson here and
# an extra `select($c.mood == ...)` filter per pool entry. Pool schema and this
# call site do not change.
# Severity ladder is encoded entirely in the pool's numeric weights (data, not
# code). Equal-weight ties resolve to the later pool-array entry (jq max_by
# keeps the last of equal maxima).
lines_json=$(jq -c --argjson c "$ctx" '
  .pools as $p
  | [ ($p["_default"] | {weight, lines}) ]
    + [ $p.time[]?    | select($c.hour >= .from and $c.hour < .to)  | {weight, lines} ]
    + [ $p.uptime[]?  | select($c.uptime_h  >= .overHours)          | {weight, lines} ]
    + [ $p.disk[]?    | select($c.disk_pct  >= .overPct)            | {weight, lines} ]
    + [ $p.thermal[]? | select($c.temp_max_c >= .overC)             | {weight, lines} ]
    + [ $p.battery[]? | select($c.battery_state == .state)          | {weight, lines} ]
  | max_by(.weight) | .lines
' "$pool")

mapfile -t lines < <(jq -r '.[]' <<<"$lines_json")
n=${#lines[@]}
(( n > 0 )) || emit_fallback

now=$(date +%s)
idx=$(( (now / rotate) % n ))
line="${lines[$idx]}"

last=""; [[ -r "$last_file" ]] && last=$(cat "$last_file")
if [[ "$line" == "$last" && "$n" -gt 1 ]]; then
  idx=$(( (idx + 1) % n )); line="${lines[$idx]}"
fi
mkdir -p "$state_dir"; printf '%s' "$line" > "$last_file"

for k in hour uptime_h disk_pct temp_max_c battery_state; do
  v=$(jq -r --arg k "$k" '.[$k]' <<<"$ctx")
  line="${line//\{$k\}/$v}"
done

jq -nc --arg l "$line" '{line:$l}'
