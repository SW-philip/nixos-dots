#!/usr/bin/env bash
# Step a wing/ledger panel one slot along its axis across all displays:
#   wing:   left/right      ledger: up/down
# One press snaps to that side of the current display; a second press hops to
# that side of the neighbouring display (left twice = left edge of the left
# display), and stops at the last display.
set -euo pipefail

STATE_DIR="${EWW_PANEL_EDGE_STATE_DIR:-$HOME/.local/state}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_BIN="${EWW_PANEL_EDGE_BIN:-$DIR/panel-edge.sh}"

usage() { echo "usage: eww-panel-step <wing|ledger> <left|right|up|down>" >&2; exit 1; }
[ $# -eq 2 ] || usage
slot="$1"; dir="$2"

case "$slot:$dir" in
  wing:left|wing:right|ledger:up|ledger:down) ;;
  *) usage ;;
esac

# Outputs ordered left-to-right by position (up/down walk the same order as
# left/right, so the ledger hops between side-by-side displays too).
# Disabled outputs have no logical geometry and are skipped. EWW_PANEL_OUTPUTS
# overrides niri for tests.
if [ -n "${EWW_PANEL_OUTPUTS:-}" ]; then
  read -r -a outs <<< "$EWW_PANEL_OUTPUTS"
else
  mapfile -t outs < <(niri msg -j outputs | jq -r \
    'to_entries | map(select(.value.logical != null)) | sort_by(.value.logical.x) | .[].key')
fi
[ "${#outs[@]}" -gt 0 ] || { echo "eww-panel-step: no outputs" >&2; exit 1; }

edge_file="$STATE_DIR/eww-panel-edge-$slot"
screen_file="$STATE_DIR/eww-panel-screen-$slot"
edge="$(cat "$edge_file" 2>/dev/null || true)"
screen="$(cat "$screen_file" 2>/dev/null || echo "${EWW_PANEL_DEFAULT_SCREEN:-${outs[-1]}}")"

idx=0
for i in "${!outs[@]}"; do [ "${outs[$i]}" = "$screen" ] && idx=$i; done

case "$dir" in left|up) lo=1 ;; *) lo=0 ;; esac
case "$slot" in wing) near_a=left; near_b=right ;; ledger) near_a=top; near_b=bottom ;; esac
# near_a is the low-index side of a display, near_b the high-index side. A
# press first snaps to that side of the current display; pressing again at
# that side hops to the same side of the next display, and stops at the last.
if [ "$lo" = 1 ]; then
  if [ "$edge" = "$near_a" ] && [ "$idx" -gt 0 ]; then idx=$((idx-1)); fi
  edge="$near_a"
else
  if [ "$edge" = "$near_b" ] && [ "$idx" -lt $((${#outs[@]}-1)) ]; then idx=$((idx+1)); fi
  edge="$near_b"
fi

exec bash "$EDGE_BIN" "$slot" "$edge" "${outs[$idx]}"
