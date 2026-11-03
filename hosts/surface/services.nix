{pkgs, lib, ...}:
{
  ############################################################
  # Smartd (NVMe monitoring)
  ############################################################
  services.smartd = {
    # default 30 min check interval keeps waking the NVMe
    extraOptions = [ "-i" "7200" ];
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
