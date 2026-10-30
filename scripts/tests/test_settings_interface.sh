#!/usr/bin/env bash
# Fixture tests for scripts/settings/interface.sh.
# shellcheck disable=SC2016,SC2154 # shim bodies expand when run; fail comes from the sourced testlib
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/settings_testlib.sh"
H="$SETTINGS_DIR/interface.sh"

shim snark '[[ "$1" == status ]] && echo "snark: ${SNARK_STATE:-on}"; [[ "$1" == toggle ]] && echo "snark: off"; exit 0'
shim notify-send

out=$(SNARK_STATE=on bash "$H" --list)
assert_has "on: offers off" "turn it off" "$out"
out=$(SNARK_STATE=off bash "$H" --list)
assert_has "off: offers on" "turn it on" "$out"

: > "$FAKE_LOG"; printf 'turn it off\n' > "$PICKS"
SNARK_STATE=on bash "$H"
assert_has "toggle runs snark" "snark toggle" "$(cat "$FAKE_LOG")"
assert_has "toggle toasts" "notify-send" "$(cat "$FAKE_LOG")"

exit "$fail"
