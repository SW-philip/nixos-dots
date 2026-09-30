{ config, lib, pkgs, ... }:
let
  idleNotifyScript = pkgs.writeShellApplication {
    name = "bluetooth-idle-notify";
    runtimeInputs = [ pkgs.bluez pkgs.coreutils pkgs.gnugrep pkgs.libnotify ];
    text = ''
      IDLE_SECS=5400
      timer_pid=""

      connected_count() {
        bluetoothctl devices Connected | wc -l
      }

      is_powered() {
        bluetoothctl show | grep -q "Powered: yes"
      }

      # See modules/bluetooth-idle-off.nix (git history) for why `jobs -rp`
      # rather than `kill -0` and why the timer wraps sleep in its own trap —
      # same pid-recycling and orphan-child hazards apply here.
      cancel_timer() {
        if [[ -n "$timer_pid" ]] && jobs -rp | grep -qx "$timer_pid"; then
          kill "$timer_pid" 2>/dev/null || true
        fi
        timer_pid=""
      }

      start_timer() {
        cancel_timer
        (
          trap 'kill "$!" 2>/dev/null; exit 0' TERM
          sleep "$IDLE_SECS" &
          wait "$!"
          notify-send "Bluetooth" "Still powered on with nothing connected after $((IDLE_SECS / 60)) minutes."
        ) &
        timer_pid=$!
      }

      stdbuf -oL bluetoothctl < <(tail -f /dev/null) | {
        if is_powered && [[ "$(connected_count)" -eq 0 ]]; then
          start_timer
        fi

        while IFS= read -r line; do
          case "$line" in
            *"Powered: yes"*)
              [[ "$(connected_count)" -eq 0 ]] && start_timer
              ;;
            *"Powered: no"*)
              cancel_timer
              ;;
            *"Connected: yes"*)
              cancel_timer
              ;;
            *"Connected: no"*)
              [[ "$(connected_count)" -eq 0 ]] && start_timer
              ;;
          esac
        done
      }
    '';
  };
in
{
  systemd.user.services.bluetooth-idle-notify = {
    Unit = {
      Description = "Notify (never power off) when Bluetooth sits idle";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
    };
    Service = {
      ExecStart = "${idleNotifyScript}/bin/bluetooth-idle-notify";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
