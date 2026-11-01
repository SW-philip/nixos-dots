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
# Anything already listed or copied is skipped up front, and only the URLs
# new to the list are fetched.
# ErsatzTV tags a video with every folder in its path; the folder only airs
# once a channel or bumper pool in modules/ersatztv.nix queries one of them
# ($NOTE_TAG, default the folder's name; empty skips the check).
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
note_tag="${NOTE_TAG-$tag}"

list="$(grep -lE "^#\s*dest:\s*${dest}\s*$" "$LIST_DIR"/*.txt | head -1 || true)"
if [[ -z "$list" ]]; then
  list="$LIST_DIR/$tag.txt"
  # channels/halloween owns halloween.txt, so commercials/halloween gets
  # commercials-halloween.txt
  [[ -e "$list" ]] && list="$LIST_DIR/${dest//\//-}.txt"
  [[ -e "$list" ]] && { echo "$list already files elsewhere; pick another folder name" >&2; exit 1; }
  printf '# dest: %s\n' "$dest" > "$list"
  echo "new list: $list"
fi

# share links differ only by their ?si= tracking id; drop it so the same
# video or playlist pasted twice is caught
clean_url() {
  sed -E 's/([?&])si=[^&]*&?/\1/; s/[?&]$//' <<<"$1"
}

listed() {
  sed -E 's/#.*//' "$list" | while read -r url _; do
    [[ -n "$url" ]] && clean_url "$url"
  done | grep -qxF -- "$1"
}

# copy_in <file>: no-op when a file of that name is already there
copy_in() {
  local to
  to="$DEST_ROOT/$dest/$(basename "$1")"
  if [[ -e "$to" ]]; then
    echo "already there: $(basename "$1")"
  else
    cp -- "$1" "$to"
    echo "copied: $(basename "$1")"
  fi
}

new=()
for arg; do
  if [[ "$arg" =~ ^https?:// ]]; then
    url="$(clean_url "$arg")"
    if listed "$url"; then
      echo "already listed: $url"
      continue
    fi
    title="$(yt-dlp --flat-playlist -I 1 --print '%(playlist_title,title)s' "$url" 2>/dev/null || true)"
    printf '%s  # %s\n' "$url" "${title:-?}" >> "$list"
    echo "listed: ${title:-$url}"
    new+=("$url")
  elif [[ -f "$arg" || -d "$arg" ]]; then
    mkdir -p "$DEST_ROOT/$dest"
    if [[ -d "$arg" ]]; then
      while IFS= read -r -d '' f; do copy_in "$f"; done < <(find "$arg" -maxdepth 1 -type f -print0 | sort -z)
    else
      copy_in "$arg"
    fi
  else
    echo "not a URL or file: $arg" >&2
    exit 1
  fi
done

rc=0
((${#new[@]})) && { "$here/yt-curate.sh" "$(basename "$list" .txt)" "${new[@]}" || rc=$?; }

[[ -z "$note_tag" ]] || grep -qF "\"$note_tag\"" "$MODULE" \
  || echo "note: nothing in $MODULE queries \"$note_tag\" yet, so it won't air" >&2
exit "$rc"
