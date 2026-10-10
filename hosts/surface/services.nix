{pkgs, lib, ...}:
let
  sandbox = import ../../lib/sandbox.nix;
in
{
  services.fwupd.enable = true;

  ############################################################
  # KDE Connect — pair with S21+ for notifications/file transfer.
  # Opens TCP+UDP 1714-1764 automatically (needed for discovery/pairing).
  ############################################################
  programs.kdeconnect.enable = true;

  services.deluge = {
    enable = true;
    openFirewall = false;
    web.enable = false;
  };

  # Not wanted by multi-user.target — deluged idling with nothing to seed
  # or download is pure idle draw (network + disk kept out of low-power
  # states). Start it manually (`systemctl start deluged`) when there's
  # actually something to transfer.
  systemd.services.deluged.wantedBy = lib.mkForce [ ];

  # deluged already runs unprivileged (User=deluge) but ships with zero
  # sandboxing from upstream — network stays wide open (bittorrent/DHT
  # need arbitrary outbound ports), filesystem is scoped to its data dir.
  systemd.services.deluged.serviceConfig = sandbox // {
    ReadWritePaths = [ "/var/lib/deluge" ];
  };

  ############################################################
  # Smartd (NVMe monitoring)
  ############################################################
  services.smartd = {
    enable = true;
    autodetect = false;
    # default 30 min check interval keeps waking the NVMe
    extraOptions = [ "-i" "7200" ];
    notifications.wall.enable = true;
    devices = [{
      device = "/dev/nvme0";
      options = lib.concatStringsSep " " [
        "-a"
        "-s S/../.././02"
        "-s L/../../7/02"
        "-l error" "-l selftest"
      ];
    }];
  };

  services.fstrim = {
    enable = true;
    interval = "weekly";
  };
}
