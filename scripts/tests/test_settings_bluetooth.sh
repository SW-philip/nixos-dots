#!/usr/bin/env bash
# Fixture tests for scripts/settings/bluetooth.sh.
# shellcheck disable=SC2016 # shim bodies expand when the shim runs, not here
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/settings_testlib.sh"
H="$SETTINGS_DIR/bluetooth.sh"
export SETTINGS_BT_SCAN_WAIT=0

shim bluetoothctl '[[ "$1" == show ]] && printf "Controller AA:BB\n\tPowered: %s\n" "${BT_POWERED:-yes}"; exit 0'
shim quantum-btmenu 'echo "scan=${QUANTUM_BT_SCAN:-unset}" >> "$FAKE_LOG"'
shim notify-send

out=$(BT_POWERED=yes bash "$H" --list)
assert_has "powered: devices row" "Devices" "$out"
assert_has "powered: offers off" "Turn Bluetooth off" "$out"
assert_has "powered: pair row" "Pair a new device" "$out"

out=$(BT_POWERED=no bash "$H" --list)
assert_has "unpowered: offers on" "Turn Bluetooth on" "$out"
assert_lacks "unpowered: no devices row" "Devices" "$out"
assert_lacks "unpowered: no pair row" "Pair a new device" "$out"

: > "$FAKE_LOG"; printf 'Turn Bluetooth off\n' > "$PICKS"
BT_POWERED=yes bash "$H"
assert_has "power off" "bluetoothctl power off" "$(cat "$FAKE_LOG")"

# pairing: adapter must be pairable (it comes up Pairable: no), scan is bounded,
# and the device menu opens in scan mode
: > "$FAKE_LOG"; printf 'Pair a new device\n' > "$PICKS"
BT_POWERED=yes bash "$H"
sleep 0.3
log=$(cat "$FAKE_LOG")
assert_has "pair: pairable on" "bluetoothctl pairable on" "$log"
assert_has "pair: bounded scan" "bluetoothctl --timeout 60 scan on" "$log"
assert_has "pair: menu in scan mode" "scan=1" "$log"

# quantum-btmenu exits non-zero on Escape: that is "back", not a failure
shim quantum-btmenu 'exit 1'
for pick in 'Devices' 'Pair a new device'; do
  : > "$FAKE_LOG"; printf '%s\n' "$pick" > "$PICKS"
  BT_POWERED=yes bash "$H"; rc=$?
  assert_eq "cancelled $pick: exit 10" 10 "$rc"
  assert_has "cancelled $pick: still handed off" "quantum-btmenu" "$(cat "$FAKE_LOG")"
  assert_lacks "cancelled $pick: no toast" "notify-send Settings" "$(cat "$FAKE_LOG")"
done

: > "$PICKS"
BT_POWERED=yes bash "$H"; rc=$?
assert_eq "escape: exit 10" 10 "$rc"

# shellcheck disable=SC2154 # fail is set by settings_testlib.sh
exit "$fail"
