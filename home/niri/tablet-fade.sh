#!/usr/bin/env bash
# Full-screen crossfade over the tablet-mode switchover (cover attach/detach).
# `out` fades a palette-colour overlay in; `in` fades it back out once the
# switch is done. Never leaves the screen covered: a watchdog closes the
# overlay if `in` never arrives.
set -uo pipefail

EWW="${TABLET_EWW:-eww}"
SYSTEMCTL="${TABLET_SYSTEMCTL:-systemctl}"
WAIT="${TABLET_FADE_WAIT:-0.35}"
WATCHDOG="${TABLET_FADE_WATCHDOG:-6}"
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
WD_FILE="$RUNTIME/tablet-fade.watchdog"

# A usage error exits 2 whatever the daemon state, so check it before the guards.
case "${1:-}" in
  out|in) ;;
  *) echo "usage: tablet-fade out|in" >&2; exit 2 ;;
esac

# Kid's session shares surface-kbd-monitor but has no eww daemon; and an
# `eww open` with no daemon would spawn one outside eww.service.
"$SYSTEMCTL" --user cat eww.service >/dev/null 2>&1 || exit 0
"$EWW" ping >/dev/null 2>&1 || exit 0

stop_watchdog() {
  if [[ -s "$WD_FILE" ]]; then
    local pid kids
    pid=$(cat "$WD_FILE")
    # The watchdog's own `sleep` outlives a kill of its subshell; reap it too.
    kids=$(pgrep -P "$pid" 2>/dev/null)
    # shellcheck disable=SC2086
    kill "$pid" $kids 2>/dev/null
  fi
  rm -f "$WD_FILE"
}

case "${1:-}" in
  out)
    stop_watchdog
    # Armed before the overlay goes up, so a kill mid-fade can't strand it. On
    # firing it drops its pid file, unless a newer `out` already replaced it.
    (
      sleep "$WATCHDOG"
      "$EWW" close tablet-fade >/dev/null 2>&1
      [[ "$(cat "$WD_FILE" 2>/dev/null)" == "$BASHPID" ]] && rm -f "$WD_FILE"
    ) >/dev/null 2>&1 &
    echo $! > "$WD_FILE"
    disown
    "$EWW" open tablet-fade >/dev/null 2>&1
    "$EWW" update fade_on=true >/dev/null 2>&1
    sleep "$WAIT"
    ;;
  in)
    "$EWW" update fade_on=false >/dev/null 2>&1
    sleep "$WAIT"
    "$EWW" close tablet-fade >/dev/null 2>&1
    stop_watchdog
    ;;
esac
