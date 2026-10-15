#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../tablet-gestures.sh"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"
cleanup() {
  [ -n "${MAINPID:-}" ] && kill "$MAINPID" 2>/dev/null || true
  [ -f "$TMP/pids" ] && while read -r p; do kill "$p" 2>/dev/null || true; done < "$TMP/pids"
  rm -rf "$TMP"
}
trap cleanup EXIT

# fake sysfs: event3 is the touchscreen, event4 the stylus
# eventN/device is a symlink to inputNN, as in real sysfs
mkdir -p "$TMP/sys/event3" "$TMP/sys/event4" "$TMP/sys/input5" "$TMP/sys/input6" "$TMP/bin"
echo "IPTSD Virtual Touchscreen 045E:0C1A" > "$TMP/sys/input5/name"
echo "IPTSD Virtual Stylus 045E:0C1A"      > "$TMP/sys/input6/name"
ln -s ../input5 "$TMP/sys/event3/device"
ln -s ../input6 "$TMP/sys/event4/device"

export GESTURES_SYSFS_INPUT="$TMP/sys" GESTURES_DEV_DIR=/dev/input
export GESTURES_ACT=/x/tablet-act GESTURES_LISGD="$TMP/bin/lisgd" GESTURES_POLL=0.2
# shellcheck disable=SC1090
source "$SCRIPT"

[ "$(find_device)" = "/dev/input/event3" ] && pass "find_device picks the touchscreen, not the stylus" || fail "find_device picks the touchscreen, not the stylus"
if ( SYSFS_INPUT="$TMP/nosys"; find_device >/dev/null ); then fail "find_device fails when there is no touchscreen"; else pass "find_device fails when there is no touchscreen"; fi

o() { orientation_for "$1"; }
{ [ "$(o Normal)" = 0 ] && [ "$(o 90)" = 3 ] && [ "$(o 180)" = 2 ] && [ "$(o 270)" = 1 ] && [ "$(o Flipped)" = 0 ]; } \
  && pass "orientation table" || fail "orientation table"
[ "$(GESTURES_O90=1 o 90)" = 1 ] && pass "GESTURES_O90 overrides the 90 orientation" || fail "GESTURES_O90 overrides the 90 orientation"

[ "$(GESTURES_O270=2 o 270)" = 2 ] && pass "GESTURES_O270 overrides the 270 orientation" || fail "GESTURES_O270 overrides the 270 orientation"

joined() { lisgd_args "$@" | tr '\n' '|'; }
a="$(joined /dev/input/event3 2736 1824 3)"
case "$a" in *"-d|/dev/input/event3|-w|2736|-h|1824|-o|3|"*) pass "lisgd_args: device, native size, orientation" ;; *) fail "lisgd_args: device, native size, orientation ($a)" ;; esac
for g in "1,UD,T,*,R,/x/tablet-act sheet-open" "1,DU,B,*,R,/x/tablet-act launcher-open" \
         "1,LR,L,*,R,/x/tablet-act overview" "1,RL,R,*,R,/x/tablet-act notif"; do
  case "$a" in *"-g|$g|"*) pass "gesture: $g" ;; *) fail "gesture: $g" ;; esac
done
case "$a" in *"|-v|"*) fail "no -v unless GESTURES_VERBOSE" ;; *) pass "no -v unless GESTURES_VERBOSE" ;; esac
case "$(GESTURES_VERBOSE=1 joined /dev/input/event3 2736 1824 0)" in *"|-v|"*) pass "GESTURES_VERBOSE adds -v" ;; *) fail "GESTURES_VERBOSE adds -v" ;; esac

# main loop: stub niri reports the transform from a file, stub lisgd records its argv and sleeps
cat > "$TMP/bin/niri" <<STUB
#!/usr/bin/env bash
[ "\$(cat "$TMP/transform")" = EMPTY ] && exit 1
printf '{"eDP-1":{"logical":{"transform":"%s"},"modes":[{"width":2736,"height":1824}],"current_mode":0}}\n' "\$(cat "$TMP/transform")"
STUB
cat > "$TMP/bin/lisgd" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$TMP/launches"
echo \$\$ >> "$TMP/pids"
exec sleep 30
STUB
chmod +x "$TMP/bin/niri" "$TMP/bin/lisgd"
echo Normal > "$TMP/transform"
export PATH="$TMP/bin:$PATH"

( set +e; main ) &
MAINPID=$!
sleep 1
[ "$(wc -l < "$TMP/launches")" = 1 ] && grep -q -- '-o 0 ' "$TMP/launches" && pass "starts lisgd once at orientation 0" || fail "starts lisgd once at orientation 0"
echo 90 > "$TMP/transform"
sleep 1.5
{ [ "$(wc -l < "$TMP/launches")" = 2 ] && tail -1 "$TMP/launches" | grep -q -- '-o 3 '; } && pass "restarts at orientation 3 after rotating to 90" || fail "restarts at orientation 3 after rotating to 90"
first=$(head -1 "$TMP/pids")
if kill -0 "$first" 2>/dev/null; then fail "the old lisgd was stopped"; else pass "the old lisgd was stopped"; fi
sleep 1
[ "$(wc -l < "$TMP/launches")" = 2 ] && pass "no restart while the transform is unchanged" || fail "no restart while the transform is unchanged"

# a failed niri read must not restart lisgd at orientation 0 while rotated
n=$(wc -l < "$TMP/launches")
echo EMPTY > "$TMP/transform"
sleep 0.8
echo 90 > "$TMP/transform"
sleep 0.8
[ "$(wc -l < "$TMP/launches")" = "$n" ] && pass "an empty transform read does not restart lisgd" || fail "an empty transform read does not restart lisgd"

# iptsd recreates the touchscreen: same eventN, new inputNN
mkdir -p "$TMP/sys/input7"
echo "IPTSD Virtual Touchscreen 045E:0C1A" > "$TMP/sys/input7/name"
ln -sfn ../input7 "$TMP/sys/event3/device"
sleep 1
{ [ "$(wc -l < "$TMP/launches")" = 3 ] && tail -1 "$TMP/launches" | grep -q -- '-d /dev/input/event3 '; } && pass "relaunches lisgd when the touchscreen device is recreated" || fail "relaunches lisgd when the touchscreen device is recreated"
second=$(sed -n 2p "$TMP/pids")
if kill -0 "$second" 2>/dev/null; then fail "the lisgd on the vanished device was stopped"; else pass "the lisgd on the vanished device was stopped"; fi

# lisgd dying on its own is restarted
n=$(wc -l < "$TMP/launches")
kill "$(tail -1 "$TMP/pids")"
sleep 1
[ "$(wc -l < "$TMP/launches")" = $((n + 1)) ] && pass "restarts lisgd after it dies" || fail "restarts lisgd after it dies"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
