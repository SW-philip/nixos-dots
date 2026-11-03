# Every nixpkgs patch/override in one place. Each file is one overlay; ones
# that work around an upstream bug carry a `drop when:` line saying what to
# check before deleting them. Locally packaged software is in packages.nix.
# Applied on desktop and surface (unstable) and the stable installer; retro and
# pi don't take it.
{ inputs, system }:
final: prev:
let
  args = { inherit inputs system; };
  overlays = map (f: import f args) [
    ./packages.nix
    ./pegasus-cxx17.nix
    ./emulator-ffmpeg7.nix
    ./niri-session-env.nix
    ./go-librespot.nix
    ./squeekboard.nix
  ];
in
prev.lib.composeManyExtensions overlays final prev
