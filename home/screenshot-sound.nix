{ config, pkgs, ... }:
let
  # niri's screenshot action has no hook; it announces the capture on its IPC
  # event stream instead.
  shutterScript = pkgs.writeShellApplication {
    name = "screenshot-sound";
    runtimeInputs = [ pkgs.niri pkgs.pipewire ];
    text = ''
      niri msg --json event-stream | while IFS= read -r line; do
        case "$line" in
          *ScreenshotCaptured*) pw-play ${../assets/sounds/shutter.wav} >/dev/null 2>&1 || true ;;
        esac
      done
    '';
  };
in
{
  systemd.user.services.screenshot-sound = {
    Unit = config.lib.niri.unit { wayland = true; } {
      Description = "Play a shutter sound when niri captures a screenshot";
    };
    Service = {
      ExecStart = "${shutterScript}/bin/screenshot-sound";
      Restart = "always";
      RestartSec = "2s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
