#!/usr/bin/env bash
# Toggle the eww notif-center on the focused output; the flag file gates notif-controls feed. EWW, NIRI, JQ, NOTIF_HISTORY_BIN come from the Nix wrapper.
: "${EWW:?}"
flag="${XDG_RUNTIME_DIR:-/tmp}/notif-center-open"
if "$EWW" active-windows 2>/dev/null | grep -q '^notif-center'; then
  rm -f "$flag"
  "${NOTIF_HISTORY_BIN:-true}" query "" 2>/dev/null || true
  "$EWW" close notif-center
else
  out="$("${NIRI:-niri}" msg -j focused-output 2>/dev/null | "${JQ:-jq}" -r .name 2>/dev/null || true)"
  printf '%s' "$out" > "$flag"
  if [ -n "$out" ]; then "$EWW" open notif-center --screen "$out"; else "$EWW" open notif-center; fi
fi
