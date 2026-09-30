#!/usr/bin/env bash
# Deploy a Skyscraper scrape (~/.skyscraper/config.ini staging output) into
# the real /srv/roms/<system> on desktop. Run this ON DESKTOP, after
# `Skyscraper -p <platform> -s screenscraper` + `Skyscraper -p <platform> -f
# pegasus` have populated ~/skyscraper-staging/<system>.
#
# Never writes /srv/roms/<system>/metadata.pegasus.txt itself — that's a
# systemd.tmpfiles symlink into the Nix store (hosts/desktop/config.nix),
# read-only, and it's the only place the REAL launch= command lives.
# Skyscraper has no idea what that command is and invents its own
# RetroPie-style runcommand.sh default; deploying its header verbatim would
# silently break every game's launch. Pegasus accepts extra
# `<name>.metadata.pegasus.txt` files in the same directory as bare `game:`
# overrides onto whatever the primary header already discovered, so this
# strips Skyscraper's header and keeps only the per-game blocks.
#
# Skyscraper also writes assets.*/file paths as absolute, rooted at the
# staging gameListFolder — rewrite them to where the files actually land
# under /srv/roms before deploying.
#
# Some systems (gamecube-wii) share one /srv/roms dir across multiple
# Skyscraper platform tokens (gc + wii), each scraped as a separate pass
# with its own gameListFolder subdir (config.ini) so their `-f pegasus`
# writes don't collide. Pass the token as $2 for those — it selects the
# right staging subdir AND gives each pass its own destination sidecar
# name (skyscraper-<token>.metadata.pegasus.txt) so gc and wii don't
# clobber each other's deployed metadata either. Omit $2 for ordinary
# single-platform systems (unchanged behavior).
set -euo pipefail

sys="${1:?usage: skyscraper-deploy.sh <system-dir> [platform-token] (e.g. n64, snes, psx, or gamecube-wii gc)}"
token="${2:-}"
dest="/srv/roms/$sys"

if [[ -n "$token" ]]; then
  staging="$HOME/skyscraper-staging/$sys/$token"
  sidecar="skyscraper-$token.metadata.pegasus.txt"
else
  staging="$HOME/skyscraper-staging/$sys"
  sidecar="skyscraper.metadata.pegasus.txt"
fi

if [[ ! -f "$staging/metadata.pegasus.txt" ]]; then
  echo "No staged gamelist at $staging/metadata.pegasus.txt — run Skyscraper -p <platform> -f pegasus first." >&2
  exit 1
fi

sed "s#$staging#$dest#g" "$staging/metadata.pegasus.txt" \
  | awk '/^game:/{f=1} f' \
  > "$staging/$sidecar"

sudo rsync -a --chmod=Da+rx,Fa+r "$staging/media/" "$dest/media/"
sudo install -m 0644 "$staging/$sidecar" "$dest/$sidecar"

echo "Deployed $sys -> $dest (media/ + $sidecar)"
