#!/usr/bin/env bash
# Toggle the eww notif-center on the focused output; the flag file gates notif-controls feed. EWW, NIRI, JQ, NOTIF_HISTORY_BIN come from the Nix wrapper.
: "${EWW:?}"
flag="${XDG_RUNTIME_DIR:-/tmp}/notif-center-open"
if "$EWW" active-windows 2>/dev/null | grep -q '^notif-center'; then
  rm -f "$flag"
  "$EWW" close notif-center
  # query reset spawns python (~200 ms); detach so it can't delay the close
  ("${NOTIF_HISTORY_BIN:-true}" query "" >/dev/null 2>&1 &)
else
  # raise the flag first so the controls refresh runs while niri/eww set the window up
  : > "$flag"
  out="$("${NIRI:-niri}" msg -j focused-output 2>/dev/null | "${JQ:-jq}" -r .name 2>/dev/null || true)"
  if [ -n "$out" ]; then "$EWW" open notif-center --screen "$out"; else "$EWW" open notif-center; fi
fi
