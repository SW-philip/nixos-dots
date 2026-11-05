#!/usr/bin/env bash
# Run uniremote's tests outside the Nix build: bash pkgs/uniremote/run-tests.sh [pytest args]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec nix shell --impure --expr 'let pkgs = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}; in pkgs.python3.withPackages (ps: with ps; [pytest requests requests-mock samsungtvws yarl pygobject3])' -c env PYTHONPATH=src python3 -m pytest -q "${@:-tests}"
