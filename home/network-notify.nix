{ lib, pkgs, ... }:
let
  networkCheckScript = pkgs.writeShellApplication {
    name = "network-notify";
    runtimeInputs = [ pkgs.networkmanager pkgs.gnugrep pkgs.gawk pkgs.coreutils pkgs.libnotify ];
    text = ''
      STATE_DIR="$HOME/.local/state/network-notify"
      mkdir -p "$STATE_DIR"
      SEEN_FILE="$STATE_DIR/seen"
      touch "$SEEN_FILE"

      if ! active_raw=$(nmcli -t -f active,ssid dev wifi 2>/dev/null); then
        exit 0
      fi
      active_ssid=$(printf '%s\n' "$active_raw" | awk -F: '$1=="yes"{print $2}')

      # --rescan no rides on NetworkManager's own scan cache (kept fresh by
      # the existing quantum-wifi-rescan timer, home/waybar/netstatus.nix)
      # instead of forcing a fresh active scan every 5 minutes.
      if ! visible_raw=$(nmcli -t -f SSID dev wifi list --rescan no 2>/dev/null); then
        exit 0
      fi
      visible=$(printf '%s\n' "$visible_raw" | grep -v '^$' | sort -u || true)

      if ! saved_raw=$(nmcli -t -f TYPE,NAME connection show 2>/dev/null); then
        exit 0
      fi
      saved=$(printf '%s\n' "$saved_raw" | awk -F: '$1=="802-11-wireless"{print $2}' | sort -u)

      # visible_saved (saved networks currently visible, active or not) is what
      # gets persisted to `seen` — it deliberately includes the active network,
      # so a brief disconnect/reassociation blip doesn't make your own network
      # look "newly back in range" the next time it's visible again. The active
      # SSID is excluded only from the notification set below, never from `seen`.
      visible_saved=$(comm -12 <(printf '%s\n' "$visible") <(printf '%s\n' "$saved") || true)

      new=$(comm -23 <(printf '%s\n' "$visible_saved") <(sort -u "$SEEN_FILE") || true)
      to_notify=$(printf '%s\n' "$new" | grep -vxF "$active_ssid" || true)

      while IFS= read -r ssid; do
        [ -n "$ssid" ] || continue
        notify-send -u normal "WiFi" "$ssid is back in range" 2>/dev/null || true
      done <<< "$to_notify"

      if [ -n "$visible_saved" ]; then
        echo "$visible_saved" | sort -u > "$SEEN_FILE"
      else
        : > "$SEEN_FILE"
      fi
    '';
  };
in
{
  systemd.user.services.network-notify = {
    Unit = {
      Description = "Notify when a saved WiFi network comes back into range";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${networkCheckScript}/bin/network-notify";
    };
  };

  systemd.user.timers.network-notify = {
    Unit.Description = "Poll visible WiFi networks for saved SSIDs back in range";
    Timer = {
      OnStartupSec = "2min";
      OnUnitActiveSec = "5min";
      AccuracySec = "1min";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
