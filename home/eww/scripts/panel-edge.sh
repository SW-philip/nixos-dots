#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${EWW_PANEL_EDGE_STATE_DIR:-$HOME/.local/state}"

usage() {
  echo "usage: eww-panel-edge <wing|wing-tv|ledger|ledger-tv> <edge> [screen]" >&2
  exit 1
}

window_name() {
  case "$1" in
    wing)      echo "status-$2" ;;
    wing-tv)   echo "status-tv-$2" ;;
    ledger)    echo "ledger-$2" ;;
    ledger-tv) echo "ledger-tv-$2" ;;
  esac
}

[ $# -eq 2 ] || [ $# -eq 3 ] || usage
slot="$1"
edge="$2"
screen="${3:-}"

case "$slot" in
  wing|wing-tv)     valid="left right" ;;
  ledger|ledger-tv) valid="top bottom" ;;
  *) echo "eww-panel-edge: unknown slot '$slot' (want: wing, wing-tv, ledger, ledger-tv)" >&2; exit 1 ;;
esac

case " $valid " in
  *" $edge "*) ;;
  *) echo "eww-panel-edge: invalid edge '$edge' for slot '$slot' (want: $valid)" >&2; exit 1 ;;
esac

state_file="$STATE_DIR/eww-panel-edge-$slot"
mkdir -p "$STATE_DIR"
printf '%s' "$edge" > "$state_file"
# The screen file is only written when a screen is given; no file means the
# window's own :monitor (home/eww/default.nix substitutes the connector).
if [ -n "$screen" ]; then
  printf '%s' "$screen" > "$STATE_DIR/eww-panel-screen-$slot"
fi

# Close every other legal edge for this slot unconditionally rather than
# trusting the old state-file value -- self-healing if the real daemon and
# the state file ever disagree (corrupted/hand-edited file, a crash between
# write and open, etc). A close against a window that isn't actually open
# is a harmless no-op, silenced here; the open below is NOT silenced, since
# a failed open on an interactive CLI should be a visible failure.
for e in $valid; do
  [ "$e" = "$edge" ] || eww close "$(window_name "$slot" "$e")" >/dev/null 2>&1 || true
done

win="$(window_name "$slot" "$edge")"
if [ -n "$screen" ]; then
  # Re-opening an already-open window on another screen needs a close first.
  eww close "$win" >/dev/null 2>&1 || true
  eww open "$win" --screen "$screen"
else
  eww open "$win"
fi
