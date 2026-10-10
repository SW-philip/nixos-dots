{ pkgs, ... }:
let
  syncStatus = pkgs.writeShellApplication {
    name = "sync-status";
    runtimeInputs = with pkgs; [ bash jq curl coreutils gnused gnugrep findutils libnotify ];
    text = builtins.readFile ../scripts/sync-status.sh;
  };
  syncConflicts = pkgs.writeShellApplication {
    name = "sync-conflicts";
    runtimeInputs = with pkgs; [ jq coreutils gnused gnugrep diffutils less ];
    text = builtins.readFile ../scripts/sync-conflicts.sh;
  };
in
{
  home.packages = [ syncStatus syncConflicts ];

  systemd.user.services.sync-status = {
    Unit.Description = "Summarise Syncthing health into ~/.cache/sync-status.json";
    Service = {
      Type = "oneshot";
      ExecStart = "${syncStatus}/bin/sync-status";
      Nice = 19;
    };
  };

  systemd.user.timers.sync-status = {
    Unit.Description = "sync-status timer";
    Timer = { OnStartupSec = "90s"; OnUnitActiveSec = "2min"; AccuracySec = "1min"; };
    Install.WantedBy = [ "timers.target" ];
  };
}
