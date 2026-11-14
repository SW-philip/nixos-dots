{ config, pkgs, lib, allThemes, ... }:
let
  l = import ../../themes/layout.nix;


  # myConfig.themes (the guest account) narrows drmis to a fixed set whose main
  # wallpapers are git-tracked, so nothing reads ~/nixos at runtime.
  only       = config.myConfig.themes;
  restricted = only != [ ];
  themes =
    let
      unknown  = lib.filter (s: !(allThemes ? ${s})) only;
      untracked = lib.filter (s: allThemes.${s}.wallpaper == null) only;
    in
    assert lib.assertMsg (unknown == [ ]) "myConfig.themes: unknown theme(s) ${toString unknown}";
    assert lib.assertMsg (untracked == [ ])
      "myConfig.themes: git add -f the main wallpaper-<slug>.png of ${toString untracked}";
    if restricted then lib.getAttrs only allThemes else allThemes;

  # ── Theme config templates ────────────────────────────────────────────────

  # Static rofi config.rasi — palette-independent; colors are imported from a
  # separate file drmis regenerates per-theme (see rofiColors below).
  rofiConfig = pkgs.writeText "rofi-config.rasi" (import ../rofi/config.nix);
  menu       = import ../rofi/menu.nix { inherit pkgs; };

  # ── Extracted theme generators ────────────────────────────────────────────
  mkSwayncCss       = import ./swaync/style.nix;
  mkGhosttyConfig   = import ../ghostty/config.nix;
  mkGhosttyCss      = import ../ghostty/style.nix;
  mkRofiColors      = import ../rofi/colors.nix;
  mkSqueekboardCss  = import ./squeekboard.nix;
  mkLixLogoutCSS    = import ../lix-logout/style.nix;
  mkUniremoteCss    = import ../uniremote/style.nix;
  mkZedTheme        = import ../zed/theme.nix;
  mkHyprlock        = import ../hyprlock/config.nix;
  mkFastfetchConfig = import ../fastfetch/config.nix;
  mkFastfetchLogo   = import ../fastfetch/logo.nix;
  mkNixMark         = import ../nix-mark/mark.nix;

  # ── Utility scripts ────────────────────────────────────────────────────────
  # surface (8 GB) keeps the still pit
  s = import ./scripts.nix { inherit pkgs lib; animatePit = config.myConfig.isDesktop; };

  # Desktop audio routing follows the display (see kanshi profiles below).
  # tvCriteria is the TV's EDID identity from `niri msg outputs` — matching the
  # connector (HDMI-A-1) instead would fire for anything in that port.
  tvCriteria = "Samsung Electric Company SAMSUNG 0x01000E00";
  hdmiSink   = "alsa_output.pci-0000_01_00.1.hdmi-stereo";
  spdifSink  = "alsa_output.pci-0000_00_1f.3.iec958-stereo";

  # Mod+B / surface MouseMiddle / TV hamburger — toggles the eww notif-center
  # (notif-center-toggle, installed by home/eww). Script name kept from the
  # swaync days; the binds spawn it by this derivation.
  sidebarToggleBin = pkgs.writeShellScript "swaync-toggle" ''
    exec notif-center-toggle
  '';

  lockScreenBin = config.myConfig.lockScreenScript;

  home = config.home.homeDirectory;

  # ── Per-theme derivations — generated from allThemes ─────────────────────
  themeConfigs = lib.mapAttrs (slug: t:
    let
      wallpaperFallback = if restricted then t.wallpaper
                          else if t.isLight then "${home}/Images/rothkos_dawn_tall.png"
                          else "${home}/Images/rothkos_moon_tall.png";
      # wallpaper-*.png files are gitignored so builtins.readDir never sees them;
      # record the live FS dir so apply-theme can find them at runtime instead.
      wallpaperLiveDir  = if restricted then t.dir
                          else "${home}/nixos/themes/${t.family}/${builtins.baseNameOf t.dir}";
      # pandora config still needs a path baked in — use fallback since PNGs aren't in store
      pandoraWallpaper  = wallpaperFallback;
    in {
      swayncCss      = pkgs.writeText "swaync-style-${slug}.css"        (mkSwayncCss     { p = t.palette; inherit l; });
      # runCommand, not writeText: emit_colors.py does CIE76 ΔE math to pick the bar
      # colours per theme (a fixed accent pair goes invisible where harmonize_accents collapses them).
      ewwScss        = pkgs.runCommand "eww-colors-${slug}.scss" { } ''
        cp ${../eww/emit_colors.py} emit_colors.py
        cp ${../../scripts/theme_lib/colormath.py} colormath.py
        ${pkgs.python3}/bin/python3 emit_colors.py \
          "${t.palette.STAGE}" "${t.palette.SCORE}" "${t.palette.REST}" "${t.palette.LYRIC}" \
          "${t.palette.MUTE}" "${t.palette.SOTTO}" "${t.palette.FIFTH}" "${t.palette.FERMATA}" \
          "${t.palette.PIANO}" "${t.palette.SEVENTH}" "${t.palette.FORTE}" "${t.palette.ROOT}" \
          "${t.palette.STAFF}" "${t.palette.WING}" "${t.palette.STAFF_A_DROP}" > $out
      '';
      niriKdl        = pkgs.writeText "niri-config-${slug}.kdl"         (import ./config.kdl.nix { p = t.palette; inherit l; cursorSize = if config.myConfig.hiDpi then 48 else 24; isDesktop = config.myConfig.isDesktop; hasTouch = config.myConfig.hasTouch; toggleOskBin = "${s.toggleOsk}/bin/toggle-osk"; launcherBin = "${s.launcher}/bin/launcher"; inherit sidebarToggleBin lockScreenBin; });
      waybarCss      = pkgs.writeText "waybar-style-${slug}.css"        (import ../waybar/style.nix { p = t.palette; inherit l; });
      waybarSh       = pkgs.writeText "waybar-palette-${slug}.sh"       t.shContent;
      nemoCss        = pkgs.writeText "nemo-gtk3-${slug}.css"           (import ../nemo/gtk3.css.nix t.palette);
      squeekboardCss = pkgs.writeText "squeekboard-gtk-${slug}.css"     (mkSqueekboardCss { p = t.palette; });
      rofiColors     = pkgs.writeText "rofi-colors-${slug}.rasi"        (mkRofiColors    { p = t.palette; inherit lib; });
      lixLogoutCss   = pkgs.writeText "lix-logout-style-${slug}.css"    (mkLixLogoutCSS  { p = t.palette; inherit l; });
      uniremoteCss   = pkgs.writeText "uniremote-style-${slug}.css"     (mkUniremoteCss  { p = t.palette; });
      ghostty        = pkgs.writeText "ghostty-config-${slug}"          (mkGhosttyConfig { p = t.palette; });
      ghosttyCss     = pkgs.writeText "ghostty-gtk-${slug}.css"         (mkGhosttyCss    { p = t.palette; });
      tmuxTheme      = pkgs.writeText "tmux-theme-${slug}.conf"         (import ../tmux/theme.nix { p = t.palette; });
      digikamColors  = pkgs.writeText "digikam-${slug}.colors"          (import ../digikam/colors.nix { p = t.palette; });
      hyprlockConf   = pkgs.writeText "hyprlock-${slug}.conf"           (mkHyprlock      { p = t.palette; inherit l config lib; });
      firefoxCss     = pkgs.writeText "firefox-chrome-${slug}.css"      (import ../firefox/userChrome.css.nix  t.palette);
      userContentCss = pkgs.writeText "firefox-content-${slug}.css"     (import ../firefox/userContent.css.nix t.palette);
      pandora        = pkgs.writeText "pandora-${slug}.kdl"             (mkPandoraCfg pandoraWallpaper);
      inherit wallpaperFallback wallpaperLiveDir;
      fastfetchLogo   = mkFastfetchLogo   { inherit t pkgs lib; };
      nixMark         = mkNixMark        { inherit t pkgs lib; };
      fastfetchConfig = pkgs.writeText "fastfetch-config-${slug}.jsonc" (mkFastfetchConfig { inherit t config pkgs; });
      fastfetchConfigSsh = pkgs.writeText "fastfetch-config-ssh-${slug}.jsonc" (mkFastfetchConfig { inherit t config pkgs; ssh = true; });
      zedTheme        = pkgs.writeText "zed-theme-${slug}.json"         (builtins.toJSON (mkZedTheme { inherit t; }));
      startpageCss   = pkgs.writeText "startpage-palette-${slug}.css" (import ../startpage/palette.css.nix t.palette);
      isLight         = t.isLight;
      pair            = t.palette.PAIR or null;
    }
  ) themes;

  mkPandoraCfg = wallpaper:
    if config.myConfig.isDesktop then ''
      output "DP-3" {
          image "${wallpaper}"
          mode "scroll-vertical"
      }
      output "DP-2" {
          image "${wallpaper}"
          mode "scroll-vertical"
      }
      animation {}
    '' else ''
      output "eDP-1" {
          image "${wallpaper}"
          mode "static"
      }
      animation {}
    '';

  # Where each per-theme rendered file lands, relative to $HOME. A new
  # deployable file is one entry here plus its themeConfigs key; drmis needs
  # no change. mode: copy = real file, link = symlink into the store.
  themeTargets =
    let
      copy = dest: { inherit dest; mode = "copy"; };
      link = dest: { inherit dest; mode = "link"; };
    in {
      swayncCss          = copy ".config/swaync/style.css";
      ewwScss            = copy ".config/eww/colors.scss";
      niriKdl            = copy ".config/niri/config.kdl";
      waybarCss          = copy ".config/waybar/style.css";
      waybarSh           = copy ".config/waybar/palette.sh";
      nemoCss            = copy ".config/gtk-3.0/gtk.css";
      squeekboardCss     = copy ".config/squeekboard-gtk/gtk-3.0/gtk.css";
      rofiColors         = copy ".config/rofi/colors.rasi";
      lixLogoutCss       = copy ".config/lix-logout/style.css";
      uniremoteCss       = copy ".config/uniremote/style.css";
      ghostty            = copy ".config/ghostty/config";
      ghosttyCss         = copy ".config/ghostty/ghostty.css";
      tmuxTheme          = copy ".config/tmux/theme.conf";
      digikamColors      = copy ".local/share/digikam/colorschemes/drmis.colors";
      hyprlockConf       = copy ".config/hypr/hyprlock.conf";
      fastfetchLogo      = link ".local/share/fastfetch/logo.png";
      nixMark            = link ".local/state/nix-mark-img";
      fastfetchConfig    = copy ".config/fastfetch/config.jsonc";
      fastfetchConfigSsh = copy ".config/fastfetch/config-ssh.jsonc";
      zedTheme           = copy ".config/zed/themes/drmis.json";
      startpageCss       = copy ".local/share/startpage/palette.css";
    };

  # themeConfigs keys that are not table-deployed: drmis reads them directly
  # (firefox's two files go per profile) or they are baked elsewhere (pandora).
  themeDataKeys = [
    "firefoxCss" "userContentCss" "pandora"
    "wallpaperFallback" "wallpaperLiveDir" "isLight" "pair"
  ];

  # Derived from themeConfigs so a new per-theme key can't be forgotten here.
  # toJSON turns each derivation into its store path; pandora is baked into
  # config, not read by drmis. Every themeConfigs key must be a table target or
  # a listed data key, and every target must exist in themeConfigs.
  themeMapJson =
    let
      sample   = lib.head (lib.attrValues themeConfigs);
      known    = lib.attrNames themeTargets ++ themeDataKeys;
      unknown  = lib.subtractLists known (lib.attrNames sample);
      dests    = lib.mapAttrsToList (_: t: t.dest) themeTargets;
      # PAIR is "the next theme in my group": following it from any theme must
      # come back to that theme through themes that exist (a closed cycle).
      pairCloses = s:
        let
          limit = lib.length (lib.attrNames allThemes);
          go = n: x:
            let y = allThemes.${x}.palette.PAIR or null; in
            if n > limit || y == null || !(allThemes ? ${y}) then false
            else if y == s then true
            else go (n + 1) y;
        in go 1 s;
      badPairs = lib.filter (s: (allThemes.${s}.palette.PAIR or null) != null && !(pairCloses s))
        (lib.attrNames allThemes);
    in
    assert lib.assertMsg (unknown == [])
      "themeConfigs keys with no themeTargets entry or themeDataKeys listing: ${toString unknown}";
    assert lib.assertMsg (lib.unique dests == dests)
      "themeTargets has duplicate dest paths";
    assert lib.assertMsg (badPairs == [])
      "themes whose PAIR chain does not return to them: ${toString badPairs}";
    pkgs.writeText "drmis-theme-map.json" (builtins.toJSON {
      _meta  = {};
      themes = lib.mapAttrs (_: cfgs:
        removeAttrs cfgs ([ "pandora" ] ++ lib.attrNames themeTargets) // {
          files = lib.mapAttrs (key: tgt: tgt // { src = cfgs.${key}; }) themeTargets;
        }) themeConfigs;
    });

  drmisPython = pkgs.python3.withPackages (ps: [ ps.rich ps.readchar ps.pillow ]);

  # A directory, not a single file: drmis.py is the core and drmis_tui.py is
  # imported lazily. @THEME_MAP_PATH@ is substituted into the core only.
  drmisSrc = pkgs.runCommand "drmis-src" { } ''
    mkdir $out
    substitute ${./drmis.py} $out/drmis.py --replace-fail @THEME_MAP_PATH@ ${themeMapJson}
    cp ${./drmis_tui.py} $out/drmis_tui.py
  '';

  drmis = pkgs.writeShellScriptBin "drmis" ''
    export PATH="${lib.makeBinPath [ pkgs.resvg pkgs.theme-fade ]}:$PATH"
    exec ${drmisPython}/bin/python3 -c 'import sys; sys.path.insert(0, "${drmisSrc}"); import drmis; drmis.main()' "$@"
  '';

  # What a restricted account gets on its PATH: the authoring commands (pick,
  # regen, get) all need ~/nixos.
  drmisCmd = if !restricted then drmis else pkgs.writeShellScriptBin "drmis" ''
    case "''${1:-}" in
      set|let) exec ${drmis}/bin/drmis "$@" ;;
      *) echo "drmis: this account has 'drmis set <theme>' and 'drmis let' only. Themes: ${toString only}" >&2
         exit 2 ;;
    esac
  '';

  # A fresh restricted home has no theme state, and `drmis let` exits 1 on an
  # unknown (empty) slug: start it on the first allowed theme.
  seedTheme = lib.optionalString restricted ''
    _st="$HOME/.local/state/theme"
    case " ${toString only} " in
      *" $(cat "$_st" 2>/dev/null) "*) ;;
      *) mkdir -p "''${_st%/*}"; printf '%s' ${lib.head only} > "$_st" ;;
    esac
  '';

