#!/usr/bin/env bash
# dnsreport — what the pi's AdGuard blocked, grouped by list, device and novelty. Reads retro's archive
# (hosts/retro/dns-querylog.nix) like dnslog; only blocked rows cross the wire, jq runs here.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: dnsreport [-d DAYS] [-t N] [-c]
  -d DAYS  window to report on (default 7)
  -t N     rows per section (default 15)
  -c       CSV on stdout instead of the report: domain,list,devices,count,first,last
EOF
}

[ "${1:-}" = --help ] && { usage; exit 0; }
days=7 top=15 csv=0
while getopts "d:t:ch" o; do
  case $o in
    d) days=$OPTARG ;;
    t) top=$OPTARG ;;
    c) csv=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$days" =~ ^[0-9]+$ && "$top" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }

fleet=${FLEET_JSON:-/etc/fleet.json}
clients=${DNS_CLIENTS_JSON:-$HOME/.config/dnslog/clients.json}
if [ -r "$clients" ]; then
  names=$(jq -c 'with_entries({key: .value, value: .key})' "$clients")
else
  names=$(jq -c 'with_entries({key: .value.ip, value: .key})' "$fleet" 2>/dev/null || echo '{}')
fi
since=$(date -d "-$days days" +%F)
recent=$(date -d "-1 day" +%F)
months=$((days / 28 + 2))

# one A + one AAAA lookup is a single attempt, so a domain's count is its busiest query type
ssh -o BatchMode=yes -o ConnectTimeout=10 retro \
  "sudo systemctl start dns-querylog-pull || echo 'dnsreport: pull from the pi failed; using what retro has' >&2
   sudo find /var/lib/dns-querylog -name '*.jsonl' | sort | tail -n $months | xargs -r sudo cat | grep -F '\"IsFiltered\":true' || true" \
  | jq -rs --argjson names "$names" --arg since "$since" --arg recent "$recent" \
      --argjson days "$days" --argjson top "$top" --argjson csv "$csv" '
      def list: (.Result.Rules[0].FilterListID // 0)
                | if . == 1 then "adguard" elif . == 2 then "smarttv" elif . == 0 then "custom" else "list\(.)" end;
      def dev: $names[.IP] // .IP;
      def attempts: group_by(.QT) | map(length) | max;
      def pad($w): tostring | . + (" " * ([$w - length, 0] | max));
      def lpad($w): tostring | (" " * ([$w - length, 0] | max)) + .;

      map(select(.T[0:10] >= $since))
      | (group_by(.QH) | map({
          domain: .[0].QH,
          list: (map(list) | unique | join("+")),
          devices: (map(dev) | unique),
          count: attempts,
          first: (map(.T) | min),
          last: (map(.T) | max)
        }) | sort_by(-.count)) as $doms
      | if $csv == 1 then
          (["domain","list","devices","count","first","last"] | @csv),
          ($doms[] | [.domain, .list, (.devices | join(" ")), .count, .first, .last] | @csv)
        else
          def row: "  \(.count | lpad(6))  \(.domain | pad(42)) \(.devices | join(","))";
          "blocked DNS, last \($days)d (since \($since)): \($doms | map(.count) | add // 0) lookups, \($doms | length) domains",
          "",
          "by list",
          ($doms | group_by(.list) | map({list: .[0].list, n: (map(.count) | add), d: length}) | sort_by(-.n)[]
            | "  \(.list | pad(8)) \(.n | lpad(7)) lookups  \(.d | lpad(5)) domains"),
          ( $doms | group_by(.list)[] | "", "top \(.[0].list)", (.[:$top][] | row) ),
          "",
          "by device",
          ( group_by(dev) | map({dev: (.[0] | dev), n: (group_by(.QH) | map(attempts) | add), d: (map(.QH) | unique | length)})
            | sort_by(-.n)[] | "  \(.dev | pad(16)) \(.n | lpad(7)) lookups  \(.d | lpad(5)) domains"),
          "",
          "new in the last 24h (not seen earlier in the window)",
          ( [$doms[] | select(.first[0:10] >= $recent)] | if length == 0 then "  none" else (.[:$top][] | row) end )
        end'
