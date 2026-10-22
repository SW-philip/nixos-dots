#!/usr/bin/env bash
# tv-add <folder> <url|file>... — put videos where the ErsatzTV channels
# pick them up. <folder> is relative to kid_and_henry, e.g.
# channels/crafts or bumpers/kid-shorts.
#
#   tv-add channels/crafts 'https://www.youtube.com/playlist?list=…'
#   tv-add bumpers/kid-shorts ~/Videos/edits/   # every file in the folder
#
# URLs (single videos or whole playlists) are appended to the yt-curate list
# that files into <folder> (created if none does) and fetched by
# yt-curate.sh, so rerunning `yt-curate.sh <list>` later picks up anything
# new in a playlist. Local files (or a folder's files) are copied in as-is.
# ErsatzTV tags a video with every folder in its path; the folder only airs
# once a channel or bumper pool in modules/ersatztv.nix queries one of them.
set -euo pipefail

LIST_DIR="${LIST_DIR:-$HOME/nixos/assets/yt-curate}"
DEST_ROOT="${DEST_ROOT:-/srv/Videos/kid_and_henry}"
MODULE="${MODULE:-$HOME/nixos/modules/ersatztv.nix}"
here="$(dirname "$(readlink -f "$0")")"

usage="usage: tv-add <folder> <url|file>..."
dest="${1:?$usage}"; shift
(($#)) || { echo "$usage" >&2; exit 1; }
dest="${dest%/}"
tag="${dest##*/}"

list="$(grep -lE "^#\s*dest:\s*${dest}\s*$" "$LIST_DIR"/*.txt | head -1 || true)"
if [[ -z "$list" ]]; then
  list="$LIST_DIR/$tag.txt"
  [[ -e "$list" ]] && { echo "$list already files elsewhere; pick another folder name" >&2; exit 1; }
  printf '# dest: %s\n' "$dest" > "$list"
  echo "new list: $list"
fi

fetch=0
for arg; do
  if [[ "$arg" =~ ^https?:// ]]; then
    if grep -qF -- "$arg" "$list"; then
      echo "already listed: $arg"
    else
      title="$(yt-dlp --flat-playlist -I 1 --print '%(playlist_title,title)s' "$arg" 2>/dev/null || true)"
      printf '%s  # %s\n' "$arg" "${title:-?}" >> "$list"
      echo "listed: ${title:-$arg}"
    fi
    fetch=1
  elif [[ -f "$arg" || -d "$arg" ]]; then
    mkdir -p "$DEST_ROOT/$dest"
    if [[ -d "$arg" ]]; then
      find "$arg" -maxdepth 1 -type f -exec cp --update=none -t "$DEST_ROOT/$dest/" -- {} +
    else
      cp --update=none -- "$arg" "$DEST_ROOT/$dest/"
    fi
    echo "copied: ${arg%/}"
  else
    echo "not a URL or file: $arg" >&2
    exit 1
  fi
done

rc=0
((fetch)) && { "$here/yt-curate.sh" "$(basename "$list" .txt)" || rc=$?; }

grep -qF "\"$tag\"" "$MODULE" \
  || echo "note: nothing in $MODULE queries \"$tag\" yet, so it won't air" >&2
exit "$rc"
