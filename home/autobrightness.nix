{ pkgs, ... }:
let
  autobrightness = pkgs.writeShellApplication {
    name = "autobrightness";
    runtimeInputs = [ pkgs.coreutils pkgs.brightnessctl pkgs.gawk ];
    text = builtins.readFile ../scripts/autobrightness.sh;
  };
in
{
  # Tunables (curve, hold time, ...) are AB_* env vars with defaults in the script.
  systemd.user.services.autobrightness = {
    Unit = {
      Description = "Ambient-light auto brightness (fixed curve, no learning)";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
    };
    Service = {
      ExecStart = "${autobrightness}/bin/autobrightness";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
