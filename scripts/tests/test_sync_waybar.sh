#!/usr/bin/env bash
# Fixture tests for home/waybar/scripts/sync.sh over canned snapshots.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/home/waybar/scripts/sync.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}
export SYNC_FILE="$T/snap.json" SYNC_NOW=2000000100 SYNC_PALETTE=/nonexistent
field() { bash "$SCRIPT" | jq -r "$1"; }

assert_eq "missing snapshot: nosnap" nosnap "$(field .class)"

snap() {   # snap <level> <generated_at> <conflict-count> <reason>
  jq -n --arg level "$1" --argjson gen "$2" --argjson n "$3" --arg reason "$4" '
    {generated_at:$gen, api_ok:true, peer:{name:"SWphil", connected:($reason == "")},
     folders:[{id:"Documents", state:"idle", need_bytes:0, completion:100, errors:0}],
     conflicts:[range(0;$n) | {path:"Documents/a & b.sync-conflict-20261007-120000-MYMYMYM.txt", loser_is_local:true}],
     unsynced_since:null, level:$level, reasons:(if $reason == "" then [] else [$reason] end)}' > "$T/snap.json"
}

snap ok 2000000090 0 ""
assert_eq "ok: class"          ok  "$(field .class)"
assert_eq "ok: idle slot" '<span font_family="Hack Nerd Font Mono">󰓦</span> <span alpha="1%">0</span>' "$(field .text)"
[[ $(field .tooltip) == *"SWphil: connected"* && $(field .tooltip) == *"Documents  idle  100%"* ]]
assert_eq "ok: tooltip rows"   0 $?

snap warn 2000000090 2 ""
assert_eq "warn: class"        warn "$(field .class)"
[[ $(field .text) == *"</span> 2" ]]; assert_eq "warn: conflict count in text" 0 $?
[[ $(field .tooltip) == *"conflict: Documents/a &amp; b"* ]]; assert_eq "warn: tooltip escapes &" 0 $?

snap wait 2000000090 0 "SWphil offline"
assert_eq "wait: class"        wait "$(field .class)"
[[ $(field .tooltip) == *"! SWphil offline"* ]]; assert_eq "wait: reason in tooltip" 0 $?

snap wait 2000000090 0 "SWphil offline"
jq '.unsynced_since = 1999999000' "$T/snap.json" > "$T/snap2.json" && mv "$T/snap2.json" "$T/snap.json"
[[ $(field .tooltip) == *"unsynced for 18m"* ]]; assert_eq "unsynced: age line in tooltip" 0 $?
snap wait 2000000090 0 "SWphil offline"
[[ $(field .tooltip) != *"unsynced for"* ]]; assert_eq "synced: no age line" 0 $?

snap bad 2000000090 0 "syncthing is not running"
assert_eq "bad: class"         bad  "$(field .class)"

snap ok 1999999000 0 ""
assert_eq "old snapshot: stale" stale "$(field .class)"

exit $fail
