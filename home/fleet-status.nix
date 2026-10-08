{ pkgs, ... }:
let
  fleetStatus = pkgs.writeShellApplication {
    name = "fleet-status";
    runtimeInputs = with pkgs; [ bash git jq openssh coreutils gnused tailscale ];
    text = builtins.readFile ../scripts/fleet-status.sh;
  };
in
{
  home.packages = [ fleetStatus ];

  systemd.user.services.fleet-status = {
    Unit.Description = "Probe the fleet and write ~/.cache/fleet-status.json";
    Service = {
      Type = "oneshot";
      ExecStart = "${fleetStatus}/bin/fleet-status";
      Nice = 19;
    };
  };

  systemd.user.timers.fleet-status = {
    Unit.Description = "fleet-status timer";
    Timer = { OnStartupSec = "90s"; OnUnitActiveSec = "5min"; };
    Install.WantedBy = [ "timers.target" ];
  };
}
