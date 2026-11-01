# The `overnight` command (scripts/overnight.sh), shared by the NixOS and home-manager halves.
{ pkgs }:
pkgs.writeShellApplication {
  name = "overnight";
  runtimeInputs = with pkgs; [ coreutils gnugrep findutils jq systemd libnotify less ];
  text = builtins.readFile ../scripts/overnight.sh;
}
