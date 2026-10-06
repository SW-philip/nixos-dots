{ config, pkgs, lib, ... }:
let
  # ── Theme auto-discovery ────────────────────────────────────────────────
  themesRoot = ../../themes;
  l          = import "${themesRoot}/layout.nix";

  allThemes =
    let
      loadTheme = family: folderName:
        let
          dir   = "${themesRoot}/${family}/${folderName}";
          files = builtins.readDir dir;

          nixName = builtins.head (builtins.attrNames (
            lib.filterAttrs (n: _: lib.hasPrefix "palette-" n && lib.hasSuffix ".nix" n) files));
          slug = lib.removeSuffix ".nix" (lib.removePrefix "palette-" nixName);

          shName = builtins.head (builtins.attrNames (
            lib.filterAttrs (n: _: lib.hasPrefix "palette-" n && lib.hasSuffix ".sh" n) files));

          wallpaper = let f = "wallpaper-${slug}.png";
                      in if files ? ${f} then "${dir}/${f}" else null;

          p = import "${dir}/${nixName}";
        in {
          inherit family slug wallpaper dir;
          palette   = p;
          shContent = builtins.readFile "${dir}/${shName}";
          isLight   = p.isLight or ((p.TEMPO or "12px") == "13px");
        };

      familyDirs = lib.filterAttrs (_: t: t == "directory") (builtins.readDir themesRoot);

      familyThemes = family:
        let themeDirs = lib.filterAttrs (_: t: t == "directory")
                          (builtins.readDir "${themesRoot}/${family}");
        in lib.mapAttrs' (folder: _:
             let t = loadTheme family folder;
             in lib.nameValuePair t.slug t
           ) themeDirs;

    in lib.foldlAttrs (acc: family: _: acc // familyThemes family) {} familyDirs;

  # ── Theme config templates ────────────────────────────────────────────────

  # Power profile has no boolean on/off, so it's a picker rather than a
  # "toggle" — same shape as vpn-toggle.sh: list the profiles
  # actually available on this host's hardware (powerprofilesctl list
  # already filters this), mark the current one, powerprofilesctl set on
  # selection instead of blind-cycling with no visible state.
  powerProfilePickerBin = pkgs.writeShellScript "swaync-power-profile-picker" ''
    current=$(powerprofilesctl get 2>/dev/null || echo "balanced")
    mapfile -t available < <(powerprofilesctl list 2>/dev/null | awk '/^[* ] ?[a-z]/ { gsub(/[* :]/, ""); print $1 }')
    ordered=(power-saver balanced performance)

    entries=()
    for p in "''${ordered[@]}"; do
      printf '%s\n' "''${available[@]}" | grep -qx "$p" || continue
      if [[ "$p" == "$current" ]]; then
        entries+=("$p  [on]")
      else
        entries+=("$p")
      fi
    done

    choice=$(printf '%s\n' "''${entries[@]}" | fuzzel --dmenu --prompt "Power Profile › " --width 300 --lines ''${#entries[@]}) || exit 0
    [[ -z "$choice" ]] && exit 0

    selected=$(echo "$choice" | sed 's/  \[on\]$//')
    [[ "$selected" == "$current" ]] && exit 0

    if powerprofilesctl set "$selected" 2>/dev/null; then
      notify-send -u low "Power Profile" "Switched to $selected" 2>/dev/null || true
    else
      notify-send -u normal "Power Profile" "Failed to set $selected — EPP locked (governor stuck?)" 2>/dev/null || true
    fi
  '';

  # Wing/ledger edge is independently switchable per slot via
  # `eww-panel-edge` (home/eww/scripts/panel-edge.sh, wired up by
  # home/eww/default.nix) but that's CLI-only — this menu is the
  # interactive front end for it. Reads state directly from the same files
  # ExecStartPost and eww-panel-edge already treat as the source of truth;
  # writes nothing itself.
  panelEdgePickerBin = pkgs.writeShellScript "swaync-panel-edge-picker" ''
    state_dir="''${EWW_PANEL_EDGE_STATE_DIR:-$HOME/.local/state}"

    read_edge() {
      cat "$state_dir/eww-panel-edge-$1" 2>/dev/null || true
    }

    labels=()
    slots=()
    edges=()

    add_row() {
      local label="$1" slot="$2" edge="$3" current="$4"
      if [[ "$edge" == "$current" ]]; then
        labels+=("$label  [on]")
      else
        labels+=("$label")
      fi
      slots+=("$slot")
      edges+=("$edge")
    }

    wing_edge=$(read_edge wing)
    ledger_edge=$(read_edge ledger)

    add_row "Wing → Left"     wing   left   "$wing_edge"
    add_row "Wing → Right"    wing   right  "$wing_edge"
    add_row "Ledger → Top"    ledger top    "$ledger_edge"
    add_row "Ledger → Bottom" ledger bottom "$ledger_edge"

    ${lib.optionalString config.myConfig.isDesktop ''
    wing_tv_edge=$(read_edge wing-tv)
    ledger_tv_edge=$(read_edge ledger-tv)
    add_row "Wing TV → Left"     wing-tv   left   "$wing_tv_edge"
    add_row "Wing TV → Right"    wing-tv   right  "$wing_tv_edge"
    add_row "Ledger TV → Top"    ledger-tv top    "$ledger_tv_edge"
    add_row "Ledger TV → Bottom" ledger-tv bottom "$ledger_tv_edge"
    ''}

    choice=$(printf '%s\n' "''${labels[@]}" | fuzzel --dmenu --prompt "Panel Edges › " --width 300 --lines ''${#labels[@]}) || exit 0
    [[ -z "$choice" ]] && exit 0

    sel_slot=""
    sel_edge=""
    for i in "''${!labels[@]}"; do
      if [[ "''${labels[$i]}" == "$choice" ]]; then
        sel_slot="''${slots[$i]}"
        sel_edge="''${edges[$i]}"
        break
      fi
    done
    [[ -z "$sel_slot" ]] && exit 0

    current="$(read_edge "$sel_slot")"
    [[ "$sel_edge" == "$current" ]] && exit 0

    if err=$(eww-panel-edge "$sel_slot" "$sel_edge" 2>&1); then
      notify-send -u low "Panel Edges" "$choice" 2>/dev/null || true
    else
      notify-send -u normal "Panel Edges" "Failed to set $choice: $err" 2>/dev/null || true
    fi
  '';

  # DND uses swaync's own native toggle/query — no custom script needed.
  # (The waybar-era dnd-toggle.sh called makoctl, a daemon this system
  # doesn't run; that button silently never worked. swaync-client -d/-D
  # is the real, working mechanism.)
  systemActions = [
    {
      label = "󰂛  Do Not Disturb";
      type = "toggle";
      command = "${pkgs.swaynotificationcenter}/bin/swaync-client -d";
      update-command = "${pkgs.swaynotificationcenter}/bin/swaync-client -D";
    }
    {
      label = "󰒲  Screen Lock";
      type = "toggle";
      command = "systemctl --user is-active --quiet hypridle.service && systemctl --user stop hypridle.service || systemctl --user start hypridle.service";
      update-command = "systemctl --user is-active --quiet hypridle.service && echo true || echo false";
    }
    {
      label = "󰌌  NiriBridge";
      type = "toggle";
      command = "systemctl --user is-active --quiet niri-bridge.service && systemctl --user stop niri-bridge.service || { systemctl --user reset-failed niri-bridge.service; systemctl --user start niri-bridge.service; }";
      update-command = "systemctl --user is-active --quiet niri-bridge.service && echo true || echo false";
    }
  ]
  ++ lib.optional (!config.myConfig.isDesktop) {
    label = "󰔃  Auto-Rotate";
    type = "toggle";
    command = "systemctl --user is-active --quiet niri-rotation.service && systemctl --user stop niri-rotation.service || systemctl --user start niri-rotation.service";
    update-command = "systemctl --user is-active --quiet niri-rotation.service && echo true || echo false";
  }
  ++ lib.optional (!config.myConfig.isDesktop) {
    label = "󰌓  On-Screen Keyboard";
    type = "toggle";
    command = "${s.toggleOsk}/bin/toggle-osk";
    update-command = "${s.toggleOsk}/bin/toggle-osk status";
  }
  ++ [
    {
      label = "󰈐  Power Profile";
      command = "${powerProfilePickerBin}";
    }
    {
      label = "󰓡  Panel Edges";
      command = "${panelEdgePickerBin}";
    }
  ];

  appearanceActions = [
    {
      label = "󰔎  Pick Theme";
      command = "ghostty --class=drmis-pick -e drmis pick";
    }
    {
      label = "Free Palestine";
      command = "drmis set free-palestine";
    }
  ];

  # quantum-bt-toggle is installed via home.packages by home/waybar/bluetooth.nix
  # (unconditionally enabled on both hosts) — referenced here by bare name since
  # swaync's systemd user service PATH already includes ~/.nix-profile/bin.
  # VPN is referenced by absolute path, matching how netstatus.nix itself calls
  # vpn-toggle.sh. Wi-Fi and Bluetooth's update-commands both read hardware
  # power state directly (nmcli/busctl) rather than shelling out to a script —
  # same inline shape as the Screen Lock/Auto-Rotate update-commands above.
  #
  # swaync runs every action through `Shell.parse_argv("/bin/sh -c \"%s\"")`
  # (functions.vala execute_command), so each string here must be a bare POSIX
  # sh snippet with NO literal double-quotes and NO wrapping `sh -c '...'` — an
  # embedded `"` collides with swaync's own `"%s"` and shreds the argv, and the
  # mangled command exits instantly, which used to trip an fd double-free in
  # execute_command and crash-loop swaync at boot. `[` not `[[` (dash), and
  # rely on the values being single tokens so `$(...)` needs no quoting.
  # BT Devices (quantum-btmenu) and full Wi-Fi network selection
  # (quantum-wifimenu) are intentionally not called from here — both stay
  # reachable via their waybar module's own on-click handler
  # (home/waybar/bluetooth.nix, home/waybar/netstatus.nix).
  connectivityActions = [
    {
      label = "󰖩  Wi-Fi";
      type = "toggle";
      command = "[ $(nmcli radio wifi) = enabled ] && nmcli radio wifi off || nmcli radio wifi on";
      update-command = "[ $(nmcli radio wifi) = enabled ] && echo true || echo false";
    }
    {
      label = "󰂯  Bluetooth";
      type = "toggle";
      command = "quantum-bt-toggle";
      update-command = "busctl get-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered 2>/dev/null | grep -q true && echo true || echo false";
    }
    {
      label = "󰖂  VPN";
      command = "bash ${config.home.homeDirectory}/.config/waybar/scripts/vpn-toggle.sh";
    }
  ];

  # Static swaync config.json — palette-independent, only style.css carries colors.
  # keyboard-shortcuts=true gives the control center exclusive keyboard focus,
  # so on surface every open/close moves text focus away and back and squeekboard
  # hides/re-shows with it. Surface runs it off (KeyboardMode.NONE); desktop keeps Esc/arrow nav.
  swayncConfig = pkgs.writeText "swaync-config.json" ''
    {
      "positionX": "right",
      "positionY": "top",
      "control-center-margin-top": 8,
      "control-center-margin-bottom": 8,
      "control-center-margin-right": 8,
      "control-center-margin-left": 0,
      "notification-icon-size": 48,
      "notification-body-image-height": 100,
      "notification-body-image-width": 200,
      "timeout": 5,
      "timeout-low": 3,
      "timeout-critical": 0,
      "fit-to-screen": true,
      "control-center-width": 360,
      "notification-window-width": 300,
      "keyboard-shortcuts": ${lib.boolToString config.myConfig.isDesktop},
      "image-visibility": "when-available",
      "transition-time": 100,
      "hide-on-clear": true,
      "hide-on-action": true,
      "notification-inline-replies": true,
      "script-fail-notify": true,
      "scripts": {},
      "notification-visibility": {},
      "widgets": ${builtins.toJSON (
        [ "title" "notifications" "label#hdr-audio" "volume" ]
        ++ lib.optional (!config.myConfig.isDesktop) "backlight"
        ++ [
          "label#hdr-connectivity" "buttons-grid#connectivity"
          "label#hdr-system" "buttons-grid#system"
          "label#hdr-appearance" "buttons-grid#appearance"
        ]
      )},
      "widget-config": {
        "title": {
          "text": "Notifications",
          "clear-all-button": true,
          "button-text": "Clear All"
        },
        "label#hdr-audio": { "text": "Audio & Display" },
        "label#hdr-connectivity": { "text": "Connectivity" },
        "label#hdr-system": { "text": "System" },
        "label#hdr-appearance": { "text": "Appearance" },
        "volume": {},
        "backlight": { "device": "intel_backlight" },
        "buttons-grid#connectivity": { "actions": ${builtins.toJSON connectivityActions} },
        "buttons-grid#system": { "actions": ${builtins.toJSON systemActions} },
        "buttons-grid#appearance": { "actions": ${builtins.toJSON appearanceActions} },
        "notifications": { "vexpand": true }
      }
    }
  '';

  # Static fuzzel.ini — palette-independent; colors are included from a
  # separate file drmis regenerates per-theme (see fuzzelColors below).
  fuzzelConfig = pkgs.writeText "fuzzel-config.ini" (import ../fuzzel/config.nix { inherit l; });

  # ── Extracted theme generators ────────────────────────────────────────────
  mkSwayncCss       = import ./swaync/style.nix;
  mkGhosttyConfig   = import ../ghostty/config.nix;
  mkGhosttyCss      = import ../ghostty/style.nix;
  mkFuzzelColors    = import ../fuzzel/colors.nix;
  mkSqueekboardCss  = import ./squeekboard.nix;
  mkLixLogoutCSS    = import ../lix-logout/style.nix;
  mkUniremoteCss    = import ../uniremote/style.nix;
  mkZedTheme        = import ../zed/theme.nix;
  mkHyprlock        = import ../hyprlock/config.nix;
  mkFastfetchConfig = import ../fastfetch/config.nix;
  mkFastfetchLogo   = import ../fastfetch/logo.nix;
  mkNixMark         = import ../nix-mark/mark.nix;

  # ── Utility scripts ────────────────────────────────────────────────────────
  s = import ./scripts.nix { inherit pkgs lib; };

  # Desktop audio routing follows the display (see kanshi profiles below).
  # tvCriteria is the TV's EDID identity from `niri msg outputs` — matching the
  # connector (HDMI-A-1) instead would fire for anything in that port.
  tvCriteria = "Samsung Electric Company SAMSUNG 0x01000E00";
  hdmiSink   = "alsa_output.pci-0000_01_00.1.hdmi-stereo";
  spdifSink  = "alsa_output.pci-0000_00_1f.3.iec958-stereo";

  sessionActions = import ./session-actions.nix { inherit pkgs lib config; };

  # Mod+B / surface MouseMiddle / TV hamburger — toggles swaync's control
  # center. (The waybar stats sidebar it used to sit beside is gone; the eww
  # status window replaces it.)
  sidebarToggleBin = pkgs.writeShellScript "swaync-toggle" ''
    exec ${pkgs.swaynotificationcenter}/bin/swaync-client -t
  '';

  # Shared with the greeter (pkgs/greeter/default.nix) — edit
  # ../../assets/snark-lines.txt to change the wording everywhere.
  snarkLinesFile = pkgs.writeText "hyprlock-snark-lines.txt" (builtins.readFile ../../assets/snark-lines.txt);

  # Picks a random line from the shared snark pool (../../assets/snark-lines.txt,
  # also read by the greeter) and substitutes it into a throwaway copy of
  # the currently-deployed hyprlock.conf (drmis-managed, never written to
  # here), then execs hyprlock against that copy. Falls back to plain
  # hyprlock whenever anything here can't be done, so a wrong password never
  # risks leaving the screen unlockable. HYPRLOCK_SNARK_DRY_RUN=1 short-
  # circuits before exec'ing hyprlock, for scripted verification.
  lockScreenBin = pkgs.writeShellScript "hyprlock-snark-launcher" ''
    snark_file="${snarkLinesFile}"
    conf="$HOME/.config/hypr/hyprlock.conf"
    tmp="''${XDG_RUNTIME_DIR:-/tmp}/hyprlock-active.conf"

    render() {
      [[ -r "$snark_file" && -r "$conf" ]] || return 1
      mapfile -t lines < "$snark_file"
      [[ ''${#lines[@]} -gt 0 ]] || return 1
      local line="''${lines[RANDOM % ''${#lines[@]}]}"
      local content
      content="$(cat "$conf")" || return 1
      content="''${content//@@SNARK@@/$line}"
      printf '%s\n' "$content" > "$tmp" 2>/dev/null
    }

    if render; then
      if [[ -n "''${HYPRLOCK_SNARK_DRY_RUN:-}" ]]; then
        echo "$tmp"
        exit 0
      fi
      exec hyprlock -c "$tmp"
    fi

    [[ -n "''${HYPRLOCK_SNARK_DRY_RUN:-}" ]] && { echo "FALLBACK"; exit 0; }
    exec hyprlock
  '';

  home = config.home.homeDirectory;

  # ── Per-theme derivations — generated from allThemes ─────────────────────
  themeConfigs = lib.mapAttrs (slug: t:
    let
      subtleBorder      = if t.isLight then "#0000000a" else "#ffffff0a";
      faintBorder       = if t.isLight then "#00000006" else "#ffffff06";
      wallpaperFallback = if t.isLight then "${home}/Images/rothkos_dawn_tall.png"
                          else "${home}/Images/rothkos_moon_tall.png";
      # wallpaper-*.png files are gitignored so builtins.readDir never sees them;
      # record the live FS dir so apply-theme can find them at runtime instead.
      wallpaperLiveDir  = "${home}/nixos/themes/${t.family}/${builtins.baseNameOf t.dir}";
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
      niriKdl        = pkgs.writeText "niri-config-${slug}.kdl"         (import ./config.kdl.nix { p = t.palette; inherit l; cursorSize = if config.myConfig.isDesktop then 24 else 48; isDesktop = config.myConfig.isDesktop; toggleOskBin = "${s.toggleOsk}/bin/toggle-osk"; launcherBin = "${s.launcher}/bin/launcher"; inherit sidebarToggleBin lockScreenBin; });
      waybarCss      = pkgs.writeText "waybar-style-${slug}.css"        (import ../waybar/style.nix { p = t.palette; inherit l; });
      waybarSh       = pkgs.writeText "waybar-palette-${slug}.sh"       t.shContent;
      nemoCss        = pkgs.writeText "nemo-gtk3-${slug}.css"           (import ../nemo/gtk3.css.nix t.palette);
      squeekboardCss = pkgs.writeText "squeekboard-gtk-${slug}.css"     (mkSqueekboardCss { p = t.palette; });
      fuzzelColors   = pkgs.writeText "fuzzel-colors-${slug}.ini"       (mkFuzzelColors  { p = t.palette; inherit lib; });
      lixLogoutCss   = pkgs.writeText "lix-logout-style-${slug}.css"    (mkLixLogoutCSS  { p = t.palette; inherit l; });
      uniremoteCss   = pkgs.writeText "uniremote-style-${slug}.css"     (mkUniremoteCss  { p = t.palette; });
      ghostty        = pkgs.writeText "ghostty-config-${slug}"          (mkGhosttyConfig { p = t.palette; });
      ghosttyCss     = pkgs.writeText "ghostty-gtk-${slug}.css"         (mkGhosttyCss    { p = t.palette; });
      tmuxTheme      = pkgs.writeText "tmux-theme-${slug}.conf"         (import ../tmux/theme.nix { p = t.palette; });
      hyprlockConf   = pkgs.writeText "hyprlock-${slug}.conf"           (mkHyprlock      { p = t.palette; inherit l config lib; });
      firefoxCss     = pkgs.writeText "firefox-chrome-${slug}.css"      (import ../firefox/userChrome.css.nix  t.palette);
      userContentCss = pkgs.writeText "firefox-content-${slug}.css"     (import ../firefox/userContent.css.nix t.palette);
      pandora        = pkgs.writeText "pandora-${slug}.kdl"             (mkPandoraCfg pandoraWallpaper);
      tuigreetTheme  = mkTuigreetTheme t.palette;
      inherit wallpaperFallback wallpaperLiveDir;
      fastfetchLogo   = mkFastfetchLogo   { inherit t pkgs lib; };
      nixMark         = mkNixMark        { inherit t pkgs lib; };
      fastfetchConfig = pkgs.writeText "fastfetch-config-${slug}.jsonc" (mkFastfetchConfig { inherit t config pkgs; });
      fastfetchConfigSsh = pkgs.writeText "fastfetch-config-ssh-${slug}.jsonc" (mkFastfetchConfig { inherit t config pkgs; ssh = true; });
      zedTheme        = pkgs.writeText "zed-theme-${slug}.json"         (builtins.toJSON (mkZedTheme { inherit t; }));
      startpageCss   = pkgs.writeText "startpage-palette-${slug}.css" (import ../startpage/palette.css.nix t.palette);
      isLight         = t.isLight;
    }
  ) allThemes;

  mkPandoraCfg = wallpaper:
    if config.myConfig.isDesktop then ''
      output "DP-1" {
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

  mkTuigreetTheme = p:
    lib.concatStringsSep ";" [
      "background=${p.HALL}"
      "container=${p.STAGE}"
      "border=${p.ROOT}"
      "text=${p.SCORE}"
      "prompt=${p.FIFTH}"
      "time=${p.PIANO}"
      "action=${p.SOTTO}"
      "button=${p.FORTE}"
      "input=${p.SCORE}"
    ];

  # Derived from themeConfigs so a new per-theme key can't be forgotten here
  # (drmis KeyErrors at runtime on a missing one). toJSON turns each
  # derivation into its store path; pandora is baked into config, not read by drmis.
  themeMapJson = pkgs.writeText "drmis-theme-map.json" (builtins.toJSON {
    _meta  = {};
    themes = lib.mapAttrs (_: cfgs: removeAttrs cfgs [ "pandora" ]) themeConfigs;
  });

  drmisPython = pkgs.python3.withPackages (ps: [ ps.rich ps.readchar ]);

  drmisPy = pkgs.writeText "drmis.py" (
    builtins.replaceStrings [ "@THEME_MAP_PATH@" ] [ "${themeMapJson}" ]
      (builtins.readFile ./drmis.py)
  );

  drmis = pkgs.writeShellScriptBin "drmis" ''
    export PATH="${lib.makeBinPath [ pkgs.resvg ]}:$PATH"
    exec ${drmisPython}/bin/python3 ${drmisPy} "$@"
  '';

in
{

  myConfig.sidebarToggleScript = sidebarToggleBin;
  myConfig.lockScreenScript = lockScreenBin;

  home.activation.applyTheme = lib.hm.dag.entryAfter ["writeBoundary"] ''
    $DRY_RUN_CMD ${drmis}/bin/drmis let
    ${pkgs.niri}/bin/niri msg action load-config-file 2>/dev/null || true
  '';

  systemd.user.services.swaybg = {
    Unit = {
      Description = "swaybg wallpaper";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      # drmis restarts this on every theme switch; systemd's default
      # 5-starts/10s crash-loop guard has nothing to protect here and
      # otherwise wedges the wallpaper (silently, since drmis discards
      # systemctl's stderr) after a handful of switches in quick succession.
      StartLimitIntervalSec = 0;
    };
    Service = {
      ExecStart = "${s.swaybgLauncher}";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  home.packages = [
    pkgs.swaybg s.toggleDisplayMode drmis s.mprisWatch s.toggleOsk s.launcher
    pkgs.satty pkgs.losslesscut-bin s.shootAnnotate s.screenRecordToggle
  ];

  xdg.configFile."swaync/config.json" = lib.mkForce { source = swayncConfig; force = true; };
  xdg.configFile."fuzzel/fuzzel.ini"  = lib.mkForce { source = fuzzelConfig; force = true; };

  # single_instance_apps: apps that restore their own windows/tabs on
  # relaunch, so niri-session-manager must not spawn a second copy on top
  # of what they self-restore.
  # app_mappings: app-id -> launch command, for apps whose saved app-id
  # doesn't match the binary that launches them (confirmed live via
  # `niri msg -j windows`, not guessed — see
  # docs/superpowers/plans/2026-07-08-niri-named-workspaces.md Task 3).
  # xournalpp mapping predates this file (previously hand-edited
  # directly in ~/.config); folded in here to keep them declarative.
  xdg.configFile."niri-session-manager/config.toml" = {
    # force: this path predates home-manager management (a hand-edited
    # file already existed on disk); without force, activation fails
    # with "Existing file would be clobbered".
    force = true;
    text = ''
      [single_instance_apps]
      apps = [
          "firefox",
          "thunderbird",
          "spotify",
      ]

      [app_mappings]
      "com.mitchellh.ghostty"            = ["ghostty"]
      "dev.zed.Zed"                      = ["zeditor"]
      "com.github.xournalpp.xournalpp"   = ["xournalpp"]
      "element"                          = ["element-desktop"]
      "org.kde.kdenlive"                 = ["kdenlive"]
      "org.kde.easyeffects"              = ["easyeffects"]
      "libreoffice-writer"               = ["libreoffice", "--writer"]
    '';
  };

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
            { criteria = "DP-1"; status = "enable"; mode = "1920x1080@60.000"; position = "0,0"; scale = 1.25; }
            { criteria = "DP-2"; status = "enable"; mode = "1920x1080@60.000"; position = "1536,0"; scale = 1.25; }
          ];
          exec = [ "${s.setWaybarMode} dual" "${s.setDefaultSink} ${spdifSink}" "${s.setBridgeEdge} DP-1" ];
        };
      }
      { profile = {
          name = "desktop-solo";
          outputs = [
            { criteria = "DP-1"; status = "enable"; mode = "1920x1080@60.000"; position = "0,0"; scale = 1.25; }
            { criteria = "DP-2"; status = "disable"; }
          ];
          exec = [ "${s.setWaybarMode} dual" "${s.setDefaultSink} ${spdifSink}" "${s.setBridgeEdge} DP-1" ];
        };
      }
      { profile = {
          name = "desktop-single";
          outputs = [
            { criteria = "DP-1"; status = "enable"; mode = "1920x1080@60.000"; position = "0,0"; scale = 1.25; }
          ];
          exec = [ "${s.setWaybarMode} dual" "${s.setDefaultSink} ${spdifSink}" "${s.setBridgeEdge} DP-1" ];
        };
      }
      { profile = {
          name = "desktop-single-dp2";
          outputs = [
            { criteria = "DP-1"; status = "disable"; }
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
            { criteria = "DP-1"; status = "disable"; }
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
        };
      }
    ];
  };

  systemd.user.services.kanshi.Unit.ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
  systemd.user.services.kanshi.Service.RestartSec = "2s";

}
