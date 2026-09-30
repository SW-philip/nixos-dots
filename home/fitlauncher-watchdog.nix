{ lib, config, ... }:

{
  # Kept as a plain script (scripts/fitlauncher-watchdog.sh) rather than
  # pkgs.writeShellApplication like bluetooth-battery-notify/usb-notify:
  # that helper forces `set -euo pipefail`, and this script's
  # `pgrep ... | head -1` legitimately returns non-zero under `pipefail`
  # whenever nothing matches -- the common case, since fit-launcher usually
  # isn't running. Forced -e would exit the script before it ever reached
  # the "nothing running" no-op path.
  systemd.user.services.fitlauncher-watchdog = {
    Unit = {
      Description = "Kill fit-launcher/aria2c if stuck pegging CPU at 0 KB/s";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${config.home.homeDirectory}/nixos/scripts/fitlauncher-watchdog.sh";
    };
  };

  systemd.user.timers.fitlauncher-watchdog = {
    Unit.Description = "Poll fit-launcher/aria2c for a stuck retry-storm every 20s";
    Timer = {
      OnStartupSec = "20s";
      OnUnitActiveSec = "20s";
      AccuracySec = "1s";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
