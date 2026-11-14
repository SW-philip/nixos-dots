{ config, pkgs, lib, ... }:
let
  sysBin = "/run/current-system/sw/bin";
in {

  options.waybar.tether.enable = lib.mkEnableOption "tether (iPhone) bridge daemon";

  config = lib.mkIf config.waybar.tether.enable {
    # Wayland is only for clipboard sync.
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
