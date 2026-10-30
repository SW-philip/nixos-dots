#!/usr/bin/env bash
# settings-bluetooth: power, device list and pairing for the settings hub.
# shellcheck disable=SC2317,SC2329
set -euo pipefail
# shellcheck source=/dev/null
source "${SETTINGS_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib.sh}"

bt_powered() { [[ "$(bluetoothctl show 2>/dev/null | awk '$1 == "Powered:" {print $2}')" == yes ]]; }

bt_set() { bluetoothctl power "$1" >/dev/null; toast "Bluetooth" "$1"; }

# The quantum menus exit non-zero on Escape; treat that as "back", not a failure.
bt_menu() { quantum-btmenu || return 10; }

# The adapter comes up Pairable: no. One bounded scan (never a long-lived
# bluetoothctl REPL, which caches every advertising device and balloons).
bt_pair() {
  bluetoothctl power on >/dev/null
  bluetoothctl pairable on >/dev/null
  toast "Bluetooth" "Pairing mode on, scanning for 60s"
  bluetoothctl --timeout 60 scan on >/dev/null 2>&1 &
  sleep "${SETTINGS_BT_SCAN_WAIT:-5}"
  QUANTUM_BT_SCAN=1 quantum-btmenu || return 10
}

rows() {
  if bt_powered; then
    printf '󰂯 Devices\tbt_menu\n'
    printf '󰂱 Pair a new device\tbt_pair\n'
    printf '󰂲 Turn Bluetooth off\tbt_set off\n'
  else
    printf '󰂯 Turn Bluetooth on\tbt_set on\n'
  fi
}

case "${1:-}" in
  --help) echo "usage: settings-bluetooth [--list]"; exit 0 ;;
  --list) export SETTINGS_LIST=1; rows | run_menu "Bluetooth" ;;
  "") rows | run_menu "Bluetooth" ;;
  *) echo "usage: settings-bluetooth [--list]" >&2; exit 2 ;;
esac
