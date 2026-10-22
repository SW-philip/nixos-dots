{pkgs, lib, ...}:
let
  sandbox = import ../../lib/sandbox.nix;
in
{
  services.fwupd.enable = true;

  # Upstream timer is hourly + Persistent, so it also fires right after boot.
  systemd.timers.fwupd-refresh.timerConfig = {
    OnCalendar = [ "" "monthly" ];
    RandomizedDelaySec = "1d";
  };

  ############################################################
  # KDE Connect — pair with S21+ for notifications/file transfer.
  # Opens TCP+UDP 1714-1764 automatically (needed for discovery/pairing).
  ############################################################
  programs.kdeconnect.enable = true;

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

  # btrfs mounts with discard=async (kernel default), so a weekly fstrim only
  # re-trims what's already been discarded and takes ~10 min after boot catch-up.
  services.fstrim.enable = false;
}
