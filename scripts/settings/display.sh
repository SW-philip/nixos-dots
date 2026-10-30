#!/usr/bin/env bash
# settings-display: monitor layout/scale (desktop), brightness/rotation/warmth (surface).
# shellcheck disable=SC2317,SC2329
set -euo pipefail
# shellcheck source=/dev/null
source "${SETTINGS_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib.sh}"

# Written by Sunshine's prep-cmd (modules/sunshine.nix). Disabling a captured
# output mid-stream freezes KMS capture, so no monitor rows while it exists.
STREAM_FLAG="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sunshine-streaming"

profile() { kanshictl switch "$1"; toast "Display" "$1"; }

# Temporary: the next kanshi profile switch re-applies its own scale.
scale() {
  local out
  out=$(niri msg --json focused-output | jq -r .name)
  niri msg output "$out" scale "$1"
  toast "Display" "$out scale $1"
}
scale_menu() {
  printf '%s\n' 1.0 1.25 1.5 1.75 2.0 | awk '{printf "󰍹 %s\tscale %s\n", $1, $1}' | run_menu "Scale (focused monitor)"
}

clear_stream_flag() { rm -f "$STREAM_FLAG"; toast "Display" "Stream flag cleared"; }

bright() {
  case "$1" in
    up)   brightnessctl -e4 -n2% set +5% >/dev/null ;;
    down) brightnessctl -e4 -n2% set 5%- >/dev/null ;;
  esac
  toast "Brightness" "$(brightnessctl -m | cut -d, -f4)"
}

toggle_user_unit() { # $1 = unit, $2 = toast title, $3 = toast text when stopped, $4 = when started
  if systemctl --user is-active --quiet "$1"; then
    systemctl --user stop "$1"; toast "$2" "$3"
  else
    systemctl --user start "$1"; toast "$2" "$4"
  fi
}
rotation() { toggle_user_unit niri-rotation.service Rotation locked auto; }
warmth() { toggle_user_unit reader-warmth.service "Reader warmth" off on; }

rows() {
  if has_cap desktop; then
    if [[ -e "$STREAM_FLAG" ]]; then
      printf '󰍹 Streaming: monitor changes are off\ttrue\n'
      printf '󰆴 Clear stale stream flag\tclear_stream_flag\n'
    else
      printf '󰍹 Both monitors\tprofile desktop-dual\n'
      printf '󰍹 DP-2 only\tprofile desktop-single-dp2\n'
      printf '󰍹 Stream layout (DP-2, TV scale)\tprofile desktop-stream\n'
      printf '󰍹 Scale\tscale_menu\n'
    fi
  fi
  if has_cap backlight; then
    printf '󰃟 Brightness up\tbright up\n'
    printf '󰃞 Brightness down\tbright down\n'
  fi
  if has_cap touch; then
    if systemctl --user is-active --quiet niri-rotation.service; then
      printf '󰑵 Lock rotation\trotation\n'
    else
      printf '󰑵 Auto-rotate\trotation\n'
    fi
    if systemctl --user is-active --quiet reader-warmth.service; then
      printf '󰖔 Turn reader warmth off\twarmth\n'
    else
      printf '󰖔 Turn reader warmth on\twarmth\n'
    fi
  fi
}

case "${1:-}" in
  --help) echo "usage: settings-display [--list]"; exit 0 ;;
  --list) export SETTINGS_LIST=1; rows | run_menu "Display" ;;
  "") rows | run_menu "Display" ;;
  *) echo "usage: settings-display [--list]" >&2; exit 2 ;;
esac
