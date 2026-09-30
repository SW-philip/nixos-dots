#!/usr/bin/env bash
# Right-click action menu — built from whatever plugins are actually loaded
# on the selected device (busctl loadedPlugins), so an iPhone (no sftp/sms)
# gets a different menu than the Android phone (has both) automatically.
set -euo pipefail

# fuzzel --dmenu: centered, flat, colours from ~/.config/fuzzel/fuzzel.ini.
launcher=(fuzzel --dmenu --lines 10)

mapfile -t paired < <(kdeconnect-cli -l --id-name-only 2>/dev/null)

if [[ "${#paired[@]}" -eq 0 ]]; then
    notify-send "KDE Connect" "No paired devices — pair from the phone's KDE Connect app first."
    exit 1
fi

if [[ "${#paired[@]}" -eq 1 ]]; then
    device_id="${paired[0]%% *}"
    device_name="${paired[0]#* }"
else
    choice=$(printf '%s\n' "${paired[@]#* }" | "${launcher[@]}" --prompt "Device:")
    [[ -z "$choice" ]] && exit 0
    device_id=""
    for line in "${paired[@]}"; do
        if [[ "${line#* }" == "$choice" ]]; then
            device_id="${line%% *}"
            device_name="$choice"
            break
        fi
    done
    [[ -z "$device_id" ]] && exit 0
fi

mapfile -t loaded_plugins < <(
    busctl --user call org.kde.kdeconnect "/modules/kdeconnect/devices/${device_id}" \
        org.kde.kdeconnect.device loadedPlugins 2>/dev/null \
        | grep -oE '"[a-zA-Z_]+"' | tr -d '"'
)

has_plugin() {
    local p="$1" x
    for x in "${loaded_plugins[@]:-}"; do
        [[ "$x" == "$p" ]] && return 0
    done
    return 1
}

# Browse an arbitrary local path via fuzzel --dmenu (no zenity/GTK pickers in
# this repo — see home/waybar/scripts/weather.py). fuzzel --dmenu allows
# custom entries by default, so typing an absolute path works too, not just
# navigating.
pick_file() {
    local dir="$HOME" entries=() choices=() sel candidate
    while true; do
        mapfile -t entries < <(ls -1A "$dir" 2>/dev/null | sort)
        choices=("..")
        for e in "${entries[@]}"; do
            if [[ -d "$dir/$e" ]]; then choices+=("${e}/"); else choices+=("$e"); fi
        done
        sel=$(printf '%s\n' "${choices[@]}" | "${launcher[@]}" --prompt "${dir}:")
        [[ -z "$sel" ]] && return 1

        if [[ "$sel" == ".." ]]; then
            dir=$(dirname "$dir")
            continue
        fi

        if [[ "$sel" == /* && -e "$sel" ]]; then
            candidate="$sel"
        else
            candidate="${dir}/${sel%/}"
        fi

        if [[ -d "$candidate" ]]; then
            dir="$candidate"
        elif [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        # else: stale/invalid entry, redraw the same directory
    done
}

labels=() keys=()
add_item() { labels+=("$1"); keys+=("$2"); }

has_plugin kdeconnect_findmyphone   && add_item "Ring (find phone)" ring
has_plugin kdeconnect_ping          && add_item "Ping"              ping
has_plugin kdeconnect_share         && add_item "Send file"         sendfile
has_plugin kdeconnect_clipboard     && add_item "Send clipboard"    clipboard
has_plugin kdeconnect_sftp          && add_item "Browse files"      browse
has_plugin kdeconnect_runcommand    && add_item "Run command"       runcommand
has_plugin kdeconnect_lockdevice    && add_item "Lock device"       lock
has_plugin kdeconnect_sms           && add_item "Send SMS"          sms
add_item "Unpair"  unpair
add_item "Refresh" refresh

choice_label=$(printf '%s\n' "${labels[@]}" | "${launcher[@]}" --prompt "${device_name}:")
[[ -z "$choice_label" ]] && exit 0

action=""
for i in "${!labels[@]}"; do
    if [[ "${labels[$i]}" == "$choice_label" ]]; then
        action="${keys[$i]}"
        break
    fi
done

case "$action" in
  ring)
    kdeconnect-cli -d "$device_id" --ring
    ;;
  ping)
    kdeconnect-cli -d "$device_id" --ping
    notify-send "KDE Connect" "Pinged ${device_name}"
    ;;
  sendfile)
    if path=$(pick_file); then
        kdeconnect-cli -d "$device_id" --share "$path"
        notify-send "KDE Connect" "Sent $(basename "$path") to ${device_name}"
    fi
    ;;
  clipboard)
    kdeconnect-cli -d "$device_id" --send-clipboard
    notify-send "KDE Connect" "Clipboard sent to ${device_name}"
    ;;
  browse)
    kdeconnect-cli -d "$device_id" --mount >/dev/null 2>&1
    sleep 1
    mount_point=$(kdeconnect-cli -d "$device_id" --get-mount-point 2>/dev/null | tail -n1)
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then
        nemo "$mount_point" &
        disown
    else
        notify-send "KDE Connect" "Could not mount ${device_name} — is it unlocked and reachable?"
    fi
    ;;
  runcommand)
    # kdeconnect-cli doesn't document --list-commands' exact separator;
    # tolerate either "id: name" or "id name" by splitting on whichever of
    # ':' or ' ' comes first.
    mapfile -t cmds < <(kdeconnect-cli -d "$device_id" --list-commands 2>/dev/null)
    if [[ "${#cmds[@]}" -eq 0 ]]; then
        notify-send "KDE Connect" "No remote commands configured on ${device_name}"
    else
        cmd_choice=$(printf '%s\n' "${cmds[@]#*[: ]}" | sed 's/^ *//' | "${launcher[@]}" --prompt "Command:")
        [[ -z "$cmd_choice" ]] && exit 0
        for line in "${cmds[@]}"; do
            name="${line#*[: ]}"; name="${name# }"
            if [[ "$name" == "$cmd_choice" ]]; then
                cmd_id="${line%%[: ]*}"
                kdeconnect-cli -d "$device_id" --execute-command "$cmd_id"
                break
            fi
        done
    fi
    ;;
  lock)
    kdeconnect-cli -d "$device_id" --lock
    notify-send "KDE Connect" "Locked ${device_name}"
    ;;
  sms)
    dest=$(printf '' | "${launcher[@]}" --prompt "Phone number:")
    [[ -z "$dest" ]] && exit 0
    msg=$(printf '' | "${launcher[@]}" --prompt "Message:")
    [[ -z "$msg" ]] && exit 0
    kdeconnect-cli -d "$device_id" --send-sms "$msg" --destination "$dest"
    notify-send "KDE Connect" "SMS sent via ${device_name}"
    ;;
  unpair)
    kdeconnect-cli -d "$device_id" --unpair
    notify-send "KDE Connect" "Unpaired ${device_name}"
    ;;
  refresh)
    kdeconnect-cli --refresh
    ;;
esac
