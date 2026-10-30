#!/usr/bin/env bash
# Eval all hosts (no build). Channels differ (desktop=unstable, surface/retro=26.05), so all must pass.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Cheap and eval-free, so it also runs on surface before the skip below.
scripts/palette-lint.sh

# Static lint (also eval-free). Tests under scripts/tests/ are excluded: their `$?` idiom trips SC2319.
nix run nixpkgs#shellcheck -- -S warning scripts/*.sh
git ls-files -z '*.nix' | xargs -0 nix run nixpkgs#deadnix -- --fail --no-lambda-pattern-names -q

# Surface is 8 GB: evaluating two full configs there risks the oomd reaping the shell.
if hostname | grep -qi surface; then
  echo "check-hosts: SKIPPED on surface (8 GB) — nothing was evaluated; run it on desktop" >&2
  exit 3
fi

# Recipient check before the full eval: a host that can't decrypt passwords.yaml boots locked out.
scripts/secrets-lint.sh

for h in desktop surface retro pi; do
  echo "eval $h..."
  nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" >/dev/null
done
echo "ok: desktop + surface + retro + pi evaluate"
