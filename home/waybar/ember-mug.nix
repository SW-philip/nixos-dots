{ config, pkgs, lib, ... }:
let
  isDesktop = config.myConfig.isDesktop;
  scriptsDir = "${config.home.homeDirectory}/.config/waybar/scripts";
  mugMac = "00:00:00:00:00:01";

  # Does the actual BLE fetch and writes ~/.cache/waybar/ember-mug/status.json.
  # Run on a timer (below) so eww's mug row is a pure cache read -- no BLE
  # traffic on every bar refresh.
  #
  # Also invoked directly by bt-device-probe.sh's connect-event handler,
  # outside the timer. The mug's own poll connect is itself a BlueZ
  # "Connected: yes" transition, which is exactly what that handler reacts
  # to -- without serializing, the timer's routine poll would trigger a
  # second, overlapping connect-event-driven poll on top of itself, opening
  # two concurrent BLE sessions against one device (confirmed live: this
  # produced a crash from both processes racing to rename the same
  # status.json.tmp, and is the likely cause of the mug's connection
  # visibly bouncing). flock forces any second caller to wait for the
  # first to finish instead of racing it.
  pollScript = pkgs.writeShellScriptBin "ember-mug-poll" ''
    export PATH="${lib.makeBinPath [ pkgs.python-ember-mug ]}:$PATH"
    lockdir="''${XDG_CACHE_HOME:-$HOME/.cache}/waybar/ember-mug"
    mkdir -p "$lockdir"
    exec ${pkgs.util-linux}/bin/flock -w 25 "$lockdir/poll.lock" \
      ${pkgs.python3}/bin/python3 ${scriptsDir}/ember-mug-poll.py "${mugMac}"
  '';
in
{
  options.waybar.emberMug.enable = lib.mkEnableOption "Ember mug poll service/timer";

  config = lib.mkIf (config.waybar.emberMug.enable && !isDesktop) {
    home.packages = [ pollScript ];

    # Same shape as home/waybar/weather.nix's radar-cache: a oneshot poll
    # driven by a periodic timer, keeping the actual BLE connect off waybar's
    # own poll path entirely.
    systemd.user.services.ember-mug-poll = {
      Unit = {
        Description = "Poll Ember mug status into cache";
        After = [ "graphical-session.target" "bluetooth.service" ];
        PartOf = [ "graphical-session.target" ];
        ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${pollScript}/bin/ember-mug-poll";
      };
    };

    systemd.user.timers.ember-mug-poll = {
      Unit.Description = "Ember mug status poll timer";
      Timer = {
        OnStartupSec = "10s";
        OnUnitActiveSec = "60s";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
