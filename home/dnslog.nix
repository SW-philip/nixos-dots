{ config, lib, pkgs, ... }:
let
  dnslog = pkgs.writeShellApplication {
    name = "dnslog";
    runtimeInputs = with pkgs; [ jq openssh coreutils ];
    text = builtins.readFile ../scripts/dnslog.sh;
  };
  dnsreport = pkgs.writeShellApplication {
    name = "dnsreport";
    runtimeInputs = with pkgs; [ jq openssh coreutils findutils gnugrep ];
    text = builtins.readFile ../scripts/dnsreport.sh;
  };
  # tailnet devices outside inventory.json (the phone) get a name in the logs too
  clients = (import ../hosts/tailnet-policy.nix).hosts;
  state = "${config.home.homeDirectory}/.local/state/dnsreport";
in
{
  home.packages = [ dnslog dnsreport ];

  xdg.configFile."dnslog/clients.json".text = builtins.toJSON clients;

  # a week of blocked DNS kept as text, so "did this start last Tuesday?" has an answer
  goodnight.jobs.dnsreport = lib.mkIf config.myConfig.isDesktop { every = "week"; };
  systemd.user.services.dnsreport = lib.mkIf config.myConfig.isDesktop {
    Unit.Description = "Save the weekly blocked-DNS report";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "dnsreport-save" ''
        ${pkgs.coreutils}/bin/mkdir -p ${state}
        ${dnsreport}/bin/dnsreport -d 7 > ${state}/$(${pkgs.coreutils}/bin/date +%F).txt
        ${pkgs.findutils}/bin/find ${state} -name '*.txt' -mtime +180 -delete
      ''}";
      Nice = 19;
    };
  };
  systemd.user.timers.dnsreport = lib.mkIf config.myConfig.isDesktop {
    Unit.Description = "Weekly blocked-DNS report";
    Timer = { OnCalendar = "weekly"; RandomizedDelaySec = "1h"; Persistent = true; };
    Install.WantedBy = [ "timers.target" ];
  };

  # the push button: the menu's "DNS Log" pulls fresh entries and keeps following
  xdg.desktopEntries.dnslog = {
    name = "DNS Log";
    icon = "network-server";
    exec = "${pkgs.ghostty}/bin/ghostty --class=dev.prepko.dnslog -e dnslog -f -n 100";
    terminal = false;
    categories = [ "Network" "Utility" ];
  };
}
