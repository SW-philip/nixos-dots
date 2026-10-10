{ lib, pkgs, ... }:
let
  threshold = 20;
  batteryCheckScript = pkgs.writeShellApplication {
    name = "bluetooth-battery-notify";
    runtimeInputs = [ pkgs.bluez pkgs.gnugrep pkgs.gawk pkgs.coreutils pkgs.libnotify ];
    text = ''
      STATE_DIR="$HOME/.local/state/bt-battery-notify"
      mkdir -p "$STATE_DIR"
      THRESHOLD=${toString threshold}

      # Not every device exposes bluez's Battery1 interface — the grep on
      # "Battery Percentage:" simply won't match for those, and they're
      # skipped, not treated as an error.
      bluetoothctl devices Connected 2>/dev/null | while IFS= read -r line; do
        mac=$(awk '{print $2}' <<<"$line")
        name=$(cut -d' ' -f3- <<<"$line")
        [ -n "$mac" ] || continue

        flag="$STATE_DIR/$mac"
        info=$(bluetoothctl info "$mac" 2>/dev/null || true)

        pct=$(grep -oP 'Battery Percentage:.*\(\K[0-9]+(?=\))' <<<"$info" || true)

        # Some HID gamepads (e.g. hid-playstation for DS4/DS5) report battery
        # via a kernel power_supply node keyed by MAC, entirely separate from
        # bluez's own Battery1 interface -- bluetoothctl never sees it.
        if [ -z "$pct" ]; then
          mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
          mac_underscore=$(echo "$mac_lower" | tr ':' '_')
          for supply in /sys/class/power_supply/*; do
            [ -f "$supply/capacity" ] || continue
            supply_lower=$(echo "$supply" | tr '[:upper:]' '[:lower:]')
            case "$supply_lower" in
              *"$mac_lower"*|*"$mac_underscore"*)
                pct=$(cat "$supply/capacity")
                break
                ;;
            esac
          done
        fi

        if [ -z "$pct" ]; then
          rm -f "$flag"
          continue
        fi

        if [ "$pct" -lt "$THRESHOLD" ]; then
          if [ ! -f "$flag" ]; then
            notify-send -u normal "Bluetooth" "$name battery low ($pct%)" 2>/dev/null || true
            touch "$flag"
          fi
        else
          rm -f "$flag"
        fi
      done || true

      # Drop flags for devices that are no longer connected, so a future
      # reconnect-while-low can notify again instead of staying silenced.
      connected_macs=$(bluetoothctl devices Connected 2>/dev/null | awk '{print $2}' || true)
      for f in "$STATE_DIR"/*; do
        [ -e "$f" ] || continue
        mac=$(basename "$f")
        grep -qxF "$mac" <<<"$connected_macs" || rm -f "$f"
      done
    '';
  };
in
{
  systemd.user.services.bluetooth-battery-notify = {
    Unit = {
      Description = "Notify when a connected Bluetooth device's battery is low";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${batteryCheckScript}/bin/bluetooth-battery-notify";
    };
  };

  systemd.user.timers.bluetooth-battery-notify = {
    Unit.Description = "Poll connected Bluetooth devices' battery level";
    Timer = {
      OnStartupSec = "1min";
      OnUnitActiveSec = "15min";
      AccuracySec = "1min";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
