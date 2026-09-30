{ lib, pkgs, ... }:
let
  lowPct = 20;
  criticalPct = 10;
  hysteresis = 5;
  batteryCheckScript = pkgs.writeShellApplication {
    name = "battery-low-notify";
    runtimeInputs = [ pkgs.coreutils pkgs.libnotify ];
    text = ''
      BAT="/sys/class/power_supply/BAT1"
      STATE_DIR="$HOME/.local/state/battery-low-notify"
      mkdir -p "$STATE_DIR"
      LOW_PCT=${toString lowPct}
      CRITICAL_PCT=${toString criticalPct}
      HYSTERESIS=${toString hysteresis}
      low_flag="$STATE_DIR/low"
      critical_flag="$STATE_DIR/critical"

      [ -r "$BAT/capacity" ] && [ -r "$BAT/status" ] || exit 0

      capacity=$(cat "$BAT/capacity" 2>/dev/null || true)
      status=$(cat "$BAT/status" 2>/dev/null || true)
      [[ "$capacity" =~ ^[0-9]+$ ]] && [ -n "$status" ] || exit 0

      if [ "$status" != "Discharging" ]; then
        rm -f "$low_flag" "$critical_flag"
        exit 0
      fi

      if [ "$capacity" -le "$CRITICAL_PCT" ]; then
        if [ ! -f "$critical_flag" ]; then
          notify-send -u critical "Battery" "$capacity% remaining — plug in soon" 2>/dev/null || true
          touch "$critical_flag" "$low_flag"
        fi
      elif [ "$capacity" -le "$LOW_PCT" ]; then
        if [ "$capacity" -ge $((CRITICAL_PCT + HYSTERESIS)) ]; then
          rm -f "$critical_flag"
        fi
        if [ ! -f "$low_flag" ]; then
          notify-send -u normal "Battery" "$capacity% remaining" 2>/dev/null || true
          touch "$low_flag"
        fi
      elif [ "$capacity" -ge $((LOW_PCT + HYSTERESIS)) ]; then
        rm -f "$low_flag" "$critical_flag"
      fi
    '';
  };
in
{
  systemd.user.services.battery-low-notify = {
    Unit = {
      Description = "Notify when laptop battery is low";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${batteryCheckScript}/bin/battery-low-notify";
    };
  };

  systemd.user.timers.battery-low-notify = {
    Unit.Description = "Poll laptop battery level";
    Timer = {
      OnStartupSec = "30s";
      OnUnitActiveSec = "60s";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
