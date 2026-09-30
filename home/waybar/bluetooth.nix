{ config, pkgs, lib, ... }:
let
  isDesktop = config.myConfig.isDesktop;

  bluetoothScript = pkgs.writeShellScriptBin "quantum-bluetooth" ''
    export PATH=${lib.makeBinPath [ pkgs.bluez pkgs.glib pkgs.jq ]}:$PATH
    exec ${config.home.homeDirectory}/.config/waybar/scripts/quantum-bluetooth.sh
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

  # Spawns 1-2 bluetoothctl subprocesses (each with its own D-Bus init) when
  # connected — enough to be visible as a "pop in" on every cold-start (see
  # home/waybar/scripts/waybar-cache-poll). Poll it in the background instead;
  # the module's own exec becomes a cache read. The module keeps interval=1
  # for a snappy-feeling bar, but the underlying data only actually changes
  # on the poll timer's own cadence.
  cachePollScript = pkgs.writeShellScriptBin "waybar-cache-poll" (builtins.readFile ./scripts/waybar-cache-poll);
  cacheReadScript = pkgs.writeShellScriptBin "waybar-cache-read" (builtins.readFile ./scripts/waybar-cache-read);
  cacheName = "bluetooth";
  fallbackJson = builtins.toJSON { text = "…"; tooltip = "loading…"; class = "unknown"; };

  # jq swaps the rich `text` for the bare glyph `text_compact` so the top-bar
  # cluster doesn't jump when a device (with a name + battery %) connects.
  # `// .text` keeps a pre-first-poll fallback JSON valid.
  topMod = {
    "exec" = "${cacheReadScript}/bin/waybar-cache-read ${cacheName} 15 '${fallbackJson}'"
           + " | ${pkgs.jq}/bin/jq -c '.text = (.text_compact // .text)'";
    "interval" = 1;
    "return-type" = "json";
    "on-click" = "${btmenuScript}/bin/quantum-btmenu";
    "on-click-right" = "${bttoggleScript}/bin/quantum-bt-toggle";
    "tooltip" = true;
  };
in {
  options.waybar.bluetooth.enable = lib.mkEnableOption "bluetooth module";

  config = lib.mkIf config.waybar.bluetooth.enable {
    home.packages = [ bluetoothScript btmenuScript bttoggleScript btClassifyScript cachePollScript cacheReadScript ];

    systemd.user.services."waybar-${cacheName}-poll" = {
      Unit = {
        Description = "Poll bluetooth status into cache for waybar";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${cachePollScript}/bin/waybar-cache-poll ${cacheName} ${bluetoothScript}/bin/quantum-bluetooth";
      };
    };

    systemd.user.timers."waybar-${cacheName}-poll" = {
      Unit.Description = "Bluetooth status poll timer";
      Timer = {
        OnStartupSec = "5s";
        OnUnitActiveSec = "5s";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };

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
