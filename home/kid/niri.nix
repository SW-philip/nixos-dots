{ pkgs, ... }:
let
  moon = import ../../themes/Dark/indigo-rose/palette-indigo-rose.nix;

  # Their wallpaper: the orange soft-serve from the Lix "ice cream" theme named
  # after the account. Static — this account has no theme switcher, so swaybg just paints this.
  # Imported as a Nix path (copied into the store), so the PNG is force-tracked
  # past themes/**/wallpaper-*.png in .gitignore — the theme rotation's runtime
  # ${home}/nixos lookup isn't available to this account.
  wallpaper = ../../themes/Light/kid/wallpaper-kid.png;

  # Mod+H target: bounce back to the dashboard. Closing whatever's on top is
  # safe even when the kid is already on "home" — the dashboard itself is a
  # systemd-supervised service (below) that respawns immediately if killed.
  homeKeyScript = pkgs.writeShellScript "kid-go-home" ''
    set -euo pipefail
    ${pkgs.niri}/bin/niri msg action close-window
    ${pkgs.niri}/bin/niri msg action focus-workspace "home"
  '';

  kdl = ''
    // Kid's niri — deliberately tiny and forgiving.
    // Apps open as one big fullscreen column (one thing at a time).

    input {
        keyboard {
            xkb { layout "us"; }
            repeat-delay 250
            repeat-rate 40
        }
        // Off, not just gesture-tuned: the Type Cover trackpad's built-in
        // niri swipe (workspace switch) was the only way the kid could ever
        // leave the dashboard — confirmed on-device that the touchscreen
        // itself has no swipe-navigation at all, only the trackpad does.
        // Their actual pointer is the touchscreen (a separate input class,
        // unaffected by this) plus the PS4 controller for Pegasus, so the
        // trackpad isn't needed for anything and is pure attack surface.
        touchpad {
            off
        }
        focus-follows-mouse max-scroll-amount="0%"
    }

    // Surface internal HiDPI panel.
    output "eDP-1" {
        mode "2736x1824@60.000"
        scale 2.0
    }

    workspace "home"
    workspace "active"

    layout {
        gaps 8
        border {
            width 4
            active-color "${moon.ROOT}"
            inactive-color "${moon.BAR}"
            urgent-color "${moon.FORTE}"
        }
        focus-ring { off; }
        preset-column-widths {
            proportion 0.5
            proportion 1.0
        }
        default-column-width { proportion 1.0; }
    }

    // app-id is a best guess (org.gnome.Epiphany, the conventional GNOME/GTK4
    // D-Bus application ID) — unverified, no live Wayland session available
    // during implementation. The systemd service below runs epiphany with
    // --kiosk-mode alone (no --application-mode/profile), which keeps this
    // plain default app-id rather than a per-profile one. If the dashboard
    // doesn't land on "home" during Task 7's on-device check, get the real
    // app-id via `niri msg --json windows` and correct this match.
    window-rule {
        match app-id="org.gnome.Epiphany"
        open-on-workspace "home"
        open-maximized true
    }

    prefer-no-csd

    cursor {
        xcursor-theme "posys_cursor_scalable"
        xcursor-size 48
    }

    environment {
        XCURSOR_THEME "posys_cursor_scalable"
        XCURSOR_SIZE "48"
        XDG_CURRENT_DESKTOP "niri"
        XDG_SESSION_DESKTOP "niri"
        DISPLAY ":0"
    }

    // X11 bridge for SDL/X apps (tuxpaint, the games); logged to the journal so
    // its output doesn't land on the login VT.
    spawn-at-startup "systemd-cat" "-t" "xwayland-satellite" "xwayland-satellite"
    // Ice-cream wallpaper so their screen isn't a flat default background.
    spawn-at-startup "swaybg" "-o" "*" "-i" "${wallpaper}" "-m" "fill"

    animations {
        slowdown 1.0
        window-open  { duration-ms 200; }
        window-close { duration-ms 150; }
    }

    binds {
        Mod+Space  { spawn "nwg-drawer"; }
        Mod+Return { spawn "ghostty"; }

        Mod+Q { close-window; }
        Mod+F { fullscreen-window; }
        Mod+O { toggle-overview; }

        Mod+Left  { focus-column-left; }
        Mod+Right { focus-column-right; }
        Mod+Down  { focus-window-down; }
        Mod+Up    { focus-window-up; }

        Mod+H { spawn "${homeKeyScript}"; }

        XF86AudioRaiseVolume  allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%+"; }
        XF86AudioLowerVolume  allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"; }
        XF86AudioMute         allow-when-locked=true { spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"; }
        XF86MonBrightnessUp   { spawn "brightnessctl" "set" "+5%"; }
        XF86MonBrightnessDown { spawn "brightnessctl" "set" "5%-"; }
    }
  '';
in
{
  ########################################
  # Kid's niri session — niri (not mango) so the kid lands here by default
  # at the greeter, and so the surface-tablet.nix auto-rotation service (which
  # drives niri via `niri msg`) works for the kid. Validated at build with
  # `niri validate`; a typo fails the build instead of the login.
  ########################################
  xdg.configFile."niri/config.kdl".source =
    pkgs.runCommandLocal "kid-niri-config.kdl"
      { inherit kdl; passAsFile = [ "kdl" ]; } ''
        cp "$kdlPath" "$out"
        ${pkgs.niri}/bin/niri validate -c "$out"
      '';

}
