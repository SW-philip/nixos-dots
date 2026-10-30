#!/usr/bin/env bash
# commands: list the tools this flake gives you, grouped, from assets/commands.json.
#   commands            everything
#   commands <text>     entries whose name, group or description contains <text>
#   commands --json     the registry as JSON
set -euo pipefail
REG=${COMMANDS_JSON:-$(dirname "${BASH_SOURCE[0]}")/../assets/commands.json}

usage() { echo "usage: commands [--json] [filter]"; }

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --json) cat "$REG"; exit 0 ;;
  -*) usage >&2; exit 2 ;;
esac
filter=${1:-}

# Groups print in registry order; jq's group_by would sort them.
rows=$(jq -r --arg f "$filter" '
  map(select(($f == "") or ((.name + " " + .group + " " + .desc) | ascii_downcase | contains($f | ascii_downcase)))) as $hit
  | (reduce ($hit[] | .group) as $g ([]; if any(.[]; . == $g) then . else . + [$g] end)) as $groups
  | $groups[] as $g
  | $hit[] | select(.group == $g)
  | [.group, .name, (.desc + (if .host then " [" + .host + "]" else "" end))] | @tsv' "$REG")

if [[ -z "$rows" ]]; then
  echo "no commands match '$filter'" >&2
  exit 1
fi

last=
while IFS=$'\t' read -r group name desc; do
  if [[ "$group" != "$last" ]]; then
    if [[ -n "$last" ]]; then echo; fi
    echo "$group"
    last=$group
  fi
  printf '  %-26s %s\n' "$name" "$desc"
done <<<"$rows"
