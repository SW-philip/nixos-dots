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
chmod +x "$TMP/bin/fuzzel" "$TMP/bin/eww" "$TMP/bin/niri"

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

# --- curated list: registry routing and "All apps" ---
export LAUNCHER_NIRI="$TMP/bin/niri"
cat > "$TMP/favs.json" <<'JSON'
[{"icon":"I","label":"Firefox","cmd":"firefox"},
 {"icon":"I","label":"Terminal","cmd":"ghostty -e htop"},
 {"icon":"I","label":"Files","cmd":"nemo"},
 {"icon":"I","label":"All apps","cmd":"fuzzel"}]
JSON
cat > "$TMP/registry.json" <<'JSON'
{"self":"surface","apps":{
 "firefox":{"exec":["firefox","--name","firefox"],"remoteExec":["firefox"],"hosts":["desktop","surface"]},
 "com.mitchellh.ghostty":{"exec":["ghostty"],"remoteExec":["ghostty"],"hosts":["desktop","surface"]}}}
JSON
export APP_LAUNCH_REGISTRY="$TMP/registry.json"
echo attached > "$TMP/surface-cover"
pick() { : > "$STUB_LOG"; : > "$STUB_LOG.in"; STUB_PICK=$1 LAUNCHER_FAVS="$TMP/favs.json" bash "$LAUNCHER"; }
last() { tail -n1 "$STUB_LOG"; }

pick 0
[ "$(last)" = "niri msg action spawn -- sh -c app-launch firefox" ] && pass "registry app routed through app-launch" || fail "registry app routed through app-launch ($(last))"
pick 1
[ "$(last)" = "niri msg action spawn -- sh -c ghostty -e htop" ] && pass "cmd with args is left alone" || fail "cmd with args is left alone ($(last))"
pick 2
[ "$(last)" = "niri msg action spawn -- sh -c nemo" ] && pass "non-registry app spawns as before" || fail "non-registry app spawns as before ($(last))"
grep -q "All apps" "$STUB_LOG.in" && pass "All apps row is listed" || fail "All apps row is listed"
pick 3
[ "$(grep -c '^fuzzel' "$STUB_LOG")" = 2 ] && ! grep -q '^niri' "$STUB_LOG" && ! last | grep -q -- --dmenu \
  && pass "All apps opens plain fuzzel, spawns nothing" || fail "All apps opens plain fuzzel, spawns nothing"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
