{ config, pkgs, lib, ... }:
let
  isDesktop = config.myConfig.isDesktop;

  netstatusScript = pkgs.writeShellScriptBin "netstatus" ''
    exec ${pkgs.bash}/bin/bash ${config.home.homeDirectory}/.config/waybar/scripts/netstatus.sh "$@"
  '';

  wifimenuScript = pkgs.writeShellScriptBin "quantum-wifimenu" ''
    export PATH=${lib.makeBinPath [
      pkgs.fuzzel pkgs.networkmanager pkgs.libnotify pkgs.coreutils pkgs.gnused pkgs.gawk pkgs.bash
    ]}:$PATH

    export WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-wayland-0}
    export XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

    exec ${config.home.homeDirectory}/.config/waybar/scripts/quantum-wifimenu.sh
  '';

  wifiRescanScript = pkgs.writeShellScriptBin "quantum-wifi-rescan" ''
    exec ${pkgs.networkmanager}/bin/nmcli dev wifi rescan
  '';

  # netstatus.sh's get_speed() sleeps a full second to sample throughput —
  # the single biggest contributor to the module's "pop in as it loads"
  # cold-start (see home/waybar/scripts/waybar-cache-poll). Poll it in the
  # background instead; the module's own exec becomes a cache read.
  cachePollScript = pkgs.writeShellScriptBin "waybar-cache-poll" (builtins.readFile ./scripts/waybar-cache-poll);
  cacheReadScript = pkgs.writeShellScriptBin "waybar-cache-read" (builtins.readFile ./scripts/waybar-cache-read);
  cacheName = "network";
  fallbackJson = builtins.toJSON { text = "󰖪"; tooltip = "loading…"; class = "unknown"; };

  # See bluetooth.nix: shared cache, jq swaps in the bare glyph for the top bar.
  topMod = {
    exec = "${cacheReadScript}/bin/waybar-cache-read ${cacheName} 90 '${fallbackJson}'"
         + " | ${pkgs.jq}/bin/jq -c '.text = (.text_compact // .text)'";
    return-type = "json";
    interval = 5;
    tooltip = true;
    on-click = "${wifimenuScript}/bin/quantum-wifimenu";
    on-click-right = "bash ${config.home.homeDirectory}/.config/waybar/scripts/vpn-toggle.sh";
  };
in {
  options.waybar.netstatus.enable = lib.mkEnableOption "netstatus module";
  config = lib.mkIf config.waybar.netstatus.enable {
    home.packages = [ netstatusScript wifimenuScript wifiRescanScript cachePollScript cacheReadScript ];

    systemd.user.services.quantum-wifi-rescan = {
      Unit = {
        Description = "Refresh NetworkManager WiFi scan cache";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${wifiRescanScript}/bin/quantum-wifi-rescan";
      };
    };

    systemd.user.timers.quantum-wifi-rescan = {
      Unit.Description = "Periodic WiFi rescan to keep the menu list fresh";
      Timer = {
        OnBootSec = "1min";
        OnUnitActiveSec = "3min";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };

    systemd.user.services."waybar-${cacheName}-poll" = {
      Unit = {
        Description = "Poll network status into cache for waybar";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${cachePollScript}/bin/waybar-cache-poll ${cacheName} ${netstatusScript}/bin/netstatus";
      };
    };

    systemd.user.timers."waybar-${cacheName}-poll" = {
      Unit.Description = "Network status poll timer";
      Timer = {
        OnStartupSec = "5s";
        OnUnitActiveSec = "30s";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };

    programs.waybar.settings = lib.mkMerge [
      (lib.mkIf isDesktop {
        leftBar."custom/network"  = topMod;
        rightBar."custom/network" = topMod;
        tvTopBar."custom/network" = topMod;
      })
      (lib.mkIf (!isDesktop) {
        surfaceTopBar."custom/network" = topMod;
      })
    ];
  };
}
