#!/usr/bin/env bash
# hide-apps <id>... — hide launcher entries without breaking MIME handling: copy the real
# .desktop (real Exec, MimeType, actions) into the user dir with NoDisplay=true. Files we
# wrote before (marker line) that are no longer listed are removed; others are never touched.
set -euo pipefail

OUT=${HIDE_APPS_OUT:-$HOME/.local/share/applications}
SEARCH=${HIDE_APPS_SEARCH:-/etc/profiles/per-user/$(id -un)/share:/run/current-system/sw/share:$HOME/.nix-profile/share:/nix/profile/share:$HOME/.local/state/nix/profile/share}
MARK='# hide-apps: generated, do not edit'

mkdir -p "$OUT"
declare -A want=()
for id in "$@"; do want[$id]=1; done

for f in "$OUT"/*.desktop; do
  [[ -e $f ]] || continue
  [[ $(head -n1 "$f") == "$MARK" ]] || continue
  id=$(basename "$f" .desktop)
  [[ -n ${want[$id]:-} ]] || rm -f "$f"
done

IFS=: read -ra dirs <<<"$SEARCH"
for id in "$@"; do
  src=
  for d in "${dirs[@]}"; do
    if [[ -f $d/applications/$id.desktop ]]; then src=$d/applications/$id.desktop; break; fi
  done
  [[ -n $src ]] || continue
  dest=$OUT/$id.desktop
  if [[ -e $dest && $(head -n1 "$dest") != "$MARK" ]]; then continue; fi
  {
    echo "$MARK"
    awk '/^\[Desktop Entry\]/ { print; print "NoDisplay=true"; main = 1; next }
         /^\[/ { main = 0 }
         main && /^NoDisplay=/ { next }
         { print }' "$src"
  } > "$dest.tmp"
  mv -f "$dest.tmp" "$dest"
done
