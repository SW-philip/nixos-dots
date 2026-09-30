#!/usr/bin/env bash
# ============================================================
# volume_watch.sh
# Refreshes the waybar volume module the instant PipeWire's sink
# volume/mute actually changes — from ANY source (media keys,
# pavucontrol, scroll, a Bluetooth remote's own volume buttons) —
# instead of only the handful of paths this repo explicitly wires
# a waybar signal onto.
#
# pw-dump -m streams incremental diffs, not a full re-dump, so most
# events won't even mention a sink node; the jq filter below yields
# "[]" for those and we skip them.
# ============================================================
set -euo pipefail

FILTER='[.[] | select(.info.props["media.class"]? == "Audio/Sink") | {id, mute: (.info.params.Props[0].mute // false), vol: (.info.params.Props[0].channelVolumes // [])}]'

pw-dump -m -N 2>/dev/null | jq -c --unbuffered "$FILTER" | \
  while read -r state; do
    [[ "$state" == "[]" ]] && continue
    pkill -RTMIN+1 waybar 2>/dev/null || true
  done
