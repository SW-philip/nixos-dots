{ config, lib, pkgs, ... }:
let
  cfg = config.waybar.lixLogout;
  p = import ../../themes/Rose-Pine/midnight-rose/palette-midnight-rose.nix;
in
{
  options.waybar.lixLogout = {
    enable = lib.mkEnableOption "lix-logout waybar module";
    label = lib.mkOption {
      type = lib.types.str;
      default = "󰐻";
      description = "Label shown in the waybar button";
    };
    tooltip = lib.mkOption {
      type = lib.types.str;
      default = "<span foreground='${p.FIFTH}'>Lock</span><span foreground='${p.BAR}'> · </span><span foreground='${p.ROOT}'>Logout</span><span foreground='${p.BAR}'> · </span><span foreground='${p.FORTE}'>Reboot</span><span foreground='${p.BAR}'> · </span><span foreground='${p.SOTTO}'>Shutdown</span>\n<span foreground='${p.BAR}'>────────────────────</span>\n<span foreground='${p.FIFTH}'>Right-click for more.</span>";
      description = "Tooltip text on hover";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.lix-logout ];
  };
}
