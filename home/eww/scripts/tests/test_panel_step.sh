#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/edge" <<'STUB'
#!/usr/bin/env bash
echo "$*" > "$EDGE_OUT"
STUB
chmod +x "$TMP/edge"
export EWW_PANEL_EDGE_BIN="$TMP/edge" EDGE_OUT="$TMP/out"
export EWW_PANEL_EDGE_STATE_DIR="$TMP/state" EWW_PANEL_OUTPUTS="DP-1 DP-2" EWW_PANEL_DEFAULT_SCREEN="DP-2"
mkdir -p "$TMP/state"

step() { bash "$DIR/../panel-step.sh" "$@"; cat "$TMP/out"; }
seed() { printf '%s' "$2" > "$TMP/state/eww-panel-edge-$1"; [ -z "${3:-}" ] || printf '%s' "$3" > "$TMP/state/eww-panel-screen-$1"; }

seed wing right DP-2
[ "$(step wing left)" = "wing left DP-2" ] && pass "left once: left edge of current display" || fail "left once"
seed wing left DP-2
[ "$(step wing left)" = "wing left DP-1" ] && pass "left twice: left edge of left display" || fail "left twice"
seed wing left DP-1
[ "$(step wing left)" = "wing left DP-1" ] && pass "left stops at the leftmost edge" || fail "left stop"
seed wing left DP-1
[ "$(step wing right)" = "wing right DP-1" ] && pass "right once: right edge of current display" || fail "right once"
seed wing right DP-1
[ "$(step wing right)" = "wing right DP-2" ] && pass "right twice: right edge of right display" || fail "right twice"
seed wing right DP-2
[ "$(step wing right)" = "wing right DP-2" ] && pass "right stops at the rightmost edge" || fail "right stop"

rm -f "$TMP/state/eww-panel-screen-wing"; seed wing right
[ "$(step wing left)" = "wing left DP-2" ] && pass "no screen file defaults to the baked connector" || fail "default screen"

bash "$DIR/../panel-step.sh" wing up >/dev/null 2>&1 && fail "rejects up for wing" || pass "rejects up for wing"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
