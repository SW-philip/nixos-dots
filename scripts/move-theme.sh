#!/usr/bin/env bash
# Move a theme dir to another family with plain mv: the gitignored wallpaper
# PNGs must travel too, which git mv alone would leave behind. Idempotent; if
# the destination exists (a host that just pulled the move) only leftovers move.
set -euo pipefail
slug=${1:?usage: move-theme.sh <slug> <family>}
family=${2:?usage: move-theme.sh <slug> <family>}
root=${THEMES_ROOT:-$(git rev-parse --show-toplevel)/themes}
dest=$root/$family/$slug
mkdir -p "$root/$family"
for src in "$root"/*/"$slug"; do
  [[ -d $src && $src != "$dest" ]] || continue
  if [[ ! -e $dest ]]; then
    mv "$src" "$dest"
  else
    (cd "$src" && find . -type f -print0 | while IFS= read -r -d '' f; do
        mkdir -p "$dest/$(dirname "$f")"; mv -n "$f" "$dest/$f"; done)
    find "$src" -depth -type d -empty -delete
  fi
done
echo "$slug -> $family"
