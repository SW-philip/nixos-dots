{ config, pkgs, lib, ... }:
let
  isDesktop = config.myConfig.isDesktop;

  # Starting the oneshot blocks until the probe finishes; the signal then re-runs the module.
  # Last line on purpose: nothing after a signal to waybar is guaranteed to run.
  refreshScript = pkgs.writeShellScriptBin "waybar-fleet-refresh" ''
    ${pkgs.systemd}/bin/systemctl --user start fleet-status.service
    ${pkgs.systemd}/bin/systemctl --user kill --kill-whom=main -s RTMIN+11 waybar.service || true
  '';

  # Close the quivr window if one is open, else open it.
  toggleScript = pkgs.writeShellScriptBin "waybar-fleet-toggle" ''
    id=$(${pkgs.niri}/bin/niri msg -j windows | ${pkgs.jq}/bin/jq -r 'map(select(.app_id == "dev.prepko.quivr")) | .[0].id // empty')
    if [ -n "$id" ]; then
      exec ${pkgs.niri}/bin/niri msg action close-window --id "$id"
    fi
    exec ${pkgs.ghostty}/bin/ghostty --class=dev.prepko.quivr -e quivr
  '';

  mod = {
    exec = "bash ${config.home.homeDirectory}/.config/waybar/scripts/fleet.sh";
    return-type = "json";
    interval = 15;
    signal = 11;
    tooltip = true;
    on-click = "${toggleScript}/bin/waybar-fleet-toggle";
    on-click-right = "${refreshScript}/bin/waybar-fleet-refresh";
  };
in {
  options.waybar.fleet.enable = lib.mkEnableOption "fleet status module";
  config = lib.mkIf config.waybar.fleet.enable {
    home.packages = [ refreshScript toggleScript ];

    programs.waybar.settings = lib.mkMerge [
      (lib.mkIf isDesktop { leftBar."custom/fleet" = mod; })
      (lib.mkIf (!isDesktop) { surfaceTopBar."custom/fleet" = mod; })
    ];
  };
}
