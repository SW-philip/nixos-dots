#!/usr/bin/env bash
# Feed for the eww `spark` listener: one {re,rep} per pill slot, which the `spk`
# widget (eww.yuck) feeds to replace() to colour one random letter of a label.
# Reshuffles every REFRESH s and as soon as the theme palette moves.
set -euo pipefail

pal="${SPARKLE_PALETTE:-$HOME/.config/waybar/palette.sh}"
slots="${SPARKLE_SLOTS:-40}"
refresh="${SPARKLE_REFRESH:-300}"

# S = one "not a letter" atom; an escaped entity counts as one so its a/m/p/l/t/g
# are never picked. The match is k skipped letters plus the letter to colour,
# falling back to k=0 when the text has fewer.
S='(?:&(?:amp|lt|gt);|[^A-Za-z])'

emit() {
  local -a accents=()
  local name
  # shellcheck disable=SC1090
  . "$pal"
  for name in ROOT FIFTH SOTTO SEVENTH PIANO; do
    [[ -n "${!name:-}" ]] && accents+=("${!name}")
  done
  (( ${#accents[@]} )) || return 0
  for ((i = 0; i < slots; i++)); do
    printf '%s %s\n' "$((RANDOM % 6))" "${accents[RANDOM % ${#accents[@]}]}"
  done | jq -Rnc --arg s "$S" '[inputs | split(" ") as [$k, $c] | {
      re: "^(?:(?:\($s)*[A-Za-z]){\($k)}\($s)*|\($s)*)[A-Za-z]", c: $c }]'
}

mtime() { stat -c %Y "$pal" 2>/dev/null || echo 0; }

while :; do
  seen=$(mtime)
  emit || true
  for ((t = 0; t < refresh; t += 3)); do
    sleep 3
    [[ "$(mtime)" == "$seen" ]] || break
  done
done
