#!/usr/bin/env bash
# Fixture tests for scripts/sync-conflicts.sh over a canned snapshot.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sync-conflicts.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/Documents"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

export SYNC_ROOT="$T" SYNC_FILE="$T/snap.json" PAGER=cat
C=Documents/a.sync-conflict-20261007-120000-MYMYMYM.txt
printf 'one\n' > "$T/Documents/a.txt"
printf 'two\n' > "$T/$C"
jq -n --arg c "$C" '{conflicts:[{path:$c, day:"20261007", time:"120000", loser_is_local:true}]}' > "$T/snap.json"

out=$(bash "$SCRIPT" list)
assert_eq "list: numbered with note" "1	$C	your edit lost" "$out"

out=$(bash "$SCRIPT" show 1 2>&1)
[[ $out == *"-one"* && $out == *"+two"* ]]; assert_eq "show: diff of original vs conflict" 0 $?

echo '{"conflicts":[]}' > "$T/snap2.json"
assert_eq "list: empty" "no conflicts" "$(SYNC_FILE=$T/snap2.json bash "$SCRIPT" list)"

bash "$SCRIPT" show 9 >/dev/null 2>&1; assert_eq "show: out of range fails" 1 $?

echo y | bash "$SCRIPT" drop 1 >/dev/null 2>&1
[[ ! -e $T/$C ]]; assert_eq "drop: conflict copy removed" 0 $?
[[ -e $T/Documents/a.txt ]]; assert_eq "drop: original kept" 0 $?

exit $fail
