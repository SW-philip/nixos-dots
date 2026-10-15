#!/usr/bin/env bash
# nixfetch [host|--all] [--now] [--imports]: flake-side report for a fleet host. Reads only the nixfetch and
# fleet-status caches plus this clone of the repo; the collector keeps the caches fresh, so no ssh here.
set -euo pipefail

REPO=${NIXFETCH_ROOT:-$HOME/nixos}
CACHE=${NIXFETCH_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/nixfetch}
FLEET=${NIXFETCH_FLEET_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/fleet-status.json}
PALETTE=${NIXFETCH_PALETTE:-$HOME/.config/waybar/palette.sh}
NOW=${NIXFETCH_NOW:-$(date +%s)}
STALE_S=${NIXFETCH_STALE_S:-10800}   # two missed collector runs plus slack (sampler 1h + collector 1h + jitter is normal)
SRC=${NIXFETCH_SRC:-/var/lib/nixfetch/host.json}   # this host's own sample, fresher than the collected copy
DELAY=${NIXFETCH_DELAY:-0.03}
AGE_WARN_D=90    # oldest flake input: older than this is WARN
AGE_BAD_D=365    # ... and older than this is BAD
MAX_W=78
SNARK_FILE=${NIXFETCH_SNARK:-}
SNARK_USER=$HOME/.local/share/nixfetch/snark.txt
GRAD_LINES=7
HOSTS=${NIXFETCH_HOSTS:-"desktop surface retro pi"}
SELF=${NIXFETCH_SELF:-$(uname -n)}
# numbers within +-1e15 only, floored (jq prints from ~1e17 as 1e+NN, which bash arithmetic rejects; 1e15 is a safe margin); anything else drops out so arithmetic never sees junk
JQ_INT='def int: if type == "number" and . > -1e15 and . < 1e15 then floor else empty end; '

nix_name() { case $1 in desktop) echo SWphil ;; surface) echo SWsurface ;; retro) echo SWretro ;; pi) echo SWpi ;; *) echo "$1" ;; esac; }
self_host() { local h; for h in $HOSTS; do [[ "${SELF,,}" == "$(nix_name "$h" | tr '[:upper:]' '[:lower:]')" ]] && { echo "$h"; return; }; done; echo "${HOSTS%% *}"; }

target="" all=0 fast=0 full_imports=0
for a in "$@"; do
  case $a in
    --all) all=1 ;;
    --now) fast=1 ;;
    --imports) full_imports=1 ;;
    -*) echo "usage: nixfetch [host|--all] [--now] [--imports]" >&2; exit 2 ;;
    *) target=$a ;;
  esac
done
if [[ -n "$target" && " $HOSTS " != *" $target "* ]]; then
  echo "nixfetch: unknown host '$target' (known: $HOSTS)" >&2; exit 2
fi
[[ -n "$target" ]] || target=$(self_host)
[[ -t 1 ]] || fast=1

