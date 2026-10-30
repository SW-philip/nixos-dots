#!/usr/bin/env bash
# Fixture tests for scripts/settings/display.sh.
# shellcheck disable=SC2016 # shim bodies expand when the shim runs, not here
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/settings_testlib.sh"
H="$SETTINGS_DIR/display.sh"

shim kanshictl
shim niri '[[ "$*" == *focused-output* ]] && echo "{\"name\":\"DP-1\"}"; exit 0'
shim brightnessctl 'echo "intel_backlight,backlight,500,50%,1000"'
shim systemctl '[[ "$*" == *is-active* ]] && exit "${ACTIVE_RC:-0}"; exit 0'
shim notify-send
FLAG="$XDG_RUNTIME_DIR/sunshine-streaming"

out=$(SETTINGS_CAPS="desktop" bash "$H" --list)
assert_has "desktop: both monitors" "Both monitors" "$out"
assert_has "desktop: dp-2 only" "DP-2 only" "$out"
assert_has "desktop: stream layout" "Stream layout" "$out"
assert_has "desktop: scale submenu" "Scale" "$out"
assert_lacks "desktop: no brightness" "Brightness" "$out"

out=$(SETTINGS_CAPS="touch backlight" ACTIVE_RC=0 bash "$H" --list)
assert_has "surface: brightness up" "Brightness up" "$out"
assert_has "surface: rotation active offers lock" "Lock rotation" "$out"
assert_has "surface: warmth active offers off" "Turn reader warmth off" "$out"
assert_lacks "surface: no monitor profiles" "Both monitors" "$out"
out=$(SETTINGS_CAPS="touch backlight" ACTIVE_RC=3 bash "$H" --list)
assert_has "surface: rotation inactive offers auto" "Auto-rotate" "$out"
assert_has "surface: warmth inactive offers on" "Turn reader warmth on" "$out"

# a stream is live: monitor changes would freeze Sunshine's KMS capture
touch "$FLAG"
out=$(SETTINGS_CAPS="desktop" bash "$H" --list)
assert_has "streaming: notice row" "Streaming" "$out"
assert_lacks "streaming: no both-monitors row" "Both monitors" "$out"
assert_lacks "streaming: no scale row" "Scale" "$out"
printf 'Clear stale stream flag\n' > "$PICKS"
SETTINGS_CAPS="desktop" bash "$H" >/dev/null
assert_eq "clear flag: removed" no "$([[ -e "$FLAG" ]] && echo yes || echo no)"

: > "$FAKE_LOG"; printf 'Both monitors\n' > "$PICKS"
SETTINGS_CAPS="desktop" bash "$H" >/dev/null
assert_has "switch profile" "kanshictl switch desktop-dual" "$(cat "$FAKE_LOG")"

: > "$FAKE_LOG"; printf 'Scale\n1.5\n' > "$PICKS"
SETTINGS_CAPS="desktop" bash "$H" >/dev/null
assert_has "scale focused output" "niri msg output DP-1 scale 1.5" "$(cat "$FAKE_LOG")"

: > "$FAKE_LOG"; printf 'Brightness up\n' > "$PICKS"
SETTINGS_CAPS="backlight" bash "$H" >/dev/null
assert_has "brightness up" "brightnessctl -e4 -n2% set +5%" "$(cat "$FAKE_LOG")"

: > "$FAKE_LOG"; printf 'Lock rotation\n' > "$PICKS"
SETTINGS_CAPS="touch" ACTIVE_RC=0 bash "$H" >/dev/null
assert_has "rotation stops service" "systemctl --user stop niri-rotation.service" "$(cat "$FAKE_LOG")"

: > "$PICKS"
SETTINGS_CAPS="desktop" bash "$H" >/dev/null; rc=$?
assert_eq "escape: exit 10" 10 "$rc"

# shellcheck disable=SC2154 # fail is set by settings_testlib.sh
exit "$fail"
