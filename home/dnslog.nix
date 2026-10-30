{ pkgs, ... }:
let
  dnslog = pkgs.writeShellApplication {
    name = "dnslog";
    runtimeInputs = with pkgs; [ jq openssh coreutils ];
    text = builtins.readFile ../scripts/dnslog.sh;
  };
in
{
  home.packages = [ dnslog ];

  # the push button: fuzzel's "DNS Log" pulls fresh entries and keeps following
  xdg.desktopEntries.dnslog = {
    name = "DNS Log";
    icon = "network-server";
    exec = "${pkgs.ghostty}/bin/ghostty --class=dev.prepko.dnslog -e dnslog -f -n 100";
    terminal = false;
    categories = [ "Network" "Utility" ];
  };
}
