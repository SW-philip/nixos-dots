# System-level hardware capabilities, set once per host in hosts/<name>/config.nix.
# home-manager's myConfig.{hiDpi,onBattery} default from these via osConfig
# (modules/home-options.nix), so system and user modules can't disagree.
{ lib, ... }:
{
  options.myConfig.hiDpi = lib.mkEnableOption "a fractional-scale high-DPI internal panel";
  options.myConfig.onBattery = lib.mkEnableOption "a portable, battery-bound host";
}
