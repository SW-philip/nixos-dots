{ config, pkgs, lib, ... }:

let
  isDesktop = config.myConfig.isDesktop;

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
    ./fleet.nix
    ./sync.nix
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
      # Desktop splits the surface's single bar across the two monitors:
      # media/connectivity on the left screen, the rest on the right.
      leftBar = lib.mkIf isDesktop {
        name = "top-left";
        layer = "top";
        position = "top";
        output = "DP-1";
        height = desktopBarThickness;
        modules-left   = [ ];
        modules-center = [ ];
        # sqlch leads modules-right (its outermost/left edge): the track title
        # resizes it constantly, and as the left-most right module only its own
        # left edge moves, so the rest stay pinned to the screen edge.
        modules-right  = [ "custom/sqlch" "custom/bluetooth" "custom/network" "custom/fleet" "custom/sync" "custom/kdeconnect" "custom/volume" ];
      };

      # Desktop has no battery module (charge is an eww widget).
      rightBar = lib.mkIf isDesktop {
        name = "right";
        layer = "top";
        position = "top";
        output = "DP-2";
        height = desktopBarThickness;
        # Weather follows the workspace indicator on the fixed left edge; the
        # clock stays alone in modules-center so its width swings just re-centre it.
        modules-left   = [ "custom/niri-workspace" "custom/weather" ];
        modules-center = [ "custom/clock" ];
        modules-right  = [ "custom/notification" ];
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
        modules-left   = [ "custom/niri-workspace" "custom/weather" "custom/launch-ghostty" ];
        modules-center = [ "custom/clock" ];
        # sqlch leads modules-right so its title-driven width changes only
        # push its own left edge, not volume/notification (see rightBar).
        modules-right  = [ "custom/sqlch" "custom/bluetooth" "custom/network" "custom/notification" "custom/volume" ];
        "custom/clock"       = config.programs.waybar.settings.rightBar."custom/clock" or {};
        "custom/weather"     = config.programs.waybar.settings.rightBar."custom/weather" or {};
        "custom/volume"      = config.programs.waybar.settings.leftBar."custom/volume" or {};
        "custom/sqlch"       = config.programs.waybar.settings.leftBar."custom/sqlch" or {};
        # Mouse-clickable terminal: niri keybinds don't survive the wayvnc
        # modifier-desync over VNC, but the pointer path does.
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
        modules-right  = [ "custom/sqlch" "custom/bluetooth" "custom/network" "custom/fleet" "custom/sync" "custom/notification" "custom/kdeconnect" "custom/volume" ];
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

  # DP-2 alone (streaming, or Mod+Ctrl+S): one bar carrying both screens' modules.
  xdg.configFile."waybar/config-single-dp2" = lib.mkIf isDesktop {
    text = builtins.toJSON [
      ({
        name = "single-desktop";
        layer = "top";
        position = "top";
        output = "DP-2";
        height = desktopBarThickness;
        modules-left   = [ "custom/niri-workspace" "custom/weather" ];
        modules-center = [ "custom/clock" ];
        modules-right  = [ "custom/sqlch" "custom/bluetooth" "custom/network" "custom/notification" "custom/kdeconnect" "custom/volume" ];
      }
      // lib.genAttrs [ "custom/niri-workspace" "custom/weather" "custom/clock" "custom/notification" ]
           (m: config.programs.waybar.settings.rightBar.${m} or {})
      // lib.genAttrs [ "custom/sqlch" "custom/bluetooth" "custom/network" "custom/kdeconnect" "custom/volume" ]
           (m: config.programs.waybar.settings.leftBar.${m} or {}))
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
    fleet.enable = true;
    sync.enable = true;
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
