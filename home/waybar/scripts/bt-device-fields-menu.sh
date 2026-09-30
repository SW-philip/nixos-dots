#!/usr/bin/env bash
set -uo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/bt-device-info"
PREFS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/bt-device-info/prefs"

# fuzzel --dmenu: centered, flat, colours from ~/.config/fuzzel/fuzzel.ini.
launcher=(fuzzel --dmenu --lines 10)

mac="${1:?mac required}"
cache_file="$CACHE_DIR/${mac}.json"
[[ -f "$cache_file" ]] || exit 0

# Every field except "type" is a user-visible pick candidate -- type drives
# the audio-active dot automatically and isn't something to toggle off.
mapfile -t field_keys < <(jq -r 'keys[] | select(. != "type")' "$cache_file" 2>/dev/null)
if [[ ${#field_keys[@]} -eq 0 ]]; then
  # No optional fields probed (e.g. a BR/EDR device with no GATT Device
  # Information Service). Fall into the loop anyway -- "Done" then writes the
  # prefs marker, without which a paired+trusted device would re-open this
  # menu on every connect.
  notify-send "Bluetooth" "No optional info gathered for this device yet."
fi

mkdir -p "$PREFS_DIR"
prefs_file="$PREFS_DIR/$mac"
declare -A selected=()

# Re-opening via "edit visible info" should show the current picks checked,
# not reset to nothing -- pre-seed from any existing prefs file.
if [[ -f "$prefs_file" ]]; then
  while IFS= read -r existing_key; do
    [[ -n "$existing_key" ]] && selected["$existing_key"]=1
  done < "$prefs_file"
fi

DONE_ITEM="✅ Done"
REPROBE_ITEM="🔄 Re-probe now"

while true; do
  choices=()
  for key in "${field_keys[@]}"; do
    value=$(jq -r --arg k "$key" '.[$k]' "$cache_file")
    mark="☐"
    [[ -n "${selected[$key]:-}" ]] && mark="☑"
    choices+=("$mark $key: $value")
  done
  choices+=("$REPROBE_ITEM")
  choices+=("$DONE_ITEM")

  choice=$(printf '%s\n' "${choices[@]}" | "${launcher[@]}" --prompt 'Show which info?')
  [[ -z "$choice" ]] && exit 0
  [[ "$choice" == "$DONE_ITEM" ]] && break
  if [[ "$choice" == "$REPROBE_ITEM" ]]; then
    if bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes"; then
      bt-device-probe.sh probe --force "$mac" >/dev/null
      mapfile -t field_keys < <(jq -r 'keys[] | select(. != "type")' "$cache_file" 2>/dev/null)
    else
      notify-send "Bluetooth" "Connect the device first to re-probe."
    fi
    continue
  fi

  picked_key=$(echo "$choice" | sed -E 's/^[☐☑] ([a-z_]+): .*/\1/')
  if [[ -n "${selected[$picked_key]:-}" ]]; then
    unset "selected[$picked_key]"
  else
    selected[$picked_key]=1
  fi
done

: > "$prefs_file"
for key in "${!selected[@]}"; do
  echo "$key" >> "$prefs_file"
done
