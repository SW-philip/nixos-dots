#!/usr/bin/env bash
# whats-new: after a switch, summarise what changed against the previous system generation.
# Package diff via nvd, commit subjects between the two flake revisions (empty when either
# generation was built from a dirty tree). Full text goes to $STATE/last.txt; the notification
# click opens it.
set -euo pipefail

PROFILES=${WHATSNEW_PROFILES:-/nix/var/nix/profiles}
ROOT=${WHATSNEW_ROOT:-$HOME/nixos}
STATE=${WHATSNEW_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/whats-new}
OUT=$STATE/last.txt

cur=$(readlink -f "$PROFILES/system")
n=$(basename "$(readlink "$PROFILES/system")" | sed -E 's/^system-([0-9]+)-link$/\1/')
prev=
for ((i = n - 1; i > 0 && i > n - 20; i--)); do
  [[ -e $PROFILES/system-$i-link ]] && { prev=$(readlink -f "$PROFILES/system-$i-link"); break; }
done
[[ -n $prev && $prev != "$cur" ]] || { echo "whats-new: no previous generation to compare"; exit 0; }

rev() { "$1/sw/bin/nixos-version" --configuration-revision 2>/dev/null || true; }
old=$(rev "$prev"); new=$(rev "$cur")

mkdir -p "$STATE"
{
  echo "generation $((n - 1)) -> $n"
  nvd diff "$prev" "$cur" || true
  if [[ -n $old && -n $new && $old != "$new" ]]; then
    echo; echo "commits:"
    git -C "$ROOT" log --oneline "$old..$new" 2>/dev/null || echo "(revisions not in local history)"
  fi
} >"$OUT"

summary=$(grep -E '^(Added|Removed|Closure size)|\[[UAR]' "$OUT" | grep -cE '\[[UAR]' || true)
body="$summary package changes"
commits=$(sed -n '/^commits:/,$p' "$OUT" | sed 1d | head -3)
[[ -n $commits ]] && body+=$'\n'$commits

cat "$OUT"
if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
  ( act=$(notify-send -A open=Open "Switched to generation $n" "$body" 2>/dev/null || true)
    [[ $act == open ]] && exec ghostty --class=dev.prepko.whats-new -e less -R "$OUT" ) >/dev/null 2>&1 &
  disown
fi
