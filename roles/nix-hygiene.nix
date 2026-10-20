# Store and footprint hygiene shared by the headless/appliance hosts (retro,
# pi). desktop and surface get theirs from roles/base.nix instead (nh clean,
# bigger free-space thresholds); the two don't mix.
{ lib, ... }:
{
  nix.settings = {
    allowed-users = [ "prepko" ];
    # nixos-rebuild --build-host copies unsigned closures from desktop.
    trusted-users = [ "root" "prepko" ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = lib.mkDefault "--delete-older-than 14d";
  };

  documentation.enable = false;
  environment.defaultPackages = [ ];
  zramSwap.enable = true;
}
