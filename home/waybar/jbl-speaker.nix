{ config, pkgs, lib, ... }:
let
  isDesktop = config.myConfig.isDesktop;
  scriptsDir = "${config.home.homeDirectory}/.config/waybar/scripts";
  cfg = config.waybar.jblSpeaker;

  python = pkgs.python3.withPackages (ps: [ ps.bleak ]);

  namesArgs = lib.concatMapStringsSep " " (n: "--names ${lib.escapeShellArg n}") cfg.names;

  # Runs as the poll service's ExecStartPost: take the MAC the poll just
  # learned and push its full result into ~/.cache/bt-device-info/<mac>.json,
  # the only cache quantum-bluetooth.sh's connected branch reads. Without this
  # the 120s poll refreshes a file nothing renders from. bt-device-probe.sh
  # calls `bt-classify` (a home.packages wrapper) and `jq` by bare name.
  mergeHook = pkgs.writeShellApplication {
    name = "jbl-speaker-merge-hook";
    runtimeInputs = [ pkgs.jq pkgs.bluez pkgs.coreutils ];
    text = ''
      export PATH="${scriptsDir}:${config.home.homeDirectory}/.nix-profile/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:$PATH"
      status="''${XDG_CACHE_HOME:-$HOME/.cache}/waybar/jbl-speaker/status.json"
      [[ -f "$status" ]] || exit 0
      mac=$(jq -r '.mac // empty' "$status" 2>/dev/null || true)
      [[ -n "$mac" ]] || exit 0
      exec ${scriptsDir}/bt-device-probe.sh jbl-merge "$mac"
    '';
  };

  # flock serialises the timer poll against the connect-event poll
  # bt-device-probe.sh fires -- two concurrent BLE sessions to one speaker
  # bounce the connection (same failure the mug hit; see ember-mug.nix).
  pollScript = pkgs.writeShellScriptBin "jbl-speaker-poll" ''
    lockdir="''${XDG_CACHE_HOME:-$HOME/.cache}/waybar/jbl-speaker"
    mkdir -p "$lockdir"
    exec ${pkgs.util-linux}/bin/flock -w 25 "$lockdir/poll.lock" \
      ${python}/bin/python3 ${scriptsDir}/jbl-speaker-poll.py ${namesArgs} "$@"
  '';
in
{
  options.waybar.jblSpeaker = {
    enable = lib.mkEnableOption "JBL speaker battery poller";
    names = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "JBL" "SWjbl" ];
      description = "Advertised-name substrings that identify the speaker.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pollScript ];

    systemd.user.services.jbl-speaker-poll = {
      Unit = {
        Description = "Poll JBL speaker battery into cache for waybar";
        After = [ "graphical-session.target" "bluetooth.service" ];
        PartOf = [ "graphical-session.target" ];
        ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${pollScript}/bin/jbl-speaker-poll";
        # `-`: a merge failure (e.g. no MAC learned yet) must not fail the unit.
        ExecStartPost = "-${mergeHook}/bin/jbl-speaker-merge-hook";
      };
    };

    systemd.user.timers.jbl-speaker-poll = {
      Unit.Description = "JBL speaker battery poll timer";
      Timer = {
        OnStartupSec = "15s";
        # Slower cadence on the 8GB Surface -- a BLE scan+connect every 2min is
        # more than that host wants competing with Firefox/builds for memory.
        OnUnitActiveSec = if isDesktop then "120s" else "300s";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
