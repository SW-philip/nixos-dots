#!/usr/bin/env bash
# fleet.sh: waybar feed for the fleet glyph, read from the fleet-status snapshot.
# Per-host state mirrors scripts/ff-fleet.sh; test_fleet.sh checks the two agree.
#   fleet.sh            one JSON line: text, class, tooltip
#   fleet.sh --states   "<host>\t<ok|warn|bad>" per host (test hook)
set -euo pipefail

SNAP=${FLEET_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/fleet-status.json}
NOW=${FLEET_NOW:-$(date +%s)}
STALE_S=${FLEET_STALE_S:-300}
# shellcheck source=/dev/null
source "${FLEET_PALETTE:-$HOME/.config/waybar/palette.sh}" 2>/dev/null || true
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/waybar-lib.sh"

OK=${FIFTH:-}; WARN=${FERMATA:-}; BAD=${FORTE:-}; DIM=${REST:-}; ACCENT=${ROOT:-}
GLYPH='<span font_family="Hack Nerd Font Mono">󰒋</span>'
# the count slot is always rendered (an invisible 0 when nothing needs attention) so the bar never jitters
IDLE="$GLYPH <span alpha=\"0\">0</span>"

col() { # colour text — a bare string when the palette is unavailable
  if [[ -n "$1" ]]; then printf "<span foreground='%s'>%s</span>" "$1" "$2"; else printf '%s' "$2"; fi
}
colour_of() { case $1 in ok) echo "$OK" ;; warn) echo "$WARN" ;; bad) echo "$BAD" ;; *) echo "$DIM" ;; esac; }
age() {   # seconds -> 45s | 12m | 3h | 2d
  local s=$1
  if (( s < 0 )); then s=0; fi
  if   (( s < 90 ));     then echo "${s}s"
  elif (( s < 5400 ));   then echo "$(( (s + 30) / 60 ))m"
  elif (( s < 129600 )); then echo "$(( (s + 1800) / 3600 ))h"
  else                        echo "$(( (s + 43200) / 86400 ))d"
  fi
}
emit() { jq -nc --arg text "$1" --arg class "$2" --arg tooltip "$3" '{text:$text, class:$class, tooltip:$tooltip}'; }

if [[ ! -r "$SNAP" ]]; then
  [[ ${1:-} == --states ]] && exit 0
  emit "$IDLE" nosnap "$(col "$DIM" "no snapshot yet")"; exit 0
fi
if ! jq -e '.hosts' "$SNAP" >/dev/null 2>&1; then
  [[ ${1:-} == --states ]] && exit 0
  emit "$IDLE" nosnap "$(col "$DIM" "unreadable snapshot")"; exit 0
fi

# classify <row-json> -> cls label short when
classify() {
  local row=$1 up ssh_ok rev dirty drift ahead built notes=()
  up=$(jq -r '.up' <<<"$row"); ssh_ok=$(jq -r '.ssh_ok' <<<"$row")
  rev=$(jq -r '.rev // ""' <<<"$row"); dirty=$(jq -r '.dirty // false' <<<"$row")
  drift=$(jq -r '.drift // "null"' <<<"$row"); ahead=$(jq -r '.ahead // 0' <<<"$row")
  built=$(jq -r '.built_age_s // "null"' <<<"$row")
  short=${rev:0:8}; when=""
  if [[ "$built" != null ]]; then when=$(age "$built"); fi
  if [[ "$up" != true ]]; then cls=bad; label=down
  elif [[ "$ssh_ok" != true ]]; then cls=warn; label="ssh not answering"
  elif [[ -z "$rev" ]]; then cls=warn; label=unstamped
  elif [[ "$drift" == null ]]; then cls=warn; label="unknown commit"
  else
    cls=ok
    if (( drift > 0 && ahead > 0 )); then
      cls=bad; notes+=("diverged")
    else
      if (( drift > 0 )); then cls=warn; notes+=("$drift behind"); fi
      if (( ahead > 0 )); then cls=warn; notes+=("$ahead ahead"); fi
    fi
    if [[ "$dirty" == true ]]; then
      if [[ "$cls" == ok ]]; then cls=warn; fi
      notes+=("dirty")
    fi
    label="in step"
    if (( ${#notes[@]} > 0 )); then label=$(printf '%s, ' "${notes[@]}"); label=${label%, }; fi
  fi
}

mapfile -t rows < <(jq -c '.hosts[]' "$SNAP")
if [[ ${1:-} == --states ]]; then
  for row in "${rows[@]}"; do classify "$row"; printf '%s\t%s\n' "$(jq -r .host <<<"$row")" "$cls"; done
  exit 0
fi

gen=$(jq -r '.generated_at // 0' "$SNAP")
stale=0; if (( NOW - gen > STALE_S )); then stale=1; fi

worst=ok; bad_n=0; any_down=0; any_diverged=0; tip=""
for row in "${rows[@]}"; do
  classify "$row"
  name=$(jq -r .host <<<"$row")
  if [[ "$cls" != ok ]]; then bad_n=$((bad_n + 1)); fi
  if [[ "$cls" == bad ]]; then worst=bad; elif [[ "$cls" == warn && "$worst" == ok ]]; then worst=warn; fi
  if [[ "$label" == down ]]; then any_down=1; fi
  if [[ "$label" == *diverged* ]]; then any_diverged=1; fi
  line=$(printf '● %-8s %s %s' "$name" "${short:-—}" "$label")
  if [[ -n "$when" ]]; then line+=" · $when"; fi
  tip+="$(col "$(colour_of "$cls")" "$line")"$'\n'
done

if (( stale )); then class=stale; bucket=stale
elif (( any_diverged )); then class=$worst; bucket=diverged
elif (( any_down )); then class=$worst; bucket=down
elif [[ "$worst" != ok ]]; then class=$worst; bucket=behind
else class=ok; bucket=ok; fi

rule=$(col "$DIM" "────────────────────")
tip+="$rule"$'\n'
if (( stale )); then tip+="$(col "$DIM" "snapshot $(age $((NOW - gen))) old")"$'\n'; fi
tip+="$(col "$ACCENT" "$(waybar_snark fleet "$bucket" "the fleet has no comment.")")"

text=$IDLE
if (( bad_n > 0 )); then text="$GLYPH $bad_n"; fi
emit "$text" "$class" "$tip"
