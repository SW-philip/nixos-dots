#!/usr/bin/env bash
# ff-fleet <host>: one fastfetch row value for a fleet host, read from the fleet-status snapshot.
# Colours arrive as env vars (FF_OK FF_WARN FF_BAD FF_DIM FF_RS) so the palette stays in Nix.
set -euo pipefail

SNAP=${FF_FLEET_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/fleet-status.json}
NOW=${FF_NOW:-$(date +%s)}
STALE_S=${FF_STALE_S:-300}
OK=${FF_OK:-}; WARN=${FF_WARN:-}; BAD=${FF_BAD:-}; DIM=${FF_DIM:-}; RS=${FF_RS:-}
host=${1:?usage: ff-fleet <host>}

age() {   # seconds -> 45s | 12m | 3h | 2d
  local s=$1
  (( s < 0 )) && s=0
  if   (( s < 90 ));     then echo "${s}s"
  elif (( s < 5400 ));   then echo "$(( (s + 30) / 60 ))m"
  elif (( s < 129600 )); then echo "$(( (s + 1800) / 3600 ))h"
  else                        echo "$(( (s + 43200) / 86400 ))d"
  fi
}
dot() { printf '%s●%s' "$1" "$RS"; }

if [[ ! -r "$SNAP" ]]; then echo "${DIM}no snapshot yet${RS}"; exit 0; fi
jq -e '.hosts' "$SNAP" >/dev/null 2>&1 || { echo "${DIM}unreadable snapshot${RS}"; exit 0; }
row=$(jq -c --arg h "$host" '.hosts[]? | select(.host == $h)' "$SNAP" 2>/dev/null || true)
if [[ -z "$row" ]]; then echo "${DIM}not in snapshot${RS}"; exit 0; fi

gen=$(jq -r '.generated_at // 0' "$SNAP")
stale=""
if (( NOW - gen > STALE_S )); then stale=" ${DIM}(snapshot $(age $((NOW - gen))) old)${RS}"; fi

up=$(jq -r '.up' <<<"$row");          ssh_ok=$(jq -r '.ssh_ok' <<<"$row")
rev=$(jq -r '.rev // ""' <<<"$row");  dirty=$(jq -r '.dirty // false' <<<"$row")
drift=$(jq -r '.drift // "null"' <<<"$row"); ahead=$(jq -r '.ahead // 0' <<<"$row")
built=$(jq -r '.built_age_s // "null"' <<<"$row")
when=""; if [[ "$built" != null ]]; then when=" · $(age "$built")"; fi
short=${rev:0:8}

if [[ "$up" != true ]]; then
  echo "$(dot "$BAD") ${BAD}down${RS}${stale}"
elif [[ "$ssh_ok" != true ]]; then
  echo "$(dot "$WARN") ${WARN}up, ssh not answering${RS}${stale}"
elif [[ -z "$rev" ]]; then
  echo "$(dot "$WARN") ${WARN}unstamped${RS}${when}${stale}"
elif [[ "$drift" == null ]]; then
  echo "$(dot "$WARN") ${short} ${WARN}unknown commit${RS}${when}${stale}"
else
  color=$OK; notes=()
  if (( drift > 0 && ahead > 0 )); then
    color=$BAD; notes+=("diverged")
  else
    if (( drift > 0 )); then color=$WARN; notes+=("$drift behind"); fi
    if (( ahead > 0 )); then color=$WARN; notes+=("$ahead ahead"); fi
  fi
  if [[ "$dirty" == true ]]; then
    if [[ "$color" == "$OK" ]]; then color=$WARN; fi
    notes+=("dirty")
  fi
  label="in step"
  if (( ${#notes[@]} > 0 )); then label=$(printf '%s, ' "${notes[@]}"); label=${label%, }; fi
  echo "$(dot "$color") ${short} ${color}${label}${RS}${when}${stale}"
fi
