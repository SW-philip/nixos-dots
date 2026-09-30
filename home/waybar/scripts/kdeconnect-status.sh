#!/usr/bin/env bash
# Waybar KDE Connect status indicator — replaces the generic systray icon
# (kdeconnect-indicator publishes its own SNI entry that dragged in an
# unrelated tray icon too; this only ever shows KDE Connect's own state).

# shellcheck source=/dev/null
source "$HOME/.config/waybar/palette.sh" 2>/dev/null || true

FIFTH="${FIFTH:-#9ccfd8}"
REST="${REST:-#908caa}"

# kdeconnectd is D-Bus-activated on demand, not autostarted at login (see
# profiles/prepko/surface.nix) — busctl list-names only reports names already
# owned on the bus, so this check itself never triggers activation. A real
# kdeconnect-cli call below would.
if ! busctl --user list-names 2>/dev/null | grep -q '^org\.kde\.kdeconnect '; then
    jq -cn \
        --arg text "<span foreground='${REST}'>📱</span>" \
        --arg tooltip "KDE Connect: not running (open the app to start it)" \
        --arg class "unpaired" \
        '{text:$text, tooltip:$tooltip, class:$class}'
    exit 0
fi

mapfile -t paired < <(kdeconnect-cli -l --id-name-only 2>/dev/null)
mapfile -t available < <(kdeconnect-cli -a --id-name-only 2>/dev/null)

if [[ "${#paired[@]}" -eq 0 ]]; then
    jq -cn \
        --arg text "<span foreground='${REST}'>📱 no device</span>" \
        --arg tooltip "KDE Connect: no paired devices" \
        --arg class "unpaired" \
        '{text:$text, tooltip:$tooltip, class:$class}'
    exit 0
fi

is_available() {
    local id="$1" line
    for line in "${available[@]}"; do
        [[ "${line%% *}" == "$id" ]] && return 0
    done
    return 1
}

# Battery plugin only mounts its D-Bus object once a device is actually
# connected, and charge reads -1 until the first report arrives after that
# (seen on both the Android and iOS clients) — both cases just mean "no
# reading yet", not an error, so stay silent rather than show 0%/garbage.
battery_of() {
    local id="$1" path charge charging
    path="/modules/kdeconnect/devices/${id}/battery"
    charge=$(busctl --user get-property org.kde.kdeconnect "$path" \
        org.kde.kdeconnect.device.battery charge 2>/dev/null | awk '{print $2}')
    [[ -z "$charge" || "$charge" == "-1" ]] && return
    charging=$(busctl --user get-property org.kde.kdeconnect "$path" \
        org.kde.kdeconnect.device.battery isCharging 2>/dev/null | awk '{print $2}')
    if [[ "$charging" == "true" ]]; then
        echo "${charge}%⚡"
    else
        echo "${charge}%"
    fi
}

online_name="" online_battery=""
tooltip_lines=()
for line in "${paired[@]}"; do
    id="${line%% *}"
    name="${line#* }"
    if is_available "$id"; then
        battery=$(battery_of "$id")
        label="online"
        [[ -n "$battery" ]] && label="online · ${battery}"
        tooltip_lines+=("<span foreground='${FIFTH}'>●</span> ${name} — ${label}")
        if [[ -z "$online_name" ]]; then
            online_name="$name"
            online_battery="$battery"
        fi
    else
        tooltip_lines+=("<span foreground='${REST}'>○</span> ${name} — offline")
    fi
done

tooltip=$(printf '%s\n' "${tooltip_lines[@]}")

if [[ -n "$online_name" ]]; then
    suffix=""
    [[ -n "$online_battery" ]] && suffix=" ${online_battery}"
    text="<span foreground='${FIFTH}'>📱 ${online_name}${suffix}</span>"
    class="connected"
else
    text="<span foreground='${REST}'>📱 offline</span>"
    class="disconnected"
fi

jq -cn --arg text "$text" --arg tooltip "$tooltip" --arg class "$class" \
    '{text:$text, tooltip:$tooltip, class:$class}'
