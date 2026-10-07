#!/usr/bin/env bash
# Fixture tests for scripts/ff-sync.sh.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ff-sync.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_has() {   # name, needle, haystack
  if [[ "$3" == *"$2"* ]]; then echo "PASS: $1"; else echo "FAIL: $1 — '$2' not in '$3'"; fail=1; fi
}
export FF_SYNC_FILE="$T/snap.json" FF_NOW=2000000100 FF_OK='<ok>' FF_WARN='<warn>' FF_BAD='<bad>' FF_DIM='<dim>' FF_RS='</>'
snap() {   # snap <level> <generated_at> <conflicts> <reason>
  jq -n --arg level "$1" --argjson gen "$2" --argjson n "$3" --arg reason "$4" '
    {generated_at:$gen, peer:{name:"SWphil", connected:true}, level:$level,
     conflicts:[range(0;$n) | {path:"x", loser_is_local:true}],
     reasons:(if $reason == "" then [] else [$reason] end)}' > "$T/snap.json"
}

assert_has "missing: no snapshot" "no snapshot yet" "$(bash "$SCRIPT")"
snap ok 2000000090 0 "";                assert_has "ok: in sync + peer" "<ok>●</> <ok>in sync</> · SWphil" "$(bash "$SCRIPT")"
snap wait 2000000090 0 "SWphil offline"; assert_has "wait: dim reason"  "<dim>SWphil offline</>" "$(bash "$SCRIPT")"
snap warn 2000000090 2 "Documents behind"; assert_has "warn: reason + conflicts" "<warn>Documents behind, 2 conflicts</>" "$(bash "$SCRIPT")"
snap bad 2000000090 0 "syncthing is not running"; assert_has "bad: red reason" "<bad>syncthing is not running</>" "$(bash "$SCRIPT")"
snap ok 1999999000 0 "";                assert_has "old: stale note" "snapshot" "$(bash "$SCRIPT")"

exit $fail
