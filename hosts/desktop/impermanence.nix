{ ... }:
{
  imports = [ ../../modules/root-rollback.nix ];
  rootRollback.device = "/dev/mapper/luks-d8543351-206f-4b3e-884f-9d0ea8c2eebd";

  environment.persistence."/persist" = {
    hideMounts = true;

    directories = [
      "/var/lib/nixos"
      "/var/lib/NetworkManager"
      { directory = "/etc/NetworkManager/system-connections"; mode = "0700"; }
      "/var/lib/tailscale"
      "/var/lib/jellyfin-whisper"
      "/var/lib/bluetooth"
      "/var/lib/sbctl"
      { directory = "/var/lib/sops-nix"; mode = "0700"; }
      "/var/lib/systemd/timers"
      "/var/lib/systemd/rfkill"
      "/var/lib/systemd/timesync"
      "/var/lib/fwupd"
      "/var/lib/upower"
      "/var/lib/OpenRGB"
      "/var/lib/myln"
      "/var/lib/libvirt"
      # nfsdcld client records: without them surface's NFSv4 reclaim after a
      # reboot fails and it drops its locks.
      "/var/lib/nfs"
      "/var/lib/power-profiles-daemon"
      "/var/lib/lastlog"
      "/var/lib/btrfs"
      "/var/lib/systemd/coredump"
      "/var/lib/systemd/pstore"
      "/var/cache/jellyfin"
      "/var/cache/tuigreet"
      "/var/log"
      # State file for services.logrotate.extraArgs below.
      "/var/lib/logrotate"
      # `sudo nixos-rebuild --target-host` ssh's as root.
      { directory = "/root/.ssh"; mode = "0700"; }
    ];

    files = [
      "/etc/adjtime"
      # systemd-creds host key: anything encrypted against it is unreadable once it changes.
      "/var/lib/systemd/credential.secret"
    ];
  };

  # Without its state file logrotate restarts every log's rotation clock at each
  # boot. It can't be a persisted file: logrotate renames a temp file over it,
  # which fails with EBUSY on a bind mount, so it lives in a persisted directory.
  services.logrotate.extraArgs = [ "-s" "/var/lib/logrotate/status" ];

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

  services.openssh.hostKeys = [
    { path = "/persist/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    { path = "/persist/etc/ssh/ssh_host_rsa_key";    type = "rsa"; bits = 4096; }
  ];
}
