{ config, pkgs, lib, ... }:
let
  isDesktop = config.myConfig.isDesktop;
  bar = if config.waybar.barName != "" then config.waybar.barName
        else if isDesktop then "rightBar" else "surfaceTopBar";

  volScript = pkgs.writeShellScriptBin "volume" ''
    exec ${pkgs.bash}/bin/bash ${config.home.homeDirectory}/.config/waybar/scripts/volume.sh "$@"
  '';
in {
  options.waybar.volume.enable = lib.mkEnableOption "volume module";

  config = lib.mkIf config.waybar.volume.enable {
    home.packages = [ volScript ];

    programs.waybar.settings.${bar}."custom/volume" = {
      exec = "${volScript}/bin/volume";
      return-type = "json";
      signal = 1;
      on-click = "${volScript}/bin/volume toggle";
      on-click-right = "${config.home.homeDirectory}/.config/waybar/scripts/volume-popup.sh";
    }
    # Surface's 3-finger tap = middle-click compositor-wide (see
    # home/niri/config.kdl.nix), so pavucontrol moves to double-click there.
    // (if isDesktop
        then { on-click-middle = "${pkgs.pavucontrol}/bin/pavucontrol"; }
        else { on-double-click-middle = "${pkgs.pavucontrol}/bin/pavucontrol"; });

    # Event-driven refresh: watches PipeWire directly for sink volume/mute
    # changes, so the module stays accurate regardless of what changed it
    # (media keys, pavucontrol, a Bluetooth remote) instead of only the
    # paths this repo explicitly signals waybar from.
    systemd.user.services.volume-watch = {
      Unit = {
        Description = "Refresh waybar volume module on PipeWire sink change";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
      };
      Service = {
        Environment = [
          "PATH=${pkgs.lib.makeBinPath [ pkgs.pipewire pkgs.jq pkgs.procps pkgs.bash ]}"
        ];
        ExecStart = "${config.home.homeDirectory}/.config/waybar/scripts/volume_watch.sh";
        Restart = "always";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
