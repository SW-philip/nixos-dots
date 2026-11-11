#!/usr/bin/env bash
# Find empty folders in user-content areas and optionally remove them. Run
# nightly by goodnight (home/empty-dirs.nix) with --delete; bare `empty-dirs`
# only reports. Never scanned: $HOME dotdirs, git repos, *.trickplay, and
# anything matching a keep pattern (config: ~/.config/empty-dirs/{roots,keep}).
#
# "New Folder"/"untitled folder" leftovers go after a day; any other empty
# folder only once it has sat untouched for EMPTY_DIRS_DAYS (default 14).
set -euo pipefail
CONF="${EMPTY_DIRS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/empty-dirs}"
MIN_DAYS="${EMPTY_DIRS_DAYS:-14}"
delete=0; [[ "${1:-}" == --delete ]] && delete=1
say() { echo "empty-dirs: $*"; }

read_list() { [[ -f "$1" ]] && grep -vE '^\s*(#|$)' "$1" || true; }
mapfile -t roots < <(read_list "$CONF/roots")
mapfile -t keep  < <(read_list "$CONF/keep")
((${#roots[@]})) || roots=("$HOME")

junk_re='^(new|untitled) (folder|directory)( ?\(?[0-9]+\)?)?$'
now=$(date +%s)
removed=0 pending=0

for root in "${roots[@]}"; do
  [[ -d "$root" ]] || continue
  # find's -path `*` also matches `/`, so /srv/Videos/*/commercials covers every channel.
  prune=(-path "$HOME/.*" -o -name '*.trickplay' -o -name node_modules)
  for k in "${keep[@]}"; do prune+=(-o -path "$k"); done
  while IFS= read -r -d '' repo; do
    [[ "$repo" == "$root" ]] || prune+=(-o -path "$repo")
  done < <(find "$root" -xdev \( "${prune[@]}" \) -prune -o -name .git -printf '%h\0' 2>/dev/null)
  while IFS= read -r -d '' d; do
    name="${d##*/}"
    age=$(( (now - $(stat -c %Y -- "$d")) / 86400 ))
    if [[ "${name,,}" =~ $junk_re ]]; then need=1; else need=$MIN_DAYS; fi
    if ((age < need)); then
      say "waiting  ${age}d/${need}d  $d"; pending=$((pending + 1)); continue
    fi
    if ((delete)); then
      if rmdir -- "$d" 2>/dev/null; then say "removed  $d"; removed=$((removed + 1))
      else say "cannot remove $d"; fi
    else
      say "would remove  (${age}d)  $d"; removed=$((removed + 1))
    fi
  done < <(find "$root" -xdev -mindepth 1 \( "${prune[@]}" \) -prune \
             -o -type d -empty -print0 2>/dev/null)
done

if ((delete)); then say "$removed removed, $pending not old enough yet"
else say "$removed to remove, $pending not old enough yet (dry run; --delete to act)"; fi
