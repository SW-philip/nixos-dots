#!/usr/bin/env bash
# burn.sh — download video + audio (best quality, mp4, max speed)
# Usage: burn.sh [--n filename] [--afl] <URL> [URL2 ...]
# Optional quality cap: QUALITY=1080 burn.sh <URL>

set -euo pipefail

OUTDIR="/srv/Videos/burn"
mkdir -p "$OUTDIR"

NAME=""
AFL=0
URLS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --n)   NAME="$2"; shift 2 ;;
    --afl) AFL=1; shift ;;
    *)     URLS+=("$1"); shift ;;
  esac
done

if [[ ${#URLS[@]} -eq 0 ]]; then
  echo "Usage: burn.sh [--n filename] [--afl] <URL> [URL2 ...]"
  echo "  Optional: QUALITY=1080 burn.sh <URL>  (e.g. 720, 1080, 1440, 2160)"
  exit 1
fi

to_camel() {
  local input="${1,,}"
  local result="" first=1
  for word in $input; do
    if [[ $first -eq 1 ]]; then result="$word"; first=0
    else result+="${word^}"; fi
  done
  echo "$result"
}

afl_date() {
  local d="$1"
  local months=("" January February March April May June July August September October November December)
  local y="${d:0:4}" m="${d:5:2}" day="${d:8:2}"
  echo "${day#0}${months[10#$m]}${y:2:2}"
}

if [[ $AFL -eq 1 ]]; then
  read -rp "Home team: " AFL_HOME
  read -rp "Away team: " AFL_AWAY
  read -rp "Date (YYYY-MM-DD) [$(date +%Y-%m-%d)]: " AFL_DATE
  AFL_DATE="${AFL_DATE:-$(date +%Y-%m-%d)}"
  NAME="$(to_camel "$AFL_HOME")_$(to_camel "$AFL_AWAY")_$(afl_date "$AFL_DATE")"
elif [[ -z "$NAME" ]]; then
  read -rp "Title (leave blank to use auto-name): " NAME
fi

if [[ -n "${QUALITY:-}" ]]; then
  FORMAT="bestvideo[height<=${QUALITY}]+bestaudio/best[height<=${QUALITY}]"
else
  FORMAT="bestvideo+bestaudio/best"
fi

if [[ -n "$NAME" ]]; then
  OUTTEMPLATE="$OUTDIR/$NAME.mp4"
else
  OUTTEMPLATE="$OUTDIR/%(uploader)s - %(title)s.%(ext)s"
fi

yt-dlp \
  --format "$FORMAT" \
  --merge-output-format mp4 \
  --output "$OUTTEMPLATE" \
  --downloader ffmpeg \
  --hls-use-mpegts \
  --newline \
  --concurrent-fragments 8 \
  --retries 10 \
  --fragment-retries 10 \
  --embed-thumbnail \
  --embed-metadata \
  --no-playlist \
  "${URLS[@]}"
