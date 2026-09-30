{ config, pkgs, lib, ... }:

let
  isDesktop = config.myConfig.isDesktop;
  launcherBin = "${(import ../niri/scripts.nix { inherit pkgs lib; }).launcher}/bin/launcher";

  # Top-bar thickness per host.
  desktopBarThickness = 48;
  tvBarThickness       = 53;
  surfaceBarThickness  = 46;

  waybarLauncher = pkgs.writeShellScript "waybar-launcher" ''
    CFG="''${XDG_CONFIG_HOME:-$HOME/.config}/waybar"

    # Only the Rose-Pine family ships a real installed GTK theme; every other
    # drmis-picked theme (Custom, Rose-Pine, ...) has no matching gtk-4.0
    # widget theme, so leave GTK_THEME unset and let apps fall back to the
    # actual system default (dconf gtk-theme) instead of forcing a mismatched
    # one that silently breaks things like GTK4 tooltip rendering.
    case "$(cat "$HOME/.local/state/theme" 2>/dev/null)" in
      midnight-rose)    export GTK_THEME=rose-pine ;;
      indigo-rose)      export GTK_THEME=rose-pine-moon ;;
      cream-terracotta) export GTK_THEME=rose-pine-dawn ;;
    esac

    MODE=$(cat "$HOME/.local/state/waybar-mode" 2>/dev/null)
    if [ "$MODE" = "single-dp2" ]; then
      exec ${pkgs.waybar}/bin/waybar -c "$CFG/config-single-dp2"
    else
      exec ${pkgs.waybar}/bin/waybar -c "${config.xdg.configFile."waybar/config-main".source}"
    fi
  '';

