#!/usr/bin/env bash
# tape.sh — download video only, no audio (mkv)
# Usage: tape.sh [--n filename] <URL> [URL2 ...]
# Optional quality override: QUALITY=1080 tape.sh <URL>

set -euo pipefail

OUTDIR="/srv/Videos/tape"
mkdir -p "$OUTDIR"

NAME=""
URLS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --n) NAME="$2"; shift 2 ;;
    *)   URLS+=("$1"); shift ;;
  esac
done

if [[ ${#URLS[@]} -eq 0 ]]; then
  echo "Usage: tape.sh [--n filename] <URL> [URL2 ...]"
  echo "  Optional: QUALITY=1080 tape.sh <URL>  (e.g. 720, 1080, 1440, 2160)"
  exit 1
fi

if [[ -n "${QUALITY:-}" ]]; then
  FORMAT="bestvideo[height<=${QUALITY}]"
else
  FORMAT="bestvideo"
fi

if [[ -n "$NAME" ]]; then
  OUTTEMPLATE="$OUTDIR/$NAME.%(ext)s"
else
  OUTTEMPLATE="$OUTDIR/%(uploader)s - %(title)s.%(ext)s"
fi

yt-dlp \
  --format "$FORMAT" \
  --merge-output-format mkv \
  --output "$OUTTEMPLATE" \
  --embed-metadata \
  --no-playlist \
  "${URLS[@]}"
