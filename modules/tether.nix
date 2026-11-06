{ inputs, pkgs, ... }:
{
  imports = [ inputs.tether.nixosModules.default ];

  # Overlay (not inputs.tether.packages) so it builds against our nixpkgs, not the input's own copy.
  nixpkgs.overlays = [ inputs.tether.overlays.default ];

  programs.tether = {
    enable = true;
    package = pkgs.tether;
    wifi = { enable = true; openFirewall = true; };
    bluetooth = { enable = true; adapters = [ "hci0" ]; };
  };
}
