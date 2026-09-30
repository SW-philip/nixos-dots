{ pkgs, lib, ... }:
let
  s = import ../home/niri/scripts.nix { inherit pkgs lib; };
in
{
  ########################################
  # Surface tablet user services — shared by Phil's and Kid's profiles.
  # Auto-rotation, on-screen keyboard, and the Type Cover detach monitor.
  ########################################

  ########################################
  # Screen auto-rotation
  ########################################
  systemd.user.services.niri-rotation = {
    Unit = {
      Description = "Auto-rotate niri output via iio-niri";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.iio-niri}/bin/iio-niri listen -m eDP-1";
      Restart = "on-failure";
      RestartSec = "3s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  ########################################
  # On-screen keyboard — started/stopped by surface-kbd-monitor.
  # Squeekboard shows itself on text-field focus (input-method-v2) while running.
  ########################################
  systemd.user.services.squeekboard = {
    Unit = {
      Description = "On-screen keyboard (squeekboard)";
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      # Private XDG_CONFIG_HOME so squeekboard's GTK3 loads the drmis palette
      # sheet without touching nemo's global ~/.config/gtk-3.0/gtk.css.
      # The private XDG_CONFIG_HOME also hides the dconf user db, so the
      # gsettings override below is delivered via the keyfile backend.
      Environment = [
        "XDG_CONFIG_HOME=%h/.config/squeekboard-gtk"
        "GSETTINGS_BACKEND=keyfile"
      ];
      ExecStart = "${pkgs.squeekboard}/bin/squeekboard";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    # No WantedBy — demand-started by surface-kbd-monitor
  };

  # screen-keyboard-enabled is inverted inside squeekboard: true = auto-show on
  # text-field focus, false = never (state.rs Presence::Present). The file is
  # rewritten live by surface-osk-focus-policy (true only while a browser has
  # focus), so it can't be a read-only store symlink. Until that service has
  # written it, squeekboard just doesn't auto-show.

  ########################################
  # Auto-show only in browser fields; everywhere else the three-finger tap
  # (surface-osk-gesture) is the on/off switch.
  ########################################
  systemd.user.services.surface-osk-focus-policy = {
    Unit = {
      Description = "Squeekboard auto-shows only while a browser has focus";
      PartOf = [ "squeekboard.service" ];
      After = [ "squeekboard.service" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python3 ${../scripts/osk-focus-policy.py} %h/.config/squeekboard-gtk/glib-2.0/settings/keyfile ${s.toggleOsk}/bin/toggle-osk /run/current-system/sw/bin/niri";
      Restart = "on-failure";
      RestartSec = "3s";
    };
    Install.WantedBy = [ "squeekboard.service" ];
  };

  ########################################
  # Three-finger tap toggles the keyboard. Bound to squeekboard.service so it
  # only exists while the Type Cover is detached.
  ########################################
  systemd.user.services.surface-osk-gesture = {
    Unit = {
      Description = "Three-finger tap toggles the on-screen keyboard";
      PartOf = [ "squeekboard.service" ];
      After = [ "squeekboard.service" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python3 ${../scripts/osk-gesture.py} ${s.toggleOsk}/bin/toggle-osk ${s.pegasusExit}/bin/pegasus-exit";
      Restart = "on-failure";
      RestartSec = "3s";
    };
    Install.WantedBy = [ "squeekboard.service" ];
  };

  ########################################
  # Type Cover keyboard monitor
  ########################################
  systemd.user.services.surface-kbd-monitor = {
    Unit = {
      Description = "Run squeekboard only while the Surface Type Cover is detached";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = pkgs.writeShellScript "surface-kbd-monitor" ''
        SC="${pkgs.systemd}/bin/systemctl"
        STATE="$XDG_RUNTIME_DIR/surface-cover"

        kbd_present() {
          grep -qlF "Type Cover Keyboard" /sys/class/input/*/name 2>/dev/null
        }

        update() {
          if kbd_present; then
            echo attached > "$STATE"
            $SC --user stop squeekboard.service 2>/dev/null || true
          else
            echo detached > "$STATE"
            $SC --user start squeekboard.service 2>/dev/null || true
          fi
        }

        update

        ${pkgs.systemd}/bin/udevadm monitor --udev --property --subsystem-match=input \
          | ${pkgs.gawk}/bin/awk '
              /^UDEV/  { action=""; name=""; next }
              /^ACTION=/ { action = substr($0, 8) }
              /^NAME=/   { name = substr($0, 6); gsub(/"/, "", name) }
              /^$/       {
                if (name ~ /Type Cover Keyboard/) { print action; fflush() }
                action=""; name=""
              }
            ' \
          | while read -r _event; do
              sleep 0.3
              update
            done
      '';
      Restart = "on-failure";
      RestartSec = "3s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
