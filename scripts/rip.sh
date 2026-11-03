#!/usr/bin/env bash
# rip.sh — download audio only (best available, no conversion)
# Usage: rip.sh [--n filename] <URL> [URL2 ...]

set -euo pipefail

OUTDIR="/srv/Audios/rip"
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
  echo "Usage: rip.sh [--n filename] <URL> [URL2 ...]"
  exit 1
fi

if [[ -n "$NAME" ]]; then
  OUTTEMPLATE="$OUTDIR/$NAME.%(ext)s"
else
  OUTTEMPLATE="$OUTDIR/%(uploader)s - %(title)s.%(ext)s"
fi

yt-dlp \
  --format "bestaudio" \
  --output "$OUTTEMPLATE" \
  --embed-thumbnail \
  --embed-metadata \
  --no-playlist \
  "${URLS[@]}"
