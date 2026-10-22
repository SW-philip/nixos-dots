#!/usr/bin/env bash
# yt-curate.sh <collection> — download a hand-picked list of videos into a
# Jellyfin library folder. The list is plain text, one URL per line ('#'
# comments and blank lines ignored), at $LIST_DIR/<collection>.txt.
# Put "# dest: bumpers/foo" in the list to file it under $DEST_ROOT/bumpers/foo
# (default: the collection name).
# "# maxheight: 720" caps the resolution (default 1080).
# A line may carry a cut — `URL 126-266 # label` (seconds) — to keep only
# that span of a longer video; it is saved as <label>.mkv.
#
#   yt-curate.sh clem-brain-breaks
#   yt-curate.sh hen-music-videos --dry-run
#
# Only URLs on the list are fetched (--no-playlist unless the line is itself
# a playlist you chose). Whole videos use a per-collection download archive;
# cuts skip when <label>.mkv already exists. A failed line is reported and
# skipped; rerun to retry just those (exit 1 if any failed).
set -euo pipefail

LIST_DIR="${LIST_DIR:-$HOME/nixos/assets/yt-curate}"
DEST_ROOT="${DEST_ROOT:-/srv/Videos/kid_and_henry}"

collection="${1:?usage: yt-curate.sh <collection> [--dry-run]}"
dry="${2:-}"
list="$LIST_DIR/$collection.txt"
# a "# dest: bumpers/monster-jam" line in the list picks the subfolder
sub="$(sed -nE 's/^#\s*dest:\s*(\S+).*/\1/p' "$list" | head -1)"
dest="$DEST_ROOT/${sub:-$collection}"
# "# maxheight: 720" caps resolution for long files (default 1080)
maxh="$(sed -nE 's/^#\s*maxheight:\s*([0-9]+).*/\1/p' "$list" | head -1)"
maxh="${maxh:-1080}"

[[ -f "$list" ]] || { echo "no list: $list" >&2; exit 1; }
mkdir -p "$dest"

common=(
  -f "bv*[height<=$maxh]+ba/b[height<=$maxh]"
  --merge-output-format mkv
  --embed-metadata --embed-thumbnail
  --no-overwrites
  # a few dozen unpaced fetches in a row trip YouTube's "confirm you're not
  # a bot" block on the home IP for hours
  --sleep-requests 1 --sleep-interval 5 --max-sleep-interval 15
)
[[ "$dry" == "--dry-run" ]] && common+=(--simulate --print "%(uploader)s - %(title)s")

fail=0
while IFS= read -r line; do
  label="${line#*#}"; [[ "$line" == *'#'* ]] || label=""
  read -r url span _ <<<"${line%%#*}"
  [[ -n "$url" ]] || continue
  label="$(sed -E 's/^\s+|\s+$//g' <<<"$label")"

  if [[ "${span:-}" =~ ^[0-9]+-[0-9]+$ ]]; then
    [[ -n "$label" ]] || { echo "cut needs a # label: $line" >&2; exit 1; }
    out="$dest/${label//\//-}.mkv"
    [[ -e "$out" ]] && continue
    yt-dlp "${common[@]}" --no-playlist --force-keyframes-at-cuts \
      --download-sections "*${span}" -o "${out%.mkv}.%(ext)s" "$url" \
      || { echo "failed: $label" >&2; fail=1; }
  else
    # ErsatzTV titles Other Videos by filename, ignoring the embedded tag, so
    # the name is the guide title; .archive (not the name) tracks video ids.
    yt-dlp "${common[@]}" --download-archive "$dest/.archive" \
      -o "$dest/%(title)s.%(ext)s" "$url" \
      || { echo "failed: $url" >&2; fail=1; }
  fi
done < "$list"

# trim "| Read Aloud Kids Book | …" clutter from the new names (guide titles)
[[ "$dry" == "--dry-run" ]] \
  || python3 -I "$(dirname "$(readlink -f "$0")")/tidy-titles.py" "$dest" --apply \
  || fail=1
exit "$fail"
