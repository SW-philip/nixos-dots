# unstable's rustc denies invalid_runtime_symbol_definitions, which squeekboard
# 1.43.1 trips (it defines its own `close(u32)`), so take the same version
# from the stable channel, where it still compiles and is cached.
# drop when: squeekboard builds on nixpkgs-unstable's rustc.
{ inputs, ... }:
_final: prev: {
  inherit (inputs.nixpkgs.legacyPackages.${prev.stdenv.hostPlatform.system}) squeekboard;
}
