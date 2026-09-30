{ config, lib, pkgs, ... }:
let
  scriptsDir = "${config.home.homeDirectory}/.config/waybar/scripts";

  probeScript = pkgs.writeShellApplication {
    name = "bluetooth-device-probe";
    runtimeInputs = [ pkgs.glib pkgs.bluez pkgs.coreutils pkgs.gnugrep ];
    text = ''
      export PATH="${scriptsDir}:$PATH"

      # gdbus object paths carry the MAC as dev_AA_BB_...; a one-shot
      # `bluetoothctl devices` line carries it as AA:BB:... -- accept either.
      mac_from_line() {
        grep -oE '([0-9A-Fa-f]{2}[:_]){5}[0-9A-Fa-f]{2}' <<<"$1" | head -n1 | tr '_' ':'
      }

      # Startup catch-up: the service (re)starts while devices are already
      # connected (after nrs, after login), and gdbus only streams events from
      # now on -- without this an already-connected device's cached battery
      # stays stale until its next reconnect. `refresh-battery` no-ops unless a
      # cache file already exists, so this never probes or opens a menu for an
      # unconfigured device. `|| true`: an empty `grep` (nothing connected)
      # exits 1 and would trip `set -e` before the monitor loop starts.
      { bluetoothctl devices Connected 2>/dev/null \
          | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' \
          | while IFS= read -r mac; do
              bt-device-probe.sh refresh-battery "$mac" &
            done ; } || true

      # Event source is `gdbus monitor` on org.bluez, NOT a long-lived bare
      # `bluetoothctl` REPL (as modules/bluetooth-idle-off.nix still uses). With
      # BLE discovery running in the session -- blueman-applet keeps the adapter
      # on `Discovering: yes` -- bluetoothctl's monitor mode caches every
      # advertising device it overhears and never evicts them; observed
      # ballooning to ~290 MB RSS within minutes on the Surface (7.6 GiB total).
      # gdbus is a stateless signal printer and stays flat. One line per signal;
      # the device object path carries the MAC. Filter on the `org.bluez.Device1`
      # interface specifically -- `org.bluez.MediaControl1` also emits a
      # `'Connected': <true>` on the same path a beat later.
      gdbus monitor --system --dest org.bluez | while IFS= read -r line; do
        case "$line" in
          *dev_*"'org.bluez.Device1'"*"'Connected': <true>"*)
            mac=$(mac_from_line "$line")
            [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || continue
            (
              first=$(bt-device-probe.sh probe "$mac")
              if [[ "$first" == "1" ]]; then
                "${scriptsDir}/bt-device-fields-menu.sh" "$mac"
              fi
            ) &
            ;;
          # bluez restores a stale cached Battery1.Percentage on connect and
          # only updates it when the device pushes a GATT battery notification
          # (iOS does this sporadically, never on connect). Mirror blueman:
          # react to the Battery1 appear/change signal so a configured device's
          # tooltip converges to the real value. Matches both InterfacesAdded
          # (Battery1 first appears) and later PropertiesChanged.
          *dev_*"'org.bluez.Battery1'"*"'Percentage'"*)
            mac=$(mac_from_line "$line")
            [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || continue
            bt-device-probe.sh refresh-battery "$mac" &
            ;;
        esac
      done
    '';
  };
in
{
  systemd.user.services.bluetooth-device-probe = {
    Unit = {
      Description = "Probe newly connected Bluetooth devices for available info";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
    };
    Service = {
      Environment = [
        # bt-device-probe.sh's own bare `bt-classify` call needs the profile
        # bin dirs on PATH -- that's where home.packages' writeShellScriptBin
        # wrapper (home/waybar/bluetooth.nix) actually lands. Confirmed live:
        # an explicit Environment=PATH= on a unit fully replaces (not merges
        # with) the systemd --user manager's environment.d-sourced default
        # PATH, so this service can't rely on that default including it.
        "PATH=${lib.makeBinPath [
          pkgs.bluez pkgs.jq pkgs.coreutils pkgs.gnused pkgs.gawk pkgs.findutils
        ]}:${scriptsDir}:${config.home.homeDirectory}/.nix-profile/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      ExecStart = "${probeScript}/bin/bluetooth-device-probe";
      # gdbus monitor exiting (e.g. bluez restart) drops us out of the read
      # loop with a clean status, so "always", not "on-failure".
      Restart = "always";
      RestartSec = "2s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
