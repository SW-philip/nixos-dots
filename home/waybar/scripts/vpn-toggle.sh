#!/usr/bin/env bash

SYSTEMCTL="/run/current-system/sw/bin/systemctl"
SUDO="/run/wrappers/bin/sudo"

declare -A VPN_SERVICES=(
  ["New York"]="protonvpn-ny"
  ["Brisbane, AU"]="protonvpn-au"
  ["Canada"]="protonvpn-ca"
)
VPN_ORDER=("New York" "Brisbane, AU" "Canada")

# Detect active ProtonVPN tunnel
active_vpn_svc=""
active_vpn_label=""
for label in "${VPN_ORDER[@]}"; do
  svc="wg-quick-${VPN_SERVICES[$label]}.service"
  if $SYSTEMCTL is-active --quiet "$svc" 2>/dev/null; then
    active_vpn_svc="$svc"
    active_vpn_label="$label"
    break
  fi
done

# Detect Tailscale state
tailscale_on=false
$SYSTEMCTL is-active --quiet tailscaled.service 2>/dev/null && tailscale_on=true

# Build menu entries, marking the active one
entries=()
for label in "${VPN_ORDER[@]}"; do
  if [ "$active_vpn_label" = "$label" ]; then
    entries+=("󰖂  $label  [on]")
  else
    entries+=("    $label")
  fi
done

if $tailscale_on; then
  entries+=("󰒄  Tailscale  [on]")
else
  entries+=("    Tailscale")
fi
entries+=("󰖪  Disconnect")

choice=$(printf '%s\n' "${entries[@]}" \
  | fuzzel --dmenu --prompt "Network › " --width 300 --lines 5) || exit 0
[ -z "$choice" ] && exit 0

if [[ "$choice" == *"Disconnect"* ]]; then
  [ -n "$active_vpn_svc" ] && $SUDO -n $SYSTEMCTL stop "$active_vpn_svc" 2>/dev/null
  $tailscale_on && $SUDO -n $SYSTEMCTL stop tailscaled.service 2>/dev/null
  notify-send "Network" "Disconnected" -i network-vpn-off
  exit 0
fi

if [[ "$choice" == *"Tailscale"* ]]; then
  if $tailscale_on; then
    $SUDO -n $SYSTEMCTL stop tailscaled.service && \
      notify-send "Tailscale" "Disconnected" -i network-vpn-off || \
      notify-send "Tailscale" "Disconnect failed" -i network-error
  else
    [ -n "$active_vpn_svc" ] && $SUDO -n $SYSTEMCTL stop "$active_vpn_svc" 2>/dev/null
    $SUDO -n $SYSTEMCTL start tailscaled.service && \
      notify-send "Tailscale" "Connected" -i network-vpn-symbolic || \
      notify-send "Tailscale" "Connect failed" -i network-error
  fi
  exit 0
fi

# ProtonVPN selection — strip icon prefix and [on] suffix to recover the label
selected_label=$(echo "$choice" | sed 's/^[^A-Za-z]*//' | sed 's/  \[on\]$//')
target="${VPN_SERVICES[$selected_label]:-}"
[ -z "$target" ] && exit 1

$tailscale_on && $SUDO -n $SYSTEMCTL stop tailscaled.service 2>/dev/null

# Wait for tailscale0 to actually disappear before bringing up a second
# full-tunnel interface — both fight over the default route/DNS if they're
# ever up at once, which silently breaks connectivity even though wg-quick
# itself reports success (it never checks for a real handshake).
if $tailscale_on; then
  for _ in $(seq 1 20); do
    ip link show tailscale0 &>/dev/null || break
    sleep 0.25
  done
fi

[ -n "$active_vpn_svc" ] && $SUDO -n $SYSTEMCTL stop "$active_vpn_svc" 2>/dev/null

if ! $SUDO -n $SYSTEMCTL start "wg-quick-${target}.service"; then
  notify-send "VPN" "Connect failed — service wouldn't start" -i network-error
  exit 1
fi

# systemctl start succeeding only means wg-quick set up the interface and
# routes — it does NOT mean the peer answered. Poll for a real handshake
# before declaring success; if one never lands, tear the tunnel back down
# instead of leaving a dead full-tunnel route in place.
handshake=0
for _ in $(seq 1 20); do
  ts=$($SUDO -n wg show "$target" latest-handshakes 2>/dev/null | awk '{print $2}')
  if [ -n "$ts" ] && [ "$ts" != "0" ]; then
    handshake=1
    break
  fi
  sleep 0.5
done

if [ "$handshake" = "1" ]; then
  notify-send "VPN" "Connected — $selected_label" -i network-vpn-symbolic
else
  $SUDO -n $SYSTEMCTL stop "wg-quick-${target}.service" 2>/dev/null
  notify-send "VPN" "Connect failed — no handshake from $selected_label" -i network-error
  exit 1
fi
