#!/usr/bin/env bash
# surface-prebuild.sh — build surface's system on the build host with nom's progress UI.
# Usage: surface-prebuild.sh <ssh-host>
# nh 4.5.0 shows no progress for --build-host runs; the build below is the same one it does,
# so the nh call that follows finds the closure already built and only copies and switches.

set -euo pipefail

HOST=${1:?usage: surface-prebuild.sh <ssh-host>}
FLAKE=${NH_FLAKE:-$HOME/nixos}

# internal-json goes to stderr; stdout is just the store path, which nh recomputes.
nix build "git+file://$FLAKE#nixosConfigurations.surface.config.system.build.toplevel" \
  --store "ssh-ng://$HOST" --eval-store auto --no-link \
  --log-format internal-json -v 2>&1 >/dev/null | nom --json
