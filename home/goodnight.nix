# The nightly fleet batch (scripts/goodnight.sh) and its audit (scripts/goodnight-audit.sh).
# A user timer like fleet-status, desktop only: it already has working unattended ssh to the
# other hosts, and the one privileged step is the sudo -n goodnight-activate wrapper
# (roles/goodnight-activate.nix). Deploy is off until goodnight.deploy.enable is set, so a
# fresh rebuild never starts deploying by itself.
{ config, lib, pkgs, ... }:
let
  audit = pkgs.writeShellApplication {
    name = "goodnight-audit";
    runtimeInputs = with pkgs; [ bash jq openssh coreutils findutils gnugrep hostname libnotify ];
    text = builtins.readFile ../scripts/goodnight-audit.sh;
  };
  goodnight = pkgs.writeShellApplication {
    name = "goodnight";
    runtimeInputs = with pkgs; [ audit bash jq openssh coreutils findutils gnugrep gawk git util-linux hostname libnotify ];
    text = builtins.readFile ../scripts/goodnight.sh;
  };
in
{
  options.goodnight.deploy.enable = lib.mkEnableOption "the nightly deploy of origin/main (off: it only reports what it would deploy)";

  config = {
    home.packages = [ audit goodnight ];

    systemd.user.services.goodnight = {
      Unit.Description = "Nightly fleet batch: wake, deploy, audit, housekeeping, backups";
      Service = {
        Type = "oneshot";
        ExecStart = "${goodnight}/bin/goodnight run";
        Environment = [
          "GOODNIGHT_HEALTH_CHECK=${../scripts/health-check.sh}"
          "GOODNIGHT_NOTIFY=1"
        ] ++ lib.optional config.goodnight.deploy.enable "GOODNIGHT_DEPLOY=1";
        Nice = 19;
        IOSchedulingClass = "idle";
        # a night with a stream-wait is long, but never unbounded
        TimeoutStartSec = "6h";
      };
    };

    systemd.user.timers.goodnight = {
      Unit.Description = "goodnight timer";
      # Persistent: if desktop was off at 02:30 the batch runs after the next login.
      Timer = { OnCalendar = "*-*-* 02:30:00"; RandomizedDelaySec = "10m"; Persistent = true; };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
