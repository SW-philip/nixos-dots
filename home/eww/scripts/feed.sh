#!/usr/bin/env bash
# deflisten driver: run a command every <interval>s after an initial <offset>s
# delay, printing only when the output changed. eww re-evaluates every widget
# bound to a var on each line, so unchanged repeats are pure load; the offsets
# keep the feeds from all waking on the same tick.
set -u
interval=$1 offset=$2 cmd=$3
sleep "$offset"
last=
while :; do
  cur=$(bash -c "$cmd" 2>/dev/null) || cur=$last
  [ "$cur" = "$last" ] || { printf '%s\n' "$cur"; last=$cur; }
  sleep "$interval"
done
