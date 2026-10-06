{ config, pkgs, lib, ... }:

let
  isDesktop = config.myConfig.isDesktop;
  bar = if config.waybar.barName != "" then config.waybar.barName
        else if isDesktop then "rightBar" else "surfaceTopBar";

  clockScript = pkgs.writeShellScriptBin "quantum-clock" ''
    exec ${pkgs.python3}/bin/python3 ${config.home.homeDirectory}/.config/waybar/scripts/quantum_clock.py "$@"
  '';
in
{
  options.waybar.clock.enable = lib.mkEnableOption "clock module";

  config = lib.mkIf config.waybar.clock.enable {
    home.packages = [ clockScript ];

    programs.waybar.settings.${bar}."custom/clock" = {
      exec = "${clockScript}/bin/quantum-clock stream";
      return-type = "json";
      # The feed ticks itself once a second; a click only edits the mode file,
      # which the next tick picks up, so it must not respawn the process.
      exec-on-event = false;
      restart-interval = 3;
      on-click       = "${clockScript}/bin/quantum-clock next";
      on-click-right = "${pkgs.gnome-calendar}/bin/gnome-calendar";
    };
  };
}
