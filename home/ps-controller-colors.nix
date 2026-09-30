{ pkgs, ... }:
let
  # Sets each connected PS4/PS5 controller's lightbar to a themed color and
  # keeps the same physical controller on the same color across reconnects.
  #
  # Player identity: hid-playstation keys its power_supply node by MAC
  # (ps-controller-battery-<mac>, same trick bluetooth-battery-notify.nix
  # uses for battery %) but the LED class devices under the controller's
  # uhid node are only named by an arbitrary inputN index, not the MAC. The
  # uhid device directory is the parent both live under, so walking up from
  # the power_supply node two levels lands on the leds/ sibling for that
  # exact controller.
  #
  # Player color: first-seen MAC order, persisted, so "their" controller keeps
  # its color across sessions instead of shuffling on whichever one happens
  # to reconnect first. Colors always come from palette.sh, never hardcoded.
  colorScript = pkgs.writeShellApplication {
    name = "ps-controller-colors";
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep ];
    text = ''
      # waybar/palette.sh, not theme/palette.sh: drmis deploys the active
      # theme there on every "drmis set" (see do_let in drmis.py) —
      # theme/palette.sh is a stale home-manager xdg.configFile frozen to
      # whatever theme was hardcoded at the time (confirmed live: it never
      # tracked the active theme, so the lightbar never actually changed).
      PALETTE="$HOME/.config/waybar/palette.sh"
      [[ -f "$PALETTE" ]] || exit 0
      # shellcheck source=/dev/null
      source "$PALETTE"

      STATE_DIR="$HOME/.local/state/ps-controller-colors"
      ORDER_FILE="$STATE_DIR/order"
      mkdir -p "$STATE_DIR"
      touch "$ORDER_FILE"

      # Player 1..4 accent order — same accent set rgb-moon's "aurora" mode
      # draws from, just reordered so the primary accent (ROOT) is Player 1.
      COLORS=("$ROOT" "$FORTE" "$FIFTH" "$SEVENTH")

      hex_channel() { # $1=#rrggbb  $2=0|1|2 (r/g/b)
        local h="''${1:1}" off=$(( $2 * 2 ))
        printf '%d' "0x''${h:off:2}"
      }

      shopt -s nullglob
      for supply in /sys/class/power_supply/ps-controller-battery-*; do
        mac=$(basename "$supply")
        mac=$(tr '[:upper:]' '[:lower:]' <<<"''${mac#ps-controller-battery-}")

        if ! grep -qxF "$mac" "$ORDER_FILE"; then
          echo "$mac" >> "$ORDER_FILE"
        fi
        index=$(grep -m1 -nxF "$mac" "$ORDER_FILE" | cut -d: -f1)
        color="''${COLORS[$(( (index - 1) % ''${#COLORS[@]} ))]}"

        # supply -> …/uhid/<id>/power_supply/ps-controller-battery-<mac>;
        # two dirnames up is the uhid device dir the leds/ siblings live in.
        uhid_dir=$(dirname "$(dirname "$(readlink -f "$supply")")")
        leds_dir="$uhid_dir/leds"
        [[ -d "$leds_dir" ]] || continue

        for channel in red green blue; do
          off=0; [[ "$channel" == green ]] && off=1; [[ "$channel" == blue ]] && off=2
          raw=$(hex_channel "$color" "$off")
          leds=("$leds_dir"/*:"$channel")
          for led in "''${leds[@]}"; do
            [[ -w "$led/brightness" ]] || continue
            max=$(<"$led/max_brightness")
            echo $(( (raw * max + 127) / 255 )) > "$led/brightness"
          done
        done

        # "global" is the lightbar's master brightness on this driver —
        # without it at max the RGB mix above is invisible.
        globals=("$leds_dir"/*:global)
        for led in "''${globals[@]}"; do
          [[ -w "$led/brightness" ]] || continue
          cat "$led/max_brightness" > "$led/brightness"
        done
      done
    '';
  };

  watchScript = pkgs.writeShellApplication {
    name = "ps-controller-colors-watch";
    runtimeInputs = [ pkgs.glib pkgs.bluez colorScript ];
    text = ''
      # Catch-up pass: controllers already connected when this service
      # (re)starts (after nrs, after login) won't fire another Connected
      # signal for gdbus to see.
      ps-controller-colors || true

      # gdbus monitor, not a long-lived bluetoothctl REPL — see
      # home/bluetooth-device-probe.nix's comment for why the REPL balloons
      # to ~290MB with discovery running. Any connect just triggers a full
      # rescan; ps-controller-colors itself is cheap and idempotent, so
      # there's no need to filter for "is this actually a controller" here.
      gdbus monitor --system --dest org.bluez | while IFS= read -r line; do
        case "$line" in
          *dev_*"'org.bluez.Device1'"*"'Connected': <true>"*)
            ps-controller-colors || true
            ;;
        esac
      done
    '';
  };
in
{
  home.packages = [ colorScript ];

  systemd.user.services.ps-controller-colors = {
    Unit = {
      Description = "Color connected PS4/PS5 controller lightbars from the active theme palette";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
    };
    Service = {
      ExecStart = "${watchScript}/bin/ps-controller-colors-watch";
      # gdbus monitor exiting (e.g. bluez restart) drops out of the read
      # loop with a clean status, so "always", not "on-failure".
      Restart = "always";
      RestartSec = "2s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
