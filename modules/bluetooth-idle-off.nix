{ pkgs, ... }:
let
  idleOffScript = pkgs.writeShellApplication {
    name = "bluetooth-idle-off";
    runtimeInputs = [ pkgs.bluez pkgs.glib pkgs.coreutils pkgs.gnugrep ];
    text = ''
      IDLE_SECS=180
      timer_pid=""

      connected_count() {
        bluetoothctl devices Connected | wc -l
      }

      is_powered() {
        bluetoothctl show | grep -q "Powered: yes"
      }

      cancel_timer() {
        # jobs -rp (not kill -0) is deliberate: kill -0 only proves *some*
        # process holds this pid, and after the timer's subshell exits
        # naturally the number can be recycled by an unrelated (possibly
        # root-owned) process. jobs -rp only ever lists pids of this
        # shell's own still-running background jobs, so a stale/recycled
        # pid never matches and we never signal the wrong process.
        if [[ -n "$timer_pid" ]] && jobs -rp | grep -qx "$timer_pid"; then
          kill "$timer_pid" 2>/dev/null || true
        fi
        timer_pid=""
      }

      start_timer() {
        cancel_timer
        # The trap+wait wrapping (rather than a plain
        # `sleep "$IDLE_SECS" && bluetoothctl power off`) matters: with
        # the plain form, $! /$timer_pid captures the *wrapper subshell's*
        # own pid, while "sleep" runs as a separate child process under
        # it. `kill "$timer_pid"` in cancel_timer only terminates that
        # wrapper - it does not reach the sleep child, which would then
        # keep running as an orphan and still call `bluetoothctl power
        # off` once it elapses, silently defeating cancellation. Here the
        # wrapper backgrounds sleep itself, `wait`s on it, and a TERM trap
        # explicitly kills that specific sleep child (via bash's own $!)
        # before exiting - so a single `kill "$timer_pid"` from
        # cancel_timer reliably tears down the whole thing. On natural
        # completion (no TERM received) the trap never fires and control
        # falls through to `bluetoothctl power off` as intended.
        (
          trap 'kill "$!" 2>/dev/null; exit 0' TERM
          sleep "$IDLE_SECS" &
          wait "$!"
          bluetoothctl power off
        ) &
        timer_pid=$!
      }

      # Event source is `gdbus monitor`, not a long-lived bare `bluetoothctl`
      # REPL: with BLE discovery on, the REPL caches every advertising device
      # it overhears and balloons to ~290 MB (see home/bluetooth-device-probe.nix).
      # gdbus prints one PropertiesChanged line per signal and stays flat.
      # Match on the interface name so MediaControl1's own `Connected` re-emit
      # on the same path is ignored.
      #
      # The initial-sync check and the monitor loop are wrapped together
      # in one brace group so they run as a single pipe stage - and
      # therefore share one subshell and one job table. Without this,
      # bash forks a separate subshell for the pipeline's last stage (no
      # `shopt -s lastpipe` here), so a timer armed by initial sync would
      # live in the parent shell's job table while every cancel_timer
      # call from inside the loop checks the subshell's job table -
      # never seeing it, so it could never be cancelled.
      gdbus monitor --system --dest org.bluez | {
        # Initial state sync - covers service (re)start while already idle.
        if is_powered && [[ "$(connected_count)" -eq 0 ]]; then
          start_timer
        fi

        while IFS= read -r line; do
          case "$line" in
            *"'org.bluez.Adapter1'"*"'Powered': <true>"*)
              [[ "$(connected_count)" -eq 0 ]] && start_timer
              ;;
            *"'org.bluez.Adapter1'"*"'Powered': <false>"*)
              cancel_timer
              ;;
            *"'org.bluez.Device1'"*"'Connected': <true>"*)
              cancel_timer
              ;;
            *"'org.bluez.Device1'"*"'Connected': <false>"*)
              [[ "$(connected_count)" -eq 0 ]] && start_timer
              ;;
          esac
        done
      }
    '';
  };
in
{
  systemd.services.bluetooth-idle-off = {
    description = "Power off Bluetooth after 3 minutes idle";
    after = [ "bluetooth.service" ];
    bindsTo = [ "bluetooth.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${idleOffScript}/bin/bluetooth-idle-off";
      Restart = "always";
      RestartSec = 2;

      # bluetoothctl/gdbus only talk to bluezd over the D-Bus system socket —
      # bluez's own dbus policy (share/dbus-1/system.d/bluetooth.conf)
      # allows any user to call org.bluez, so this needs no capabilities,
      # no device nodes, and no network of its own.
      DynamicUser = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictSUIDSGID = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      LockPersonality = true;
      RemoveIPC = true;
      MemoryDenyWriteExecute = true;
      SystemCallFilter = [ "@system-service" ];
      SystemCallArchitectures = "native";
      CapabilityBoundingSet = [ ];
      UMask = "0077";
    };
  };
}
