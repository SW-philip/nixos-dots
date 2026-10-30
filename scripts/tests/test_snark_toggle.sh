#!/usr/bin/env bash
# Tests for scripts/snark.sh and the quiet-mode check in waybar-lib.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export XDG_STATE_HOME="$T/state"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

S="$ROOT/scripts/snark.sh"
assert_eq "default is on" "snark: on" "$(bash "$S")"
assert_eq "off" "snark: off" "$(bash "$S" off)"
assert_eq "flag file exists" yes "$([[ -e $XDG_STATE_HOME/snark-off ]] && echo yes || echo no)"
assert_eq "off sticks" "snark: off" "$(bash "$S" status)"
assert_eq "toggle back on" "snark: on" "$(bash "$S" toggle)"
assert_eq "toggle off" "snark: off" "$(bash "$S" toggle)"
assert_eq "on" "snark: on" "$(bash "$S" on)"
bash "$S" bogus 2>/dev/null; assert_eq "bad arg: exit 2" 2 $?

# waybar-lib: quiet mode returns nothing and trims the rule + snark tail
cat > "$T/snark.json" <<'JSON'
{"network": {"wired": ["a line"]}}
JSON
lib() { SNARK_FILE="$T/snark.json" bash -c "source '$ROOT/home/waybar/scripts/waybar-lib.sh'; $1"; }
assert_eq "on: picks a line" "a line" "$(lib "waybar_snark network wired fb")"
bash "$S" off >/dev/null
assert_eq "off: no line, fallback ignored" "" "$(lib "waybar_snark network wired fb")"
tip=$'head\nrule\nsnark'
assert_eq "off: tail trimmed" "head" "$(lib "waybar_unsnark \$'$tip'" | tr -d '\r')"
bash "$S" on >/dev/null
assert_eq "on: tail kept" $'head\nrule\nsnark' "$(lib "waybar_unsnark \$'head\\nrule\\nsnark'")"

exit "$fail"
