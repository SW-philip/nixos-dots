{ config, pkgs, lib, ... }:
let
  isDesktop = config.myConfig.isDesktop;

  # gdbus = event source, busctl = one GetManagedObjects per change (see
  # scripts/bluetooth_status.py).
  bluetoothScript = pkgs.writeShellScriptBin "quantum-bluetooth" ''
    export PATH=${lib.makeBinPath [ pkgs.glib pkgs.systemd ]}:$PATH
    exec ${pkgs.python3}/bin/python3 ${config.home.homeDirectory}/.config/waybar/scripts/bluetooth_status.py "$@"
  '';

  btmenuScript = pkgs.writeShellScriptBin "quantum-btmenu" ''
    export PATH=${lib.makeBinPath [
      pkgs.fuzzel pkgs.bluez pkgs.glib pkgs.jq pkgs.libnotify pkgs.wireplumber pkgs.coreutils pkgs.gnused pkgs.gawk
    ]}:$PATH

    export WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-wayland-0}
    export XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

    exec ${config.home.homeDirectory}/.config/waybar/scripts/quantum-btmenu.sh
  '';

  bttoggleScript = pkgs.writeShellScriptBin "quantum-bt-toggle" ''
    export PATH=${lib.makeBinPath [ pkgs.bluez pkgs.glib ]}:$PATH
    exec ${config.home.homeDirectory}/.config/waybar/scripts/quantum-bt-toggle.sh
  '';

  btClassifyScript = pkgs.writeShellScriptBin "bt-classify" ''
    export PATH=${lib.makeBinPath [ pkgs.bluez pkgs.jq pkgs.pipewire ]}:$PATH
    exec ${config.home.homeDirectory}/.config/waybar/scripts/bt-classify.sh "$@"
  '';

  # One streaming process per bar, driven by BlueZ D-Bus signals; it emits the
  # bare glyph as `text` so the top-bar cluster doesn't jump when a device
  # (with a name + battery %) connects.
  topMod = {
    "exec" = "${bluetoothScript}/bin/quantum-bluetooth stream";
    "exec-on-event" = false;
    "restart-interval" = 3;
    "return-type" = "json";
    "on-click" = "${btmenuScript}/bin/quantum-btmenu";
    "on-click-right" = "${bttoggleScript}/bin/quantum-bt-toggle";
    "tooltip" = true;
  };
in {
  options.waybar.bluetooth.enable = lib.mkEnableOption "bluetooth module";

  config = lib.mkIf config.waybar.bluetooth.enable {
    home.packages = [ bluetoothScript btmenuScript bttoggleScript btClassifyScript ];

    programs.waybar.settings = lib.mkMerge [
      (lib.mkIf isDesktop {
        leftBar."custom/bluetooth"  = topMod;
        rightBar."custom/bluetooth" = topMod;
        tvTopBar."custom/bluetooth" = topMod;
      })
      (lib.mkIf (!isDesktop) {
        surfaceTopBar."custom/bluetooth" = topMod;
      })
    ];
  };
}
