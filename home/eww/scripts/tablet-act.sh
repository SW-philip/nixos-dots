#!/usr/bin/env bash
# Touch actions for the tablet strip and sheet: tablet-act <action> [arg].
set -uo pipefail

EWW="${TABLET_EWW:-eww}"
TOGGLE_OSK="${TABLET_TOGGLE_OSK:-toggle-osk}"
SQLCH_STEP="${TABLET_SQLCH_STEP:-waybar-sqlch}"
LAUNCHER="${TABLET_LAUNCHER:-launcher}"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}"
SHEET_STAMP="$RUNTIME/tablet-sheet-opened"
now_ns() { echo "${TABLET_NOW_NS:-$(date +%s%N)}"; }

# clamp <value> <min> <max>: eww scales send floats ("40.000000"); junk becomes min.
clamp() {
  local v="${1%%.*}"
  [[ "$v" =~ ^[0-9]+$ ]] || v=$2
  (( v < $2 )) && v=$2
  (( v > $3 )) && v=$3
  echo "$v"
}

# eww's scale fires :onchange when the feed sets :value too; skipping a write
# that matches the current level absorbs that echo.
cur_vol() {
  local out
  out=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null) || return 1
  [[ "$out" == "Volume: "* ]] || return 1
  awk '{ printf "%d", $2 * 100 + 0.5 }' <<<"$out"
}
cur_bright() {
  local out
  out=$(brightnessctl -m 2>/dev/null) || return 1
  out=$(cut -d, -f4 <<<"$out" | tr -d '%')
  [[ "$out" =~ ^[0-9]+$ ]] || return 1
  echo "$out"
}

case "${1:-}" in
  vol)
    t=$(clamp "${2:-}" 0 100)
    [[ "$(cur_vol)" == "$t" ]] || wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ "$t%" ;;
  bright)
    t=$(clamp "${2:-}" 1 100)
    [[ "$(cur_bright)" == "$t" ]] || brightnessctl set "$t%" >/dev/null ;;
  mute)   wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
  wifi)
    if [[ "$(nmcli radio wifi)" == enabled ]]; then nmcli radio wifi off; else nmcli radio wifi on; fi ;;
  bt)
    if bluetoothctl show | grep -q 'Powered: yes'; then bluetoothctl power off; else bluetoothctl power on; fi ;;
  osk)    "$TOGGLE_OSK" ;;
  rotate)
    if systemctl --user is-active --quiet niri-rotation.service; then
      systemctl --user stop niri-rotation.service
    else
      systemctl --user start niri-rotation.service
    fi ;;
  dnd)    swaync-client -d >/dev/null ;;
  notif)  "$EWW" close tablet-sheet >/dev/null 2>&1; swaync-client -t >/dev/null ;;
  profile)
    case "$(powerprofilesctl get)" in
      balanced)    next=performance ;;
      performance) next=power-saver ;;
      *)           next=balanced ;;
    esac
    powerprofilesctl set "$next" || powerprofilesctl set power-saver ;;
  sqlch)
    case "${2:-}" in
      toggle)
        if [[ "$(sqlch status | head -1 | tr '[:upper:]' '[:lower:]')" == *paused* ]]; then
          sqlch play-last
        else
          sqlch pause
        fi ;;
      next) "$SQLCH_STEP" --next ;;
      prev) "$SQLCH_STEP" --prev ;;
      *)    echo "tablet-act: sqlch needs toggle|next|prev" >&2; exit 2 ;;
    esac ;;
  sheet)
    # Ignore the strip toggle that arrives with a top-edge swipe, in either order (sheet-open is idempotent).
    last=$(cat "$SHEET_STAMP" 2>/dev/null || true)
    if [[ "$last" =~ ^[0-9]+$ ]] && (( $(now_ns) - last < 800000000 )); then exit 0; fi
    "$EWW" open --toggle tablet-sheet ;;
  sheet-open)
    # eww open with no daemon would start one outside eww.service's cgroup
    "$EWW" ping >/dev/null 2>&1 || exit 0
    now_ns > "$SHEET_STAMP"
    "$EWW" active-windows 2>/dev/null | grep -q '^tablet-sheet:' || "$EWW" open tablet-sheet ;;
  launcher-open)
    "$EWW" ping >/dev/null 2>&1 || exit 0
    "$EWW" active-windows 2>/dev/null | grep -q '^launcher-tablet:' || "$EWW" open launcher-tablet ;;
  overview) niri msg action open-overview ;;
  launcher) "$LAUNCHER" ;;
  suspend) "$EWW" close tablet-sheet >/dev/null 2>&1; systemctl suspend ;;
  *)       echo "usage: tablet-act vol N|bright N|mute|wifi|bt|osk|rotate|dnd|notif|profile|sqlch toggle|next|prev|sheet|sheet-open|overview|launcher|launcher-open|suspend" >&2; exit 2 ;;
esac
