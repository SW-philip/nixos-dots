#!/usr/bin/env bash
# wallpaper-follow: keep the `card` awww daemon (the workspace-tier wallpaper) on the blob layout
# for each output's focused workspace. Layout N is <stem>-pos<N>.png next to the wallpaper that
# drmis points ~/.local/state/wallpaper at (N = (workspace idx - 1) % 5, 0 = the plain file).
set -euo pipefail

POINTER=${WALLPAPER_POINTER:-$HOME/.local/state/wallpaper}
VARIANTS=5
FADE=${WALLPAPER_FADE_S:-0.25}
declare -A last

pick() { # idx -> image path
  local base v=$(( ($1 - 1) % VARIANTS )) alt
  base=$(<"$POINTER")
  alt="${base%.png}-pos$v.png"
  if (( v )) && [[ -e $alt ]]; then echo "$alt"; else echo "$base"; fi
}

sync_all() {
  local out idx img
  while read -r out idx; do
    img=$(pick "$idx")
    [[ ${last[$out]:-} == "$img" ]] && continue
    last[$out]=$img
    awww img -n card -o "$out" "$img" --transition-type fade --transition-duration "$FADE"
  done < <(niri msg --json workspaces | jq -r '.[] | select(.is_active) | "\(.output) \(.idx)"')
}

until awww query -n card >/dev/null 2>&1; do sleep 0.3; done
sync_all
niri msg --json event-stream | jq --unbuffered -r 'select(.WorkspaceActivated) | .WorkspaceActivated.id' \
  | while read -r _; do sync_all; done
