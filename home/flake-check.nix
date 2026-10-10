{ pkgs, ... }:
let
  flakeCheck = pkgs.writeShellApplication {
    name = "flake-check";
    runtimeInputs = with pkgs; [ bash git jq nix nvd gh curl hostname coreutils gnugrep gnused gawk findutils util-linux libnotify ];
    text = builtins.readFile ../scripts/flake-check.sh;
  };
in
{
  home.packages = [ flakeCheck ];

  systemd.user.services.flake-check = {
    Unit.Description = "Preview a flake update: what moves, why, and what it costs";
    Service = {
      Type = "oneshot";
      ExecStart = "${flakeCheck}/bin/flake-check";
      Environment = [ "HOME=%h" "PWD=%h/nixos" ];
      WorkingDirectory = "%h/nixos";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  systemd.user.timers.flake-check = {
    Unit.Description = "flake-check weekly";
    Timer = { OnCalendar = "Sun 04:00"; Persistent = true; RandomizedDelaySec = "30min"; };
    Install.WantedBy = [ "timers.target" ];
  };
}
