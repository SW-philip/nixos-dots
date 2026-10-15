#!/usr/bin/env bash
# Tablet launcher favourites as rows of four tiles (three in portrait): [[{icon,label,cmd,accent},...],...] (accent = column).
# Prints [] for a missing, unreadable, invalid or empty file so the grid just renders empty.
favs="${LAUNCHER_FAVS:-$HOME/.local/share/eww/launcher-favs.json}"

portrait() {
  [[ -n "${LAUNCHER_PORTRAIT:-}" ]] && { [[ "$LAUNCHER_PORTRAIT" = 1 ]]; return; }
  niri msg --json outputs 2>/dev/null \
    | jq -e '."eDP-1".logical.transform | test("(90|270)$")' >/dev/null 2>&1
}

cols=4
portrait && cols=3

if [[ -r "$favs" ]] && rows=$(jq -c --argjson n "$cols" '[range(0; length; $n) as $i | .[$i:$i+$n] | to_entries | map(.value + {accent: .key})]' "$favs" 2>/dev/null); then
  printf '%s\n' "$rows"
else
  printf '%s\n' '[]'
fi
