{ config, lib, pkgs, ... }:
let
  cfg = config.waybar.lixLogout;
in
{
  options.waybar.lixLogout = {
    enable = lib.mkEnableOption "lix-logout waybar module";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.lix-logout ];
  };
}
