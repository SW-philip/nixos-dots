#!/usr/bin/env bash
# Swaps the surface's bar to match the Type Cover: detached => eww tablet
# strip (waybar stopped), attached => waybar. Idempotent. Reads the state file
# surface-kbd-monitor writes.
set -uo pipefail

EWW="${TABLET_EWW:-eww}"
SYSTEMCTL="${TABLET_SYSTEMCTL:-systemctl}"
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE="$RUNTIME/surface-cover"
# waybar.service's ExecCondition lets waybar run while detached only if this exists
FAILED="$RUNTIME/tablet-strip-failed"
WAIT="${TABLET_STRIP_WAIT:-3}"

# Kid's session shares surface-kbd-monitor but has no eww daemon
"$SYSTEMCTL" --user cat eww.service >/dev/null 2>&1 || exit 0

strip_up() { "$EWW" active-windows 2>/dev/null | grep -q '^tablet-strip:'; }

if [ "$(cat "$STATE" 2>/dev/null)" = detached ]; then
  rm -f "$FAILED"
  # `eww open` spawns its own daemon when the socket is dead, outside eww.service's cgroup.
  # eww.service's ExecStartPost reruns this script once the daemon is up.
  daemon_up=
  for _ in $(seq 1 $((WAIT * 5))); do
    "$EWW" ping >/dev/null 2>&1 && { daemon_up=1; break; }
    sleep 0.2
  done
  if [ -z "$daemon_up" ]; then
    touch "$FAILED"
    "$SYSTEMCTL" --user start waybar.service 2>/dev/null || true
    exit 0
  fi
  "$SYSTEMCTL" --user stop waybar.service 2>/dev/null || true
  strip_up || "$EWW" open tablet-strip >/dev/null 2>&1 || true
  for _ in $(seq 1 $((WAIT * 5))); do
    strip_up && exit 0
    sleep 0.2
  done
  touch "$FAILED"
  "$SYSTEMCTL" --user start waybar.service 2>/dev/null || true
else
  rm -f "$FAILED"
  "$EWW" close tablet-sheet tablet-strip >/dev/null 2>&1 || true
  "$SYSTEMCTL" --user start waybar.service 2>/dev/null || true
fi
