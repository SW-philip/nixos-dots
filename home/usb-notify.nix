{ lib, pkgs, ... }:
let
  usbNotifyScript = pkgs.writeShellApplication {
    name = "usb-notify";
    runtimeInputs = [ pkgs.systemd pkgs.gawk pkgs.libnotify ];
    text = ''
      # udevadm monitor's block-per-event format, same awk state-machine shape
      # as surface-kbd-monitor (profiles/surface-tablet.nix): accumulate
      # KEY=VALUE lines into vars, act on the blank-line block terminator.
      # DEVTYPE=="usb_device" filters out per-interface sub-events so a
      # composite device (hub, webcam+mic) fires one notification, not one
      # per interface. ID_*_FROM_DATABASE (hwdb-matched, human-readable) is
      # preferred when present; on this hardware it usually isn't, so the
      # fallback to udev's own ID_VENDOR/ID_MODEL (underscore-separated,
      # cleaned up here) is the common case, not a rare edge.
      udevadm monitor --udev --property --subsystem-match=usb | awk '
        /^UDEV/       { action=""; devtype=""; vendor=""; model=""; next }
        /^ACTION=/    { action = substr($0, 8) }
        /^DEVTYPE=/   { devtype = substr($0, 9) }
        /^ID_VENDOR_FROM_DATABASE=/ { vendor = substr($0, 25) }
        /^ID_MODEL_FROM_DATABASE=/  { model = substr($0, 24) }
        /^ID_VENDOR=/ {
          if (vendor == "") { vendor = substr($0, 11); gsub(/_/, " ", vendor) }
        }
        /^ID_MODEL=/ {
          if (model == "") { model = substr($0, 10); gsub(/_/, " ", model) }
        }
        /^$/ {
          if (devtype == "usb_device" && action != "") {
            label = vendor
            if (model != "") { label = (label == "" ? model : label " " model) }
            if (label == "") { label = "device" }
            print action "|" label
            fflush()
          }
          action=""; devtype=""; vendor=""; model=""
        }
      ' | while IFS='|' read -r action label; do
        case "$action" in
          add)    notify-send -u normal "USB" "$label connected" 2>/dev/null || true ;;
          remove) notify-send -u low    "USB" "$label disconnected" 2>/dev/null || true ;;
        esac
      done
    '';
  };
in
{
  systemd.user.services.usb-notify = {
    Unit = {
      Description = "Notify on USB device plug/unplug";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
    };
    Service = {
      ExecStart = "${usbNotifyScript}/bin/usb-notify";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
