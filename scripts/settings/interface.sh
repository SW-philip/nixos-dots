#!/usr/bin/env bash
# settings-interface: interface behaviour for the settings hub.
# shellcheck disable=SC2317,SC2329
set -euo pipefail
# shellcheck source=/dev/null
source "${SETTINGS_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib.sh}"

snark_toggle() { toast "Snark" "$(snark toggle)"; }

rows() {
  if [[ "$(snark status)" == "snark: on" ]]; then
    printf '󰋗 Snark is on: turn it off\tsnark_toggle\n'
  else
    printf '󰋗 Snark is off: turn it on\tsnark_toggle\n'
  fi
}

case "${1:-}" in
  --help) echo "usage: settings-interface [--list]"; exit 0 ;;
  --list) export SETTINGS_LIST=1; rows | run_menu "Interface" ;;
  "") rows | run_menu "Interface" ;;
  *) echo "usage: settings-interface [--list]" >&2; exit 2 ;;
esac