ACC="" OK="" WARN="" BAD="" DIM="" RS="" G0="" G1=""
if [[ -t 1 && -z "${NO_COLOR:-}" && -r "$PALETTE" ]]; then
  # shellcheck disable=SC1090
  source "$PALETTE"
  ansi() { local h=${1#\#}; printf '\033[38;2;%d;%d;%dm' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }
  G0=${ROOT#\#} G1=${FIFTH#\#}
  ACC=$(ansi "$ROOT") OK=$(ansi "$FIFTH") WARN=$(ansi "$FERMATA") BAD=$(ansi "$FORTE") DIM=$(ansi "$REST") RS=$'\033[0m'
fi

grad() {   # step n -> escape for that step of the ROOT..FIFTH gradient; empty when uncoloured
  [[ -n "$G0" ]] || return 0
  local i=$1 n=$2 c ch=() k a b
  for k in 0 2 4; do
    a=$(printf '%d' "0x${G0:k:2}"); b=$(printf '%d' "0x${G1:k:2}")
    ch+=( $(( a + (b - a) * i / (n - 1) )) )
  done
  c=$(printf '\033[38;2;%d;%d;%dm' "${ch[@]}")
  printf '%s' "$c"
}

width() {
  local w=${NIXFETCH_COLS:-${COLUMNS:-}}
  [[ -n "$w" ]] || w=$(tput cols 2>/dev/null || true)
  [[ "$w" =~ ^[0-9]+$ ]] && (( w > 0 )) || w=$MAX_W
  (( w > MAX_W )) && w=$MAX_W
  echo "$w"
}
W=$(width)

hrule() { local s; s=$(printf '%*s' "$1" ''); printf '%s' "${s// /─}"; }
box_top() { local t="╭─ $1 "; emit "$DIM╭─ $ACC$1$DIM $(hrule $(( W - ${#t} )))$RS"; }
box_end() { emit "$DIM╰$(hrule $(( W - 1 )))$RS"; }
bar() {   # n -> ▰▰▱▱▱
  local n=$1 i out=""
  (( n > 5 )) && n=5
  for i in 1 2 3 4 5; do (( i <= n )) && out+="▰" || out+="▱"; done
  printf '%s' "$out"
}

emit() { printf '%s\n' "$1"; [[ $fast == 1 ]] || sleep "$DELAY"; }
row()  { emit "$(printf '%s│%s %s%-9s%s %s' "$DIM" "$RS" "$ACC" "$1" "$RS" "$2")"; }

age() {   # seconds -> 45s | 12m | 3h | 2d
  local s=$1
  (( s < 0 )) && s=0
  if   (( s < 90 ));     then echo "${s}s"
  elif (( s < 5400 ));   then echo "$(( (s + 30) / 60 ))m"
  elif (( s < 129600 )); then echo "$(( (s + 1800) / 3600 ))h"
  else                        echo "$(( (s + 43200) / 86400 ))d"
  fi
}

imports_of() {   # direct imports of hosts/<host>/config.nix, one repo-relative path per line
  local cfg="$REPO/hosts/$1/config.nix"
  [[ -r "$cfg" ]] || return 0
  { grep -oE '\.\./\.\./[A-Za-z0-9_./-]+|\./[A-Za-z0-9_-]+\.nix' "$cfg" || true; } \
    | sed -e 's|^\.\./\.\./||' -e "s|^\./|hosts/$1/|" | awk '!seen[$0]++'
}

imports_summary() {   # stdin paths -> "hosts 9 · roles 5"
  awk 'BEGIN { n = split("hosts roles modules identities profiles home pkgs secrets", o, " "); for (i = 1; i <= n; i++) known[o[i]] = 1 }
    { split($0, p, "/"); c[p[1]]++; if (!(p[1] in known) && !(p[1] in seenx)) { seenx[p[1]] = 1; x[++nx] = p[1] } }
    END { for (i = 1; i <= n; i++) if (c[o[i]]) out = out (out ? " · " : "") o[i] " " c[o[i]]
          for (i = 1; i <= nx; i++) out = out (out ? " · " : "") x[i] " " c[x[i]]
          print out }'
}

# diverged > offline > reboot > behind > ahead > stale > current
snark_row() {
  local state=$1 host=$2 file="" lines pick idx n seed
  if [[ -r "$SNARK_USER" ]]; then file=$SNARK_USER; elif [[ -n "$SNARK_FILE" && -r "$SNARK_FILE" ]]; then file=$SNARK_FILE; fi
  [[ -n "$file" ]] || return 0
  lines=$(grep -F -- "$state: " "$file" 2>/dev/null | grep "^$state: " | sed "s/^$state: //" || true)
  [[ -n "$lines" ]] || return 0
  n=$(wc -l <<<"$lines")
  seed=${NIXFETCH_SNARK_SEED:-}
  if [[ "$seed" =~ ^[0-9]+$ ]]; then idx=$(( seed % n ))
  else idx=$(( (NOW / 86400 + $(printf '%s' "$host" | cksum | cut -d' ' -f1)) % n )); fi
  pick=$(sed -n "$(( idx + 1 ))p" <<<"$lines")
  emit ""
  emit "  ${DIM}$pick${RS}"
}

render() {
  local host=$1 f="$CACHE/$1.json" name; name=$(nix_name "$host")
  if [[ "$host" == "$(self_host)" && -r "$SRC" ]] && jq -e 'type == "object"' "$SRC" >/dev/null 2>&1; then
    local src_at cache_at=0
    src_at=$(jq -r "$JQ_INT"'(.generated_at | int) // 0' "$SRC")
    [[ -r "$f" ]] && cache_at=$(jq -r "$JQ_INT"'(.generated_at | int) // 0' "$f" 2>/dev/null || echo 0)
    (( src_at > cache_at )) && f=$SRC
  fi
  emit ""
  local gi=0
  while IFS= read -r l; do emit "$(grad "$gi" "$GRAD_LINES")$l$RS"; gi=$(( gi + 1 )); done <<'ART'
   \\  \\ //
  ==\\__\\/ //
    //   \\//
 ==//     //==
  //\\___//
 // /\\  \\==
// //  \\  \\
ART
  emit ""
  emit "  $name ${DIM}· $host · nixfetch${RS}"
  emit "$DIM$(hrule "$W")$RS"
  emit ""

  if [[ ! -r "$f" ]] || ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    box_top STATE
    row "state" "${DIM}no data yet — the collector hasn't seen $host${RS}"
    box_end
    snark_row nodata "$name"
    return
  fi

  local rev version gen built booted kernel closure gen_at
  rev=$(jq -r '.rev // ""' "$f");        version=$(jq -r '.version // "—"' "$f")
  gen=$(jq -r "$JQ_INT"'(.generation | int) // ""' "$f"); built=$(jq -r "$JQ_INT"'(.built_at | int) // ""' "$f")
  booted=$(jq -r '.booted_same' "$f");   kernel=$(jq -r '.kernel_same' "$f")
  closure=$(jq -r "$JQ_INT"'(.closure_bytes | int) // ""' "$f"); gen_at=$(jq -r "$JQ_INT"'(.generated_at | int) // 0' "$f")

  local drift ahead dirty fleet_rev offline
  fleet_rev=$(jq -r --arg h "$host" '.hosts[]? | select(.host == $h) | .rev // ""' "$FLEET" 2>/dev/null || true)
  offline=$(jq -r --arg h "$host" '.hosts[]? | select(.host == $h) | (.ssh_ok == false)' "$FLEET" 2>/dev/null || true)
  [[ -n "$fleet_rev" ]] && rev=$fleet_rev   # drift is computed against this one
  drift=$(jq -r --arg h "$host" "$JQ_INT"'.hosts[]? | select(.host == $h) | (.drift | int) // ""' "$FLEET" 2>/dev/null || true)
  ahead=$(jq -r --arg h "$host" "$JQ_INT"'.hosts[]? | select(.host == $h) | (.ahead | int) // 0' "$FLEET" 2>/dev/null || true)
  dirty=$(jq -r --arg h "$host" '.hosts[]? | select(.host == $h) | .dirty // false' "$FLEET" 2>/dev/null || true)

  local rv="${DIM}—${RS}" state=current
  if [[ -n "$rev" ]]; then
    rv="${rev:0:8}"
    [[ "$dirty" == true ]] && rv+=" ${WARN}dirty${RS}"
    if [[ -z "$drift" && "$offline" == true ]]; then rv+=" ${DIM}○ offline${RS}"; state=offline
    elif [[ -z "$drift" ]]; then rv+=" ${WARN}unknown commit${RS}"
    elif (( drift > 0 && ahead > 0 )); then rv+=" ${BAD}✖ diverged${RS}"; state=diverged
    elif (( drift > 0 )); then rv+=" ${WARN}▲ $drift behind $(bar "$drift")${RS}"; state=behind
    elif (( ahead > 0 )); then rv+=" ${WARN}▲ $ahead ahead $(bar "$ahead")${RS}"; state=ahead
    else rv+=" ${OK}● current${RS}"; fi
  fi
  box_top STATE
  row "rev" "$rv"
  if [[ -n "$gen" ]]; then
    local g="#$gen"; [[ -n "$built" ]] && g+=" · $(age $((NOW - built))) ago"
    row "gen" "$g"
  fi
  if [[ "$booted" == true ]]; then row "booted" "${OK}● running the deployed generation${RS}"
  elif [[ "$kernel" == false ]]; then row "booted" "${WARN}↻ reboot pending (kernel changed)${RS}"; [[ $state == current || $state == behind || $state == ahead ]] && state=reboot
  else row "booted" "${DIM}older generation booted${RS}"; fi
  box_end

  emit ""
  box_top SYSTEM
  row "version" "$version"
  [[ -n "$closure" ]] && row "closure" "$(numfmt --to=iec --format='%.0f' "$closure")"
  local imp isum; imp=$(imports_of "$host")
  isum=$(imports_summary <<<"$imp")
  [[ -n "$imp" && -n "$isum" ]] && row "imports" "$isum"
  box_end

  emit ""
  box_top FLAKE
  local tag; tag=$(git -C "$REPO" describe --tags --abbrev=0 --match '20*' 2>/dev/null || true)
  if [[ -n "$tag" ]]; then
    row "release" "$tag · $(age $((NOW - $(git -C "$REPO" log -1 --format=%ct "$tag")))) ago"
  fi
  local shipped; shipped=$(git -C "$REPO" log -1 --format=%ct main 2>/dev/null || true)
  [[ -n "$shipped" ]] && row "main" "last commit $(age $((NOW - shipped))) ago"
  local oldest
  oldest=$(jq -r "$JQ_INT"'[.inputs[] | {name, t: (.last_modified | int)} | select(.t)] | sort_by(.t) | first // empty | "\(.name) \(.t)"' "$f" 2>/dev/null || true)
  if [[ -n "$oldest" ]]; then
    local od=$(( (NOW - ${oldest##* }) / 86400 )) oc=$OK
    (( od >= AGE_WARN_D )) && oc=$WARN
    (( od >= AGE_BAD_D )) && oc=$BAD
    row "oldest" "${oldest% *} · ${oc}$(age $((NOW - ${oldest##* }))) old${RS}"
  fi
  local themes nhosts
  themes=$(find "$REPO/themes" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l) || true
  nhosts=$(find "$REPO/hosts" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) || true
  row "tree" "$themes themes · $nhosts hosts"
  box_end

  if (( NOW - gen_at > STALE_S )); then
    emit ""
    emit "  ${DIM}(stale: sampled $(age $((NOW - gen_at))) ago)${RS}"
    [[ $state == current ]] && state=stale
  fi
  if (( full_imports == 1 )) && [[ -n "$imp" ]]; then
    emit ""
    emit "  ${DIM}imports${RS}"
    while IFS= read -r l; do emit "    $l"; done <<<"$imp"
  fi
  snark_row "$state" "$name"
}

if (( all == 1 )); then for h in $HOSTS; do render "$h"; done; else render "$target"; fi
emit ""
