{ config, pkgs, lib, ... }:
let
  isDesktop = config.myConfig.isDesktop;

  # sync-conflicts is on waybar's PATH (home profile); hold the terminal open to read the list
  mod = {
    exec = "bash ${config.home.homeDirectory}/.config/waybar/scripts/sync.sh";
    return-type = "json";
    interval = 30;
    tooltip = true;
    on-click = "${pkgs.ghostty}/bin/ghostty -e sh -c 'sync-conflicts; echo; read -r _'";
  };
in {
  options.waybar.sync.enable = lib.mkEnableOption "syncthing status module";
  config = lib.mkIf config.waybar.sync.enable {
    programs.waybar.settings = lib.mkMerge [
      (lib.mkIf isDesktop { leftBar."custom/sync" = mod; })
      (lib.mkIf (!isDesktop) { surfaceTopBar."custom/sync" = mod; })
    ];
  };
}
