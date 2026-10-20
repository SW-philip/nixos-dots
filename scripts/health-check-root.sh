#!/usr/bin/env bash
# health-check-root: the root-only reads health-check.sh needs, as fixed commands with
# validated arguments. Lets prepko run these NOPASSWD without a wildcard sudo rule on
# btrfs/systemd-cryptenroll (a `*` there would also match --wipe-slot and friends).
#   btrfs-stats <mountpoint>   btrfs device stats; the mountpoint must be a mounted btrfs
#   tpm <device>               systemd-cryptenroll listing; the device must be a LUKS partition
#   efi-images                 the unified kernel images on the ESP
#   smart <device>             smartctl health/identity/attributes; the device must be a whole disk
set -euo pipefail

die() { echo "health-check-root: $*" >&2; exit 2; }

case "${1:-}" in
  btrfs-stats)
    mp=${2:-}
    [[ $mp == /* ]] || die "btrfs-stats needs an absolute mountpoint"
    [[ "$(findmnt -no FSTYPE -- "$mp" 2>/dev/null)" == btrfs ]] || die "$mp is not a mounted btrfs"
    exec btrfs device stats "$mp"
    ;;
  tpm)
    dev=${2:-}
    lsblk -rno PATH,FSTYPE | awk -v d="$dev" '$1 == d && $2 == "crypto_LUKS" {f = 1} END {exit !f}' \
      || die "$dev is not a LUKS partition"
    exec systemd-cryptenroll "$dev"
    ;;
  efi-images)
    shopt -s nullglob
    images=(/boot/EFI/Linux/*.efi)
    [[ ${#images[@]} -gt 0 ]] || die "no images in /boot/EFI/Linux"
    exec ls -- "${images[@]}"
    ;;
  smart)
    dev=${2:-}
    lsblk -drno PATH,TYPE | awk -v d="$dev" '$1 == d && $2 == "disk" {f = 1} END {exit !f}' \
      || die "$dev is not a disk"
    # smartctl's exit status is a bitmask (failing attrs, logged errors, ...) that the
    # caller reads from the text; standby,0 skips a sleeping HDD instead of spinning it up.
    smartctl -H -i -A -l devstat -n standby,0 -- "$dev" || true
    ;;
  *) die "usage: health-check-root btrfs-stats <mountpoint> | tpm <device> | efi-images | smart <device>" ;;
esac
