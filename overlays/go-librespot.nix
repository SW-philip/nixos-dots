# go-librespot is not in nixos-26.05, so it comes from nixpkgs-unstable,
# bumped to v0.10.5 for the device_auth login (the interactive one is
# rejected by Spotify's client id).
# drop when: the stable channel ships go-librespot >= 0.10.5.
{ inputs, ... }:
final: prev: {
  go-librespot =
    inputs.nixpkgs-unstable.legacyPackages.${prev.stdenv.hostPlatform.system}.go-librespot.overrideAttrs
      (old: rec {
        version = "0.10.5";
        src = old.src.override {
          tag = "v${version}";
          hash = "sha256-lSObYalZqAYfik59L5PrH4CGcZilA7Tpzx4tVmTdsks=";
        };
        vendorHash = "sha256-fxB99qZE+U355iKJHIl7LgxqHmYgCiU1FpbyObTXVcQ=";
      });
}
