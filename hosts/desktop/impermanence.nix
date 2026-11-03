{ ... }:
{
  imports = [ ../../roles/impermanence.nix ];
  rootRollback.device = "/dev/mapper/luks-d8543351-206f-4b3e-884f-9d0ea8c2eebd";

  environment.persistence."/persist".directories = [
    "/var/lib/jellyfin-whisper"
    "/var/lib/upower"
    "/var/lib/OpenRGB"
    "/var/lib/myln"
    "/var/lib/libvirt"
    # nfsdcld client records: without them surface's NFSv4 reclaim after a
    # reboot fails and it drops its locks.
    "/var/lib/nfs"
    "/var/lib/btrfs"
    "/var/cache/jellyfin"
    # `sudo nixos-rebuild --target-host` ssh's as root.
    { directory = "/root/.ssh"; mode = "0700"; }
  ];

  # Jellyfin writes ~100G of transcode segments a day and deletes them; as plain
  # /persist content the hourly btrbk snapshots pinned every one for days. A
  # nested subvolume is left out of snapshots. `v` only creates it when the path
  # is missing, so an existing plain directory must be removed by hand first.
  systemd.tmpfiles.rules = [
    "v /persist/var/cache/jellyfin/transcodes 0750 jellyfin jellyfin -"
  ];

  environment.etc."machine-id" = {
    text = "35872b60dbfe485ca1505bc546c91848\n";
    mode = "0444";
  };
}
