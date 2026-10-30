#!/usr/bin/env bash
# dnslog — show the fleet's DNS queries: the pi's AdGuard log as archived on retro (hosts/retro/dns-querylog.nix).
# Triggers retro's pull first, so output is as fresh as AdGuard's last buffer flush (size_memory entries).
set -euo pipefail

usage() {
  cat <<'EOF'
usage: dnslog [-n N] [-b] [-f] [-a] [PATTERN]
  -n N     last N matching queries (default 40)
  -b       blocked queries only
  -f       keep following (retro pulls every 15 min)
  -a       every row: don't fold a name's A/AAAA/repeat lookups in the same second
  PATTERN  fixed-string match on domain or client IP
EOF
}

[ "${1:-}" = --help ] && { usage; exit 0; }
n=40 blocked=0 follow=0 all=0
while getopts "n:bfah" o; do
  case $o in
    n) n=$OPTARG ;;
    b) blocked=1 ;;
    f) follow=1 ;;
    a) all=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
pattern=${1:-}
[[ "$n" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
fleet=${FLEET_JSON:-/etc/fleet.json}
# a fleet host name matches its tailnet IP, the form the log records
if [ -n "$pattern" ] && ip=$(jq -er --arg h "$pattern" '.[$h].ip // empty' "$fleet" 2>/dev/null); then
  pattern="\"IP\":\"$ip\""
fi

# Filter on retro so only matches cross the wire; jq isn't on retro, so parsing is local.
filters="cat"
[ -n "$pattern" ] && filters+=" | grep --line-buffered -F -- $(printf %q "$pattern")"
((blocked)) && filters+=" | grep --line-buffered -F '\"IsFiltered\":true'"
# folding drops up to ~3 of every 4 rows, so over-fetch and trim after it (a stream can't be trimmed)
fetch=$((follow ? n : n * 4))
show="sudo cat \"\$f\" | $filters | tail -n $fetch"
((follow)) && show="$show; sudo tail -n0 -F \"\$f\" | $filters"

remote="sudo systemctl start dns-querylog-pull || echo 'dnslog: pull from the pi failed; showing what retro has' >&2
f=\$(sudo find /var/lib/dns-querylog -name '*.jsonl' | sort | tail -n1)
[ -n \"\$f\" ] || { echo 'dnslog: no log on retro yet' >&2; exit 1; }
$show"

# tailnet clients get their host name; LAN clients stay as IPs
names=$(jq -c 'with_entries({key: .value.ip, value: .key})' "$fleet" 2>/dev/null || echo '{}')

# Folding is streaming (first row of a group prints at once) so -f never holds a line back.
ssh -o BatchMode=yes -o ConnectTimeout=10 retro "$remote" \
  | jq -n --unbuffered -r --argjson names "$names" --argjson all "$all" '
      def pad($w): tostring | . + (" " * ([$w - length, 0] | max));
      foreach inputs as $e ({sec: "", seen: {}};
        ($e.T[0:19]) as $s | ($e.IP + " " + $e.QH) as $k
        | (if .sec == $s then . else {sec: $s, seen: {}} end)
        | .dup = (($all == 0) and (.seen[$k] // false))
        | .seen[$k] = true;
        select(.dup | not) | $e
        | [ (.T[5:10] + " " + .T[11:19]),
            ($names[.IP] // .IP | pad(15)),
            (if $all == 1 or (.QT | IN("A", "AAAA") | not) then (.QT | pad(5)) else "" end) + .QH
              + (if .Result.IsFiltered then "  [blocked]" else "" end)
          ] | join("  "))' \
  | if ((follow)); then cat; else tail -n "$n"; fi
