#!/usr/bin/env bash
# Fixture tests for scripts/settings/network.sh.
# shellcheck disable=SC2016 # shim bodies expand when the shim runs, not here
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/settings_testlib.sh"
H="$SETTINGS_DIR/network.sh"

shim nmcli '[[ $# -eq 2 && "$1 $2" == "radio wifi" ]] && echo "${WIFI:-enabled}"; exit 0'
shim quantum-wifimenu
shim systemctl 'echo "$VPN_UNITS"'
shim notify-send

out=$(WIFI=enabled VPN_UNITS='' bash "$H" --list)
assert_has "wifi on: networks row" "Wi-Fi networks" "$out"
assert_has "wifi on: offers off" "Turn Wi-Fi off" "$out"
assert_lacks "wifi on: no 'on' row" "Turn Wi-Fi on" "$out"
assert_lacks "no vpn units: no VPN row" "VPN" "$out"

out=$(WIFI=disabled VPN_UNITS=wg-quick-protonvpn-ny.service bash "$H" --list)
assert_has "wifi off: offers on" "Turn Wi-Fi on" "$out"
assert_has "vpn units: VPN row" "VPN" "$out"

: > "$FAKE_LOG"; printf 'Turn Wi-Fi off\n' > "$PICKS"
WIFI=enabled VPN_UNITS='' bash "$H"
assert_has "pick off: nmcli called" "nmcli radio wifi off" "$(cat "$FAKE_LOG")"
assert_has "pick off: toast" "notify-send" "$(cat "$FAKE_LOG")"

: > "$FAKE_LOG"; printf 'Wi-Fi networks\n' > "$PICKS"
WIFI=enabled VPN_UNITS='' bash "$H"
assert_has "pick networks: hands off" "quantum-wifimenu" "$(cat "$FAKE_LOG")"

# quantum menus exit non-zero on Escape: that is "back", not a failure
shim quantum-wifimenu 'exit 1'
: > "$FAKE_LOG"; printf 'Wi-Fi networks\n' > "$PICKS"
WIFI=enabled VPN_UNITS='' bash "$H"; rc=$?
assert_eq "cancelled hand-off: exit 10" 10 "$rc"
assert_has "cancelled hand-off: still handed off" "quantum-wifimenu" "$(cat "$FAKE_LOG")"
assert_lacks "cancelled hand-off: no toast" "notify-send" "$(cat "$FAKE_LOG")"

: > "$PICKS"
WIFI=enabled VPN_UNITS='' bash "$H"; rc=$?
assert_eq "escape: exit 10" 10 "$rc"

# shellcheck disable=SC2154 # fail is set by settings_testlib.sh
exit "$fail"
