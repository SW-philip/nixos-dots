#!/usr/bin/env bash
# Usage: bash home/niri/test_tablet_shell.sh <path-to-tablet-shell.sh>
set -euo pipefail
SCRIPT="${1:?usage: test_tablet_shell.sh <path-to-tablet-shell.sh>}"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
[ "${2:-}" = cat ] && exit "${STUB_NO_EWW_UNIT:-0}"
exit 0
STUB
cat > "$TMP/eww" <<'STUB'
#!/usr/bin/env bash
echo "eww $*" >> "$STUB_LOG"
case "$1" in
  ping)  [ -z "${STUB_NO_DAEMON:-}" ]; exit ;;
  open)  [ -n "${STUB_STRIP_FAILS:-}" ] || touch "$STUB_DIR/strip-open" ;;
  close) rm -f "$STUB_DIR/strip-open" ;;
  active-windows) [ -e "$STUB_DIR/strip-open" ] && echo "tablet-strip: tablet-strip"; true ;;
esac
exit 0
STUB
chmod +x "$TMP/systemctl" "$TMP/eww"

# run <cover-state, '' = missing file> [strip-fails] [no-eww-unit] [pre-existing-marker] [no-daemon]
run() {
  rm -f "$TMP/surface-cover" "$TMP/log" "$TMP/strip-open" "$TMP/tablet-strip-failed"
  : > "$TMP/log"
  [ -n "$1" ] && echo "$1" > "$TMP/surface-cover"
  [ -n "${4:-}" ] && touch "$TMP/tablet-strip-failed"
  XDG_RUNTIME_DIR="$TMP" STUB_LOG="$TMP/log" STUB_DIR="$TMP" \
    STUB_STRIP_FAILS="${2:-}" STUB_NO_EWW_UNIT="${3:-0}" STUB_NO_DAEMON="${5:-}" \
    TABLET_EWW="$TMP/eww" TABLET_SYSTEMCTL="$TMP/systemctl" TABLET_STRIP_WAIT=1 \
    bash "$SCRIPT"
}
logged()  { grep -qxF "$1" "$TMP/log"; }

run detached
{ logged "systemctl --user stop waybar.service" && logged "eww open tablet-strip" \
  && ! logged "systemctl --user start waybar.service"; } \
  && pass "detached: waybar stopped, strip opened, waybar not restarted" \
  || fail "detached: waybar stopped, strip opened, waybar not restarted"

run detached 1
{ logged "systemctl --user start waybar.service" && [ -e "$TMP/tablet-strip-failed" ]; } \
  && pass "detached, strip never appears: waybar comes back, failure marker set" \
  || fail "detached, strip never appears: waybar comes back, failure marker set"

run detached "" 0 "" 1
{ ! grep -q '^eww open' "$TMP/log" && logged "systemctl --user start waybar.service" \
  && ! logged "systemctl --user stop waybar.service" && [ -e "$TMP/tablet-strip-failed" ]; } \
  && pass "detached, no eww daemon: no eww open, waybar kept, marker set" \
  || fail "detached, no eww daemon: no eww open, waybar kept, marker set"

run attached "" 0 1
{ logged "eww close tablet-sheet tablet-strip" && logged "systemctl --user start waybar.service" \
  && [ ! -e "$TMP/tablet-strip-failed" ]; } \
  && pass "attached: strip closed, waybar started, marker cleared" \
  || fail "attached: strip closed, waybar started, marker cleared"

run ""
{ logged "eww close tablet-sheet tablet-strip" && logged "systemctl --user start waybar.service"; } \
  && pass "missing state file is treated as attached" \
  || fail "missing state file is treated as attached"

run detached "" 1
{ [ "$(wc -l < "$TMP/log")" = "1" ] && logged "systemctl --user cat eww.service"; } \
  && pass "no eww.service (Kid): does nothing" \
  || fail "no eww.service (Kid): does nothing"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
