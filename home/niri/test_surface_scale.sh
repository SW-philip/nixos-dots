#!/usr/bin/env bash
# Usage: bash home/niri/test_surface_scale.sh <path-to-surface-scale>
set -euo pipefail
SCRIPT="${1:?usage: test_surface_scale.sh <path-to-surface-scale>}"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/niri" <<'STUB'
#!/usr/bin/env bash
echo "niri $*" > "$STUB_LOG"
STUB
chmod +x "$TMP/niri"

run() { # state-file-content-or-empty-for-missing
  rm -f "$TMP/surface-cover" "$TMP/log"
  [ -n "$1" ] && echo "$1" > "$TMP/surface-cover"
  NIRI="$TMP/niri" XDG_RUNTIME_DIR="$TMP" STUB_LOG="$TMP/log" bash "$SCRIPT"
  cat "$TMP/log"
}

[ "$(run detached)" = "niri msg output eDP-1 scale 2.4" ] && pass "detached => 2.4" || fail "detached => 2.4"
[ "$(run attached)" = "niri msg output eDP-1 scale 2.0" ] && pass "attached => 2.0" || fail "attached => 2.0"
[ "$(run "")"       = "niri msg output eDP-1 scale 2.0" ] && pass "missing => 2.0"  || fail "missing => 2.0"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
