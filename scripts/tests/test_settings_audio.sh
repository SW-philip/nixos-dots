#!/usr/bin/env bash
# Fixture tests for scripts/settings/audio.sh.
# shellcheck disable=SC2016 # shim bodies expand when the shim runs, not here
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/settings_testlib.sh"
H="$SETTINGS_DIR/audio.sh"

cat > "$T/pw.json" <<'JSON'
[
 {"id":50,"type":"PipeWire:Interface:Node","info":{"props":{"media.class":"Audio/Sink","node.name":"sink_a","node.description":"Speakers"}}},
 {"id":51,"type":"PipeWire:Interface:Node","info":{"props":{"media.class":"Audio/Sink","node.name":"sink_b","node.description":"HDMI"}}},
 {"id":60,"type":"PipeWire:Interface:Node","info":{"props":{"media.class":"Audio/Source","node.name":"mic_a","node.description":"Desk Mic"}}},
 {"id":9,"type":"PipeWire:Interface:Metadata","props":{"metadata.name":"default"},
  "metadata":[{"key":"default.audio.sink","value":{"name":"sink_b"}},{"key":"default.audio.source","value":{"name":"mic_a"}}]}
]
JSON
shim pw-dump 'cat "$PW_JSON"'
export PW_JSON="$T/pw.json"
shim wpctl 'echo "Volume: 0.50"'
shim pavucontrol
shim setsid
shim notify-send

out=$(bash "$H" --list-outputs)
assert_has "outputs: default marked" "● HDMI" "$out"
assert_has "outputs: other listed" "  Speakers" "$out"
out=$(bash "$H" --list-inputs)
assert_has "inputs: default marked" "● Desk Mic" "$out"

out=$(SETTINGS_CAPS="" bash "$H" --list)
assert_has "main: output row" "Output" "$out"
assert_has "main: mixer row" "Open mixer" "$out"
assert_lacks "main: no pin on non-desktop" "output (" "$out"

out=$(SETTINGS_CAPS="desktop" bash "$H" --list)
assert_has "desktop: pin row" "Pin output" "$out"

: > "$FAKE_LOG"; printf 'Pin output\n' > "$PICKS"
SETTINGS_CAPS="desktop" bash "$H"
assert_eq "pin: file created" yes "$([[ -e "$XDG_RUNTIME_DIR/audio-output-pinned" ]] && echo yes || echo no)"
out=$(SETTINGS_CAPS="desktop" bash "$H" --list)
assert_has "pinned: offers unpin" "Unpin output" "$out"
printf 'Unpin output\n' > "$PICKS"
SETTINGS_CAPS="desktop" bash "$H"
assert_eq "unpin: file removed" no "$([[ -e "$XDG_RUNTIME_DIR/audio-output-pinned" ]] && echo yes || echo no)"

: > "$FAKE_LOG"; printf 'Output\nSpeakers\n' > "$PICKS"
bash "$H"
assert_has "pick output: wpctl set-default" "wpctl set-default 50" "$(cat "$FAKE_LOG")"

: > "$FAKE_LOG"; printf 'Volume up\n' > "$PICKS"
bash "$H"
assert_has "volume up" "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+" "$(cat "$FAKE_LOG")"

: > "$FAKE_LOG"; printf 'Open mixer\n' > "$PICKS"
bash "$H"
assert_has "mixer launched" "pavucontrol" "$(cat "$FAKE_LOG")"

: > "$PICKS"
bash "$H"; rc=$?
assert_eq "escape: exit 10" 10 "$rc"

# shellcheck disable=SC2154 # fail is set by settings_testlib.sh
exit "$fail"
