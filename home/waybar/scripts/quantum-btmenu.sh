#!/usr/bin/env bash
set -euo pipefail

CACHE="$HOME/.cache/quantum_bt"
mkdir -p "$CACHE"
FAVES="$CACHE/favorites"
touch "$FAVES"

# fuzzel --dmenu: centered, flat, colours from ~/.config/fuzzel/fuzzel.ini.
launcher=(fuzzel --dmenu --lines 12)

ADAPTER="/org/bluez/hci0"

if ! busctl get-property org.bluez "$ADAPTER" org.bluez.Adapter1 Powered | grep -q "true"; then
    notify-send "Bluetooth" "Please turn Bluetooth on first."
    exit 1
fi

SCAN_ITEM="🔍 Scan for new devices"

# Default fast path lists known/paired devices only (instant, no radio scan).
# After choosing the scan item we re-exec with QUANTUM_BT_SCAN=1 to list ALL
# known devices, including ones just discovered.
LIST_MODE="Paired"
[[ "${QUANTUM_BT_SCAN:-0}" == "1" ]] && LIST_MODE=""

# Currently-connected MACs (live), one call.
mapfile -t connected_macs < <(bluetoothctl devices Connected 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g;s/\r//g' | awk '/^Device/{print $2}')

is_connected() {
    local m="$1" c
    for c in "${connected_macs[@]:-}"; do
        [[ "$c" == "$m" ]] && return 0
    done
    return 1
}

# Device list (cached, instant). Line format: "Device AA:BB:.. Alias words"
mapfile -t devices < <(bluetoothctl devices $LIST_MODE 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g;s/\r//g' | awk '/^Device/{$1=""; print substr($0,2)}')

choices=("$SCAN_ITEM")
for dev in "${devices[@]:-}"; do
    [[ -z "$dev" ]] && continue
    mac=$(echo "$dev" | awk '{print $1}')
    alias=$(echo "$dev" | cut -d' ' -f2-)

    favmark=""; grep -qx "$mac" "$FAVES" && favmark="⭐ "
    status="⚪"; is_connected "$mac" && status="🟢"
    choices+=("$status $favmark $alias ($mac)")
done

choice=$(printf '%s\n' "${choices[@]}" | "${launcher[@]}" --prompt '🔊 choose bond:')
[[ -z "$choice" ]] && exit 0

if [[ "$choice" == "$SCAN_ITEM" ]]; then
    notify-send "Bluetooth" "🔍 scanning for new devices..."
    bluetoothctl scan on >/dev/null 2>&1 &
    SCAN_PID=$!
    sleep 4
    kill "$SCAN_PID" 2>/dev/null || true
    bluetoothctl scan off >/dev/null 2>&1 || true
    QUANTUM_BT_SCAN=1 exec "$0"
fi

mac=$(echo "$choice" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')
[[ -z "$mac" ]] && exit 0

action=$(printf "connect/disconnect\ntoggle favorite\nedit visible info\nrename\ntether (PAN)" | "${launcher[@]}" --prompt "Action:")
[[ -z "$action" ]] && exit 0

if [[ "$action" == "rename" ]]; then
    current_alias=$(printf "info %s\nquit\n" "$mac" | bluetoothctl 2>/dev/null | \
        sed 's/\x1b\[[0-9;]*m//g' | grep -oP '^\s*Alias:\s*\K.*')
    new_alias=$(printf '%s\n' "$current_alias" | "${launcher[@]}" --prompt "Rename to:")
    if [[ -n "$new_alias" && "$new_alias" != "$current_alias" ]]; then
        # set-alias is a per-device command with no mac argument of its own --
        # it applies to whatever device "info <mac>" last made current in this
        # same bluetoothctl session. Its arg parser also splits on whitespace,
        # so a multi-word alias needs its own literal quotes in the command
        # stream (escape any quotes already in the typed name first).
        escaped_alias=${new_alias//\"/\\\"}
        printf 'info %s\nset-alias "%s"\nquit\n' "$mac" "$escaped_alias" | bluetoothctl >/dev/null 2>&1
        notify-send "Bluetooth" "Renamed to \"$new_alias\""
    fi
    exit 0
fi

if [[ "$action" == "tether (PAN)" ]]; then
    if nmcli -g GENERAL.STATE device show "$mac" 2>/dev/null | grep -q "^100"; then
        nmcli device disconnect "$mac" >/dev/null 2>&1
        notify-send "Bluetooth" "Tether disconnected"
    else
        notify-send "Bluetooth" "Connecting tether..."
        if nmcli device connect "$mac" >/dev/null 2>&1; then
            notify-send "Bluetooth" "Tethered"
        else
            notify-send "Bluetooth" "Tether failed"
        fi
    fi
    exit 0
fi

if [[ "$action" == "edit visible info" ]]; then
    if [[ -f "$HOME/.cache/bt-device-info/${mac}.json" ]]; then
        bt-device-fields-menu.sh "$mac"
    else
        notify-send "Bluetooth" "No info gathered for this device yet -- connect it first."
    fi
    exit 0
fi

if [[ "$action" == "toggle favorite" ]]; then
    if grep -qx "$mac" "$FAVES"; then
        sed -i "/$mac/d" "$FAVES"
        notify-send "Bluetooth" "Removed favorite"
    else
        echo "$mac" >> "$FAVES"
        notify-send "Bluetooth" "Added favorite"
    fi
    exit 0
fi

if printf "info %s\nquit\n" "$mac" | bluetoothctl | grep -q "Connected: yes"; then
    printf "disconnect %s\nquit\n" "$mac" | bluetoothctl >/dev/null
    notify-send "Bluetooth" "Disconnected"
else
    notify-send "Bluetooth" "Connecting..."

    # bluetoothctl's "connect" is async: it prints only "Attempting to
    # connect..." synchronously and returns to the prompt immediately, while
    # the real "Connection successful"/"Failed to connect" line arrives later
    # via the same session's event stream. Sending "quit" right after used to
    # mean that line was (almost) never captured, so this reported "failed"
    # on every connect regardless of outcome. Give the session enough time to
    # actually receive that async result before telling it to quit — 5s
    # missed it on a live BLE device (Connection successful landed ~6-8s in);
    # 8s covers the observed case with a little margin.
    result=$(
        { printf "connect %s\n" "$mac"; sleep 8; printf "quit\n"; } | bluetoothctl
    )

    if grep -q "Connection successful" <<<"$result"; then
        notify-send "Bluetooth" "Connected"

        mac_under="${mac//:/_}"
        sleep 2
        sink_id=$(pw-dump | jq -r --arg name "bluez_output.${mac_under}" \
          '.[] | select(.info.props["node.name"] | startswith($name)?) | .id' | head -n1)
        [[ -n "$sink_id" ]] && wpctl set-default "$sink_id"
    else
        notify-send "Bluetooth" "Connection failed"
    fi
fi
