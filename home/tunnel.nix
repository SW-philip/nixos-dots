{ pkgs, ... }:
let
  ports = import ../hosts/ports.nix;
  tunnel = pkgs.writeShellApplication {
    name = "ssh-tunnel";
    runtimeInputs = with pkgs; [ jq fuzzel openssh libnotify xdg-utils iproute2 systemd gnused gawk gnugrep coreutils ];
    runtimeEnv.TUNNEL_DEFAULT_PORT = toString ports.adguard-ui;
    text = builtins.readFile ../scripts/tunnel.sh;
  };
in
{
  home.packages = [ tunnel ];
}