in
{

  myConfig.sidebarToggleScript = sidebarToggleBin;
  myConfig.drmisBin = "${drmisCmd}/bin/drmis";

  home.activation.applyTheme = lib.hm.dag.entryAfter ["writeBoundary"] (seedTheme + ''
    $DRY_RUN_CMD ${drmis}/bin/drmis let
    ${pkgs.niri}/bin/niri msg action load-config-file 2>/dev/null || true
  '');

  # Workspace-tier wallpaper: an awww daemon in its own namespace (surface
  # `awww-daemoncard`, no backdrop rule, so it lives inside each workspace).
  # Desktop auto-login (hosts/desktop/config.nix) drops a flag file; lock once
  # on that first session so streaming/auto-login never leaves it unlocked.
  systemd.user.services.autologin-lock = {
    Unit = config.lib.niri.unit { wayland = true; } {
      Description = "Lock the auto-logged-in session";
    };
    Service = {
      ExecStart = "${pkgs.writeShellScript "autologin-lock" ''
        flag="$XDG_RUNTIME_DIR/autologin-lock"
        [ -e "$flag" ] || exit 0
        rm -f "$flag"
        exec ${lockScreenBin}
      ''}";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.wallpaper-card = {
    Unit = config.lib.niri.unit { wayland = true; } {
      Description = "awww daemon: workspace-tier wallpaper";
      StartLimitIntervalSec = 0;
    };
    Service = {
      ExecStart = "${pkgs.awww}/bin/awww-daemon --namespace card";
      # The daemon runs `sh -c "exec awww restore"` when an output returns; without
      # awww on PATH that output stays black (color 000000) until the next `awww img`.
      Environment = "PATH=${lib.makeBinPath [ pkgs.awww pkgs.bash ]}";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.wallpaper-follow = {
    Unit = config.lib.niri.unit { wayland = true; } {
      Description = "wallpaper-follow: blob layout per focused workspace";
      After = [ "wallpaper-card.service" ];
      # drmis restarts wallpaper-card on a theme switch; follow re-reads the pointer on restart
      PartOf = [ "wallpaper-card.service" ];
      StartLimitIntervalSec = 0;
    };
    Service = {
      ExecStart = "${s.wallpaperFollow}/bin/wallpaper-follow";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Resident because GTK4 start-up takes >1s: a per-fade spawn lands after the change it should hide.
  systemd.user.services.theme-fade = {
    Unit = config.lib.niri.unit { wayland = true; } {
      Description = "theme-fade: full-screen dip overlay daemon";
    };
    Service = {
      ExecStart = "${pkgs.theme-fade}/bin/theme-fade daemon";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.wallpaper-pit = {
    Unit = {
      Description = "overview pit backdrop (pit-fall, or swaybg)";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      # drmis restarts this on every theme switch; systemd's default
      # 5-starts/10s crash-loop guard has nothing to protect here and
      # otherwise wedges the wallpaper (silently, since drmis discards
      # systemctl's stderr) after a handful of switches in quick succession.
      StartLimitIntervalSec = 0;
    };
    Service = {
      ExecStart = "${s.pitLauncher}";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  home.packages = [
    pkgs.swaybg pkgs.rofi menu s.toggleDisplayMode s.surfaceMode drmisCmd s.mprisWatch s.toggleOsk s.launcher
    pkgs.satty pkgs.losslesscut-bin s.shootAnnotate s.screenRecordToggle
  ];

  xdg.configFile."rofi/config.rasi"   = { source = rofiConfig; force = true; };

  xdg.configFile."xdg-desktop-portal/niri-portals.conf".text = ''
    [preferred]
    default=gtk
    org.freedesktop.impl.portal.FileChooser=gtk
    org.freedesktop.impl.portal.Access=gtk
    org.freedesktop.impl.portal.Notification=gtk
    org.freedesktop.impl.portal.Secret=gnome-keyring
    org.freedesktop.impl.portal.Settings=gtk
  '';

  xdg.configFile."autostart/blueman.desktop".text = "[Desktop Entry]\nHidden=true\n";
  xdg.configFile."autostart/nm-applet.desktop".text = "[Desktop Entry]\nHidden=true\n";

  services.kanshi = {
    enable = true;
    settings = [
      { profile = {
          name = "desktop-dual";
          outputs = [
            { criteria = "DP-3"; status = "enable"; mode = "1920x1080@60.000"; position = "0,0"; scale = 1.25; }
            { criteria = "DP-2"; status = "enable"; mode = "1920x1080@60.000"; position = "1536,0"; scale = 1.25; }
          ];
          exec = [ "${s.setWaybarMode} dual" "${s.setDefaultSink} ${spdifSink}" "${s.setBridgeEdge} DP-3" ];
        };
      }
      { profile = {
          name = "desktop-solo";
          outputs = [
            { criteria = "DP-3"; status = "enable"; mode = "1920x1080@60.000"; position = "0,0"; scale = 1.25; }
            { criteria = "DP-2"; status = "disable"; }
          ];
          exec = [ "${s.setWaybarMode} dual" "${s.setDefaultSink} ${spdifSink}" "${s.setBridgeEdge} DP-3" ];
        };
      }
      { profile = {
          name = "desktop-single";
          outputs = [
            { criteria = "DP-3"; status = "enable"; mode = "1920x1080@60.000"; position = "0,0"; scale = 1.25; }
          ];
          exec = [ "${s.setWaybarMode} dual" "${s.setDefaultSink} ${spdifSink}" "${s.setBridgeEdge} DP-3" ];
        };
      }
      { profile = {
          name = "desktop-single-dp2";
          outputs = [
            { criteria = "DP-3"; status = "disable"; }
            { criteria = "DP-2"; status = "enable"; mode = "1920x1080@60.000"; position = "0,0"; scale = 1.25; }
          ];
          exec = [ "${s.setWaybarMode} single-dp2" "${s.setDefaultSink} ${spdifSink}" "${s.setBridgeEdge} DP-2" ];
        };
      }
      { profile = {
          name = "desktop-stream";
          # Sunshine's prep-cmd switches here while Moonlight streams DP-2 to the
          # TV (modules/sunshine.nix). The 1080p capture is blown up to a 65" panel
          # viewed from a couch, so it gets a bigger scale than the desk profiles.
          outputs = [
            { criteria = "DP-3"; status = "disable"; }
            { criteria = "DP-2"; status = "enable"; mode = "1920x1080@60.000"; position = "0,0"; scale = 1.75; }
          ];
          # No setDefaultSink: Sunshine owns the default sink for the stream, and
          # forcing the undriven S/PDIF port here stalls the graph clock.
          exec = [ "${s.setWaybarMode} single-dp2" "${s.setBridgeEdge} DP-2" ];
        };
      }
      { profile = {
          name = "desktop-tv";
          # Only HDMI-A-1 (the living-room TV) connected — couch mode. Mirrors
          # the `output "HDMI-A-1"` block in config.kdl.nix; the exec routes
          # audio out the TV's own HDMI sink and reverts on unplug.
          outputs = [
            { criteria = tvCriteria; status = "enable"; mode = "1920x1080@60.000"; position = "0,0"; scale = 1.5; }
          ];
          exec = [ "${s.setWaybarMode} dual" "${s.setDefaultSink} ${hdmiSink}" "${s.setBridgeEdge} HDMI-A-1" ];
        };
      }
      { profile = {
          name = "surface";
          outputs = [
            { criteria = "eDP-1"; status = "enable"; mode = "2736x1824@60.000"; scale = 2.0; }
          ];
          # kanshi re-applies 2.0 at login even if the cover is already detached.
          exec = [ "${s.surfaceScale}/bin/surface-scale" ];
        };
      }
    ];
  };

  systemd.user.services.kanshi.Unit.ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
  systemd.user.services.kanshi.Service.RestartSec = "2s";

}
