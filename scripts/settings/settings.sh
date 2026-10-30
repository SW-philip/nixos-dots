#!/usr/bin/env bash
# settings: top-level hub. Sections come from sections.json, gated by $SETTINGS_CAPS.
# shellcheck disable=SC2317,SC2329
set -euo pipefail
# shellcheck source=/dev/null
source "${SETTINGS_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib.sh}"
SECTIONS=${SETTINGS_SECTIONS:-$(dirname "${BASH_SOURCE[0]}")/sections.json}

usage() { echo "usage: settings [--list]"; }

sections() {
  jq -r --arg caps "${SETTINGS_CAPS:-}" '
    ($caps | split(" ")) as $have
    | .[] | select(((.requires // []) - $have) | length == 0)
    | "\(.glyph) \(.label)\t\(.command)"' "$SECTIONS"
}

case "${1:-}" in
  --help) usage; exit 0 ;;
  --list) export SETTINGS_LIST=1; sections | run_menu "Settings" 0; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

# Second press closes the open menu, like the launcher.
if [[ -z "${SETTINGS_PICKER:-}" ]] && pkill -x fuzzel; then exit 0; fi

while :; do
  rc=0
  sections | run_menu "Settings" 0 || rc=$?
  if (( rc == 10 )); then continue; fi
  if (( rc == 11 )); then exit 1; fi
  exit "$rc"
done
