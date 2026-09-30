#!/usr/bin/env bash
# Pure-function tests for quantum_clock.sh hex mode.
# Requires ~/.config/waybar/palette.sh to exist (same runtime dependency
# as quantum_clock.sh itself) — run on a host where it's deployed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/quantum_clock.sh"

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

assert_eq "_hex_digit 0"  "0" "$(_hex_digit 0)"
assert_eq "_hex_digit 9"  "9" "$(_hex_digit 9)"
assert_eq "_hex_digit 10" "A" "$(_hex_digit 10)"
assert_eq "_hex_digit 15" "F" "$(_hex_digit 15)"

assert_eq "_hex_fields midnight"  "0 0 0"  "$(_hex_fields 0 0 0)"
assert_eq "_hex_fields noon"      "8 0 0"  "$(_hex_fields 12 0 0)"
assert_eq "_hex_fields 13:30:00"  "9 0 0"  "$(_hex_fields 13 30 0)"
assert_eq "_hex_fields 13:35:13"  "9 0 14" "$(_hex_fields 13 35 13)"
assert_eq "_hex_fields 13:36:00"  "9 1 1"  "$(_hex_fields 13 36 0)"

assert_eq "_hexhour_progress start of hexhour"   "0"   "$(_hexhour_progress 0 0 0)"
assert_eq "_hexhour_progress next hexhour start" "0"   "$(_hexhour_progress 1 30 0)"
assert_eq "_hexhour_progress halfway"            "500" "$(_hexhour_progress 0 45 0)"
assert_eq "_hexhour_progress ten minutes in"     "111" "$(_hexhour_progress 0 10 0)"

assert_eq "_hex_gradient_block progress=0 i=0"    "0"    "$(_hex_gradient_block 0 0)"
assert_eq "_hex_gradient_block progress=1000 i=0" "1000" "$(_hex_gradient_block 0 1000)"
assert_eq "_hex_gradient_block progress=1000 i=7" "1000" "$(_hex_gradient_block 7 1000)"
assert_eq "_hex_gradient_block progress=500 i=3"  "437"  "$(_hex_gradient_block 3 500)"

assert_eq "_lerp_rgb blend=0"    "000000" "$(_lerp_rgb 000000 ffffff 0)"
assert_eq "_lerp_rgb blend=1000" "ffffff" "$(_lerp_rgb 000000 ffffff 1000)"
assert_eq "_lerp_rgb blend=500"  "7f7f7f" "$(_lerp_rgb 000000 ffffff 500)"

bar_expected_start=""
for _i in 1 2 3 4 5 6 7 8; do bar_expected_start+='<span foreground="#0d1b2a">█</span>'; done
assert_eq "_hex_gradient_bar progress=0 all col_a" "$bar_expected_start" "$(_hex_gradient_bar 0 0)"

bar_expected_end=""
for _i in 1 2 3 4 5 6 7 8; do bar_expected_end+='<span foreground="#1b2838">█</span>'; done
assert_eq "_hex_gradient_bar progress=1000 all col_b" "$bar_expected_end" "$(_hex_gradient_bar 0 1000)"

if [[ $fail -eq 0 ]]; then
  echo "All tests passed."
else
  echo "Some tests failed."
fi
exit $fail
