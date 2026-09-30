#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

state_dir="${XDG_RUNTIME_DIR:-/tmp}"
[[ "${1:-}" == "--selftest" ]] && state_dir="$(mktemp -d)"

kind="none"; ssid=""; signal_pct=0

# NET_TEST_IFACE: test-only env override to skip route lookup (e.g., NET_TEST_IFACE=wg0)
iface="${NET_TEST_IFACE:-$(ip route get 1.1.1.1 2>/dev/null \
  | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit }}' || true)}"
case "$iface" in
  wl*)                              kind="wifi" ;;
  en*|eth*)                         kind="wired" ;;
  wg*|tun*|tap*|proton*|*vpn*)
    # the tunnel is the default route; the real link underneath is usually
    # wifi — fall through to the nmcli lookup and report that.
    kind="wifi" ;;
  ?*)                               kind="wired" ;;
esac

if [[ "$kind" == "wifi" ]] && command -v nmcli >/dev/null 2>&1; then
  signal_pct=$(nmcli -t -f active,signal dev wifi 2>/dev/null | awk -F: '$1 == "yes" { print $2; exit }' || true)
  ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1 == "yes" { print $2; exit }' || true)
  [[ "$signal_pct" =~ ^[0-9]+$ ]] || signal_pct=0
  [[ -n "$ssid" ]] || ssid="unknown"
fi

vpn=false; vpn_name=""
for n in protonvpn-ny protonvpn-au protonvpn-ca; do
  if systemctl is-active --quiet "wg-quick-${n}.service" 2>/dev/null; then
    vpn=true; vpn_name=${n#protonvpn-}; vpn_name=${vpn_name^^}
    break
  fi
done
if [[ "$vpn" != "true" ]] && systemctl is-active --quiet tailscaled.service 2>/dev/null; then
  vpn=true; vpn_name="tailscale"
fi

out=$(jq -nc \
  --arg kind "$kind" --arg ssid "$ssid" --argjson signal_pct "$signal_pct" \
  --argjson vpn "$vpn" --arg vpn_name "$vpn_name" \
  '{kind:$kind, ssid:$ssid, signal_pct:$signal_pct, vpn:$vpn, vpn_name:$vpn_name}')
printf '%s\n' "$out"
[[ "${1:-}" == "--selftest" ]] || printf '%s\n' "$out" > "$state_dir/eww-net.json"
