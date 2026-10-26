#!/usr/bin/env bash
# jellyfin-whisper: write Whisper .srt subtitles next to videos that have no text subtitle,
# newest first, until a deadline. Jellyfin picks up `<name>.<lang>.srt` on its next scan.
# Image-only (PGS) subs don't count as covered: Roku has to burn them in (the PGS freeze).
#   jellyfin-whisper [--dry-run] [FILE...]   no FILEs = scan $WHISPER_ROOTS
# Env: WHISPER_MODEL (ggml model), WHISPER_ROOTS (colon-separated), WHISPER_STATE (ledgers),
#      WHISPER_DEADLINE (seconds; no new file is started after it, default unlimited).
set -euo pipefail

: "${WHISPER_MODEL:?}" "${WHISPER_STATE:?}"
roots=${WHISPER_ROOTS:-/srv/Videos}
deadline=$(( $(date +%s) + ${WHISPER_DEADLINE:-0} ))
[[ ${WHISPER_DEADLINE:-0} -gt 0 ]] || deadline=0

dry=0
if [[ ${1:-} == --dry-run ]]; then dry=1; shift; fi

mkdir -p "$WHISPER_STATE"
# covered = has an embedded text sub (probed once); failed = whisper/ffmpeg gave nothing.
covered_ledger=$WHISPER_STATE/covered
failed_ledger=$WHISPER_STATE/failed
touch "$covered_ledger" "$failed_ledger"
declare -A skip=()
while IFS= read -r p; do skip[$p]=1; done < <(cat "$covered_ledger" "$failed_ledger")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

has_sidecar() {
  local f=$1 base dir s
  base=$(basename -- "${f%.*}")
  dir=$(dirname -- "$f")
  for s in "$dir"/*; do
    [[ $(basename -- "$s") == "$base".* ]] || continue
    case ${s,,} in *.srt|*.ass|*.ssa|*.vtt|*.sub) return 0 ;; esac
  done
  return 1
}

process() {
  local f=$1 probe audio tag out
  [[ -z ${skip[$f]:-} ]] || return 0
  has_sidecar "$f" && return 0

  probe=$(ffprobe -v error -of json -show_entries stream=index,codec_type,codec_name:stream_tags=language -- "$f") || {
    echo "probe failed: $f" >&2; echo "$f" >> "$failed_ledger"; return 0; }
  if jq -e '[.streams[] | select(.codec_type == "subtitle" and
        (.codec_name | IN("subrip","ass","ssa","mov_text","webvtt","text")))] | length > 0' <<<"$probe" >/dev/null; then
    echo "$f" >> "$covered_ledger"; return 0
  fi

  # English audio track if tagged, else the first one.
  audio=$(jq -r '[.streams[] | select(.codec_type == "audio")] as $a
    | (([$a[] | select(.tags.language == "eng")] + $a)[0].index) // empty' <<<"$probe")
  if [[ -z $audio ]]; then echo "$f" >> "$covered_ledger"; return 0; fi
  # The model is English-only; a foreign-language track is left alone.
  tag=$(jq -r --argjson i "$audio" '.streams[] | select(.index == $i) | .tags.language // "und"' <<<"$probe")
  case $tag in eng|en|und) ;; *) echo "$f" >> "$covered_ledger"; return 0 ;; esac

  if (( dry )); then echo "would transcribe (stream $audio): $f"; return 0; fi
  echo "transcribing: $f"

  if ! ffmpeg -nostdin -loglevel error -y -i "$f" -map "0:$audio" -ac 1 -ar 16000 -c:a pcm_s16le "$work/audio.wav" \
     || ! whisper-cli -m "$WHISPER_MODEL" -f "$work/audio.wav" -l en -sns -osrt -of "$work/out" > "$work/log" 2>&1; then
    echo "failed: $f" >&2; tail -5 "$work/log" >&2 2>/dev/null || true
    echo "$f" >> "$failed_ledger"; return 0
  fi

  if ! grep -q -- '-->' "$work/out.srt"; then
    echo "no speech: $f"; echo "$f" >> "$failed_ledger"; return 0
  fi
  out="${f%.*}.en.srt"
  cp -- "$work/out.srt" "$out.part" && mv -- "$out.part" "$out"
  echo "wrote $out"
}

if [[ $# -gt 0 ]]; then
  for f in "$@"; do process "$f"; done
  exit 0
fi

IFS=: read -ra root_list <<<"$roots"
while IFS=$'\t' read -r _ f; do
  if (( deadline && $(date +%s) >= deadline )); then echo "deadline reached"; break; fi
  process "$f"
done < <(find "${root_list[@]}" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \
           -o -iname '*.avi' -o -iname '*.mov' -o -iname '*.webm' -o -iname '*.ts' \) \
           -not -path '*/_broken/*' -printf '%T@\t%p\n' 2>/dev/null | sort -rn)
