{ config, pkgs, lib, ... }:

let
  # Desktop has no battery; its charge readout is an eww COMMON widget. Surface's
  # battery sits on the horizontal top bar, left of the workspace pill — a
  # single-line label.
  batteryScript = pkgs.writeShellScriptBin "battery" ''
    exec ${pkgs.bash}/bin/bash ${config.home.homeDirectory}/.config/waybar/scripts/battery.sh "$@"
  '';
in
{
  options.waybar.battery.enable = lib.mkEnableOption "battery module";

  config = lib.mkIf (config.waybar.battery.enable && !config.myConfig.isDesktop) {
    home.packages = [ batteryScript ];

    programs.waybar.settings.surfaceTopBar."custom/battery" = {
      exec = "${batteryScript}/bin/battery";
      return-type = "json";
      interval = 30;
      tooltip = true;
      on-click = "";
      format = "{}";
    };
  };
}
