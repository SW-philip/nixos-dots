{ pkgs, ... }:
let
  reaper = pkgs.writeShellApplication {
    name = "reaper";
    runtimeInputs = with pkgs; [ bash jq openssh coreutils gawk procps gnugrep libnotify ];
    text = builtins.readFile ../scripts/reaper.sh;
  };
in
{
  home.packages = [ reaper ];

  systemd.user.services.reaper = {
    Unit.Description = "Sweep the fleet for zombie and wedged processes";
    Service = {
      Type = "oneshot";
      ExecStart = "${reaper}/bin/reaper";
      Nice = 19;
    };
  };

  systemd.user.timers.reaper = {
    Unit.Description = "reaper timer";
    Timer = { OnStartupSec = "10min"; OnUnitActiveSec = "30min"; AccuracySec = "1min"; };
    Install.WantedBy = [ "timers.target" ];
  };
}
