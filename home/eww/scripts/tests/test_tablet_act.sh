#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../tablet-act.sh"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/fx"

# Every stub logs its argv; query commands also print $FX/<name> if present.
for t in wpctl brightnessctl nmcli bluetoothctl swaync-client powerprofilesctl sqlch toggle-osk waybar-sqlch niri launcher; do
  cat > "$TMP/bin/$t" <<STUB
#!/usr/bin/env bash
echo "$t \$*" >> "$TMP/log"
cat "$TMP/fx/$t" 2>/dev/null
exit 0
STUB
  chmod +x "$TMP/bin/$t"
done
# eww: `ping` fails when $FX/eww.ping.rc holds non-zero (daemon down)
cat > "$TMP/bin/eww" <<STUB
#!/usr/bin/env bash
echo "eww \$*" >> "$TMP/log"
[ "\${1:-}" = ping ] && exit "\$(cat "$TMP/fx/eww.ping.rc" 2>/dev/null || echo 0)"
cat "$TMP/fx/eww" 2>/dev/null
exit 0
STUB
chmod +x "$TMP/bin/eww"
cat > "$TMP/bin/systemctl" <<STUB
#!/usr/bin/env bash
echo "systemctl \$*" >> "$TMP/log"
[ "\${2:-}" = is-active ] && exit "\$(cat "$TMP/fx/active.rc" 2>/dev/null || echo 1)"
exit 0
STUB
chmod +x "$TMP/bin/systemctl"

