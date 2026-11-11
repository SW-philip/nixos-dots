{ config, pkgs, ... }:
let
  resourceWarn = pkgs.writeShellApplication {
    name = "resource-warn";
    runtimeInputs = [ pkgs.coreutils pkgs.gawk pkgs.libnotify pkgs.pipewire ];
    text = builtins.readFile ../scripts/resource-warn.sh;
  };
in
{
  systemd.user.services.resource-warn = {
    Unit = config.lib.niri.unit { wayland = true; } {
      Description = "Toast and chime when temperature, memory or disk I/O is under strain";
    };
    Service = {
      Environment = [ "WARN_WAV=${../assets/sounds/warning.wav}" ];
      ExecStart = "${resourceWarn}/bin/resource-warn";
      Restart = "always";
      RestartSec = "5s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
