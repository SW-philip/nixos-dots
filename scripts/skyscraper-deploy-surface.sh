#!/usr/bin/env bash
# Mirror a desktop skyscraper-deploy.sh run onto surface. Run this ON
# SURFACE, after scripts/skyscraper-deploy.sh has deployed the system on
# desktop.
#
# Surface never gets its own copy of the art — /srv/roms-nfs is desktop's
# real /srv/roms mounted read-only (hosts/surface/config.nix), so the media/
# files are already visible there. Surface only needs its own sidecar
# metadata file, with asset paths rewritten from desktop's real path
# (/srv/roms/<system>) to surface's path to the same files
# (/srv/roms-nfs/<system>), dropped into surface's local /srv/roms/<system>/
# (a small root:root tree — see hosts/surface/config.nix — alongside the
# existing metadata.pegasus.txt symlink that Pegasus already scans).
set -euo pipefail

sys="${1:?usage: skyscraper-deploy-surface.sh <system-dir> (e.g. n64, snes, psx)}"
desktop="prepko@desktop.example.ts.net"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

ssh "$desktop" "cat /srv/roms/$sys/skyscraper.metadata.pegasus.txt" > "$tmp" || {
  echo "No deployed sidecar for $sys on desktop — run scripts/skyscraper-deploy.sh $sys there first." >&2
  exit 1
}

sed "s#/srv/roms/$sys#/srv/roms-nfs/$sys#g" "$tmp" \
  | sudo tee "/srv/roms/$sys/skyscraper.metadata.pegasus.txt" > /dev/null

echo "Deployed $sys sidecar -> /srv/roms/$sys/skyscraper.metadata.pegasus.txt (surface)"
