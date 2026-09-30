{ ... }:
{
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
      "/var/lib/fwupd"
      "/var/lib/upower"
      "/var/lib/OpenRGB"
      "/var/lib/deluge"
      "/var/lib/myln"
      "/var/cache/jellyfin"
      "/var/cache/tuigreet"
      "/var/log"
    ];

    files = [];
  };

  environment.etc."machine-id" = {
    text = "35872b60dbfe485ca1505bc546c91848\n";
    mode = "0444";
  };

  services.openssh.hostKeys = [
    { path = "/persist/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    { path = "/persist/etc/ssh/ssh_host_rsa_key";    type = "rsa"; bits = 4096; }
  ];
}
