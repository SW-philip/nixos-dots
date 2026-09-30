#!/usr/bin/env bash
set -uo pipefail

JBL_MAC="90_F2_60_B3_88_9F"

# ------------------------------------------------------------
# Resolve the best available audio sink by node name.
# Priority: JBL (by MAC in node name) → any BT → empty string
# ------------------------------------------------------------
find_best_sink() {
  local dump
  dump="$(pw-dump 2>/dev/null)" || dump=""

  if [[ -n "$dump" ]]; then
    # 1. JBL by MAC embedded in node name
    local jbl_id
    jbl_id="$(echo "$dump" | jq -r --arg mac "bluez_output.${JBL_MAC}" \
      '[.[] | select(.type == "PipeWire:Interface:Node") | select(.info.props["node.name"] // "" | startswith($mac))] | first | .id // empty')"
    [[ -n "$jbl_id" ]] && echo "$jbl_id" && return

    # 2. Any other Bluetooth sink
    local bt_id
    bt_id="$(echo "$dump" | jq -r \
      '[.[] | select(.type == "PipeWire:Interface:Node") | select(.info.props["node.name"] // "" | startswith("bluez_output"))] | first | .id // empty')"
    [[ -n "$bt_id" ]] && echo "$bt_id" && return
  fi

  # 3. Fall back to system default sink
  echo "@DEFAULT_AUDIO_SINK@"
}

# ------------------------------------------------------------
# Query JBL transport state and codec from BlueZ D-Bus.
# Returns "STATE:CODEC" (e.g. "idle:SBC") when connected,
# "connected:" when paired but no active transport,
# or empty string when disconnected / unreachable.
# ------------------------------------------------------------
get_jbl_info() {
  local dev="/org/bluez/hci0/dev_${JBL_MAC}"

  local connected
  connected="$(dbus-send --system --print-reply --dest=org.bluez \
    "$dev" org.freedesktop.DBus.Properties.Get \
    string:"org.bluez.Device1" string:"Connected" 2>/dev/null | \
    awk '/variant.*boolean/{print $NF}')"
  [[ "$connected" != "true" ]] && return

  local tpath
  tpath="$(dbus-send --system --print-reply --dest=org.bluez / \
    org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null | \
    grep -o "${dev}/sep[0-9]*/fd[0-9]*" | head -1)"
  [[ -z "$tpath" ]] && echo "connected:" && return

  local state codec_byte codec_name
  state="$(dbus-send --system --print-reply --dest=org.bluez \
    "$tpath" org.freedesktop.DBus.Properties.Get \
    string:"org.bluez.MediaTransport1" string:"State" 2>/dev/null | \
    awk '/variant.*string/{gsub(/"/, "", $NF); print $NF}')"

  codec_byte="$(dbus-send --system --print-reply --dest=org.bluez \
    "$tpath" org.freedesktop.DBus.Properties.Get \
    string:"org.bluez.MediaTransport1" string:"Codec" 2>/dev/null | \
    awk '/variant.*byte/{print $NF}')"

  case "${codec_byte:-0}" in
    0) codec_name="SBC" ;;
    2) codec_name="AAC" ;;
    4) codec_name="aptX" ;;
    *) codec_name="BT"  ;;
  esac

  echo "${state:-connected}:${codec_name}"
}

# ------------------------------------------------------------
# Handle control commands: volume up|down|toggle
# ------------------------------------------------------------
CMD="${1:-}"
if [[ -n "$CMD" ]]; then
  case "$CMD" in
    up|right) wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%+ ;;
    down|left) wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%- ;;
    toggle)   wpctl set-mute   @DEFAULT_AUDIO_SINK@ toggle ;;
  esac
  pkill -RTMIN+1 waybar
  exit 0
fi

# shellcheck source=/dev/null
source "$HOME/.config/waybar/palette.sh"

SINK="$(find_best_sink)"

# ------------------------------------------------------------
# Read volume and mute state from best available sink
# ------------------------------------------------------------
if [[ -z "$SINK" ]]; then
  vol=0
  mute="true"
else
  raw="$(wpctl get-volume "$SINK" 2>/dev/null || echo "Volume: 0")"
  vol_float="$(echo "$raw" | awk '{print $2}')"
  vol="$(awk -v v="${vol_float:-0}" 'BEGIN { printf "%d", v * 100 }')"
  [[ "$raw" == *"[MUTED]"* ]] && mute="true" || mute="false"
fi

[[ "$vol" =~ ^[0-9]+$ ]] || vol=0
(( vol > 100 )) && vol=100

