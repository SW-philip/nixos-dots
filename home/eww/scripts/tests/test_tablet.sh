#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_RUNTIME_DIR="$TMP"

run() { bash "$DIR/../tablet.sh"; }

# No state file yet (desktop, or before the monitor first runs).
[ "$(run)" = "false" ] && pass "missing state file => false" || fail "missing state file => false"

echo detached > "$TMP/surface-cover"
[ "$(run)" = "true" ] && pass "detached => true" || fail "detached => true"

echo attached > "$TMP/surface-cover"
[ "$(run)" = "false" ] && pass "attached => false" || fail "attached => false"

echo garbage > "$TMP/surface-cover"
[ "$(run)" = "false" ] && pass "unknown content => false" || fail "unknown content => false"

: > "$TMP/surface-cover"
[ "$(run)" = "false" ] && pass "empty file => false" || fail "empty file => false"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
