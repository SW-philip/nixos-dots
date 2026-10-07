#!/usr/bin/env bash
# ff-sync: one fastfetch row value for Syncthing, read from the sync-status snapshot.
# Colours arrive as env vars (FF_OK FF_WARN FF_BAD FF_DIM FF_RS) so the palette stays in Nix.
set -euo pipefail

SNAP=${FF_SYNC_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/sync-status.json}
NOW=${FF_NOW:-$(date +%s)}
STALE_S=${FF_STALE_S:-300}
OK=${FF_OK:-}; WARN=${FF_WARN:-}; BAD=${FF_BAD:-}; DIM=${FF_DIM:-}; RS=${FF_RS:-}

age() {   # seconds -> 45s | 12m | 3h | 2d
  local s=$1
  if (( s < 0 )); then s=0; fi
  if   (( s < 90 ));     then echo "${s}s"
  elif (( s < 5400 ));   then echo "$(( (s + 30) / 60 ))m"
  elif (( s < 129600 )); then echo "$(( (s + 1800) / 3600 ))h"
  else                        echo "$(( (s + 43200) / 86400 ))d"
  fi
}
dot() { printf '%s●%s' "$1" "$RS"; }

if [[ ! -r $SNAP ]]; then echo "${DIM}no snapshot yet${RS}"; exit 0; fi
jq -e '.level' "$SNAP" >/dev/null 2>&1 || { echo "${DIM}unreadable snapshot${RS}"; exit 0; }

gen=$(jq -r '.generated_at // 0' "$SNAP")
stale=""
if (( NOW - gen > STALE_S )); then stale=" ${DIM}(snapshot $(age $((NOW - gen))) old)${RS}"; fi

level=$(jq -r '.level' "$SNAP")
peer=$(jq -r '.peer.name // "peer"' "$SNAP")
summary=$(jq -r '[.reasons[]?, (if (.conflicts | length) > 0 then "\(.conflicts | length) conflict\(if (.conflicts | length) == 1 then "" else "s" end)" else empty end)] | join(", ")' "$SNAP")

case $level in
  ok)   echo "$(dot "$OK") ${OK}in sync${RS} · ${peer}${stale}" ;;
  wait) echo "$(dot "$DIM") ${DIM}${summary}${RS}${stale}" ;;
  warn) echo "$(dot "$WARN") ${WARN}${summary}${RS}${stale}" ;;
  *)    echo "$(dot "$BAD") ${BAD}${summary}${RS}${stale}" ;;
esac
