#!/usr/bin/env bash
# Move every theme from the old families (Custom, Rose-Pine) into Dark/.
# Plain mv, not git mv: wallpaper PNGs are gitignored and must travel too.
# Idempotent. If Dark/<slug> already exists (a host that just pulled the move
# commit: git recreated the tracked files and left the ignored PNGs behind) it
# moves only the leftovers and never overwrites.
set -euo pipefail

root=${THEMES_ROOT:-$(git rev-parse --show-toplevel)/themes}
dest=$root/Dark
mkdir -p "$dest"

for fam in Custom Rose-Pine; do
  [[ -d $root/$fam ]] || continue
  for src in "$root/$fam"/*/; do
    src=${src%/}
    slug=$(basename "$src")
    if [[ ! -e $dest/$slug ]]; then
      mv "$src" "$dest/$slug"
    else
      (cd "$src" && find . -type f -print0 |
        while IFS= read -r -d '' f; do
          mkdir -p "$dest/$slug/$(dirname "$f")"
          mv -n "$f" "$dest/$slug/$f"
        done)
      find "$src" -depth -type d -empty -delete
    fi
  done
  find "$root/$fam" -depth -type d -empty -delete 2>/dev/null || true
done

echo "themes: $(find "$dest" -mindepth 1 -maxdepth 1 -type d | wc -l) in Dark/"
