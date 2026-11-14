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

# Stubs log their argv instead of touching a real menu/eww.
cat > "$TMP/bin/menu" <<'STUB'
#!/usr/bin/env bash
echo "menu $*" >> "$STUB_LOG"
# dmenu mode: keep the rows it was fed, answer with the index in $STUB_PICK
case " $* " in *" --dmenu "*) cat >> "$STUB_LOG.in"; echo "${STUB_PICK:-}" ;; esac
STUB
cat > "$TMP/bin/niri" <<'STUB'
#!/usr/bin/env bash
echo "niri $*" >> "$STUB_LOG"
STUB
cat > "$TMP/bin/eww" <<'STUB'
#!/usr/bin/env bash
echo "eww $*" >> "$STUB_LOG"
STUB
chmod +x "$TMP/bin/menu" "$TMP/bin/eww" "$TMP/bin/niri"

export STUB_LOG="$TMP/log"
export LAUNCHER_EWW="$TMP/bin/eww"
export PATH="$TMP/bin:$PATH"
export XDG_RUNTIME_DIR="$TMP"

run() { : > "$STUB_LOG"; bash "$LAUNCHER"; cat "$STUB_LOG"; }

[ "$(run | cut -d" " -f1-2)" = "menu --placeholder" ] && pass "no state file => drun" || fail "no state file => drun"

echo attached > "$TMP/surface-cover"
[ "$(run | cut -d" " -f1-2)" = "menu --placeholder" ] && pass "attached => drun" || fail "attached => drun"

echo garbage > "$TMP/surface-cover"
[ "$(run | cut -d" " -f1-2)" = "menu --placeholder" ] && pass "unknown state => drun" || fail "unknown state => drun"

echo detached > "$TMP/surface-cover"
[ "$(run)" = "eww open --toggle launcher-tablet" ] && pass "detached => eww open --toggle launcher-tablet" || fail "detached => eww open --toggle launcher-tablet"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
