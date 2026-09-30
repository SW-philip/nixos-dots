#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run() { LAUNCHER_FAVS="$1" bash "$DIR/../launcher-favs.sh"; }

items() { # n -> JSON array of n tiles
  jq -nc --argjson n "$1" '[range($n) | {icon:"i\(.)", label:"L\(.)", cmd:"c\(.)"}]'
}

items 12 > "$TMP/twelve.json"
out="$(run "$TMP/twelve.json")"
[ "$(jq 'length' <<<"$out")" = "3" ] && pass "12 tiles => 3 rows" || fail "12 tiles => 3 rows"
[ "$(jq -c '[.[]|length]' <<<"$out")" = "[4,4,4]" ] && pass "rows of 4" || fail "rows of 4"
[ "$(jq -r '.[2][3].cmd' <<<"$out")" = "c11" ] && pass "order preserved" || fail "order preserved"

items 5 > "$TMP/five.json"
out="$(run "$TMP/five.json")"
[ "$(jq -c '[.[]|length]' <<<"$out")" = "[4,1]" ] && pass "5 tiles => 4+1" || fail "5 tiles => 4+1"

[ "$(jq -c '[.[0][].accent]' <<<"$(run "$TMP/twelve.json")")" = "[0,1,2,3]" ] && pass "accent = column index" || fail "accent = column index"
[ "$(jq -r '.[1][0].accent' <<<"$out")" = "0" ] && pass "accent restarts each row" || fail "accent restarts each row"

echo '[]' > "$TMP/empty.json"
[ "$(run "$TMP/empty.json")" = "[]" ] && pass "empty array => []" || fail "empty array => []"

[ "$(run "$TMP/does-not-exist.json")" = "[]" ] && pass "missing file => []" || fail "missing file => []"

echo 'not json' > "$TMP/bad.json"
[ "$(run "$TMP/bad.json")" = "[]" ] && pass "invalid json => []" || fail "invalid json => []"

# The shipped seed must be valid and match the spec's 12 tiles.
SEED="$DIR/../../launcher-favs.json"
out="$(run "$SEED")"
[ "$(jq -c '[.[]|length]' <<<"$out")" = "[4,4,4]" ] && pass "seed is 4x3" || fail "seed is 4x3"
[ "$(jq '[.[][]|select(.cmd|contains("'"'"'"))]|length' <<<"$out")" = "0" ] && pass "seed cmds have no single quote" || fail "seed cmds have no single quote"
[ "$(jq -r '.[2][3].cmd' <<<"$out")" = "fuzzel" ] && pass "last tile is All apps -> fuzzel" || fail "last tile is All apps -> fuzzel"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
