#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

state_dir="${XDG_RUNTIME_DIR:-/tmp}"
selftest=false
[[ "${1:-}" == "--selftest" ]] && { selftest=true; state_dir="$(mktemp -d)"; }

adapter="/org/bluez/hci0"

# Test-only: BT_TEST_TRANSCRIPT points at a dir of canned fixtures that stand in
# for busctl/bluetoothctl, so the device-enumeration path is exercisable with the
# adapter powered off (or absent).
#   $dir/macs                       one connected-device MAC per line
#   $dir/<MAC, ':' -> '_'>.alias    device Alias string       (optional)
#   $dir/<MAC, ':' -> '_'>.battery  battery percentage int    (optional -> null)
transcript="${BT_TEST_TRANSCRIPT:-}"

emit() {
  printf '%s\n' "$1"
  [[ "$selftest" == true ]] || printf '%s\n' "$1" > "$state_dir/eww-bt.json"
}

# Bare property value (true / alias string / percentage int), or empty when the
# interface or property is absent. Never fails the caller.
prop() {
  if [[ -n "$transcript" ]]; then
    local key="${1##*/dev_}"
    case "$2.$3" in
      org.bluez.Device1.Alias)       cat "$transcript/$key.alias" 2>/dev/null || true ;;
      org.bluez.Battery1.Percentage) cat "$transcript/$key.battery" 2>/dev/null || true ;;
    esac
    return 0
  fi
  busctl --json=short get-property org.bluez "$1" "$2" "$3" 2>/dev/null \
    | jq -r '.data' 2>/dev/null || true
}

connected_macs() {
  if [[ -n "$transcript" ]]; then
    cat "$transcript/macs" 2>/dev/null || true
    return 0
  fi
  # bluez 5.86 subcommand mode does not wait for D-Bus; the interactive pipe does.
  printf 'devices Connected\nquit\n' | bluetoothctl 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g; s/\r//g' \
    | awk '/^Device /{print $2}' || true
}

if [[ -z "$transcript" ]] && ! command -v busctl >/dev/null 2>&1; then
  emit '{"available":false,"count":0,"devices":[]}'
  exit 0
fi

available=false
count=0
devices="[]"

powered=$(prop "$adapter" org.bluez.Adapter1 Powered)
[[ -n "$transcript" ]] && powered=true

if [[ "$powered" == "true" ]]; then
  available=true
  while IFS= read -r mac; do
    [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || continue
    path="$adapter/dev_${mac//:/_}"
    name=$(prop "$path" org.bluez.Device1 Alias)
    [[ -n "$name" ]] || name="$mac"
    batt=$(prop "$path" org.bluez.Battery1 Percentage)
    [[ "$batt" =~ ^[0-9]+$ ]] || batt="null"
    devices=$(jq -c --arg n "$name" --argjson b "$batt" '. + [{name:$n, battery:$b}]' <<<"$devices")
    count=$((count + 1))
  done < <(connected_macs)
fi

out=$(jq -nc --argjson available "$available" --argjson count "$count" --argjson devices "$devices" \
  '{available:$available, count:$count, devices:$devices}')
emit "$out"
