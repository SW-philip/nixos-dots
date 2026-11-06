#!/usr/bin/env bash
# ssh-tunnel — pick a host and port in fuzzel, forward localhost:<port> to it over ssh, open the browser.
# Re-run to close a running tunnel. Tunnels are transient user units named tunnel-<host>-<port>.
# "Ports" lists listening ports here and checks a typed number against them and the flake.
set -euo pipefail

FLEET_JSON=${FLEET_JSON:-/etc/fleet.json}
# the pi first: its AdGuard UI is the usual target
mapfile -t HOSTS < <(jq -r 'keys | (map(select(. == "pi")) + map(select(. != "pi")))[]' "$FLEET_JSON")
DEFAULT_PORT=${TUNNEL_DEFAULT_PORT:?set by home/tunnel.nix from hosts/ports.nix}
menu=(fuzzel --dmenu --width 420)
FLAKE=${NH_FLAKE:-$HOME/nixos}
# polkit gates this on every run (modules/port-viewer.nix); root's ss sees every process name
PKEXEC=/run/wrappers/bin/pkexec
HELPER=/run/current-system/sw/bin/port-viewer-root

# ss -tulnpH on stdin -> "port  proto  process  address" rows, one per listener
format_ports() {
  awk '{
    n = split($5, a, ":"); port = a[n]; addr = substr($5, 1, length($5) - length(port) - 1)
    proc = "-"
    if (match($7, /\(\("[^"]+"/)) proc = substr($7, RSTART + 3, RLENGTH - 4)
    printf "%-6s %-4s %-22s %s\n", port, $1, proc, addr
  }' | sort -n -u
}

# where the flake already claims a port, so a free-right-now number isn't taken in config
flake_hits() {
  grep -rnwI --include='*.nix' -- "$1" "$FLAKE"/home "$FLAKE"/hosts "$FLAKE"/modules "$FLAKE"/roles 2>/dev/null \
    | grep -iE 'port|listen|address|bind' | sed "s|$FLAKE/||" | cut -c1-110 | head -5 || true
}

check_port() {
  local port=$1 live hits out=()
  live=$(ss -tulnH | awk -v p="$port" '{n = split($5, a, ":"); if (a[n] == p) print $1}' | sort -u | paste -sd,)
  hits=$(flake_hits "$port")
  if [ -n "$live" ]; then out+=("in use here ($live)"); else out+=("free here right now"); fi
  if [ -n "$hits" ]; then
    out+=("mentioned in the flake:")
    while read -r l; do out+=("  $l"); done <<<"$hits"
  else
    out+=("not mentioned in the flake")
  fi
  printf '%s\n' "${out[@]}" | "${menu[@]}" --lines "${#out[@]}" --prompt "Port $port › " >/dev/null || true
}

# A restarted polkitd (every nrs activation, plus its own idle exits) forgets the agent, and
# pkexec then exits 127 with no dialog. Re-register the agent when polkitd is newer than it,
# and once more on a 127.
root_ports() {
  local out rc=0 pk ag
  pk=$(systemctl show -p ActiveEnterTimestampMonotonic --value polkit.service)
  ag=$(systemctl --user show -p ActiveEnterTimestampMonotonic --value polkit-agent.service)
  if [ "${pk:-0}" -gt "${ag:-0}" ]; then
    systemctl --user restart polkit-agent.service
    sleep 1
  fi
  out=$("$PKEXEC" "$(readlink -f "$HELPER")" 2>/dev/null) || rc=$?
  if [ "$rc" = 127 ]; then
    systemctl --user restart polkit-agent.service
    sleep 1
    rc=0
    out=$("$PKEXEC" "$(readlink -f "$HELPER")" 2>/dev/null) || rc=$?
  fi
  [ "$rc" = 0 ] || return "$rc"
  printf '%s\n' "$out"
}

ports_menu() {
  local rows listing sel port
  rows=$(ss -tulnpH | format_ports)
  while true; do
    listing=$(printf '%s\n' "󰌾  Show system processes (password)" "$rows")
    sel=$(printf '%s\n' "$listing" | "${menu[@]}" --lines 15 --prompt "Ports (type a number to check) › ") || return 0
    [ -z "$sel" ] && return 0
    if [[ "$sel" == 󰌾* ]]; then
      if root=$(root_ports); then
        rows=$(format_ports <<<"$root")
      else
        notify-send "Ports" "Authentication cancelled or denied" -i network-error
      fi
      continue
    fi
    port=${sel%% *}
    if [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)); then
      check_port "$port"
    fi
  done
}

active=$(systemctl --user list-units 'tunnel-*.service' --state=active --plain --no-legend 2>/dev/null \
  | awk '{print $1}' | sed -E 's/^tunnel-//; s/\.service$//' || true)

entries=("󰐕  New tunnel…" "󰒍  Ports")
while read -r t; do
  [ -n "$t" ] && entries+=("󰖂  $t  [on]")
done <<<"$active"

choice=$(printf '%s\n' "${entries[@]}" | "${menu[@]}" --lines "${#entries[@]}" --prompt "Tunnel › ") || exit 0
[ -z "$choice" ] && exit 0

if [[ "$choice" == *"Ports" ]]; then
  ports_menu
  exit 0
fi

if [[ "$choice" == *"[on]" ]]; then
  name=$(sed -E 's/^[^A-Za-z]*//; s/  \[on\]$//' <<<"$choice")
  systemctl --user stop "tunnel-$name.service"
  notify-send "Tunnel" "Closed — $name" -i network-vpn-off
  exit 0
fi

[[ "$choice" == *"New tunnel"* ]] || exit 0

host=$(printf '%s\n' "${HOSTS[@]}" | "${menu[@]}" --lines "${#HOSTS[@]}" --prompt "Host › ") || exit 0
[ -z "$host" ] && exit 0
port=$(printf '%s\n' "$DEFAULT_PORT" | "${menu[@]}" --lines 1 --prompt "Port › ") || exit 0
[ -z "$port" ] && exit 0
if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
  notify-send "Tunnel" "Bad port: $port" -i network-error
  exit 1
fi

unit="tunnel-$host-$port"
if ss -tln "sport = :$port" | grep -q LISTEN; then
  notify-send "Tunnel" "localhost:$port is already in use" -i network-error
  exit 1
fi

systemd-run --user --quiet --unit "$unit" \
  ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -L "$port:localhost:$port" "$host"

for _ in $(seq 1 20); do
  ss -tln "sport = :$port" | grep -q LISTEN && break
  sleep 0.25
done
if ! ss -tln "sport = :$port" | grep -q LISTEN; then
  systemctl --user stop "$unit.service" 2>/dev/null || true
  notify-send "Tunnel" "Couldn't reach $host" -i network-error
  exit 1
fi

notify-send "Tunnel" "$host → localhost:$port" -i network-vpn-symbolic
xdg-open "http://localhost:$port"
