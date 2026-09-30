#!/usr/bin/env bash
# game-save-merge
#
# Newest-wins merge of every local emulation account's RetroArch save tree
# (~/.config/retroarch/saves/) into the shared save store, /srv/game-saves.
#
# Run once per host AFTER /srv/game-saves exists (desktop) or is mounted
# (surface) and BEFORE switching each account's retroarch.cfg
# savefile_directory over to it. Safe to re-run any time.
#
# `rsync --update` copies a file only when the source mtime is newer than
# the destination's, so the most recently played copy of any given save
# wins. Backup detritus (*.bak, *.from-*) is excluded so it never pollutes
# the shared store. After copying, ownership is normalized to the NFS
# all_squash identity (desktop `retro`, 1002:984) and modes to 0777/0666
# so any account on either host can overwrite regardless of who wrote last.
#
# Replaces the ad-hoc "cp X.srm Y.from-Z.srm.bak" hand-copying between
# accounts. See
# docs/superpowers/specs/2026-08-29-shared-retroarch-saves-design.md
set -euo pipefail

SHARE="${SHARE:-/srv/game-saves}"

if [[ ! -d "$SHARE" ]]; then
  echo "error: $SHARE does not exist / is not mounted" >&2
  exit 1
fi

# -f, not -x: the nixpkgs launcher's process name is ".retroarch-wrapped"
# (makeWrapper), so -x retroarch never matches it.
if pgrep -f '/\.?retroarch' >/dev/null; then
  echo "error: retroarch is running -- exit all instances first (torn .srm risk)" >&2
  exit 1
fi

# Every human account on this host: uid 1000..64999 with a real /home dir.
mapfile -t accounts < <(
  getent passwd | awk -F: '$3>=1000 && $3<65000 && $6 ~ /^\/home\// {print $1":"$6}'
)

merged=0
for entry in "${accounts[@]}"; do
  user="${entry%%:*}"
  home="${entry#*:}"
  src="$home/.config/retroarch/saves/"
  # sudo test: other accounts' homes are 0750, this script's user can't
  # stat inside them, but the sudo rsync below can read them fine.
  sudo test -d "$src" || continue
  echo ">> $user: $src -> $SHARE/"
  sudo rsync -a -u \
    --exclude='*.bak' --exclude='*.bak-*' --exclude='*.claude-bak-*' \
    --exclude='*.srm.bak*' --exclude='*.from-*' --exclude='*.orig' \
    "$src" "$SHARE/"
  merged=1
done

if [[ "$merged" -eq 0 ]]; then
  echo "no per-account saves/ trees found on this host"
fi

# Normalize ownership + modes so cross-account overwrite always works.
sudo chown -R 1002:984 "$SHARE"
sudo find "$SHARE" -type d -exec chmod 0777 {} + 2>/dev/null || true
sudo find "$SHARE" -type f -exec chmod 0666 {} + 2>/dev/null || true

echo
echo "shared store now holds:"
find "$SHARE" -type f -not -name '.*' | sed "s#^$SHARE/##" | sort
