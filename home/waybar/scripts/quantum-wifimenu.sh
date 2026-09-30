#!/usr/bin/env bash
set -euo pipefail

export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

CACHE="$HOME/.cache/quantum_wifi"
mkdir -p "$CACHE"
FAVES="$CACHE/favorites"
touch "$FAVES"

# fuzzel --dmenu: centered, flat, colours from ~/.config/fuzzel/fuzzel.ini.
launcher=(fuzzel --dmenu --lines 14)

WIFI_LOG=$(mktemp)
trap 'rm -f "$WIFI_LOG"' EXIT

active_ssid="$(nmcli -t -f active,ssid dev wifi | awk -F: '$1=="yes"{print $2}')"

bars() {
  local s=$1
  if   (( s < 25 )); then echo "▂   "
  elif (( s < 50 )); then echo "▂▄  "
  elif (( s < 75 )); then echo "▂▄▆ "
  else                    echo "▂▄▆█"
  fi
}

security_label() {
  case "$1" in
    *WPA3*) echo "WPA3" ;;
    *WPA2*) echo "WPA2" ;;
    *WEP*)  echo "WEP " ;;
    "")     echo "OPEN" ;;
    *)      echo "$1"   ;;
  esac
}

mapfile -t nets < <(
  nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list --rescan no \
  | grep -v '^$' \
  | sort -t: -k2 -nr
)

choices=()

if [[ -n "$active_ssid" ]]; then
  choices+=("🔗  Connected: $active_ssid")
else
  choices+=("❌  Not connected")
fi

choices+=("🔁  Rescan networks")
choices+=("─────────────────────────────────")

for net in "${nets[@]}"; do
  ssid=$(echo "$net" | cut -d: -f1)
  signal=$(echo "$net" | cut -d: -f2)
  sec=$(echo "$net" | cut -d: -f3)

  [[ -z "$ssid" ]] && continue

  favmark=""
  grep -qxF "$ssid" "$FAVES" && favmark="⭐ "

  bar="$(bars "$signal")"
  seclabel="$(security_label "$sec")"
  safe_ssid=$(printf '%s' "$ssid" | sed 's/[<>&]/_/g')

  if [[ "$ssid" == "$active_ssid" ]]; then
    choices+=("📶  $favmark$safe_ssid  $bar  $signal%  $seclabel")
  else
    choices+=("📡  $favmark$safe_ssid  $bar  $signal%  $seclabel")
  fi
done

choice=$(printf '%s\n' "${choices[@]}" | "${launcher[@]}" --prompt '📡 wifi:')
[[ -z "$choice" ]] && exit 0

if [[ "$choice" == *"Rescan networks"* ]]; then
  notify-send "Wi-Fi" "🔁 rescanning..."
  # List now uses --rescan no, so force a real scan here before re-opening.
  nmcli dev wifi list --rescan yes >/dev/null 2>&1 || true
  exec "$0"
fi

[[ "$choice" == "─"* ]] && exit 0
[[ "$choice" == "🔗"* ]] && exit 0
[[ "$choice" == "❌"* ]] && exit 0

# Extract SSID: strip leading emoji + spaces, then grab up to the signal bars
ssid=$(echo "$choice" | sed -E 's/^(📶|📡)  (⭐ )?//' | sed -E 's/  ▂.*//')

[[ -z "$ssid" ]] && exit 0

if [[ "$ssid" == "$active_ssid" ]]; then
  action=$(printf "disconnect\ntoggle favorite" | "${launcher[@]}" --prompt "🔗 $ssid:")
  [[ -z "$action" ]] && exit 0

  if [[ "$action" == "toggle favorite" ]]; then
    if grep -qxF "$ssid" "$FAVES"; then
      grep -vxF "$ssid" "$FAVES" > "$FAVES.tmp" && mv "$FAVES.tmp" "$FAVES"
      notify-send "Wi-Fi" "Removed $ssid from favorites"
    else
      echo "$ssid" >> "$FAVES"
      notify-send "Wi-Fi" "Added $ssid to favorites"
    fi
    exit 0
  fi

  nmcli con down "$ssid" || true
  notify-send "Wi-Fi" "📴 disconnected from $ssid"
  exit 0
fi

notify-send "Wi-Fi" "connecting to $ssid..."

if nmcli -w 10 dev wifi connect "$ssid" >"$WIFI_LOG" 2>&1; then
  notify-send "Wi-Fi" "✅ connected to $ssid"
  exit 0
fi

if grep -qi "Secrets were required" "$WIFI_LOG"; then
  pass=$(echo "" | "${launcher[@]}" --prompt "🔑 password for $ssid:")
  [[ -z "$pass" ]] && exit 0

  if nmcli dev wifi connect "$ssid" password "$pass"; then
    notify-send "Wi-Fi" "✅ connected to $ssid"
  else
    notify-send "Wi-Fi" "❌ authentication failed"
  fi
else
  notify-send "Wi-Fi" "❌ failed to connect to $ssid"
fi
