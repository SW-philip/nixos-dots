#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNARK="$DIR/../snark.sh"
POOL="$(mktemp)"
STATE="$(mktemp -d)"
fails=0

cat > "$POOL" <<'JSON'
{
  "rotateSeconds": 45,
  "pools": {
    "_default": { "weight": 0, "lines": ["default-a", "default-b"] },
    "time":    [ { "weight": 10, "from": 0, "to": 5, "lines": ["night-a", "night-b"] } ],
    "uptime":  [ { "weight": 20, "overHours": 24, "lines": ["up24"] },
                 { "weight": 30, "overHours": 72, "lines": ["up72"] } ],
    "disk":    [ { "weight": 35, "overPct": 85, "lines": ["disk85 {disk_pct}"] },
                 { "weight": 60, "overPct": 95, "lines": ["disk95 {disk_pct}"] } ],
    "thermal": [ { "weight": 40, "overC": 80, "lines": ["hot {temp_max_c}"] } ],
    "battery": [ { "weight": 100, "state": "critical", "lines": ["plug in"] } ]
  }
}
JSON

run() {
  LINE=$(SNARK_POOL="$POOL" SNARK_STATE_DIR="$STATE" \
    SNARK_HOUR="$1" SNARK_UPTIME_H="$2" SNARK_DISK_PCT="$3" \
    SNARK_TEMP_MAX_C="$4" SNARK_BATTERY_STATE="$5" \
    bash "$SNARK" | jq -r '.line')
}
check() {
  if [[ "$3" == *"$2"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: got [$3] want [$2]"; fails=$((fails+1)); fi
}

run 3 10 40 50 normal;    check "3am, nothing else -> time pool" "night-" "$LINE"
run 12 80 96 50 normal;   check "disk 96 beats uptime+time -> disk95" "disk95 96" "$LINE"
run 12 80 90 50 normal;   check "disk 90 -> disk85 pool, token filled" "disk85 90" "$LINE"
run 12 100 50 85 normal;  check "thermal 85 beats uptime72" "hot 85" "$LINE"
run 12 10 40 50 critical; check "battery critical wins outright" "plug in" "$LINE"
run 12 10 40 50 normal;   check "nothing crossed -> _default" "default-" "$LINE"

rm -f "$STATE"/eww-snark.last
L1=$(SNARK_POOL="$POOL" SNARK_STATE_DIR="$STATE" SNARK_HOUR=3 SNARK_UPTIME_H=1 SNARK_DISK_PCT=1 SNARK_TEMP_MAX_C=1 SNARK_BATTERY_STATE=normal bash "$SNARK" | jq -r '.line')
L2=$(SNARK_POOL="$POOL" SNARK_STATE_DIR="$STATE" SNARK_HOUR=3 SNARK_UPTIME_H=1 SNARK_DISK_PCT=1 SNARK_TEMP_MAX_C=1 SNARK_BATTERY_STATE=normal bash "$SNARK" | jq -r '.line')
if [[ "$L1" != "$L2" ]]; then
  echo "ok   - no immediate repeat"
else
  echo "FAIL - repeat guard: [$L1]==[$L2]"; fails=$((fails+1))
fi

echo '{ this is not json' > "$POOL"
run 3 1 1 1 normal
if [[ -n "$LINE" ]]; then
  echo "ok   - garbage pool -> non-empty fallback"
else
  echo "FAIL - fallback empty"; fails=$((fails+1))
fi

# hand-edited bad rotateSeconds must not divide-by-zero / crash the deflisten
bad_rotate() {
  cat > "$POOL" <<JSON
{ "rotateSeconds": $1,
  "pools": { "_default": { "weight": 0, "lines": ["rot-a", "rot-b"] } } }
JSON
  rm -f "$STATE"/eww-snark.last
  rc=0
  OUT=$(SNARK_POOL="$POOL" SNARK_STATE_DIR="$STATE" \
    SNARK_HOUR=12 SNARK_UPTIME_H=1 SNARK_DISK_PCT=1 \
    SNARK_TEMP_MAX_C=1 SNARK_BATTERY_STATE=normal bash "$SNARK") || rc=$?
  L=$(jq -r '.line' <<<"$OUT" 2>/dev/null || true)
  if [[ $rc -eq 0 && -n "$L" && "$L" != "null" ]]; then echo "ok   - rotateSeconds=$1 -> exit 0, non-empty line"
  else echo "FAIL - rotateSeconds=$1: rc=$rc line=[$L]"; fails=$((fails+1)); fi
}
bad_rotate 0
bad_rotate '"soon"'

rm -f "$POOL"; rm -rf "$STATE"
echo
if [[ $fails -eq 0 ]]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
