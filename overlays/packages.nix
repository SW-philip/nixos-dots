# Software packaged in this repo (pkgs/).
{ inputs, system }:
_final: prev: {
  sqlch                  = prev.callPackage ../pkgs/sqlch { src = inputs.sqlch; };
  uniremote              = prev.callPackage ../pkgs/uniremote { };
  orch                   = prev.callPackage ../pkgs/orch { };
  pandora                = prev.callPackage ../pkgs/pandora { };
  python-ember-mug       = prev.callPackage ../pkgs/python-ember-mug { };
  greeter                = prev.callPackage ../pkgs/greeter { };
  lix-logout             = prev.callPackage ../pkgs/lix-logout { };
  # niri-bridge needs rustc >=1.98; nixos-26.05 (the pinned `nixpkgs`
  # this overlay applies to) ships 1.95. Pull just the toolchain from
  # nixpkgs-unstable's raw legacyPackages (an overlay-applied unstable set
  # would re-apply this overlay and recurse on itself).
  # On the flake's stable-based pkgsFor this mixes an unstable rustPlatform
  # with stable buildInputs (confirmed it links). desktop and surface apply
  # this overlay to unstable, where it's the same toolchain either way.
  niri-bridge = prev.callPackage ../pkgs/niri-bridge {
    rustPlatform = inputs.nixpkgs-unstable.legacyPackages.${system}.rustPlatform;
  };
}
