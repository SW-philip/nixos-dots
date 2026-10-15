{ pkgs, ... }:
let
  collect = pkgs.writeShellApplication {
    name = "nixfetch-collect";
    runtimeInputs = with pkgs; [ bash jq openssh coreutils ];
    text = builtins.readFile ../scripts/nixfetch-collect.sh;
  };
  nixfetch = pkgs.writeShellApplication {
    name = "nixfetch";
    runtimeInputs = with pkgs; [ bash git jq coreutils gnused gnugrep findutils gawk ncurses ];
    runtimeEnv = { NIXFETCH_SNARK = "${../assets/nixfetch-snark.txt}"; };
    text = builtins.readFile ../scripts/nixfetch.sh;
  };
in
{
  home.packages = [ collect nixfetch ];

  systemd.user.services.nixfetch-collect = {
    Unit.Description = "Pull every host's nixfetch sample into ~/.cache/nixfetch";
    Service = {
      Type = "oneshot";
      ExecStart = "${collect}/bin/nixfetch-collect";
      Nice = 19;
    };
  };

  systemd.user.timers.nixfetch-collect = {
    Unit.Description = "nixfetch-collect timer";
    Timer = { OnStartupSec = "3min"; OnUnitActiveSec = "1h"; AccuracySec = "5min"; };
    Install.WantedBy = [ "timers.target" ];
  };
}
