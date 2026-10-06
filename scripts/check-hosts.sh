#!/usr/bin/env bash
# Eval all hosts (no build). Channels differ (desktop=unstable, surface/retro=26.05), so all must pass.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Surface is 8 GB: evaluating two full configs there risks the oomd reaping the shell.
if hostname | grep -qi surface; then
  echo "check-hosts: SKIPPED on surface (8 GB) — nothing was evaluated; run it on desktop" >&2
  exit 3
fi

for h in desktop surface retro pi; do
  echo "eval $h..."
  nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" >/dev/null
done
echo "ok: desktop + surface + retro + pi evaluate"