# act <args...>; the stub log is reset first, fixtures persist until reset.
act() {
  : > "$TMP/log"
  PATH="$TMP/bin:$PATH" XDG_RUNTIME_DIR="$TMP" TABLET_NOW_NS="${NOW_NS:-}" TABLET_EWW="$TMP/bin/eww" TABLET_TOGGLE_OSK="$TMP/bin/toggle-osk" \
    TABLET_SQLCH_STEP="$TMP/bin/waybar-sqlch" bash "$SCRIPT" "$@" >/dev/null 2>&1 || true
}
fxreset() { rm -f "$TMP"/fx/*; }
saw()  { grep -qxF "$1" "$TMP/log"; }
expect() { # <name> <expected log line>
  if saw "$2"; then pass "$1"; else fail "$1 (wanted: $2; got: $(tr '\n' '|' < "$TMP/log"))"; fi
}
refute() { if saw "$2"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }

fxreset
act vol 40.000000; expect "vol strips the decimals" "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 40%"
act vol 250;       expect "vol clamps high" "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 100%"
act vol abc;       expect "vol with junk becomes 0" "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 0%"
act bright 0;      expect "brightness never goes fully dark" "brightnessctl set 1%"
act bright 60.5;   expect "brightness" "brightnessctl set 60%"
echo "Volume: 0.40" > "$TMP/fx/wpctl"
act vol 40; refute "vol equal to current is not rewritten" "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 40%"
act vol 41; expect "vol different from current is written" "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 41%"
echo "intel,backlight,48000,50%,96000" > "$TMP/fx/brightnessctl"
act bright 50; refute "brightness equal to current is not rewritten" "brightnessctl set 50%"
act bright 51; expect "brightness different from current is written" "brightnessctl set 51%"
echo "garbage" > "$TMP/fx/wpctl"; echo "garbage" > "$TMP/fx/brightnessctl"
act vol 40;    expect "unreadable current volume still writes" "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 40%"
act bright 50; expect "unreadable current brightness still writes" "brightnessctl set 50%"
fxreset
act mute;          expect "mute" "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"

fxreset; echo enabled > "$TMP/fx/nmcli"
act wifi; expect "wifi on -> off" "nmcli radio wifi off"
echo disabled > "$TMP/fx/nmcli"
act wifi; expect "wifi off -> on" "nmcli radio wifi on"

fxreset; echo "Powered: yes" > "$TMP/fx/bluetoothctl"
act bt; expect "bluetooth on -> off" "bluetoothctl power off"
echo "Powered: no" > "$TMP/fx/bluetoothctl"
act bt; expect "bluetooth off -> on" "bluetoothctl power on"

fxreset; echo 0 > "$TMP/fx/active.rc"
act rotate; expect "rotate active -> stop" "systemctl --user stop niri-rotation.service"
echo 1 > "$TMP/fx/active.rc"
act rotate; expect "rotate inactive -> start" "systemctl --user start niri-rotation.service"

fxreset
act osk;   expect "osk" "toggle-osk "
act dnd;   expect "dnd" "swaync-client -d"
act notif; { saw "eww close tablet-sheet" && saw "swaync-client -t"; } && pass "notif closes the sheet then opens swaync" || fail "notif closes the sheet then opens swaync"
act sheet; expect "sheet toggles" "eww open --toggle tablet-sheet"
act suspend; { saw "eww close tablet-sheet" && saw "systemctl suspend"; } && pass "suspend closes the sheet first" || fail "suspend closes the sheet first"

echo balanced > "$TMP/fx/powerprofilesctl"
act profile; expect "profile balanced -> performance" "powerprofilesctl set performance"
echo performance > "$TMP/fx/powerprofilesctl"
act profile; expect "profile performance -> power-saver" "powerprofilesctl set power-saver"
echo power-saver > "$TMP/fx/powerprofilesctl"
act profile; expect "profile power-saver -> balanced" "powerprofilesctl set balanced"

rm -f "$TMP/fx/powerprofilesctl"
echo "Paused: Radio Paradise" > "$TMP/fx/sqlch"
act sqlch toggle; expect "sqlch paused -> play-last" "sqlch play-last"
echo "Radio Paradise" > "$TMP/fx/sqlch"
act sqlch toggle; expect "sqlch playing -> pause" "sqlch pause"
act sqlch next;   expect "sqlch next" "waybar-sqlch --next"
act sqlch prev;   expect "sqlch prev" "waybar-sqlch --prev"

if PATH="$TMP/bin:$PATH" bash "$SCRIPT" nonsense >/dev/null 2>&1; then fail "unknown action exits non-zero"; else pass "unknown action exits non-zero"; fi
refute "unknown action ran nothing" "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"

fxreset; rm -f "$TMP/tablet-sheet-opened"
act sheet-open; expect "sheet-open opens a closed sheet" "eww open tablet-sheet"
[ -s "$TMP/tablet-sheet-opened" ] && pass "sheet-open records a timestamp" || fail "sheet-open records a timestamp"

fxreset; echo "tablet-sheet: tablet-sheet" > "$TMP/fx/eww"
act sheet-open; refute "sheet-open leaves an open sheet alone" "eww open tablet-sheet"
fxreset

echo 1000000000 > "$TMP/tablet-sheet-opened"
NOW_NS=1500000000 act sheet; refute "sheet toggle right after a gesture open is ignored" "eww open --toggle tablet-sheet"
NOW_NS=1900000000 act sheet; expect "sheet toggle after the debounce window works" "eww open --toggle tablet-sheet"
rm -f "$TMP/tablet-sheet-opened"
NOW_NS=5 act sheet;           expect "sheet toggle with no timestamp works" "eww open --toggle tablet-sheet"

act launcher-open; expect "launcher-open opens a closed launcher" "eww open launcher-tablet"
echo "launcher-tablet: launcher-tablet" > "$TMP/fx/eww"
act launcher-open; refute "launcher-open leaves an open launcher alone" "eww open launcher-tablet"
fxreset
echo 1 > "$TMP/fx/eww.ping.rc"; rm -f "$TMP/tablet-sheet-opened"
act sheet-open;    refute "sheet-open does not start a daemon when eww is down" "eww open tablet-sheet"
[ ! -e "$TMP/tablet-sheet-opened" ] && pass "sheet-open records no timestamp when eww is down" || fail "sheet-open records no timestamp when eww is down"
act launcher-open; refute "launcher-open does not start a daemon when eww is down" "eww open launcher-tablet"
fxreset

act overview; expect "overview opens (not toggles) niri's overview" "niri msg action open-overview"
act launcher; expect "launcher runs the launcher command" "launcher "

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
