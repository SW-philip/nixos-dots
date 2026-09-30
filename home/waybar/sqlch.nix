{ config, lib, pkgs, ... }:
let
  isDesktop = config.myConfig.isDesktop;
  bar = if isDesktop then "rightBar" else "surfaceTopBar";

  scripts = ./scripts;
in {
  options.waybar.sqlch = {
    enable = lib.mkEnableOption "sqlch radio status and controls";
  };

  config = lib.mkIf config.waybar.sqlch.enable {
    programs.waybar.settings.${bar}."custom/sqlch" = {
      exec = "${scripts}/waybar-sqlch --status";
      on-click        = "sqlch-gui-toggle";
      on-scroll-up    = "${scripts}/waybar-sqlch --next  && pkill -RTMIN+8 waybar";
      on-scroll-down  = "${scripts}/waybar-sqlch --prev  && pkill -RTMIN+8 waybar";
      smooth-scrolling-threshold = 3;
      signal = 8;
      interval = 1;
      return-type = "json";
      max-length = 28;
      menu = "on-click-right";
      menu-file = "${scripts}/sqlch-menu.xml";
      menu-actions = {
        sqlch-art         = "${scripts}/waybar-sqlch --art";
        sqlch-stop        = "${scripts}/waybar-sqlch --stop  && pkill -RTMIN+8 waybar";
        sqlch-clear-cache = "${scripts}/waybar-sqlch --clear-cache && pkill -RTMIN+8 waybar";
      };
    };
  };
}
