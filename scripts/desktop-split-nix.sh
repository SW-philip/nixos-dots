#!/usr/bin/env bash
# Phase 1 of desktop rollback impermanence: copy /nix into its own @nix
# subvolume (and create an empty @blank). Run ON THE DESKTOP, after `nrb` has
# built the new boot entry and before rebooting — anything built after this
# copy is missing from @nix at next boot. See
# docs/superpowers/specs/2026-10-01-desktop-rollback-impermanence-design.md.
set -euo pipefail

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
[[ $(hostname) == SWphil || $(hostname) == desktop ]] || { echo "desktop only" >&2; exit 1; }

dev=/dev/mapper/luks-d8543351-206f-4b3e-884f-9d0ea8c2eebd
top=$(mktemp -d /run/nix-split.XXXXXX)
mount -t btrfs -o subvol=/ "$dev" "$top"
trap 'systemctl start nix-daemon.socket 2>/dev/null || true; umount "$top" 2>/dev/null; rmdir "$top" 2>/dev/null || true' EXIT

# Refuse to copy over a populated target: a half-copied @nix from an
# interrupted run can't be told apart from a good one.
if [[ -e $top/@nix ]]; then
  [[ -z $(ls -A "$top/@nix") ]] || { echo "@nix exists and is not empty — inspect it, don't re-copy over it" >&2; exit 1; }
else
  btrfs subvolume create "$top/@nix"
fi
[[ -e $top/@blank ]] || btrfs subvolume create "$top/@blank"

systemctl stop nix-daemon.socket nix-daemon.service
before=$(ls /nix/store | wc -l)
echo "copying /nix ($before store entries) -> @nix (reflink)…"
cp -a --reflink=always /nix/. "$top/@nix/"
sync

after=$(ls "$top/@nix/store" | wc -l)
if [[ $before -ne $after ]]; then
  echo "MISMATCH: /nix/store has $before entries, @nix/store has $after — do NOT reboot" >&2
  exit 1
fi
[[ -s $top/@nix/var/nix/db/db.sqlite ]] || { echo "db.sqlite missing from @nix — do NOT reboot" >&2; exit 1; }
cmp -s /nix/var/nix/db/db.sqlite "$top/@nix/var/nix/db/db.sqlite" || { echo "db.sqlite differs — do NOT reboot" >&2; exit 1; }

echo "ok: $after store entries copied, db identical. Safe to reboot."
