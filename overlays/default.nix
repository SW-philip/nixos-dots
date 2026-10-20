# Every nixpkgs patch/override in one place. Each file is one overlay; ones
# that work around an upstream bug carry a `drop when:` line saying what to
# check before deleting them. Locally packaged software is in packages.nix.
{ inputs, system }:
final: prev:
let
  args = { inherit inputs system; };
  overlays = map (f: import f args) [
    ./packages.nix
    ./pegasus-cxx17.nix
    ./cage-xcursor.nix
    ./deluge-setuptools.nix
    ./anyio-py312.nix
    ./nixos-rebuild-ng.nix
    ./azahar-cstring.nix
    ./emulator-ffmpeg7.nix
    ./niri-session-env.nix
    ./go-librespot.nix
  ];
in
prev.lib.composeManyExtensions overlays final prev
