#!/usr/bin/env bash
# settings-audio: default output/input, volume, output pin and mixer for the settings hub.
# shellcheck disable=SC2317,SC2329
set -euo pipefail
# shellcheck source=/dev/null
source "${SETTINGS_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib.sh}"

default_name() { # $1 = sink|source
  pw-dump | jq -r --arg k "default.audio.$1" '
    [.[] | select(.type == "PipeWire:Interface:Metadata" and .props["metadata.name"] == "default")
     | .metadata[]? | select(.key == $k) | .value.name] | first // ""'
}

# $1 = sink|source, $2 = function to run with the node id. "● " marks the default.
node_rows() {
  local class def
  if [[ "$1" == sink ]]; then class=Audio/Sink; else class=Audio/Source; fi
  def=$(default_name "$1")
  pw-dump | jq -r --arg c "$class" --arg d "$def" --arg fn "$2" '
    .[] | select(.type == "PipeWire:Interface:Node" and .info.props["media.class"] == $c)
    | "\(if .info.props["node.name"] == $d then "● " else "  " end)\(.info.props["node.description"] // .info.props["node.name"])\t\($fn) \(.id)"'
}

node_desc() {
  pw-dump | jq -r --argjson id "$1" '.[] | select(.id == $id) | .info.props["node.description"] // .info.props["node.name"]'
}

set_default() { wpctl set-default "$1"; toast "Audio" "Default: $(node_desc "$1")"; }

output_menu() { node_rows sink set_default | run_menu "Output"; }
input_menu() { node_rows source set_default | run_menu "Input"; }

vol() {
  case "$1" in
    up)   wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+ ;;
    down) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
    mute) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
  esac
  toast "Volume" "$(wpctl get-volume @DEFAULT_AUDIO_SINK@)"
}

# While pinned, the desktop's kanshi-driven sink routing (set-default-sink)
# leaves the default alone. Lasts until unpinned or logout.
pin() { touch "$PIN_FILE"; toast "Audio" "Output pinned"; }
unpin() { rm -f "$PIN_FILE"; toast "Audio" "Output follows the display again"; }

mixer() { setsid -f pavucontrol >/dev/null 2>&1; }

rows() {
  printf '󰓃 Output\toutput_menu\n'
  printf '󰍬 Input\tinput_menu\n'
  printf '󰝝 Volume up\tvol up\n'
  printf '󰝞 Volume down\tvol down\n'
  printf '󰖁 Mute / unmute\tvol mute\n'
  if has_cap desktop; then
    if [[ -e "$PIN_FILE" ]]; then
      printf '󰐃 Unpin output (follow the display)\tunpin\n'
    else
      printf '󰐃 Pin output (stop auto-routing)\tpin\n'
    fi
  fi
  printf '󰒓 Open mixer\tmixer\n'
}

case "${1:-}" in
  --help) echo "usage: settings-audio [--list|--list-outputs|--list-inputs]"; exit 0 ;;
  --list) export SETTINGS_LIST=1; rows | run_menu "Audio" ;;
  --list-outputs) node_rows sink set_default | cut -f1 ;;
  --list-inputs) node_rows source set_default | cut -f1 ;;
  "") rows | run_menu "Audio" ;;
  *) echo "usage: settings-audio [--list|--list-outputs|--list-inputs]" >&2; exit 2 ;;
esac
