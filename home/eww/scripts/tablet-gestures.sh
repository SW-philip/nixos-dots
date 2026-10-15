#!/usr/bin/env bash
# Edge swipes for the tablet shell via lisgd. lisgd works in the touch panel's
# native orientation (-w/-h are the native panel size) and rotates swipe
# directions and edge zones itself from -o, so the loop below only restarts it
# when the output transform changes.
set -uo pipefail

OUTPUT="${GESTURES_OUTPUT:-eDP-1}"
LISGD="${GESTURES_LISGD:-lisgd}"
ACT="${GESTURES_ACT:-tablet-act}"
SYSFS_INPUT="${GESTURES_SYSFS_INPUT:-/sys/class/input}"
DEV_DIR="${GESTURES_DEV_DIR:-/dev/input}"
POLL="${GESTURES_POLL:-1}"
DEVICE_NAME="IPTSD Virtual Touchscreen"

find_device() {
  local f n
  for f in "$SYSFS_INPUT"/event*/device/name; do
    [[ -r "$f" ]] || continue
    n=$(<"$f")
    if [[ "$n" == "$DEVICE_NAME"* ]]; then
      f=${f%/device/name}
      echo "$DEV_DIR/${f##*/}"
      return 0
    fi
  done
  return 1
}

# lisgd opens the evdev node once; when iptsd recreates the uinput device the
# eventN number can be reused, but the inputNN it links to is always new.
device_id() { # <dev node>
  local n=${1##*/} l
  l=$(readlink "$SYSFS_INPUT/$n/device" 2>/dev/null) || l=$n
  echo "${l##*/}"
}

transform() {
  niri msg --json outputs 2>/dev/null | jq -r --arg o "$OUTPUT" '.[$o].logical.transform // "Normal"'
}

native_size() {
  niri msg --json outputs 2>/dev/null \
    | jq -r --arg o "$OUTPUT" '.[$o] | .modes[.current_mode] | "\(.width) \(.height)"' 2>/dev/null
}

# lisgd's -o counts 90-degree turns of the gesture frame. Defaults are a first
# guess from lisgd's own wl_output mapping; GESTURES_O90/O270 exist so the real
# values can be found on the device without a rebuild.
orientation_for() {
  case "$1" in
    90)  echo "${GESTURES_O90:-3}" ;;
    180) echo 2 ;;
    270) echo "${GESTURES_O270:-1}" ;;
    *)   echo 0 ;;
  esac
}

lisgd_args() { # <device> <native width> <native height> <orientation>
  printf '%s\n' -d "$1" -w "$2" -h "$3" -o "$4" -s 2 -t 125 -m 800
  if [[ -n "${GESTURES_VERBOSE:-}" ]]; then printf '%s\n' -v; fi
  printf '%s\n' \
    -g "1,UD,T,*,R,$ACT sheet-open" \
    -g "1,DU,B,*,R,$ACT launcher-open" \
    -g "1,LR,L,*,R,$ACT overview" \
    -g "1,RL,R,*,R,$ACT notif"
}

main() {
  local pid="" last="" last_id="" t dev id w h
  local -a args
  stop_lisgd() {
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=""; fi
  }
  trap 'stop_lisgd; exit 0' TERM INT
  trap stop_lisgd EXIT
  while :; do
    id=""
    if dev=$(find_device); then id=$(device_id "$dev"); fi
    if [[ -z "$id" ]]; then
      # no touchscreen node: lisgd is deaf anyway; restart once it reappears
      stop_lisgd
      sleep "$POLL"
      continue
    fi
    t="$(transform)"
    if [[ -z "$t" ]]; then
      # niri msg failed: keep the running orientation; on the first pass assume Normal
      [[ -n "$last" ]] && { sleep "$POLL"; continue; }
      t=Normal
    fi
    if [[ "$t" != "$last" ]] || [[ "$id" != "$last_id" ]] || [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      stop_lisgd
      read -r w h <<<"$(native_size)"
      [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || { w=2736; h=1824; }
      mapfile -t args < <(lisgd_args "$dev" "$w" "$h" "$(orientation_for "$t")")
      "$LISGD" "${args[@]}" &
      pid=$!
      last="$t"
      last_id="$id"
    fi
    sleep "$POLL"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
