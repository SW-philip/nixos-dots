#!/usr/bin/env bash
# Nightly health audit: run health-check.sh on each host, store the findings,
# and report what changed since the previous run.
#   goodnight-audit.sh [host...]     hosts: pi retro desktop surface (default: all)
#   goodnight-audit.sh --report      print the summary of the last run (report.json)
#   GOODNIGHT_STATE=dir              state dir (default ~/.local/state/goodnight)
#   GOODNIGHT_HEALTH_CHECK=path      health-check.sh to run (default: next to this script)
#   GOODNIGHT_NOTIFY=1               desktop notification when a night has a new ✗
# Exit 1 if any host has a new ✗ finding; an unreachable host is reported, not failed.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=${GOODNIGHT_STATE:-$HOME/.local/state/goodnight}
state=$root/audits
report=$root/report.json
keep=30
health_check=${GOODNIGHT_HEALTH_CHECK:-$here/health-check.sh}

FLEET_JSON=${FLEET_JSON:-/etc/fleet.json}
[[ -r $FLEET_JSON ]] || FLEET_JSON=$here/../hosts/inventory.json
fleet_self() { jq -r --arg n "${1,,}" 'to_entries[] | select(.key == $n or (.value.nick | ascii_downcase) == $n) | .key' "$FLEET_JSON" | head -n1; }
me=$(fleet_self "$(hostname)")

print_report() {
  [[ -r $report ]] || { echo "goodnight-audit: no report yet"; return 0; }
  jq -r '"last audit: " + (.generated_at | localtime | strftime("%a %b %d %H:%M")),
    (.hosts | to_entries[] | .key as $h | .value
     | if .status == "unreachable" then "  \($h): unreachable (last seen \(.last_ok // "never"))"
       else "  \($h): \(.grade) — \(.new | length) new, \(.resolved) resolved, \(.still) open, \(.unchecked) unchecked" end,
       (.new[]? | "      NEW " + (if .level == "fail" then "✗ " else "~ " end) + .section + ": " + .text))' "$report"
}
if [[ ${1:-} == --report ]]; then print_report; exit 0; fi

order=(pi retro desktop surface)
hosts=()
for a in "$@"; do
  [[ " ${order[*]} " == *" $a "* ]] || { echo "goodnight-audit: unknown host: $a" >&2; exit 2; }
  hosts+=("$a")
