{ pkgs, lib, config, inputs, ... }:
{
  options.greetd.greeting = lib.mkOption {
    type    = lib.types.str;
    default = "Welcome.";
  };

  options.greetd.greeterPalette = lib.mkOption {
    type    = lib.types.enum [ "theme" "dsa" ];
    default = "theme";
    description = ''
      Palette for the greeter: "theme" follows the live desktop palette
      (palette.sh, same as the lock screen), "dsa" is the fixed
      cream/charcoal/rust DSA preset. tuigreet remains the last-resort
      fallback regardless of this setting -- see tuigreetLaunch below.
    '';
  };

  config =
    let
      # Fallback greeter — KEEP THIS DEFINED. To recover from a broken
      # greeter: set default_session.command =
      # "${tuigreetLaunch}" and nrs (or boot the previous generation /
      # Ctrl+Alt+F2 -> tty2 to revert).
      tuigreetLaunch = pkgs.writeShellScript "tuigreet-launch" ''
        theme=$(cat /run/tuigreet-theme 2>/dev/null)
        if [ -z "$theme" ]; then
          theme="background=#232136;border=#c4a7e7;text=#e0def4;prompt=#9ccfd8;time=#f6c177;action=#ea9a97;button=#eb6f92;container=#2a273f;input=#e0def4"
        fi
        exec ${pkgs.tuigreet}/bin/tuigreet \
          --time \
          --remember \
          --remember-session \
          --greeting "${config.greetd.greeting}" \
          --asterisks \
          --asterisks-char "•" \
          --width 80 \
          --window-padding 1 \
          --container-padding 4 \
          --prompt-padding 1 \
          --greet-align center \
          --power-shutdown "systemctl poweroff" \
          --power-reboot "systemctl reboot" \
          --theme "$theme"
      '';

      # The Surface panel is HiDPI but cage outputs are always scale 1 (GDK_SCALE
      # only supersamples, it doesn't enlarge). So pass a real UI multiplier that
      # scales the greeter's logical sizes. Desktop stays 1x.
      uiScale = if config.networking.hostName == "SWsurface" then "2" else "1";
      # --scale sizes the nix mark + cursor; the pills/text/power cluster gets its
      # own smaller multiplier (--field-scale) so the fields aren't oversized next to it.
      fieldScale = if config.networking.hostName == "SWsurface" then "1.5" else "1";
      # cage outputs are scale 1, so the pointer stays at the ~24px default while the
      # rest of the greeter is scaled up — tiny on the HiDPI Surface panel. Enlarge it
      # to track uiScale (XCURSOR_SIZE is what wlroots reads for the seat cursor).
      cursorSize = if config.networking.hostName == "SWsurface" then "64" else "32";
      # XCURSOR_SIZE alone does nothing without a real Xcursor theme on XCURSOR_PATH —
      # otherwise wlroots draws its fixed-size built-in pointer (the "tiny cursor").
      # Point the greeter at the same posys theme the niri session uses; the theme
      # dir is share/icons/<name>, so XCURSOR_PATH is the share/icons parent.
      posysCursor = inputs.posys-cursor.packages.${pkgs.stdenv.hostPlatform.system}.default;
      # Surface is battery-bound, so its greeter suspends after 5 min idle;
      # desktop stays awake. The greeter session is active on seat0, so
      # polkit's allow_active grants systemctl suspend with no auth prompt.
      suspendIdle = lib.optionalString (config.networking.hostName == "SWsurface")
        "timeout 300 '${pkgs.systemd}/bin/systemctl suspend' ";
      # cage has no idle management of its own, so blank the login screen via
      # swayidle (idle-notify) + wlopm (real DPMS, cuts the backlight). Greeter
      # is exec'd as session leader so cage exits cleanly on successful login.
      # Authoritative session list: every module that registers a wayland/x
      # session (niri, mango, …) lands in sessionData.desktops. The greeter's
      # default /run/current-system/sw/share dirs aren't populated under greetd,
      # so point it here directly — new sessions then appear with no greeter change.
      sessionsDir = "${config.services.displayManager.sessionData.desktops}/share/wayland-sessions";
      # The greeter session: wrapped with idle/DPMS via swayidle+wlopm, the
      # HDMI-A-1 scale-3 workaround, cursor env, WLR_DRM_NO_ATOMIC, and
      # systemd-cat journaling.
      greeterSession = pkgs.writeShellScript "greeter-session" ''
        # -d logs every timeout/resume trigger + command it runs to the
        # greeter's systemd-cat stream (journalctl -t greeter) — otherwise a
        # successful wlopm call is silent and there's no way to tell "resume
        # never fired" from "resume fired, wlopm just didn't turn it back on".
        ${pkgs.swayidle}/bin/swayidle -d -w \
          timeout 120 '${pkgs.wlopm}/bin/wlopm --off "*"' \
          resume     '${pkgs.wlopm}/bin/wlopm --on  "*"' \
          ${suspendIdle}&
        # Set the 4K TV to scale 3 so GTK4 renders at couch-readable size.
        # wlr-randr uses wlr_output_management_v1; exits silently if not connected.
        ${pkgs.wlr-randr}/bin/wlr-randr --output HDMI-A-1 --scale 3 2>/dev/null || true
        exec ${lib.getExe pkgs.greeter} --scale ${uiScale} --field-scale ${fieldScale} \
          --palette ${config.greetd.greeterPalette} \
          --sessions-dir ${sessionsDir} --default-user prepko
      '';
      greeterLaunch = pkgs.writeShellScript "greeter-launch" ''
        export XCURSOR_THEME=posys_cursor_scalable
        export XCURSOR_PATH=${posysCursor}/share/icons
        export XCURSOR_SIZE=${cursorSize}
        # NVIDIA multi-head: atomic DRM commits time out (~40s per connector) when
        # more than one monitor is connected, causing cage to spin until greetd
        # kills it. Legacy drmModeSetCrtc per-connector is reliable.
        export WLR_DRM_NO_ATOMIC=1
        # greetd hands this script the bare login VT as stderr, so cage's
        # wlroots startup logs and the greeter's output print onto the
        # handover screen before cage grabs DRM. systemd-cat routes both to
        # the journal (journalctl -t greeter) instead — cage opens
        # DRM via libseat/logind, not stdio, so redirecting stderr is harmless.
        exec ${pkgs.systemd}/bin/systemd-cat -t greeter \
          ${pkgs.cage}/bin/cage -s -- ${greeterSession}
      '';
    in
    {
      # world-writable so drmis (running as the login user) can update them
      systemd.tmpfiles.rules = [
        "f /run/tuigreet-theme 0666 greeter greeter -"
        "d /run/greeter 0755 greeter greeter -"
        "f /run/greeter/palette.sh 0666 greeter greeter -"
      ];

      # Persist the active theme across reboots: /run is tmpfs (wiped on boot),
      # but drmis also writes the palette to ~/.config/waybar/palette.sh in /home
      # (a separate btrfs subvol that survives the impermanence root rollback).
      # Seed /run/greeter/palette.sh from there before greetd starts, so the very
      # first login screen after boot already shows the last-applied theme.
      systemd.services.greeter-palette-seed = {
        description = "Seed the greeter palette from the last-applied theme";
        wantedBy = [ "multi-user.target" ];
        before   = [ "greetd.service" ];
        after    = [ "systemd-tmpfiles-setup.service" "local-fs.target" ];
        unitConfig.ConditionPathExists = "/home/${config.myConfig.user}/.config/waybar/palette.sh";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/install -m0666 -o greeter -g greeter "
            + "/home/${config.myConfig.user}/.config/waybar/palette.sh /run/greeter/palette.sh";
        };
      };

      systemd.services.greeter-wallpaper-seed = {
        description = "Seed the greeter wallpaper from the last-applied theme";
        wantedBy = [ "multi-user.target" ];
        before   = [ "greetd.service" ];
        after    = [ "systemd-tmpfiles-setup.service" "local-fs.target" ];
        unitConfig.ConditionPathExists =
          "/home/${config.myConfig.user}/.local/state/wallpaper-img";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/install -m0644 -o greeter -g greeter "
            + "/home/${config.myConfig.user}/.local/state/wallpaper-img /run/greeter/wallpaper-img";
        };
      };

      services.greetd = {
        enable = true;
        settings.default_session = {
          # greetd provides no compositor; run the GTK greeter inside cage (kiosk).
          # greeterLaunch wraps cage to set the per-host display scale.
          # To recover from a broken greeter: set this to "${tuigreetLaunch}"
          # and nrs (or boot the previous generation / Ctrl+Alt+F2 -> tty2).
          command = "${greeterLaunch}";
          user = "greeter";
        };
      };

      systemd.services."getty@tty1".enable  = false;
      systemd.services."autovt@tty1".enable = false;

      users.users.greeter = {
        isSystemUser = true;
        group = "greeter";
      };
      users.groups.greeter = {};
    };
}
