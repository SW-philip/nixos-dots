#!/usr/bin/env bash
# subs-fill.sh [dir]... — download English subtitles for every video that has
# none (embedded or external), saved as <video>.en.srt beside it. Defaults to
# all four Jellyfin libraries. Download only: nothing is generated.
#
# Only providers that work without an account. Min scores (percent of a
# perfect hash match) mean: episodes match series+season+episode (495/809),
# movies title+year (161/323) — below that it's guessing.
set -euo pipefail

command -v subliminal >/dev/null ||
  exec nix shell nixpkgs#python3Packages.subliminal -c "$0" "$@"

V=/srv/Videos
roots=("$@")
((${#roots[@]})) || roots=(
  "$V/mom_and_dad/television" "$V/mom_and_dad/movies"
  "$V/kid_and_henry/television" "$V/kid_and_henry/movies"
)

state="$HOME/.local/state/subs-fill"
mkdir -p "$state"
log="$state/$(date +%Y%m%d-%H%M%S).log"

# has_subs <video>: an external subtitle beside it, or an embedded track
has_subs() {
  local stem="${1%.*}" s
  for s in "$stem".*; do
    case "${s,,}" in *.srt | *.ass | *.ssa | *.vtt | *.sub | *.sup) return 0 ;; esac
  done
  [[ -n "$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$1" </dev/null)" ]]
}

missing=()
for root in "${roots[@]}"; do
  while IFS= read -r -d '' f; do
    has_subs "$f" || missing+=("$f")
  done < <(find "$root" \( -name '.*' -o -iname extras -o -iname featurettes \) -prune -o \
    -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.m4v' \) -print0 | sort -z)
done
echo "${#missing[@]} videos without subtitles" | tee -a "$log"

got=0 i=0
for f in "${missing[@]}"; do
  i=$((i + 1))
  case "$f" in */movies/*) min=50 ;; *) min=60 ;; esac
  # one stalled provider used to hang the whole run
  out="$(timeout 180 subliminal download -l en -W -m "$min" \
    -p podnapisi -p gestdown -p tvsubtitles -p bsplayer "$f" </dev/null 2>&1)" || true
  if [[ "$out" == *"Downloaded 1 subtitle"* ]]; then
    got=$((got + 1))
    echo "[$i/${#missing[@]}] got  ${f#"$V"/}" | tee -a "$log"
  else
    echo "[$i/${#missing[@]}] none ${f#"$V"/}" | tee -a "$log"
  fi
done
echo "$got of ${#missing[@]} found · log: $log" | tee -a "$log"
