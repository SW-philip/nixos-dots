{ config, pkgs, lib, ... }:
let
  isDesktop = config.myConfig.isDesktop;
  bar = if config.waybar.barName != "" then config.waybar.barName
        else if isDesktop then "leftBar" else "surfaceTopBar";

  volScript = pkgs.writeShellScriptBin "volume" ''
    export PATH="${lib.makeBinPath [ pkgs.pipewire pkgs.wireplumber pkgs.systemd ]}:$PATH"
    exec ${pkgs.python3}/bin/python3 ${config.home.homeDirectory}/.config/waybar/scripts/volume.py "$@"
  '';
in {
  options.waybar.volume.enable = lib.mkEnableOption "volume module";

  config = lib.mkIf config.waybar.volume.enable {
    home.packages = [ volScript ];

    programs.waybar.settings.${bar}."custom/volume" = {
      exec = "${volScript}/bin/volume stream";
      return-type = "json";
      # The feed follows PipeWire itself (media keys, pavucontrol, BT remotes),
      # so there is no signal and a click must not respawn it.
      exec-on-event = false;
      restart-interval = 3;
      on-click = "${volScript}/bin/volume toggle";
      on-click-right = "${config.home.homeDirectory}/.config/waybar/scripts/volume-popup.sh";
    }
    # Surface's 3-finger tap = middle-click compositor-wide (see
    # home/niri/config.kdl.nix), so pavucontrol moves to double-click there.
    // (if isDesktop
        then { on-click-middle = "${pkgs.pavucontrol}/bin/pavucontrol"; }
        else { on-double-click-middle = "${pkgs.pavucontrol}/bin/pavucontrol"; });
  };
}
