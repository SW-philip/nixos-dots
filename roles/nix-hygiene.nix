# Store and footprint hygiene for the headless hosts (via roles/headless.nix). desktop and surface get theirs from roles/base.nix instead (nh clean,
# bigger free-space thresholds); the two don't mix.
{ config, lib, ... }:
{
  nix.settings = {
    allowed-users = [ config.myConfig.user ];
    # nixos-rebuild --build-host copies unsigned closures from desktop.
    trusted-users = [ "root" config.myConfig.user ];
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
