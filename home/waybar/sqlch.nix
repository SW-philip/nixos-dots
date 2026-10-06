{ config, lib, pkgs, ... }:
let
  isDesktop = config.myConfig.isDesktop;
  bar = if isDesktop then "leftBar" else "surfaceTopBar";

  # Single files, not the whole scripts dir: interpolating ./scripts would make
  # every unrelated script edit change this module's config and restart waybar.
  sqlchBin = ./scripts/waybar-sqlch;
in {
  options.waybar.sqlch = {
    enable = lib.mkEnableOption "sqlch radio status and controls";
  };

  config = lib.mkIf config.waybar.sqlch.enable {
    programs.waybar.settings.${bar}."custom/sqlch" = {
      exec = "${sqlchBin} --stream";
      # Self-ticking feed: clicks/scrolls must not respawn it, and
      # restart-interval brings it back after a palette-change exit.
      exec-on-event = false;
      restart-interval = 3;
      on-click        = "sqlch-gui-toggle";
      on-scroll-up    = "${sqlchBin} --next";
      on-scroll-down  = "${sqlchBin} --prev";
      smooth-scrolling-threshold = 3;
      return-type = "json";
      max-length = 28;
      menu = "on-click-right";
      menu-file = "${./scripts/sqlch-menu.xml}";
      menu-actions = {
        sqlch-art         = "${sqlchBin} --art";
        sqlch-stop        = "${sqlchBin} --stop";
        sqlch-clear-cache = "${sqlchBin} --clear-cache";
      };
    };
  };
}
