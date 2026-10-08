#!/usr/bin/env bash
# sync.sh: waybar feed for the Syncthing glyph, read from the sync-status snapshot.
# The snapshot already carries .level (ok|wait|warn|bad); this only renders it.
set -euo pipefail

SNAP=${SYNC_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/sync-status.json}
NOW=${SYNC_NOW:-$(date +%s)}
STALE_S=${SYNC_STALE_S:-300}
# shellcheck source=/dev/null
source "${SYNC_PALETTE:-$HOME/.config/waybar/palette.sh}" 2>/dev/null || true

age() {   # seconds -> 45s | 12m | 3h | 2d
  local s=$1
  if (( s < 0 )); then s=0; fi
  if   (( s < 90 ));     then echo "${s}s"
  elif (( s < 5400 ));   then echo "$(( (s + 30) / 60 ))m"
  elif (( s < 129600 )); then echo "$(( (s + 1800) / 3600 ))h"
  else                        echo "$(( (s + 43200) / 86400 ))d"
  fi
}

GLYPH='<span font_family="Hack Nerd Font Mono">󰓦</span>'
# a figure space holds the count slot's width with no ink: a near-transparent digit still casts the bar's text-shadow as a dark smudge
IDLE="$GLYPH&#8199;"
emit() { jq -nc --arg text "$1" --arg class "$2" --arg tooltip "$3" '{text:$text, class:$class, tooltip:$tooltip}'; }

if [[ ! -r $SNAP ]] || ! jq -e '.level' "$SNAP" >/dev/null 2>&1; then
  emit "$IDLE" nosnap "no snapshot yet"; exit 0
fi

gen=$(jq -r '.generated_at // 0' "$SNAP")
level=$(jq -r '.level' "$SNAP")
if (( NOW - gen > STALE_S )); then level=stale; fi
n=$(jq '(.conflicts // []) | length' "$SNAP")
text=$IDLE
if (( n > 0 )); then text="$GLYPH $n"; fi

tip=$(jq -r '
  def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
  ( [ "\(.peer.name | esc): \(if .peer.connected then "connected" else "offline" end)" ]
    + [ (.folders // [])[] | "\(.id | esc)  \(.state | esc)\(if .completion != null then "  \(.completion | floor)%" else "" end)" ]
    + [ (.reasons // [])[] | "! \(. | esc)" ]
    + [ (.conflicts // [])[:5][] | "conflict: \(.path | esc)" ] ) | join("\n")' "$SNAP")

since=$(jq -r '.unsynced_since // empty' "$SNAP")
if [[ -n $since ]]; then tip+=$'\n'"unsynced for $(age $((NOW - since)))"; fi

emit "$text" "$level" "$tip"