VALUE="${vol}%"
GLYPH="󰕾"

# ------------------------------------------------------------
# Determine the *semantic* bucket (low/medium/high/full/muted)
# ------------------------------------------------------------
if [[ "$mute" == "true" || "$vol" -eq 0 ]]; then
  CLASS="muted"
  bucket="mute"
else
  if   (( vol < 30 )); then bucket="low"
  elif (( vol < 70 )); then bucket="medium"
  elif (( vol < 100 )); then bucket="high"
  else bucket="full"
  fi
  CLASS="$bucket"
fi

# ------------------------------------------------------------
# Determine the *gradient* bucket (every 5 %)
# ------------------------------------------------------------
grad=$(( (vol / 5) * 5 ))
GRADIENT="vol-${grad}"          # e.g. "vol-35"

# ------------------------------------------------------------
# Build the text that Waybar will display
# ------------------------------------------------------------
# Named DISPLAY_TEXT, not SCORE -- palette.sh (sourced above) already
# exports SCORE as a palette color; reusing the name here clobbered it,
# so VOL_COLOR="$SCORE" (medium bucket) picked up "<glyph> NN%" instead
# of a hex color and broke the tooltip's Pango markup.
DISPLAY_TEXT="${GLYPH} ${VALUE}"

# ------------------------------------------------------------
# Snark system (optional flavour)
# ------------------------------------------------------------
SNARK_FILE="$HOME/.config/waybar/snark.json"
snark="Volume exists."

if [[ -f "$SNARK_FILE" ]] && command -v jq >/dev/null 2>&1; then
  snark="$(jq -r ".volume.${bucket}[]?" "$SNARK_FILE" | shuf -n1 || true)"
  [[ -n "${snark:-}" && "$snark" != "null" ]] || snark="Volume exists."
fi

case "$bucket" in
  mute)   VOL_COLOR="$BAR"        ;;
  low)    VOL_COLOR="$FIFTH"         ;;
  medium) VOL_COLOR="$SCORE" ;;
  high)   VOL_COLOR="$PIANO"         ;;
  full)   VOL_COLOR="$FORTE"         ;;
  *)      VOL_COLOR="$SCORE" ;;
esac

# ------------------------------------------------------------
# 5.5 JBL status line
# JBL_STATE : idle | active | connected | "" (disconnected/absent)
# JBL_CODEC : SBC | AAC | aptX | ""
# JBL_LINE  : Pango markup inserted between "Volume:" and the
#             divider when non-empty. Write it below.
# Palette available: SOTTO ROOT FIFTH LYRIC REST PIANO SEVENTH FORTE
# Tip: LYRIC for labels, REST only for structural chrome.
# ------------------------------------------------------------
JBL_INFO="$(get_jbl_info)"
JBL_STATE="${JBL_INFO%%:*}"
JBL_CODEC="${JBL_INFO##*:}"

_jbl_codec=""
[[ -n "$JBL_CODEC" ]] && _jbl_codec="<span foreground='${REST}'> · </span><span foreground='${SEVENTH}'>${JBL_CODEC}</span>"
[[ -n "$JBL_STATE" ]] \
  && JBL_LINE="<span foreground='${SOTTO}'>󰓃 SWjbl</span>  <span foreground='${FIFTH}'>${JBL_STATE}</span>${_jbl_codec}" \
  || JBL_LINE=""

if [[ -n "$JBL_LINE" ]]; then
  TOOLTIP="$(printf "<span foreground='${REST}'>Volume:</span> <span foreground='${VOL_COLOR}'>%s</span>\n%s\n<span foreground='${REST}'>────────────────────</span>\n<span foreground='${ROOT}'>%s</span>" "$VALUE" "$JBL_LINE" "$snark")"
else
  TOOLTIP="$(printf "<span foreground='${REST}'>Volume:</span> <span foreground='${VOL_COLOR}'>%s</span>\n<span foreground='${REST}'>────────────────────</span>\n<span foreground='${ROOT}'>%s</span>" "$VALUE" "$snark")"
fi

# ------------------------------------------------------------
# Emit JSON – pass class as an array so Waybar applies BOTH CSS classes
# ------------------------------------------------------------
jq -nc \
  --arg text "$DISPLAY_TEXT" \
  --arg tooltip "$TOOLTIP" \
  --arg class1 "$CLASS" \
  --arg class2 "$GRADIENT" \
  '{text:$text, tooltip:$tooltip, class:[$class1,$class2]}'
