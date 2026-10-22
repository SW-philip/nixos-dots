{ lib, ... }:
{
  boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;
  boot.loader.systemd-boot.enable = false;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
  };
}
