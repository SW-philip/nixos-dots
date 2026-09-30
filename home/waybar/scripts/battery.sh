#!/usr/bin/env bash
set -euo pipefail

BAT_PATH="/sys/class/power_supply/BAT1"
SNARK_FILE="$HOME/.config/waybar/snark.json"
PALETTE_FILE="$HOME/.config/waybar/palette.sh"

if [[ -f "$PALETTE_FILE" ]]; then
    source "$PALETTE_FILE"
else
    REST="#6e6a86"; BAR="#6e6a86"; ROOT="#c4a7e7"; PIANO="#f6c177"
fi

# minutes -> "1h05m" / "47m"
fmt_eta() {
    local m=$1
    if (( m >= 60 )); then
        printf '%dh%02dm' $(( m / 60 )) $(( m % 60 ))
    else
        printf '%dm' "$m"
    fi
}

ETA=""          # formatted time estimate, empty when on AC / no estimate
ETA_LABEL=""    # tooltip label for the estimate
ARROW=""        # ↑ charging / ↓ discharging / empty on AC / full
DRAW=""         # instantaneous power draw, e.g. "8.4 W"
snark_b=""      # optional second snark pool to draw from

if [[ -d "$BAT_PATH" ]]; then
    status=$(cat "$BAT_PATH/status")
    PERCENT=$(cat "$BAT_PATH/capacity")

    # CSS class / snark level by charge tier (matches style.nix + snark.json)
    if   [ "$PERCENT" -le 10 ]; then tier="critical"
    elif [ "$PERCENT" -le 25 ]; then tier="low"
    elif [ "$PERCENT" -le 50 ]; then tier="medium"
    elif [ "$PERCENT" -le 85 ]; then tier="high"
    else                             tier="full"; fi

    energy_now=$(cat "$BAT_PATH/energy_now" 2>/dev/null || echo 0)
    energy_full=$(cat "$BAT_PATH/energy_full" 2>/dev/null || echo 0)
    power_now=$(cat "$BAT_PATH/power_now" 2>/dev/null || echo 0)

    # power_now is µW; instantaneous draw matches what UPower reports
    if (( power_now > 0 )); then
        deci=$(( power_now / 100000 ))               # tenths of a watt
        DRAW="$(( deci / 10 )).$(( deci % 10 )) W"
    fi

    case $status in
        "Charging")
            GLYPH="󰂄"
            ARROW="↑"
            bucket="charging"
            remaining=$(( energy_full - energy_now ))
            if (( power_now > 0 && remaining > 0 )); then
                ETA=$(fmt_eta $(( remaining * 60 / power_now )))
                ETA_LABEL="Full in:"
            fi
            ;;
        "Discharging")
            GLYPH="󰁹"
            ARROW="↓"
            bucket="$tier"
            snark_b="discharging"                    # mix in generic on-battery snark
            if (( power_now > 0 && energy_now > 0 )); then
                ETA=$(fmt_eta $(( energy_now * 60 / power_now )))
                ETA_LABEL="Time left:"
            fi
            ;;
        *)                                           # Full / Not charging / Unknown
            GLYPH="󰂄"
            bucket="full"
            ;;
    esac
else
    PERCENT=""; tier="full"; bucket="full"; GLYPH="󰚥"; status="AC"
fi

# Inline label: direction arrow + charge + glyph. The ETA lives in the
# tooltip only (charging → "Full in:", discharging → "Time left:").
# No battery present (desktop) → just the plug glyph and ∞.
if [[ -z "$PERCENT" ]]; then
    BAT_TEXT="${GLYPH} ∞"
elif [[ -n "$ARROW" ]]; then
    BAT_TEXT="${ARROW} ${PERCENT}% ${GLYPH}"
else
    BAT_TEXT="${PERCENT}% ${GLYPH}"
fi

snark="System operational."
if [[ -f "$SNARK_FILE" ]]; then
    snark=$(jq -r --arg a "$bucket" --arg b "$snark_b" \
        '((.battery[$a] // []) + (if $b == "" then [] else (.battery[$b] // []) end)) | .[]' \
        "$SNARK_FILE" | shuf -n1 || echo "System operational.")
fi

TOOLTIP="<span foreground='${REST}'>Status:</span> ${status}"
[[ -n "$PERCENT" ]] && TOOLTIP+="
<span foreground='${REST}'>Charge:</span> ${PERCENT}%"
[[ -n "$ETA" ]]  && TOOLTIP+="
<span foreground='${REST}'>${ETA_LABEL}</span> <span foreground='${PIANO}'>${ETA}</span>"
[[ -n "$DRAW" ]] && TOOLTIP+="
<span foreground='${REST}'>Draw:</span> ${DRAW}"
TOOLTIP+="
<span foreground='${REST}'>────────────────────</span>
<span foreground='${ROOT}'>${snark}</span>"

jq -nc \
  --arg text "$BAT_TEXT" \
  --arg tooltip "$TOOLTIP" \
  --arg class "$tier" \
  '{ text: $text, tooltip: $tooltip, class: $class }'
