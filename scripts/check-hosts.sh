#!/usr/bin/env bash
# Eval both hosts (no build). Channels differ (desktop=unstable, surface=26.05), so both must pass.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Surface is 8 GB: evaluating two full configs there risks the oomd reaping the shell.
if hostname | grep -qi surface; then
  echo "check-hosts: skipped on surface (8 GB) — run it on desktop" >&2
  exit 0
fi

for h in desktop surface; do
  echo "eval $h..."
  nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" >/dev/null
done
echo "ok: desktop + surface evaluate"
