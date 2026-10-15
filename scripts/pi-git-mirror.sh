#!/usr/bin/env bash
# pi-git-mirror: keep bare mirrors of the pi's git hub (every ref, incl. refs/autosave/*) on this host.
# The pi's microSD is the only home of the claude-shared repo and the autosave refs; this is the copy off it.
set -euo pipefail

DEST=${PI_MIRROR_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/pi-git-mirror}
BASE=${PI_MIRROR_BASE:-ssh://git@pi/srv/git}
REPOS=${PI_MIRROR_REPOS:-"nixos claude-shared"}

mkdir -p "$DEST"
fail=0
for r in $REPOS; do
  dir="$DEST/$r.git"
  if [[ -d "$dir" ]]; then
    git -C "$dir" remote update --prune || { echo "pi-git-mirror: $r: fetch failed" >&2; fail=1; }
  else
    git clone -q --mirror "$BASE/$r.git" "$dir" || { echo "pi-git-mirror: $r: clone failed" >&2; fail=1; }
  fi
done
exit "$fail"
