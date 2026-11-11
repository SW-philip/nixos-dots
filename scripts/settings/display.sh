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

# Moonlight mode = DP-2 alone at the TV's couch scale (desktop-stream). DP-2
# stays enabled both ways, so it's safe mid-stream. Leaving mid-stream only
# drops the scale: a kanshi switch would run single-dp2's exec, which forces
# the S/PDIF sink and stalls Sunshine's audio.
dp2_scale() { niri msg --json outputs | jq -r '.["DP-2"].logical.scale // empty'; }
moonlight_on() { [[ "$(dp2_scale)" == 1.75 ]]; }
moonlight() {
  if ! moonlight_on; then
    kanshictl switch desktop-stream; toast "Display" "Moonlight mode on"
  elif [[ -e "$STREAM_FLAG" ]]; then
    niri msg output DP-2 scale 1.25; toast "Display" "Moonlight mode off"
  else
    kanshictl switch desktop-dual; toast "Display" "Moonlight mode off"
  fi
}
moonlight_row() {
  if moonlight_on; then printf '󰊗 Moonlight mode: on\tmoonlight\n'
  else printf '󰊗 Moonlight mode: off\tmoonlight\n'; fi
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
      moonlight_row
      printf '󰆴 Clear stale stream flag\tclear_stream_flag\n'
    else
      printf '󰍹 Both monitors\tprofile desktop-dual\n'
      printf '󰍹 DP-2 only\tprofile desktop-single-dp2\n'
      moonlight_row
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
