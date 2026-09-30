#!/usr/bin/env bash
# Recovery: chroot into the desktop NixOS install.
# Run from a live environment (e.g. the Surface booted on desktop hardware,
# or any NixOS live USB). Sudo will be prompted as needed.
set -euo pipefail

LUKS_UUID="d8543351-206f-4b3e-884f-9d0ea8c2eebd"
LUKS_NAME="cryptroot-desktop"
EFI_UUID="2FA5-FDF9"
MOUNT="/mnt/desktop"

cleanup() {
    echo "==> Cleaning up..."
    sudo umount -R "$MOUNT" 2>/dev/null || true
    sync
    sudo cryptsetup close "$LUKS_NAME" 2>/dev/null \
        || sudo dmsetup remove --force "$LUKS_NAME" 2>/dev/null \
        || true
}
trap cleanup EXIT

echo "==> Opening LUKS (enter the desktop passphrase)..."
sudo cryptsetup open "/dev/disk/by-uuid/$LUKS_UUID" "$LUKS_NAME"

echo "==> Mounting filesystems..."
sudo mkdir -p "$MOUNT"
sudo mount -t btrfs -o subvol=@ /dev/mapper/"$LUKS_NAME" "$MOUNT"
sudo mkdir -p "$MOUNT"/{home,persist,boot}
sudo mount -t btrfs -o subvol=@home    /dev/mapper/"$LUKS_NAME" "$MOUNT/home"
sudo mount -t btrfs -o subvol=@persist /dev/mapper/"$LUKS_NAME" "$MOUNT/persist"
sudo mount "/dev/disk/by-uuid/$EFI_UUID" "$MOUNT/boot"

echo "==> Entering chroot..."
echo "    Flake is at /home/prepko/nixos inside the chroot."
echo "    To rebuild: nixos-rebuild switch --flake /home/prepko/nixos#desktop"
echo "    To check TPM2/sbctl state: sbctl status; sbctl list-enrolled-keys"
sudo nixos-enter --root "$MOUNT"

# cleanup handled by trap
