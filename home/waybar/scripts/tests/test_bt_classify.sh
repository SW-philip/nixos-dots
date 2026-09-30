#!/usr/bin/env bash
# Pure-function tests for bt-classify.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bt-classify.sh"

fail=0
assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: $desc — expected '$expected', got '$actual'"
    fail=1
  else
    echo "PASS: $desc"
  fi
}

assert_eq "mac underscore" "D0_CB_C8_72_ED_45" "$(_mac_underscore "00:00:00:00:00:01")"

assert_eq "audio sink uuid -> audio" "audio" "$(_type_from_uuids "0000110b-0000-1000-8000-00805f9b34fb")"
assert_eq "headset uuid -> audio" "audio" "$(_type_from_uuids "00001108-0000-1000-8000-00805f9b34fb")"
assert_eq "handsfree uuid -> audio" "audio" "$(_type_from_uuids "0000111e-0000-1000-8000-00805f9b34fb")"
assert_eq "hid uuid -> input" "input" "$(_type_from_uuids "00001124-0000-1000-8000-00805f9b34fb")"

# Real UUID set observed live off the Work Mug (00:00:00:00:00:01) --
# GAP/GATT/Device-Information/vendor only, no audio or HID service.
assert_eq "mug uuids -> other" "other" "$(_type_from_uuids "00001530-1212-efde-1523-785feabcd123
00001800-0000-1000-8000-00805f9b34fb
00001801-0000-1000-8000-00805f9b34fb
0000180a-0000-1000-8000-00805f9b34fb
fc543622-236c-4c94-8fa9-944a3e5353fa")"

assert_eq "empty uuids -> other" "other" "$(_type_from_uuids "")"

# --- Class-of-Device decode (CoD bits 8-12 = major, 2-7 = minor) ---
assert_eq "CoD audio/headset -> headset"     "headset"     "$(_type_from_class 0x200404 "")"
assert_eq "CoD audio/handsfree -> headset"   "headset"     "$(_type_from_class 0x200408 "")"
assert_eq "CoD audio/headphones -> headphones" "headphones" "$(_type_from_class 0x200418 "")"
assert_eq "CoD audio/loudspeaker -> speaker" "speaker"     "$(_type_from_class 0x200414 "")"
assert_eq "CoD audio/portable -> speaker"    "speaker"     "$(_type_from_class 0x20041c "")"
assert_eq "CoD phone -> phone"               "phone"       "$(_type_from_class 0x5a020c "")"
assert_eq "CoD peripheral/gamepad -> gamepad" "gamepad"    "$(_type_from_class 0x000508 "")"
assert_eq "CoD peripheral/keyboard -> keyboard" "keyboard" "$(_type_from_class 0x000540 "")"
assert_eq "CoD peripheral/mouse -> mouse"    "mouse"       "$(_type_from_class 0x000580 "")"
assert_eq "CoD wearable/watch -> watch"      "watch"       "$(_type_from_class 0x000704 "")"
assert_eq "appearance earbuds when no class" "earbuds"     "$(_type_from_class "" 0x0941)"
assert_eq "empty both -> nothing"            ""            "$(_type_from_class "" "")"
assert_eq "unknown class -> nothing"         ""            "$(_type_from_class 0x1f00ff "")"

if [[ $fail -eq 0 ]]; then
  echo "All tests passed."
else
  echo "Some tests failed."
fi
exit $fail
