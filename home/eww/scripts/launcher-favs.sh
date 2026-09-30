#!/usr/bin/env bash
# Tablet launcher favourites as rows of four tiles: [[{icon,label,cmd,accent},...],...] (accent = column 0-3).
# Prints [] for a missing, unreadable, invalid or empty file so the grid just renders empty.
favs="${LAUNCHER_FAVS:-$HOME/.local/share/eww/launcher-favs.json}"
if [[ -r "$favs" ]] && rows=$(jq -c '[range(0; length; 4) as $i | .[$i:$i+4] | to_entries | map(.value + {accent: .key})]' "$favs" 2>/dev/null); then
  printf '%s\n' "$rows"
else
  printf '%s\n' '[]'
fi
