#!/usr/bin/env bash
# Polls eDP-1's niri transform; on an orientation change writes the waybar
# layout mode and restarts waybar (the launcher reads the mode file).

OUTPUT="eDP-1"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/waybar-mode"

classify() {
  case "$1" in
    *90|*270) echo portrait ;;
    *)        echo landscape ;;
  esac
}

transform() {
  niri msg --json outputs 2>/dev/null | jq -r --arg o "$OUTPUT" '.[$o].logical.transform // "Normal"'
}

# eww resolves the strip/sheet :width "100%" when the window opens, so a
# detached cover needs them reopened at the new geometry.
reopen_tablet_windows() {
  [[ "$(cat "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/surface-cover" 2>/dev/null)" == detached ]] || return 0
  "${ORIENT_EWW:-eww}" close tablet-sheet tablet-strip >/dev/null 2>&1
  "${ORIENT_TABLET_SHELL:-tablet-shell}"
}

main() {
  mkdir -p "$(dirname "$STATE")"
  local want have
  while :; do
    want="$(classify "$(transform)")"
    have="$(cat "$STATE" 2>/dev/null)"
    if [[ "$want" != "$have" ]]; then
      echo "$want" > "$STATE"
      systemctl --user restart waybar.service
      reopen_tablet_windows
    fi
    sleep 1
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
