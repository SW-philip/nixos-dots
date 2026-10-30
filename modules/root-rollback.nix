{ config, lib, utils, ... }:
let
  cfg = config.rootRollback;
  deviceUnit = "${utils.escapeSystemdPath cfg.device}.device";
in
{
  options.rootRollback.device = lib.mkOption {
    type = lib.types.str;
    example = "/dev/mapper/cryptroot";
    description = "Opened device whose btrfs top level holds @, @blank and @persist.";
  };

  # Every boot: the previous root becomes @prev (kept one boot, for recovering
  # anything that should have been persisted) and @ is a fresh snapshot of @blank.
  config.boot.initrd.systemd.services.rollback = {
    description = "Replace root subvolume @ with a fresh snapshot of @blank";
    wantedBy = [ "initrd.target" ];
    # The device unit rather than systemd-cryptsetup@<name>.service: After= on a
    # misnamed unit is silently ignored and the wipe never happens.
    requires = [ deviceUnit ];
    after = [ deviceUnit ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      # btrfs refuses to delete a subvolume with nested ones; list -o prints
      # paths relative to the top level, which is mounted at /mnt.
      delete_tree() {
        btrfs subvolume list -o "$1" | while read -r _ _ _ _ _ _ _ _ sub; do
          delete_tree "/mnt/$sub"
        done
        btrfs subvolume delete "$1"
      }

      mkdir -p /mnt
      mount -t btrfs -o subvolid=5 ${cfg.device} /mnt
      trap 'umount /mnt' EXIT

      if [ -e /mnt/@persist/.no-rollback ]; then
        echo "/persist/.no-rollback exists, keeping @"
        exit 0
      fi

      if [ -e /mnt/@prev ] && ! delete_tree /mnt/@prev; then
        echo "could not delete @prev, keeping @" >&2
        exit 1
      fi

      mv /mnt/@ /mnt/@prev
      if ! btrfs subvolume snapshot /mnt/@blank /mnt/@; then
        mv /mnt/@prev /mnt/@
        echo "snapshot of @blank failed, restored @" >&2
        exit 1
      fi
    '';
  };
}
