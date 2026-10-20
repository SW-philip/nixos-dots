#!/usr/bin/env bash
# persist-seed.sh — move existing state into /persist before the nrs that adds
# its environment.persistence entry. Run right before that nrs:
#   sudo persist-seed.sh /var/lib/foo /etc/bar ...
# Directories are copied: impermanence bind-mounts /persist/<p> over <p>, so an
# unseeded dir comes up empty and hides the old data. Files are moved:
# impermanence's mount-file.bash aborts activation if a non-empty file is
# already at the target.

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "persist-seed: needs root (sudo $0 ...)" >&2; exit 1; }
(($#)) || { echo "usage: persist-seed.sh <path>..." >&2; exit 2; }

for p in "$@"; do
  dst=/persist$p
  if findmnt -rn "$p" >/dev/null; then
    echo "skip  $p (already mounted)"
  elif [[ -e $dst ]]; then
    echo "skip  $p ($dst exists)"
  elif [[ ! -e $p ]]; then
    echo "skip  $p (missing)"
  else
    mkdir -p "$(dirname "$dst")"
    if [[ -d $p ]]; then
      cp -a --reflink=auto "$p" "$dst"
      echo "copy  $p"
    else
      mv "$p" "$dst"
      echo "move  $p"
    fi
  fi
done
