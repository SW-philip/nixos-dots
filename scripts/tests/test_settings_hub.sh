#!/usr/bin/env bash
# Fixture tests for scripts/settings/settings.sh (hub) and lib.sh run_menu.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/settings_testlib.sh"
HUB="$SETTINGS_DIR/settings.sh"

shim settings-network
shim settings-display
shim notify-send

out=$(bash "$HUB" --list)
assert_has "list: network" "Network" "$out"
assert_has "list: bluetooth" "Bluetooth" "$out"
assert_has "list: audio" "Audio" "$out"
assert_has "list: display" "Display" "$out"

# capability gating uses a fixture so the test doesn't depend on real sections
cat > "$T/gated.json" <<'JSON'
[
  {"id":"a","label":"Everyone","glyph":"x","requires":[],"kind":"menu","command":"true"},
  {"id":"b","label":"TouchOnly","glyph":"x","requires":["touch"],"kind":"menu","command":"true"}
]
JSON
out=$(SETTINGS_SECTIONS="$T/gated.json" SETTINGS_CAPS="desktop" bash "$HUB" --list)
assert_has "caps: ungated shown" "Everyone" "$out"
assert_lacks "caps: touch row hidden on desktop" "TouchOnly" "$out"
out=$(SETTINGS_SECTIONS="$T/gated.json" SETTINGS_CAPS="desktop touch" bash "$HUB" --list)
assert_has "caps: touch row shown with touch" "TouchOnly" "$out"

# pick runs the section's command, then the hub exits 0
: > "$FAKE_LOG"; printf 'Network\n' > "$PICKS"
bash "$HUB"; rc=$?
assert_eq "pick: exit 0" 0 "$rc"
assert_has "pick: ran handler" "settings-network" "$(cat "$FAKE_LOG")"

# top-level Escape: nothing runs, exit 0
: > "$FAKE_LOG"; : > "$PICKS"
bash "$HUB"; rc=$?
assert_eq "escape at top: exit 0" 0 "$rc"
assert_eq "escape at top: nothing ran" "" "$(cat "$FAKE_LOG")"

# handler Escape (exit 10) returns to the hub, which then runs the next pick
shim settings-network 'exit 10'
: > "$FAKE_LOG"; printf 'Network\nDisplay\n' > "$PICKS"
bash "$HUB"; rc=$?
assert_eq "back: exit 0" 0 "$rc"
assert_eq "back: network then display" $'settings-network \nsettings-display ' "$(grep '^settings-' "$FAKE_LOG")"

# handler failure toasts once; the hub exits 1 (11 = "already reported")
shim settings-network 'exit 3'
: > "$FAKE_LOG"; printf 'Network\n' > "$PICKS"
bash "$HUB"; rc=$?
assert_eq "failure: exit code" 1 "$rc"
assert_eq "failure: one toast" 1 "$(grep -c '^notify-send' "$FAKE_LOG")"

# a handler that already reported (11) is not toasted again
shim settings-network 'exit 11'
: > "$FAKE_LOG"; printf 'Network\n' > "$PICKS"
bash "$HUB"; rc=$?
assert_eq "reported: exit code" 1 "$rc"
assert_eq "reported: no extra toast" 0 "$(grep -c '^notify-send' "$FAKE_LOG")"

# nested run_menu (handler-style, two levels deep): one toast for the failure
# shellcheck disable=SC2317,SC2329 # called through run_menu
inner() { false; }
# shellcheck disable=SC2317,SC2329
outer() { printf 'Leaf\tinner\n' | run_menu "Inner"; }
: > "$FAKE_LOG"; printf 'Mid\nLeaf\n' > "$PICKS"
# shellcheck source=/dev/null
source "$SETTINGS_LIB"
printf 'Mid\touter\n' | run_menu "Outer"; rc=$?
assert_eq "nested: propagates 11" 11 "$rc"
assert_eq "nested: one toast" 1 "$(grep -c '^notify-send' "$FAKE_LOG")"

# fuzzel killed by a second `settings` press (>=128) ends the hub, no loop
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 143\n' > "$T/shim/killed"; chmod +x "$T/shim/killed"
SETTINGS_PICKER="$T/shim/killed" bash "$HUB"; rc=$?
assert_eq "killed picker: exits 143" 143 "$rc"

# shellcheck disable=SC2154 # fail is set by settings_testlib.sh
exit "$fail"
