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

  environment.etc."machine-id" = {
    text = "35872b60dbfe485ca1505bc546c91848\n";
    mode = "0444";
  };
}
