#!/usr/bin/env bash
# snark: turn the commentary (tooltips, ledger chip, lock screen) off and on.
#   snark [status|on|off|toggle]
# The flag is a file; consumers check for it each time they pick a line.
set -euo pipefail

flag="${XDG_STATE_HOME:-$HOME/.local/state}/snark-off"

is_on() { [[ ! -e "$flag" ]]; }
say() { is_on && echo "snark: on" || echo "snark: off"; }
set_off() { mkdir -p "$(dirname "$flag")"; touch "$flag"; }

case "${1:-status}" in
  status) say ;;
  on)     rm -f "$flag"; say ;;
  off)    set_off; say ;;
  toggle) if is_on; then set_off; else rm -f "$flag"; fi; say ;;
  *) echo "usage: snark [status|on|off|toggle]" >&2; exit 2 ;;
esac
