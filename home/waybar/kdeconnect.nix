{ config, pkgs, lib, ... }:
let
  isDesktop = config.myConfig.isDesktop;
  bar = if config.waybar.barName != "" then config.waybar.barName
        else if isDesktop then "leftBar" else "surfaceTopBar";

  statusScript = pkgs.writeShellScriptBin "waybar-kdeconnect-status" ''
    export PATH=${lib.makeBinPath [
      pkgs.kdePackages.kdeconnect-kde pkgs.jq pkgs.systemd pkgs.gnugrep
    ]}:$PATH
    exec ${config.home.homeDirectory}/.config/waybar/scripts/kdeconnect-status.sh
  '';

  menuScript = pkgs.writeShellScriptBin "waybar-kdeconnect-menu" ''
    export PATH=${lib.makeBinPath [
      pkgs.kdePackages.kdeconnect-kde pkgs.fuzzel pkgs.libnotify pkgs.nemo
      pkgs.coreutils pkgs.gnugrep pkgs.gnused
    ]}:$PATH
    export WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-wayland-0}
    export XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    exec ${config.home.homeDirectory}/.config/waybar/scripts/kdeconnect-menu.sh
  '';

  # Left-click: the bundled Kirigami GUI. Placeholder until a custom one
  # exists — Phil intends to replace this with his own eventually.
  guiScript = pkgs.writeShellScriptBin "waybar-kdeconnect-gui" ''
    export PATH=${lib.makeBinPath [ pkgs.kdePackages.kdeconnect-kde ]}:$PATH
    exec kdeconnect-app
  '';
in {
  options.waybar.kdeconnect.enable = lib.mkEnableOption "KDE Connect status module";

  config = lib.mkIf config.waybar.kdeconnect.enable {
    home.packages = [ statusScript menuScript guiScript ];

    programs.waybar.settings.${bar}."custom/kdeconnect" = {
      exec = "${statusScript}/bin/waybar-kdeconnect-status";
      return-type = "json";
      interval = 15;
      signal = 3;
      tooltip = true;
      on-click = "${guiScript}/bin/waybar-kdeconnect-gui";
      on-click-right = "${menuScript}/bin/waybar-kdeconnect-menu";
    };
  };
}
