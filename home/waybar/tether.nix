{ config, pkgs, lib, ... }:
let
  bar = config.waybar.primaryBar;
  sysBin = "/run/current-system/sw/bin";

  statusScript = pkgs.writeShellScriptBin "waybar-tether-status" ''
    exec ${pkgs.python3}/bin/python3 ${./scripts/tether-status.py} "$@"
  '';
in {

  options.waybar.tether.enable = lib.mkEnableOption "tether (iPhone) status module";

  config = lib.mkIf config.waybar.tether.enable {
    home.packages = [ statusScript ];

    programs.waybar.settings.${bar}."custom/tether" = {
      exec = "${statusScript}/bin/waybar-tether-status";
      return-type = "json";
      interval = 10;
      signal = 4;
      tooltip = true;
      on-click = "${config.home.profileDirectory}/bin/parsly toggle";
    };

    # The pill must not depend on a GUI having spawned tetherd; Wayland is only for clipboard sync.
    systemd.user.services.tetherd = {
      Unit = config.lib.niri.unit { wayland = true; } {
        Description = "Tether daemon, bridging the iPhone to this computer";
        After = [ "bluetooth.target" ];
        StartLimitIntervalSec = 60;
        StartLimitBurst = 3;
      };
      Service = {
        ExecStart = "${sysBin}/tetherd";
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
