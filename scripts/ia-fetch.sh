#!/usr/bin/env bash
# ia-fetch.sh <outdir> <archive.org identifier>... — download the biggest
# original video file of each item to <outdir>/<identifier>.<ext>. Already
# downloaded items are skipped; feed the dir to split-commercials.sh after.
#
#   ia-fetch.sh /srv/Videos/mom_and_dad/trailers/vhs \
#     VHSPreviewsFromConAirTouchstoneHomeVideoAust1998
set -euo pipefail

out="${1:?usage: ia-fetch.sh <outdir> <identifier>...}"
shift
mkdir -p "$out"

for id in "$@"; do
  have=("$out/$id".*)
  if [[ -e "${have[0]}" && "${have[0]}" != *.partial ]]; then
    echo "skip (have): $id"
    continue
  fi
  # originals over derivatives (the .ia.mp4 re-encodes), then the biggest
  name="$(curl -fsS "https://archive.org/metadata/$id" | jq -r '
    [.files[] | select(.name | test("\\.(mp4|mkv|mpe?g|avi|webm|mov|m4v)$"; "i"))]
    | sort_by((.source != "original"), -((.size // "0") | tonumber))
    | first.name // empty')"
  [[ -n "$name" ]] || { echo "no video: $id" >&2; continue; }
  # .partial so an interrupted download isn't skipped as done next run
  curl -fL --retry 3 -sS -o "$out/$id.${name##*.}.partial" \
    "https://archive.org/download/$id/$(jq -rn --arg n "$name" '$n | split("/") | map(@uri) | join("/")')"
  mv "$out/$id.${name##*.}.partial" "$out/$id.${name##*.}"
  echo "got: $id ($name)"
done
