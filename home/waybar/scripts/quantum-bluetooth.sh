#!/usr/bin/env bash

# True Nerd Font 3.x Bluetooth glyphs
ICON_OFF="󰂲"
ICON_ON="󰂯"
ICON_CONNECTED="󰂱"

# shellcheck source=/dev/null
source "$HOME/.config/waybar/palette.sh"

# Nerd Font 3.x. Keyed on bt-classify's fine type; falls back to the generic
# "connected" glyph. Verify each codepoint renders in the installed font
# before shipping -- a missing glyph shows as a tofu box.
glyph_for_type() {
  case "$1" in
    speaker)     printf '󰓃' ;;
    headphones)  printf '󰋋' ;;
    headset)     printf '󰋎' ;;
    earbuds)     printf '󰟅' ;;
    gamepad)     printf '󰊴' ;;
    phone)       printf '󰄡' ;;
    watch)       printf '󰖉' ;;
    keyboard)    printf '󰌌' ;;
    mouse)       printf '󰦋' ;;
    *)           printf '%s' "$ICON_CONNECTED" ;;
  esac
}

# Graded scale, CLAUDE.md colour-rule exception: the palette's purpose-built
# charge gradient (CHG_MORENDO = critically-low, CHG_PP = low). FORTE/ROOT
# collapse to the same hue in ~half the themes; the CHG_* scale stays distinct
# across all of them by design. Empty above 35 -- no override once healthy.
battery_colour() {
  local pct="$1"
  if   (( pct <= 15 )); then printf '%s' "$CHG_MORENDO"
  elif (( pct <= 35 )); then printf '%s' "$CHG_PP"
  else                       printf ''
  fi
}

# Escape device-controlled strings before they land in Pango markup. `&`
# first, or it double-escapes the entities from the later substitutions.
pango_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<<"$1"
}

SNARK_FILE="$HOME/.config/waybar/snark.json"
ADAPTER="/org/bluez/hci0"

snark_for() {
    local bucket="$1" fallback="${2:-}"
    if [[ -f "$SNARK_FILE" ]] && command -v jq >/dev/null; then
        local s
        s=$(jq -r ".bluetooth.${bucket}[]?" "$SNARK_FILE" 2>/dev/null | shuf -n1 || true)
        [[ -n "$s" && "$s" != "null" ]] && echo "$s" && return
    fi
    echo "$fallback"
}

# bluetoothctl subcommand mode doesn't wait for DBus in bluez 5.86+; use busctl instead
bt_powered=$(busctl get-property org.bluez "$ADAPTER" org.bluez.Adapter1 Powered 2>/dev/null | awk '{print $2}')

if [[ "$bt_powered" != "true" ]]; then
    jq -cn \
        --arg text "<span foreground='$REST'>$ICON_OFF</span>" \
        --arg text_compact "$ICON_OFF" \
        --arg tooltip "Bluetooth <span foreground='$REST'>off</span>
<span foreground='$REST'>────────────────────</span>
<span foreground='$ROOT'>$(snark_for off 'Radio silence.')</span>" \
        --arg class "off" \
        '{text: $text, text_compact: $text_compact, tooltip: $tooltip, class: $class}'
    exit 0
fi

# Interactive pipe mode required for device enumeration in bluez 5.86+
connected_mac=$(printf 'devices Connected\nquit\n' | bluetoothctl 2>/dev/null | \
    sed 's/\x1b\[[0-9;]*m//g;s/\r//g' | awk '/^Device/{print $2; exit}')

if [[ -n "$connected_mac" ]]; then
    info=$(printf "info %s\nquit\n" "$connected_mac" | bluetoothctl 2>/dev/null | \
        sed 's/\x1b\[[0-9;]*m//g;s/\r//g')
    name=$(echo "$info" | awk -F': ' '/Alias/ {print $2}')

    # bt-device-probe.sh writes {battery, charging, channel, model,
    # firmware_revision, type} to this cache on every connect event and, for
    # the JBL, on the poll timer's ExecStartPost (mug included -- it
    # special-cases the mug's own MAC). A render is just a cache read: pull
    # every field in one jq call rather than 4-6 per tick.
    cache_file="$HOME/.cache/bt-device-info/${connected_mac}.json"
    type="" battery="" charging="" channel="" model="" firmware=""
    if [[ -f "$cache_file" ]]; then
        IFS=$'\t' read -r type battery charging channel model firmware < <(
            jq -r '[.type, .battery, .charging, .channel, .model, .firmware_revision]
                   | map(if . == null then "" else tostring end) | @tsv' \
                "$cache_file" 2>/dev/null)
    fi

    glyph=$(glyph_for_type "$type")
    name_esc=$(pango_escape "$name")

    batt_span=""
    if [[ -n "$battery" ]]; then
      bc=$(battery_colour "$battery")
      batt_span="  <span foreground='${bc:-$SCORE}' size='small'>${battery}%</span>"
    fi
    bolt=""
    [[ "$charging" == "true" ]] && bolt=" 󰂄"

    text="<span foreground='$FIFTH'>$glyph</span>  <span foreground='$SCORE' size='small'>$name_esc</span>${batt_span}${bolt}"

    model_esc=$(pango_escape "$model")
    firmware_esc=$(pango_escape "$firmware")
    type_esc=$(pango_escape "$type")

    tooltip="<b>$name_esc</b>"
    [[ -n "$type" ]]     && tooltip+=$'\n'"<span foreground='$REST' size='small'>Type: ${type_esc}</span>"
    [[ -n "$battery" ]]  && tooltip+=$'\n'"<span foreground='$REST' size='small'>Battery: ${battery}%$([[ -n "$bolt" ]] && printf ' (charging)')</span>"
    [[ -n "$model" ]]    && tooltip+=$'\n'"<span foreground='$REST' size='small'>Model: ${model_esc}</span>"
    [[ -n "$firmware" ]] && tooltip+=$'\n'"<span foreground='$REST' size='small'>Firmware: ${firmware_esc}</span>"
    [[ -n "$channel" && "$channel" != "0" ]] && tooltip+=$'\n'"<span foreground='$REST' size='small'>Channel: pair ${channel}</span>"

    jq -cn \
        --arg text "$text" \
        --arg text_compact "$glyph" \
        --arg tooltip "$tooltip" \
        --arg class "on" \
        '{text: $text, text_compact: $text_compact, tooltip: $tooltip, class: $class}'
    exit 0
fi

# Powered but not connected fallback
jq -cn \
    --arg text "<span foreground='$ROOT'>$ICON_ON</span>" \
    --arg text_compact "$ICON_ON" \
    --arg tooltip "Bluetooth <span foreground='$REST'>on</span> · no device
<span foreground='$REST'>────────────────────</span>
<span foreground='$ROOT'>$(snark_for idle 'Scanning...')</span>" \
    --arg class "idle" \
    '{text: $text, text_compact: $text_compact, tooltip: $tooltip, class: $class}'