done
[[ ${#hosts[@]} -gt 0 ]] || hosts=("${order[@]}")

# Raw health-check output -> {host, ts, grade, findings[{section, level, text, key}]}.
# `key` blanks the digits so "RAM usage 59%" tonight and 61% tomorrow are one finding.
to_json() { # host ts
  jq -Rn --arg host "$1" --arg ts "$2" '
    reduce inputs as $l ({sec: "", grade: "", f: []};
      if ($l | startswith("── ")) then .sec = ($l | ltrimstr("── "))
      elif ($l | test("^  [✔~✗?] ")) then
        .f += [{section: .sec, level: ({"✔": "pass", "~": "warn", "✗": "fail", "?": "unk"}[$l[2:3]]), text: $l[4:]}]
      elif ($l | startswith("Grade:")) then .grade = ($l | ltrimstr("Grade: "))
      else . end)
    | {host: $host, ts: $ts, grade: .grade,
       findings: (.f | map(. + {key: (.section + "|" + (.text | gsub("[0-9]+"; "#")))}))}'
}

run_check() { # host -> raw output on stdout; non-zero if unreachable
  if [[ "$1" == "$me" ]]; then
    HC_HOST=$1 HC_NONINTERACTIVE=1 bash "$health_check"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=8 "prepko@$1" "HC_HOST=$1 HC_NONINTERACTIVE=1 bash -s" < "$health_check"
  fi
}

ts=$(date +%Y%m%dT%H%M%S)
new_fail=0
sums=$(mktemp -d)
trap 'rm -rf "$sums"' EXIT
for h in "${hosts[@]}"; do
  echo "== $h"
  if ! raw=$(run_check "$h" 2>/dev/null) || ! grep -q '^Grade:' <<<"$raw"; then
    echo "  UNREACHABLE (or the check did not finish) — nothing recorded"
    last=$(find "$state/$h" -maxdepth 1 -name '*.json' 2>/dev/null | sort | tail -n1 || true)
    jq -n --arg last "${last:+$(basename "$last" .json)}" '{status: "unreachable", last_ok: (if $last == "" then null else $last end)}' > "$sums/$h.json"
    continue
  fi
  dir=$state/$h
  mkdir -p "$dir"
  prev=$(find "$dir" -maxdepth 1 -name '*.json' | sort | tail -n1)
  cur=$dir/$ts.json
  to_json "$h" "$ts" <<<"$raw" > "$cur"

  echo "  $(jq -r .grade "$cur")"
  diff_json='{"new": [], "resolved": [], "still": []}'
  if [[ -z $prev ]]; then
    echo "  first run — baseline recorded"
  else
    # level+key identity: a warn that becomes a fail is a new fail.
    diff_json=$(jq -n --slurpfile p "$prev" --slurpfile c "$cur" '
      def bad: map(select(.level == "warn" or .level == "fail")) | map({(.level + "|" + .key): .}) | add // {};
      ($p[0].findings | bad) as $pb | ($c[0].findings | bad) as $cb
      | {new: [$cb | to_entries[] | select($pb[.key] == null) | .value],
         resolved: [$pb | to_entries[] | select($cb[.key] == null) | .value],
         still: [$cb | to_entries[] | select($pb[.key] != null) | .value]}')
    jq -r '.new[]      | "  NEW      " + (if .level == "fail" then "✗ " else "~ " end) + .section + ": " + .text' <<<"$diff_json"
    jq -r '.resolved[] | "  resolved " + .section + ": " + .text' <<<"$diff_json"
    jq -r '.still[]    | "  still    " + (if .level == "fail" then "✗ " else "~ " end) + .section + ": " + .text' <<<"$diff_json"
    if [[ $(jq '[.new[] | select(.level == "fail")] | length' <<<"$diff_json") -gt 0 ]]; then new_fail=1; fi
  fi
  jq -n --slurpfile c "$cur" --argjson d "$diff_json" '
    {status: "ok", ts: $c[0].ts, grade: $c[0].grade,
     new: ($d.new | map({level, section, text})), resolved: ($d.resolved | length), still: ($d.still | length),
     unchecked: ($c[0].findings | map(select(.level == "unk")) | length)}' > "$sums/$h.json"
  jq -r '.findings[] | select(.level == "unk") | "  unchecked " + .section + ": " + .text' "$cur"

  # keep the newest $keep runs per host
  find "$dir" -maxdepth 1 -name '*.json' | sort | head -n -"$keep" | xargs -r rm --
done

# Merge tonight's hosts over the previous report so a partial run keeps the others' rows.
mkdir -p "$root"
prev_hosts=$(jq -c '.hosts // {}' "$report" 2>/dev/null || echo '{}')
for f in "$sums"/*.json; do
  [[ -e $f ]] || continue
  h=$(basename "$f" .json)
  prev_hosts=$(jq -c --arg h "$h" --slurpfile v "$f" '.[$h] = $v[0]' <<<"$prev_hosts")
done
# keep keys other writers own (goodnight.sh's `phases`)
base='{}'
jq -e . "$report" >/dev/null 2>&1 && base=$(cat "$report")
jq -n --argjson base "$base" --argjson hosts "$prev_hosts" --argjson now "$(date +%s)" '$base + {generated_at: $now, hosts: $hosts}' > "$report.tmp"
mv "$report.tmp" "$report"

if [[ $new_fail -eq 1 && ${GOODNIGHT_NOTIFY:-} == 1 ]] && command -v notify-send >/dev/null; then
  body=$(jq -r '.hosts | to_entries[] | select(.value.status == "ok") | .key as $h
    | .value.new[] | select(.level == "fail") | "\($h): \(.text)"' "$report")
  notify-send -u critical "goodnight: new failure" "$body" || true
fi
exit "$new_fail"
