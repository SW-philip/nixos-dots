#!/usr/bin/env bash
# check-apps — verify every registry app's binary exists on every host that lists it.
set -euo pipefail

REGISTRY=${APP_LAUNCH_REGISTRY:-$HOME/.config/app-launch/registry.json}
self=$(jq -r .self "$REGISTRY")
bad=0

while IFS=$'\t' read -r id bin host; do
  if [[ $host == "$self" ]]; then
    probe=(bash -lc "command -v $bin")
  else
    probe=(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" "bash -lc 'command -v $bin'")
  fi
  if "${probe[@]}" >/dev/null 2>&1; then
    echo "ok       $id on $host ($bin)"
  else
    echo "MISSING  $id on $host ($bin)"
    bad=1
  fi
done < <(jq -r '.apps | to_entries[] | .key as $id | .value.exec[0] as $bin | .value.hosts[] | [$id, $bin, .] | @tsv' "$REGISTRY")

exit "$bad"
