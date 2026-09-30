#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake `eww` on PATH: logs every call instead of touching a real daemon.
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/eww" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$EWW_CALL_LOG"
exit 0
STUB
chmod +x "$FAKE_BIN/eww"

export PATH="$FAKE_BIN:$PATH"
export EWW_CALL_LOG="$TMP/calls.log"
export EWW_PANEL_EDGE_STATE_DIR="$TMP/state"

run() { bash "$DIR/../panel-edge.sh" "$@"; }

# Invalid slot is rejected, no state written.
if run bogus-slot left >"$TMP/out" 2>&1; then
  fail "rejects unknown slot (exited 0)"
else
  pass "rejects unknown slot"
fi
[ -e "$EWW_PANEL_EDGE_STATE_DIR/eww-panel-edge-bogus-slot" ] && fail "unknown slot still wrote a state file" || pass "unknown slot wrote no state file"

# Invalid edge for a valid slot is rejected (top is a ledger edge, not wing's).
if run wing top >"$TMP/out" 2>&1; then
  fail "rejects invalid edge for wing (exited 0)"
else
  pass "rejects invalid edge for wing"
fi

# First-ever call for a slot: seeds state, opens the window, and closes the
# sibling edge unconditionally (self-healing -- doesn't rely on a prior
# state file to know what to close).
: > "$EWW_CALL_LOG"
run wing left
[ "$(cat "$EWW_PANEL_EDGE_STATE_DIR/eww-panel-edge-wing")" = "left" ] && pass "wing left writes state=left" || fail "wing state not 'left'"
grep -qx "open status-left" "$EWW_CALL_LOG" && pass "wing left opens status-left" || fail "wing left did not open status-left"
grep -qx "close status-right" "$EWW_CALL_LOG" && pass "wing left closes sibling status-right unconditionally" || fail "wing left did not close status-right"

# Switching edge closes the sibling and opens the new one.
: > "$EWW_CALL_LOG"
run wing right
[ "$(cat "$EWW_PANEL_EDGE_STATE_DIR/eww-panel-edge-wing")" = "right" ] && pass "wing right writes state=right" || fail "wing state not 'right'"
grep -qx "close status-left" "$EWW_CALL_LOG" && pass "wing right closes status-left" || fail "wing right did not close status-left"
grep -qx "open status-right" "$EWW_CALL_LOG" && pass "wing right opens status-right" || fail "wing right did not open status-right"

# Re-picking the same edge still closes the (already-closed) sibling -- a
# harmless no-op against the real daemon, but exercised here to confirm the
# script doesn't skip it just because nothing "changed".
: > "$EWW_CALL_LOG"
run wing right
grep -qx "close status-left" "$EWW_CALL_LOG" && pass "re-picking the same edge still closes the sibling (idempotent no-op)" || fail "re-picking the same edge did not close status-left"
grep -qx "open status-right" "$EWW_CALL_LOG" && pass "re-picking the same edge still opens status-right" || fail "re-picking the same edge did not open status-right"

# A corrupted/garbage prior state file must not prevent the correct sibling
# from being closed -- this is the scenario Task 3's ExecStartPost falls
# back to the Nix default for, so the real daemon may have status-right
# open even though wing's state file says something bogus. The close loop
# must not trust that file's content for anything except the value being
# switched to.
: > "$EWW_CALL_LOG"
echo -n "totally-bogus-value" > "$EWW_PANEL_EDGE_STATE_DIR/eww-panel-edge-wing"
run wing left
grep -qx "close status-right" "$EWW_CALL_LOG" && pass "garbage prior state still closes status-right" || fail "garbage prior state did not close status-right"
grep -qx "open status-left" "$EWW_CALL_LOG" && pass "garbage prior state still opens status-left" || fail "garbage prior state did not open status-left"

# ledger/ledger-tv slots map to the right window names.
: > "$EWW_CALL_LOG"
run ledger top
grep -qx "open ledger-top" "$EWW_CALL_LOG" && pass "ledger top opens ledger-top" || fail "ledger top did not open ledger-top"
grep -qx "close ledger-bottom" "$EWW_CALL_LOG" && pass "ledger top closes sibling ledger-bottom" || fail "ledger top did not close ledger-bottom"

: > "$EWW_CALL_LOG"
run ledger-tv bottom
grep -qx "open ledger-tv-bottom" "$EWW_CALL_LOG" && pass "ledger-tv bottom opens ledger-tv-bottom" || fail "ledger-tv bottom did not open ledger-tv-bottom"
grep -qx "close ledger-tv-top" "$EWW_CALL_LOG" && pass "ledger-tv bottom closes sibling ledger-tv-top" || fail "ledger-tv bottom did not close ledger-tv-top"

echo
if [[ $fails -eq 0 ]]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
