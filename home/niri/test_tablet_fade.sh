#!/usr/bin/env bash
# Usage: bash home/niri/test_tablet_fade.sh <path-to-tablet-fade.sh>
set -euo pipefail
SCRIPT="${1:?usage: test_tablet_fade.sh <path-to-tablet-fade.sh>}"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"
cleanup() {
  [ -f "$TMP/tablet-fade.watchdog" ] && kill "$(cat "$TMP/tablet-fade.watchdog")" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$TMP/systemctl" <<'STUB'
#!/usr/bin/env bash
[ "${2:-}" = cat ] && exit "${STUB_NO_EWW_UNIT:-0}"
exit 0
STUB
cat > "$TMP/eww" <<'STUB'
#!/usr/bin/env bash
echo "eww $*" >> "$STUB_LOG"
[ "${1:-}" = ping ] && exit "${STUB_PING_RC:-0}"
exit 0
STUB
chmod +x "$TMP/systemctl" "$TMP/eww"

# run <out|in> [no-eww-unit] [ping-rc]
run() {
  : > "$TMP/log"
  XDG_RUNTIME_DIR="$TMP" STUB_LOG="$TMP/log" STUB_NO_EWW_UNIT="${2:-0}" STUB_PING_RC="${3:-0}" \
    TABLET_EWW="$TMP/eww" TABLET_SYSTEMCTL="$TMP/systemctl" TABLET_FADE_WAIT=0.05 TABLET_FADE_WATCHDOG=30 \
    bash "$SCRIPT" "$1"
}
lines() { tr '\n' '|' < "$TMP/log"; }
logged() { grep -qxF "$1" "$TMP/log"; }
order() { # <first> <second>: both logged, first before second
  local a b; a=$(grep -nxF "$1" "$TMP/log" | head -1 | cut -d: -f1); b=$(grep -nxF "$2" "$TMP/log" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

run out
{ order "eww ping" "eww open tablet-fade" && order "eww open tablet-fade" "eww update fade_on=true"; } \
  && pass "out: ping, open the overlay, then fade it in" || fail "out: ping, open the overlay, then fade it in ($(lines))"
if [ -s "$TMP/tablet-fade.watchdog" ] && kill -0 "$(cat "$TMP/tablet-fade.watchdog")" 2>/dev/null; then
  pass "out: starts a watchdog"
else
  fail "out: starts a watchdog"
fi

wd=$(cat "$TMP/tablet-fade.watchdog")
run in
{ order "eww update fade_on=false" "eww close tablet-fade" && ! grep -q 'tablet-fade-b' "$TMP/log"; } \
  && pass "in: fade out, then close the overlay (no second window)" || fail "in: fade out, then close the overlay (no second window) ($(lines))"
if kill -0 "$wd" 2>/dev/null; then fail "in: cancels the watchdog"; else pass "in: cancels the watchdog"; fi
[ ! -e "$TMP/tablet-fade.watchdog" ] && pass "in: removes the watchdog pid file" || fail "in: removes the watchdog pid file"

run out; first=$(cat "$TMP/tablet-fade.watchdog")
run out; second=$(cat "$TMP/tablet-fade.watchdog")
{ [ "$first" != "$second" ] && ! kill -0 "$first" 2>/dev/null && kill -0 "$second" 2>/dev/null; } \
  && pass "a newer out replaces the older watchdog" || fail "a newer out replaces the older watchdog"
run in

run out 0 1
{ ! logged "eww open tablet-fade" && ! logged "eww update fade_on=true"; } \
  && pass "no daemon (ping fails): nothing opened" || fail "no daemon (ping fails): nothing opened ($(lines))"
run in 0 1
[ "$(grep -vcxF 'eww ping' "$TMP/log")" -eq 0 ] && pass "no daemon: in runs nothing either" || fail "no daemon: in runs nothing either ($(lines))"

run out 1
[ ! -s "$TMP/log" ] && pass "no eww.service (Kid): does nothing" || fail "no eww.service (Kid): does nothing ($(lines))"

# watchdog actually closes the overlay after its timeout
: > "$TMP/log"
XDG_RUNTIME_DIR="$TMP" STUB_LOG="$TMP/log" TABLET_EWW="$TMP/eww" TABLET_SYSTEMCTL="$TMP/systemctl" \
  TABLET_FADE_WAIT=0.02 TABLET_FADE_WATCHDOG=1 bash "$SCRIPT" out
sleep 1.6
logged "eww close tablet-fade" \
  && pass "watchdog closes the overlay when 'in' never comes" || fail "watchdog closes the overlay when 'in' never comes ($(lines))"

# watchdog removes its own pid file when it fires
[ ! -e "$TMP/tablet-fade.watchdog" ] && pass "watchdog removes its pid file after firing" || fail "watchdog removes its pid file after firing"

# a replaced watchdog must not delete its successor's pid file
XDG_RUNTIME_DIR="$TMP" STUB_LOG="$TMP/log" TABLET_EWW="$TMP/eww" TABLET_SYSTEMCTL="$TMP/systemctl" \
  TABLET_FADE_WAIT=0.02 TABLET_FADE_WATCHDOG=1 bash "$SCRIPT" out
old_pid=$(cat "$TMP/tablet-fade.watchdog")
# stand in a successor: a different live pid in the file, old watchdog left running
sleep 30 & succ=$!
echo "$succ" > "$TMP/tablet-fade.watchdog"
sleep 1.6
{ [ -f "$TMP/tablet-fade.watchdog" ] && [ "$(cat "$TMP/tablet-fade.watchdog")" = "$succ" ]; } \
  && pass "old watchdog leaves a newer watchdog's pid file alone" || fail "old watchdog leaves a newer watchdog's pid file alone (old=$old_pid)"
kill "$succ" 2>/dev/null || true
rm -f "$TMP/tablet-fade.watchdog"

# in with no prior out
rm -f "$TMP/tablet-fade.watchdog"
if run in; then rc=0; else rc=$?; fi
{ [ "$rc" -eq 0 ] && logged "eww update fade_on=false" && logged "eww close tablet-fade" && ! grep -q 'tablet-fade-b' "$TMP/log"; } \
  && pass "in without a prior out: exits 0 with its usual calls" || fail "in without a prior out: exits 0 with its usual calls (rc=$rc $(lines))"

if XDG_RUNTIME_DIR="$TMP" STUB_LOG="$TMP/log" TABLET_EWW="$TMP/eww" TABLET_SYSTEMCTL="$TMP/systemctl" \
  bash "$SCRIPT" nonsense >/dev/null 2>&1; then fail "unknown argument exits non-zero"; else pass "unknown argument exits non-zero"; fi

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
