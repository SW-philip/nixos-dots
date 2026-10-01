#!/usr/bin/env bash
# Usage: bash home/niri/test_launcher.sh <path-to-launcher-script>
set -euo pipefail
LAUNCHER="${1:?usage: test_launcher.sh <path-to-launcher>}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Stubs log their argv instead of touching a real fuzzel/eww.
cat > "$TMP/bin/fuzzel" <<'STUB'
#!/usr/bin/env bash
echo "fuzzel $*" >> "$STUB_LOG"
STUB
cat > "$TMP/bin/eww" <<'STUB'
#!/usr/bin/env bash
echo "eww $*" >> "$STUB_LOG"
STUB
chmod +x "$TMP/bin/fuzzel" "$TMP/bin/eww"

export STUB_LOG="$TMP/log"
export LAUNCHER_EWW="$TMP/bin/eww"
export PATH="$TMP/bin:$PATH"
export XDG_RUNTIME_DIR="$TMP"
export LAUNCHER_FAVS="$TMP/none.json"

run() { : > "$STUB_LOG"; bash "$LAUNCHER"; cat "$STUB_LOG"; }

[ "$(run | cut -d" " -f1-2)" = "fuzzel --placeholder" ] && pass "no state file => fuzzel" || fail "no state file => fuzzel"

echo attached > "$TMP/surface-cover"
[ "$(run | cut -d" " -f1-2)" = "fuzzel --placeholder" ] && pass "attached => fuzzel" || fail "attached => fuzzel"

echo garbage > "$TMP/surface-cover"
[ "$(run | cut -d" " -f1-2)" = "fuzzel --placeholder" ] && pass "unknown state => fuzzel" || fail "unknown state => fuzzel"

echo detached > "$TMP/surface-cover"
[ "$(run)" = "eww open --toggle launcher-tablet" ] && pass "detached => eww open --toggle launcher-tablet" || fail "detached => eww open --toggle launcher-tablet"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
