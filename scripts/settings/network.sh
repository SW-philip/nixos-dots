#!/usr/bin/env bash
# settings-network: Wi-Fi and VPN rows for the settings hub.
# shellcheck disable=SC2317,SC2329
set -euo pipefail
# shellcheck source=/dev/null
source "${SETTINGS_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib.sh}"

wifi_set() { nmcli radio wifi "$1"; toast "Wi-Fi" "$1"; }
# The quantum menus exit non-zero on Escape; treat that as "back", not a failure.
wifi_menu() { quantum-wifimenu || return 10; }
vpn_menu() { bash "$HOME/.config/waybar/scripts/vpn-toggle.sh"; }

rows() {
  if command -v quantum-wifimenu >/dev/null; then
    printf '󰖩 Wi-Fi networks\twifi_menu\n'
  fi
  if [[ "$(nmcli radio wifi)" == enabled ]]; then
    printf '󰖪 Turn Wi-Fi off\twifi_set off\n'
  else
    printf '󰖩 Turn Wi-Fi on\twifi_set on\n'
  fi
  # Only hosts with the protonvpn module have these units.
  if [[ -n "$(systemctl list-unit-files 'wg-quick-protonvpn-*' --no-legend 2>/dev/null)" ]]; then
    printf '󰖂 VPN\tvpn_menu\n'
  fi
}

case "${1:-}" in
  --help) echo "usage: settings-network [--list]"; exit 0 ;;
  --list) export SETTINGS_LIST=1; rows | run_menu "Network" ;;
  "") rows | run_menu "Network" ;;
  *) echo "usage: settings-network [--list]" >&2; exit 2 ;;
esac
