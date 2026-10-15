#!/usr/bin/env bash
# classify() maps niri's eDP-1 transform to the waybar layout; a wrong mapping
# silently leaves the crushed single-row bar in portrait.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../waybar-orient.sh
source "$DIR/waybar-orient.sh"
fail=0

check() {
  local got
  got="$(classify "$1")"
  if [[ "$got" == "$2" ]]; then echo "PASS: $1 -> $2"; else echo "FAIL: $1 -> $got (want $2)"; fail=1; fi
}

check Normal landscape
check 180 landscape
check Flipped landscape
check Flipped180 landscape
check 90 portrait
check 270 portrait
check Flipped90 portrait
check Flipped270 portrait
check "" landscape

# reopen_tablet_windows: eww resolves :width "100%" at open time, so a detached
# cover needs the windows reopened after a rotation.
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
for t in eww tablet-shell; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/log"\n' "$t" "$TMPD" > "$TMPD/$t"
  chmod +x "$TMPD/$t"
done
reopen() {
  : > "$TMPD/log"
  [[ -n "$1" ]] && echo "$1" > "$TMPD/surface-cover" || rm -f "$TMPD/surface-cover"
  XDG_RUNTIME_DIR="$TMPD" ORIENT_EWW="$TMPD/eww" ORIENT_TABLET_SHELL="$TMPD/tablet-shell" reopen_tablet_windows
}
reopen detached
if [[ "$(cat "$TMPD/log")" == $'eww close tablet-sheet tablet-strip\ntablet-shell ' ]]; then
  echo "PASS: detached closes then re-runs tablet-shell"
else echo "FAIL: detached: $(tr '\n' '|' < "$TMPD/log")"; fail=1; fi
reopen attached
if [[ ! -s "$TMPD/log" ]]; then echo "PASS: attached does nothing"; else echo "FAIL: attached ran: $(tr '\n' '|' < "$TMPD/log")"; fail=1; fi
reopen ""
if [[ ! -s "$TMPD/log" ]]; then echo "PASS: missing cover file does nothing"; else echo "FAIL: missing file ran"; fail=1; fi

if (( fail == 0 )); then echo "All tests passed."; else echo "Some tests failed."; fi
exit $fail
