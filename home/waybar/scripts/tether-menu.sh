#!/usr/bin/env bash
# Click menu for the tether pill: unread conversations first (pick one to reply), then actions.
# TETHER_STATUS (the python helper) comes from the Nix wrapper; tether itself from the system profile.
set -euo pipefail
: "${TETHER_STATUS:?}"

launcher=(fuzzel --dmenu --lines 12)
actions=("Send clipboard" "Send file…" "Claim all profiles" "Release all profiles" "Re-advertise notifications")

keys=() labels=()
while IFS=$'\t' read -r key label; do
    keys+=("$key")
    labels+=("$label")
done < <("$TETHER_STATUS" threads)

menu=()
for i in "${!labels[@]}"; do
    menu+=("$((i + 1)). ${labels[$i]}")
done
menu+=("${actions[@]}")

choice=$(printf '%s\n' "${menu[@]}" | "${launcher[@]}" --prompt "tether: ") || exit 0
[[ -z "$choice" ]] && exit 0

if [[ "$choice" =~ ^([0-9]+)\.\  ]]; then
    idx=$((BASH_REMATCH[1] - 1))
    key="${keys[$idx]}"
    name="${labels[$idx]%%  *}"
    text=$(: | "${launcher[@]}" --lines 0 --prompt "reply to ${name}: ") || exit 0
    [[ -z "$text" ]] && exit 0
    if err=$(tether --bt-send "$key" "$text" 2>&1); then
        notify-send -a tether "Sent to ${name}" "$text"
    else
        notify-send -u critical -a tether "Could not send to ${name}" "$err"
    fi
    exit 0
fi

case "$choice" in
    "Send clipboard")             tether --share-clipboard ;;
    "Send file…")
        path=$(: | "${launcher[@]}" --lines 0 --prompt "file path: ") || exit 0
        [[ -n "$path" ]] && tether --send-file "${path/#\~/$HOME}" ;;
    "Claim all profiles")         tether --bt-claim all ;;
    "Release all profiles")       tether --bt-release all ;;
    "Re-advertise notifications") tether --bt-solicit ;;
esac
