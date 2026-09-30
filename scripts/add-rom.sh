#!/usr/bin/env bash
# Move a game file into /srv/roms/<system> and register it with Pegasus via
# a manual.metadata.pegasus.txt sidecar block.
#
# Never touches skyscraper.metadata.pegasus.txt — that file is owned by
# scripts/skyscraper-deploy.sh, which `install`s (overwrites) it wholesale on
# every scrape deploy. A hand-written entry living there would get silently
# wiped the next time more games get scraped for the same system. Pegasus
# merges any number of `<name>.metadata.pegasus.txt` sidecar files in a
# collection dir, so a separate manual.metadata.pegasus.txt is immune to
# that and needs no nix rebuild — this only writes runtime data outside the
# repo, same as the Skyscraper flow.
#
# file:/assets.* paths are written relative to the collection directory
# (just the filename), not absolute. desktop's metadata.pegasus.txt sets
# `directories: .` (== /srv/roms/<sys> itself) and surface's sets
# `directories: /srv/roms-nfs/<sys>` (hosts/surface/config.nix) — an
# absolute /srv/roms/... path (as skyscraper-deploy.sh writes) only
# resolves on desktop. Relative paths resolve correctly under either.
#
# ext -> system dir map mirrors `retroSystems` in hosts/desktop/config.nix /
# hosts/surface/config.nix. Keep in sync by hand if a system's extensions
# list changes there. Only extensions unique to one system are listed here;
# ambiguous ones (chd/iso/bin/cue, shared by several systems) require
# --system explicitly.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: add-rom.sh --file <path> [--system <dir>] [--title <t>]
                   [--description <d>] [--developer <d>] [--publisher <p>]
                   [--genre <g>] [--players <n>] [--release <YYYY-MM-DD>]

--system is inferred from the file extension when unambiguous (e.g. .cdi,
.gdi -> dreamcast; .nes -> nes). Extensions shared by multiple systems
(chd, iso, bin, cue) require --system explicitly.
--title defaults to the filename without its extension.
All other fields are optional and simply omitted from the metadata block
when not given.
EOF
  exit 1
}

declare -A EXT_TO_SYSTEM=(
  [nes]=nes
  [sfc]=snes [smc]=snes
  [gen]=genesis
  [gba]=gba
  [pbp]=psx
  [n64]=n64 [z64]=n64
  [rvz]=gamecube-wii [wbfs]=gamecube-wii
  [cso]=psp
  [wux]=wiiu [rpx]=wiiu
  [3ds]=3ds [cia]=3ds
  [nsp]=switch [xci]=switch
  [gdi]=dreamcast [cdi]=dreamcast
)

file=""
system=""
title=""
description=""
developer=""
publisher=""
genre=""
players=""
release=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) file="$2"; shift 2 ;;
    --system) system="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --description) description="$2"; shift 2 ;;
    --developer) developer="$2"; shift 2 ;;
    --publisher) publisher="$2"; shift 2 ;;
    --genre) genre="$2"; shift 2 ;;
    --players) players="$2"; shift 2 ;;
    --release) release="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$file" ]] || usage
[[ -f "$file" ]] || { echo "No such file: $file" >&2; exit 1; }

base="$(basename -- "$file")"
ext="${base##*.}"
ext="${ext,,}"

if [[ -z "$system" ]]; then
  system="${EXT_TO_SYSTEM[$ext]:-}"
  if [[ -z "$system" ]]; then
    echo "Can't infer a system for .$ext (ambiguous or unknown) — pass --system explicitly." >&2
    exit 1
  fi
fi

dest_dir="/srv/roms/$system"
[[ -d "$dest_dir" ]] || { echo "No such collection dir: $dest_dir" >&2; exit 1; }

dest_path="$dest_dir/$base"
if [[ -e "$dest_path" ]]; then
  if [[ "$(readlink -f -- "$file")" == "$(readlink -f -- "$dest_path")" ]]; then
    echo "Already at $dest_path — skipping move, still registering metadata."
  else
    echo "Already present: $dest_path (not overwriting)" >&2
    exit 1
  fi
else
  sudo mv -n -- "$file" "$dest_path"
  sudo chown --reference="$dest_dir" -- "$dest_path"
  sudo chmod 0644 -- "$dest_path"
  echo "Moved -> $dest_path"
fi

if [[ -z "$title" ]]; then
  title="${base%.*}"
fi

sidecar="$dest_dir/manual.metadata.pegasus.txt"
if sudo test -f "$sidecar" && sudo grep -qF "game: $title" "$sidecar"; then
  echo "manual.metadata.pegasus.txt already has an entry for '$title' — leaving it alone."
  exit 0
fi

block="game: $title
file: $base"
[[ -n "$description" ]] && block+=$'\n'"description: $description"
[[ -n "$release"     ]] && block+=$'\n'"release: $release"
[[ -n "$developer"   ]] && block+=$'\n'"developer: $developer"
[[ -n "$publisher"   ]] && block+=$'\n'"publisher: $publisher"
[[ -n "$genre"       ]] && block+=$'\n'"genre: $genre"
[[ -n "$players"     ]] && block+=$'\n'"players: $players"
block+=$'\n'

{ [[ -s "$sidecar" ]] 2>/dev/null && printf '\n'; printf '%s\n' "$block"; } | sudo tee -a "$sidecar" >/dev/null
sudo chown --reference="$dest_dir" -- "$sidecar"
sudo chmod 0644 -- "$sidecar"

echo "Added '$title' to $sidecar"
