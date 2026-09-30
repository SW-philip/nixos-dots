{ pkgs, ... }:
{
  # Wipe root on every boot: delete @ and replace with a fresh copy of @blank.
  # Runs after LUKS is open but before sysroot is mounted.
  boot.initrd.systemd.services.rollback = {
    description = "Wipe root btrfs subvolume from @blank";
    wantedBy = [ "initrd.target" ];
    after    = [ "systemd-cryptsetup@cryptroot.service" ];
    before   = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /mnt
      mount -t btrfs -o subvol=/ /dev/mapper/cryptroot /mnt

      # Delete nested subvolumes first — btrfs refuses to delete a non-empty subvolume.
      # list -o returns paths relative to top-level (e.g. @/tmp), so use /mnt/$subvol not /mnt/@/$subvol.
      btrfs subvolume list -o /mnt/@ | \
        while IFS=" " read -r _ _ _ _ _ _ _ _ subvol; do
          btrfs subvolume delete "/mnt/$subvol" || true
        done

      btrfs subvolume delete /mnt/@
      btrfs subvolume snapshot /mnt/@blank /mnt/@

      umount /mnt
    '';
  };

  boot.initrd.systemd.extraBin.btrfs = "${pkgs.btrfs-progs}/bin/btrfs";


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
      "/var/lib/deluge"
      "/var/lib/systemd/timers"
      "/var/lib/systemd/rfkill"
      "/var/lib/systemd/timesync"
      "/var/lib/fwupd"
      "/var/cache/tuigreet"
      "/var/log"
    ];

    files = [];
  };

  # Static machine-id — stable across root wipes because it's in the nix config.
  # Impermanence's files[] bind-mount can't handle /etc/machine-id on a live system
  # since the file already exists at activation time.
  environment.etc."machine-id" = {
    text = "24385d4f7c084e3c8d153b2a37073595\n";
    mode = "0444";
  };

  # openssh generates keys here if absent; existing keys in /persist/etc/ssh survive reboots
  services.openssh.hostKeys = [
    { path = "/persist/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    { path = "/persist/etc/ssh/ssh_host_rsa_key";    type = "rsa"; bits = 4096; }
  ];
}
