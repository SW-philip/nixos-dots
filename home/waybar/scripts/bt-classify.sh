#!/usr/bin/env bash
set -uo pipefail

# 16-bit Bluetooth SIG service class UUIDs (full 128-bit form, lowercase)
# that mark a device as audio- or input-capable. Deliberately conservative:
# anything not explicitly listed classifies as "other", so an unrecognized
# device (e.g. the Ember mug, which lists Device Information/vendor UUIDs
# only) never gets treated as audio-capable by default.
_AUDIO_UUIDS="0000110a-0000-1000-8000-00805f9b34fb
0000110b-0000-1000-8000-00805f9b34fb
0000110c-0000-1000-8000-00805f9b34fb
0000110e-0000-1000-8000-00805f9b34fb
00001108-0000-1000-8000-00805f9b34fb
0000111e-0000-1000-8000-00805f9b34fb"

_INPUT_UUIDS="00001124-0000-1000-8000-00805f9b34fb"

# _type_from_uuids <newline-separated UUIDs, lowercase>
# Pure: no device/network access. Prints audio|input|other.
_type_from_uuids() {
  local uuids="$1" u
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    grep -qxF "$u" <<<"$_AUDIO_UUIDS" && { echo "audio"; return; }
  done <<<"$uuids"
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    grep -qxF "$u" <<<"$_INPUT_UUIDS" && { echo "input"; return; }
  done <<<"$uuids"
  echo "other"
}

# _type_from_class <class_hex> <appearance_hex>
# Pure: no device/network access. Decode a BR/EDR Class-of-Device value
# (e.g. 0x240404) and, failing that, a BLE Appearance value (e.g. 0x0941)
# into a fine device type. Prints "" when neither says anything
# recognisable -- the caller then falls back to _type_from_uuids.
#
# CoD layout (24 bits): bits 13-23 service classes (ignored here),
# bits 8-12 major device class, bits 2-7 minor device class. Audio minor
# values are BT Assigned Numbers: 1 headset, 2 hands-free, 5 loudspeaker,
# 6 headphones, 7 portable audio. Peripheral minor bit 0x10 = keyboard,
# 0x20 = pointing device.
_type_from_class() {
  local class="${1#0x}" appearance="${2#0x}"
  if [[ -n "$class" ]]; then
    local n=$((16#$class))
    local major=$(( (n >> 8) & 0x1f ))
    local minor=$(( (n >> 2) & 0x3f ))
    case "$major" in
      4)  # Audio/Video
        case "$minor" in
          1|2) echo "headset"; return ;;
          6)   echo "headphones"; return ;;
          5|7) echo "speaker"; return ;;
          *)   echo "headset"; return ;;   # unclassified audio -- better than nothing
        esac ;;
      2)  echo "phone"; return ;;
      5)  # Peripheral
        case $(( minor & 0x30 )) in
          16) echo "keyboard"; return ;;
          32) echo "mouse"; return ;;
          48) echo "keyboard"; return ;;   # keyboard+pointing combo
          *)  echo "gamepad"; return ;;    # joystick / gamepad / remote
        esac ;;
      7)  echo "watch"; return ;;
    esac
  fi
  case "$appearance" in
    0941|0942|0943)               echo "earbuds"; return ;;
    00c0|0180|0181|0182|0183|0184) echo "watch"; return ;;
    0341|0342)                    echo "headphones"; return ;;
    03c1|03c2)                    echo "gamepad"; return ;;
  esac
  echo ""
}

# _mac_underscore <MAC>
# Pure: PipeWire's bluez node names replace ':' with '_', case preserved.
_mac_underscore() {
  echo "${1//:/_}"
}

# type_cmd <mac> -- classify a device from its bonded/cached UUID list.
# Works whether or not the device is currently connected.
type_cmd() {
  local mac="$1" info uuids class appearance fine
  info=$(printf "info %s\nquit\n" "$mac" | bluetoothctl 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g;s/\r//g')
  class=$(grep -oP 'Class:\s*\K0x[0-9a-fA-F]+' <<<"$info" | head -n1)
  appearance=$(grep -oP 'Appearance:\s*\K0x[0-9a-fA-F]+' <<<"$info" | head -n1)
  fine=$(_type_from_class "$class" "$appearance")
  if [[ -n "$fine" ]]; then
    echo "$fine"
    return
  fi
  uuids=$(grep -oP '\(\K[0-9a-fA-F-]{36}(?=\))' <<<"$info" | tr '[:upper:]' '[:lower:]')
  _type_from_uuids "$uuids"
}

# audio_active_cmd <mac> -- yes/no: does this exact device have a live
# PipeWire bluez_output node right now. Same node.name correlation
# quantum-btmenu.sh's connect flow already uses for wpctl set-default.
audio_active_cmd() {
  local mac="$1" mac_under sink_id
  mac_under=$(_mac_underscore "$mac")
  sink_id=$(pw-dump 2>/dev/null | jq -r --arg name "bluez_output.${mac_under}" \
    '.[] | select(.info.props["node.name"] // "" | startswith($name)) | .id' | head -n1)
  if [[ -n "$sink_id" ]]; then
    echo "yes"
  else
    echo "no"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    type) type_cmd "${2:?mac required}" ;;
    audio-active) audio_active_cmd "${2:?mac required}" ;;
    *) echo "usage: bt-classify {type|audio-active} <mac>" >&2; exit 1 ;;
  esac
fi
