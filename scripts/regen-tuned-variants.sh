#!/usr/bin/env bash
# The hand-tuned light/dark variants, as the exact make-variant.py calls that
# produced them. Their accents are not all recoverable from the SEED_* lines
# (the --accent slots and --no-harmonize aren't stored), so this file is the
# source of truth. Each theme is LOCKED, so `drmis regen --force` never touches
# them. Needs resvg for the wallpapers:  nix shell nixpkgs#resvg -c scripts/regen-tuned-variants.sh
set -euo pipefail
cd "$(dirname "$0")/.."

mk() { python3 scripts/make-variant.py "$@" --no-harmonize --force >/dev/null; echo "regenerated $1-$2"; }

# dark counterparts of the two bright originals
mk kid dark --mode dark \
  --seed HALL=#1d1415 --seed TONIC=#d8451e --seed MEDIANT=#8c8c3a --seed DOMINANT=#d9a23c --seed SUBDOMINANT=#9a6b86 \
  --accent SUPERTONIC=#9fb08a --accent SUBMEDIANT=#e8b9a4

# light counterparts
mk onyx-mauve light --mode light \
  --seed HALL=#f3e5dd --seed TONIC=#a8452f --seed MEDIANT=#8f8576 --seed DOMINANT=#c0607e --seed SUBDOMINANT=#8a5a78 \
  --accent SUPERTONIC=#4a3a40 --accent SUBMEDIANT=#62401f
mk wu-tang light --mode light \
  --seed HALL=#c4c4c4 --seed TONIC=#7a5c00 --seed MEDIANT=#4f6a00 --seed DOMINANT=#7a3f00 --seed SUBDOMINANT=#2e2e2e \
  --accent SUPERTONIC=#5a5000 --accent SUBMEDIANT=#7a4a10
mk free-palestine light --mode light \
  --seed HALL=#f7f7f4 --seed TONIC=#ce1126 --seed MEDIANT=#007a3d --seed DOMINANT=#6b7a2a --seed SUBDOMINANT=#2a2a2a \
  --accent SUPERTONIC=#8a1a24 --accent SUBMEDIANT=#7a5a3a
mk slate-lavender light --mode light \
  --seed HALL=#e7e5ef --seed TONIC=#7461a8 --seed MEDIANT=#566f8f --seed DOMINANT=#a8607f --seed SUBDOMINANT=#6a8a78 \
  --accent SUPERTONIC=#34345f --accent SUBMEDIANT=#85704c
mk chocolate-mint light --mode light \
  --seed HALL=#e6f3ec --seed TONIC=#2f8a68 --seed MEDIANT=#5a3a2a --seed DOMINANT=#1a7a90 --seed SUBDOMINANT=#a8504a \
  --accent SUPERTONIC=#4a5a2a --accent SUBMEDIANT=#a06a2e
mk wfp light --mode light \
  --seed HALL=#f6f1f3 --seed TONIC=#d6501f --seed MEDIANT=#5a3aa8 --seed DOMINANT=#c24a6a --seed SUBDOMINANT=#a8681a \
  --accent SUPERTONIC=#3a2a6a --accent SUBMEDIANT=#8a3a8a
