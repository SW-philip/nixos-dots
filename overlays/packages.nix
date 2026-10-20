# Software packaged in this repo (pkgs/).
{ inputs, system }:
final: prev: {
  sqlch                  = prev.callPackage ../pkgs/sqlch { src = inputs.sqlch; };
  uniremote              = prev.callPackage ../pkgs/uniremote { };
  orch                   = prev.callPackage ../pkgs/orch { };
  pandora                = prev.callPackage ../pkgs/pandora { };
  python-ember-mug       = prev.callPackage ../pkgs/python-ember-mug { };
  plymouth-silent-splash = prev.callPackage ../pkgs/plymouth-silent-splash { };
  lix-plymouth           = prev.callPackage ../pkgs/lix-plymouth { };
  dsa-plymouth           = prev.callPackage ../pkgs/dsa-plymouth { };
  greeter                = prev.callPackage ../pkgs/greeter { };
  lix-logout             = prev.callPackage ../pkgs/lix-logout { };
  # niri-bridge needs rustc >=1.98; nixos-26.05 (the pinned `nixpkgs`
  # this overlay applies to) ships 1.95. Pull just the toolchain from
  # nixpkgs-unstable's raw legacyPackages (an overlay-applied unstable set
  # would re-apply this overlay and recurse on itself).
  # This mixes an unstable-channel rustPlatform/stdenv with stable-channel
  # buildInputs (wayland, pkg-config, fetchFromGitHub) on surface's
  # nixos-26.05-based pkgsFor — confirmed it links fine, but a Task 3
  # home-manager module consuming this package should know it's a
  # cross-channel build, not a from-scratch surprise if it ever breaks.
  niri-bridge = prev.callPackage ../pkgs/niri-bridge {
    rustPlatform = inputs.nixpkgs-unstable.legacyPackages.${system}.rustPlatform;
  };
}
