#!/usr/bin/env bash
# sync-conflicts: list, inspect and drop Syncthing conflict copies recorded in the sync-status snapshot.
#   sync-conflicts [list]   numbered conflicts: index, path, which side's edit lost
#   sync-conflicts show N   diff the winner against the conflict copy
#   sync-conflicts drop N   delete conflict copy N (asks first)
set -euo pipefail

SNAP=${SYNC_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/sync-status.json}
ROOT=${SYNC_ROOT:-$HOME}

[[ -r $SNAP ]] || { echo "no sync snapshot yet (start sync-status.service)" >&2; exit 1; }
mapfile -t paths < <(jq -r '.conflicts[].path' "$SNAP")

orig_of() { sed -E 's/\.sync-conflict-[0-9]{8}-[0-9]{6}-[A-Z0-9]{7}//' <<<"$1"; }
pick() {   # validated 1-based index -> conflict path on stdout
  local n=${1:-}
  if ! [[ $n =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#paths[@]} )); then echo "no conflict number '${n}'" >&2; exit 1; fi
  echo "${paths[n-1]}"
}

cmd=${1:-list}
case $cmd in
  list)
    if (( ${#paths[@]} == 0 )); then echo "no conflicts"; exit 0; fi
    jq -r '.conflicts | to_entries[] | "\(.key + 1)\t\(.value.path)\t\(if .value.loser_is_local then "your edit lost" else "other host edit lost" end)"' "$SNAP"
    ;;
  show)
    c=$ROOT/$(pick "${2:-}")
    o=$ROOT/$(orig_of "${c#"$ROOT"/}")
    if [[ ! -e $o ]]; then echo "original is gone: $o" >&2; exit 1; fi
    if grep -Iq '' "$o" "$c" 2>/dev/null; then
      pager=${PAGER:-less -R}
      # shellcheck disable=SC2086  # PAGER may carry flags
      diff -u --color=always "$o" "$c" | $pager || true
    else
      ls -l --time-style=long-iso "$o" "$c"
    fi
    ;;
  drop)
    c=$ROOT/$(pick "${2:-}")
    rm -i -- "$c"
    ;;
  *) echo "usage: sync-conflicts [list|show N|drop N]" >&2; exit 2 ;;
esac
