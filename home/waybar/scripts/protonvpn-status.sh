#!/usr/bin/env bash
# Waybar ProtonVPN WireGuard status indicator

PALETTE="$HOME/.config/waybar/palette.sh"
# shellcheck source=/dev/null
source "$PALETTE" 2>/dev/null || true

SEVENTH="${SEVENTH:-#31748f}"
BAR="${BAR:-#6e6a86}"
FORTE="${FORTE:-#eb6f92}"
ROOT="${ROOT:-#c4a7e7}"

ICON_ON="󰖂"
ICON_OFF="󰦞"

SNARK_FILE="$HOME/.config/waybar/snark.json"

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/waybar-lib.sh"
snark_for() { waybar_snark protonvpn "$1" "${2:-}"; }

if systemctl is-active --quiet wg-quick-protonvpn.service 2>/dev/null; then
    TOOLTIP=$(printf "<span foreground='${SEVENTH}'>ProtonVPN Connected</span>\n<span foreground='${BAR}'>────────────────────</span>\n<span foreground='${ROOT}'>%s</span>" "$(snark_for on 'Traffic disguised.')")
    jq -nc --arg text "$ICON_ON" --arg tooltip "$TOOLTIP" --arg class "vpn-on" \
        '{text:$text, tooltip:$tooltip, class:$class}'
else
    TOOLTIP=$(printf "<span foreground='${BAR}'>ProtonVPN Off</span>\n<span foreground='${BAR}'>Click to connect</span>\n<span foreground='${BAR}'>────────────────────</span>\n<span foreground='${ROOT}'>%s</span>" "$(snark_for off 'Exposed to the open internet.')")
    jq -nc --arg text "$ICON_OFF" --arg tooltip "$TOOLTIP" --arg class "vpn-off" \
        '{text:$text, tooltip:$tooltip, class:$class}'
fi
