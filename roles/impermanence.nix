{ ... }:
{
  imports = [ ../modules/root-rollback.nix ];

  environment.persistence."/persist" = {
    hideMounts = true;

    directories = [
      "/var/lib/nixos"
      "/var/lib/NetworkManager"
      { directory = "/etc/NetworkManager/system-connections"; mode = "0700"; }
      "/var/lib/tailscale"
      "/var/lib/bluetooth"
      "/var/lib/sbctl"
      { directory = "/var/lib/sops-nix"; mode = "0700"; }
      "/var/lib/systemd/timers"
      "/var/lib/systemd/rfkill"
      "/var/lib/systemd/timesync"
      "/var/lib/systemd/coredump"
      "/var/lib/systemd/pstore"
      "/var/lib/fwupd"
      "/var/lib/power-profiles-daemon"
      "/var/lib/lastlog"
      "/var/log"
      # State file for services.logrotate.extraArgs below.
      "/var/lib/logrotate"
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

  services.openssh.hostKeys = [
    { path = "/persist/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    { path = "/persist/etc/ssh/ssh_host_rsa_key";    type = "rsa"; bits = 4096; }
  ];
}
