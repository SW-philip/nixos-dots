#!/usr/bin/env bash
# split-commercials.sh <outdir> <video|dir>... — cut commercial-break
# compilations into one file per spot, at the black frames broadcasters put
# between ads. Spots land in <outdir>/<source name>/NNN.mkv. Segments shorter
# than MIN or longer than MAX seconds are skipped (slates, joined programmes).
# Already-split sources (their folder exists) are skipped; delete it to redo.
#
#   split-commercials.sh /srv/Videos/kid_and_henry/commercials-split/spots-kids \
#     /srv/Videos/kid_and_henry/commercials/nick-cn
set -euo pipefail

MIN="${MIN:-4}"
MAX="${MAX:-180}"

out="${1:?usage: split-commercials.sh <outdir> <video|dir>...}"
shift
mkdir -p "$out"

# cut <src> <start> <len> <out> <input|output>: where -ss goes decides the seek
cut() {
  local seek=(-ss "$2") pre=() post=()
  [[ "$5" == input ]] && pre=("${seek[@]}") || post=("${seek[@]}")
  # re-encode: stream copy can only cut on keyframes, which bleeds ads together
  ffmpeg -hide_banner -loglevel error -nostdin -y "${pre[@]}" -i "$1" "${post[@]}" -t "$3" \
    -map 0:v:0 -map '0:a:0?' -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
    -c:a aac -b:a 160k "$4"
}

# long_enough <file> <len>: within a second of the intended length
long_enough() {
  local got
  got="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" </dev/null 2>/dev/null)"
  awk -v g="${got:-0}" -v l="$2" 'BEGIN { exit !(g >= l - 1) }'
}

split() {
  local src="$1" name dir dur cuts=() i=0 n=0 kept=0 start end len spot
  name="$(basename "${src%.*}")"
  dir="$out/${name//[^A-Za-z0-9._-]/_}"
  [[ -d "$dir" ]] && { echo "skip (done): $name"; return; }

  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src" </dev/null)"
  # midpoint of each black gap is the cut
  mapfile -t cuts < <(
    ffmpeg -hide_banner -nostats -nostdin -i "$src" -vf "blackdetect=d=0.08:pix_th=0.12" -an -f null - 2>&1 |
      grep -oE 'black_start:[0-9.]+ black_end:[0-9.]+' |
      awk -F'[: ]' '{ printf "%.3f\n", ($2 + $4) / 2 }'
  )
  cuts=(0 "${cuts[@]}" "$dur")

  # work in .partial so an interrupted source isn't skipped as done next run
  rm -rf "$dir.partial"
  mkdir -p "$dir.partial"
  for ((i = 0; i < ${#cuts[@]} - 1; i++)); do
    start="${cuts[i]}" end="${cuts[i + 1]}"
    len="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e - s }')"
    awk -v l="$len" -v lo="$MIN" -v hi="$MAX" 'BEGIN { exit !(l >= lo && l <= hi) }' || continue
    n=$((n + 1))
    spot="$dir.partial/$(printf '%03d' "$n").mkv"
    cut "$src" "$start" "$len" "$spot" input
    # a damaged seek index makes input seeking land short or empty past some
    # point; decoding up to the cut is slow but always lands
    if ! long_enough "$spot" "$len"; then
      cut "$src" "$start" "$len" "$spot" output
      long_enough "$spot" "$len" || { echo "short spot $n: $name" >&2; rm -f "$spot"; continue; }
    fi
    kept=$((kept + 1))
  done
  mv "$dir.partial" "$dir"
  echo "$kept spots: $name"
}

for arg in "$@"; do
  if [[ -d "$arg" ]]; then
    while IFS= read -r -d '' f; do split "$f"; done < <(
      find "$arg" -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mpg' -o -iname '*.webm' \) -print0 | sort -z
    )
  else
    split "$arg"
  fi
done