in
{
  imports = [
    ./battery.nix
    ./clock.nix
    ./bluetooth.nix
    ./netstatus.nix
    ./volume.nix
    ./weather.nix
    ./sqlch.nix
    ./lix-logout.nix
    ./ember-mug.nix
    ./jbl-speaker.nix
    ./stoic.nix
    ./kdeconnect.nix
    ./niri-workspace.nix
    ./notification.nix
  ];

  programs.waybar = {
    enable = true;
    systemd.enable = true;
    settings = {
      # ── Desktop Bars ──────────────────────────────────────────────────
      leftBar = lib.mkIf isDesktop {
        name = "top-left";
        layer = "top";
        position = "top";
        output = "DP-1";
        height = desktopBarThickness;
        # Weather follows the workspace indicator on the fixed left edge —
        # its rest/forecast toggle resizes it, but there's nothing to its
        # left to get shoved. Clock stays alone in modules-center: with
        # no neighbor there, its own mode-swings just re-center it, no
        # cluster to drag sideways.
        modules-left   = [ "custom/niri-workspace" "custom/weather" ];
        modules-center = [ "custom/clock" ];
        modules-right  = [ "custom/bluetooth" "custom/network" "custom/notification" ];
      };

      rightBar = lib.mkIf isDesktop {
        name = "right";
        layer = "top";
        position = "top";
        output = "DP-2";
        height = desktopBarThickness;
        modules-left   = [ "custom/niri-workspace" ];
        modules-center = [ ];
        # sqlch leads modules-right (its outermost/left edge) rather than
        # sitting in modules-center: the track title resizes it constantly,
        # and as the left-most right module only its own left edge moves —
        # volume/notification stay pinned to the screen edge. Centered, every
        # width change re-centered it and dragged the whole module sideways.
        modules-right  = [ "custom/sqlch" "custom/bluetooth" "custom/network" "custom/notification" "custom/volume" ];
      };

      # ── TV Bar (HDMI-A-1 — 65" Samsung 4K, scale 3.0 handled by niri) ──
      tvTopBar = lib.mkIf isDesktop {
        name = "tv-top";
        layer = "top";
        position = "top";
        output = "HDMI-A-1";
        height = tvBarThickness;
        # See leftBar above — weather follows the workspace indicator, clock
        # stays alone in modules-center.
        modules-left   = [ "custom/niri-workspace" "custom/weather" "custom/launch-app" "custom/toggle-sidebar" "custom/launch-ghostty" ];
        modules-center = [ "custom/clock" ];
        # sqlch leads modules-right so its title-driven width changes only
        # push its own left edge, not volume/notification (see rightBar).
        modules-right  = [ "custom/sqlch" "custom/bluetooth" "custom/network" "custom/notification" "custom/volume" ];
        "custom/clock"       = config.programs.waybar.settings.leftBar."custom/clock" or {};
        "custom/weather"     = config.programs.waybar.settings.leftBar."custom/weather" or {};
        "custom/volume"      = config.programs.waybar.settings.rightBar."custom/volume" or {};
        "custom/sqlch"       = config.programs.waybar.settings.rightBar."custom/sqlch" or {};
        # Mouse-clickable launchers: niri keybinds don't survive the wayvnc
        # modifier-desync over VNC, but the pointer path does. the launcher reaches
        # every other app from here.
        "custom/launch-app" = {
          format = "󰀻";
          on-click = "${launcherBin}";
          tooltip-format = "App launcher";
        };
        "custom/toggle-sidebar" = {
          format = "󰍜";
          on-click = "${config.myConfig.sidebarToggleScript}";
          tooltip-format = "Toggle control center";
        };
        "custom/launch-ghostty" = {
          format = "";
          on-click = "ghostty";
          tooltip-format = "Terminal (ghostty)";
        };
      };

      # ── Surface Bars ──────────────────────────────────────────────────
      surfaceTopBar = lib.mkIf (!isDesktop) {
        name = "surface-top";
        layer = "top";
        position = "top";
        output = "eDP-1";
        height = surfaceBarThickness;
        # See leftBar above — weather follows the workspace indicator, clock
        # stays alone in modules-center. Battery leads the row (surface only —
        # desktop's charge readout is an eww widget instead, it has no battery here).
        modules-left   = [ "custom/battery" "custom/niri-workspace" "custom/weather" ];
        modules-center = [ "custom/clock" ];
        # sqlch leads modules-right so its title-driven width changes only
        # push its own left edge, not the rest of the cluster (see rightBar).
        modules-right  = [ "custom/sqlch" "custom/bluetooth" "custom/network" "custom/notification" "custom/kdeconnect" "custom/volume" ];
      };

    };
  };

  xdg.configFile."waybar/config-main".text = builtins.toJSON (
    builtins.filter (b: b != {}) [
      (config.programs.waybar.settings.leftBar or {})
      (config.programs.waybar.settings.rightBar or {})
      (config.programs.waybar.settings.tvTopBar or {})
      (config.programs.waybar.settings.surfaceTopBar or {})
    ]
  );

  xdg.configFile."waybar/config-single-dp2" = lib.mkIf isDesktop {
    text = builtins.toJSON [
      # ── Top Bar ───────────────────────────────────────────────────────
      {
        name = "single-desktop-top";
        layer = "top";
        position = "top";
        output = "DP-2";
        height = 53;
        modules-left   = [ "custom/niri-workspace" ];
        modules-center = [];
        # sqlch leads modules-right so its title-driven width changes only
        # push its own left edge, not volume/notification (see rightBar).
        modules-right  = [ "custom/sqlch" "custom/bluetooth" "custom/network" "custom/notification" "custom/volume" ];

        "custom/niri-workspace" = config.programs.waybar.settings.rightBar."custom/niri-workspace" or {};
        "custom/notification" = config.programs.waybar.settings.rightBar."custom/notification" or {};
        "custom/bluetooth" = config.programs.waybar.settings.rightBar."custom/bluetooth" or {};
        "custom/network" = config.programs.waybar.settings.rightBar."custom/network" or {};
        "custom/volume" = config.programs.waybar.settings.rightBar."custom/volume" or {};
        "custom/sqlch"  = config.programs.waybar.settings.rightBar."custom/sqlch" or {};
      }

      # ── Bottom Bar ────────────────────────────────────────────────────
      {
        name = "single-desktop-bottom";
        layer = "top";
        position = "bottom";
        output = "DP-2";
        height = 53;
        # No workspace module lives on this bar (it's on the top half of
        # this fallback layout) to anchor weather against, so this stays
        # centered as a pair — same as before the leftBar/tvTopBar/
        # surfaceTopBar rework above.
        modules-left   = [];
        modules-center = [ "custom/clock" "custom/weather" ];
        modules-right  = [ "custom/lix-logout" ];

        "custom/clock"         = config.programs.waybar.settings.leftBar."custom/clock" or {};
        "custom/weather"       = config.programs.waybar.settings.leftBar."custom/weather" or {};
        "custom/lix-logout" = {
          format = "${config.waybar.lixLogout.label}\n<span size='x-small' alpha='60%'>POWER</span>";
          justify = "center";
          tooltip-format = config.waybar.lixLogout.tooltip;
          on-click = "lix-logout-toggle";
          menu = "on-click-right";
          menu-file = "${./scripts}/lix-logout-menu.xml";
          menu-actions = {
            lix-logout-suspend   = "systemctl suspend";
            lix-logout-hibernate = "systemctl hibernate";
            lix-logout-gag-1     = "notify-send 'lix-logout' 'Nice try. 🍦'";
            lix-logout-gag-2     = "notify-send 'lix-logout' 'Self-destruct sequence initiated... just kidding.'";
          };
        };
      }
    ];
  };

  # ── Systemd Service Overrides ─────────────────────────────────────
  systemd.user.services.waybar = {
    Unit = {
      Description = lib.mkForce "Waybar status bar";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Environment = [
        "PATH=${pkgs.lib.makeBinPath [
          pkgs.bash
          pkgs.bluez
          pkgs.fuzzel
          pkgs.coreutils
          pkgs.procps
          pkgs.util-linux
          pkgs.jq
          pkgs.python3
          pkgs.gnused
          pkgs.gawk
          pkgs.gnugrep
          pkgs.findutils
        ]}:${config.home.homeDirectory}/.config/waybar/scripts:${config.home.homeDirectory}/.nix-profile/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/run/wrappers/bin"
        "XDG_CURRENT_DESKTOP=niri"
        "XDG_SESSION_TYPE=wayland"
        "GIO_USE_VFS=local"
        "G_MESSAGES_DEBUG=none"
        "DCONF_PROFILE=/dev/null"
      ];
      ExecStart = lib.mkForce "${waybarLauncher}";
      Restart = lib.mkForce "on-failure";
      RestartSec = 2;
    };
  };

  # ── File Resources ────────────────────────────────────────────────
  # Shared read-only snark pool: `<module>.<state>[]` arrays, picked with `shuf`
  # by battery.sh/netstatus.sh/protonvpn-status.sh. Separate from
  # niri-workspace-snark.json (writable per-workspace-tooltip pool, seeded once,
  # deterministic csum pick — see home/waybar/niri-workspace.nix).
  xdg.configFile."waybar/snark.json".source = ./snark.json;
  xdg.configFile."waybar/scripts" = {
    source = ./scripts;
    recursive = true;
  };
  xdg.configFile."systemd/user/waybar.service.d/session-guard.conf".text = ''
    [Unit]
    ConditionEnvironment=XDG_CURRENT_DESKTOP=niri
  '';

  # ── Module Enablement ─────────────────────────────────────────────
  waybar = {
    battery.enable = true;
    clock.enable = true;
    bluetooth.enable = true;
    netstatus.enable = true;
    volume.enable = true;
    weather.enable = true;
    sqlch.enable = true;
    lixLogout.enable = true;
    emberMug.enable = true;
    jblSpeaker.enable = true;
    stoicQuote.enable = true;
    kdeconnect.enable = true;
  };
}
