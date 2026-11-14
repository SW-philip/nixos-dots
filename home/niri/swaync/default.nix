{ config, pkgs, lib, ... }:
let
  only       = config.myConfig.themes;
  restricted = only != [ ];
  s = import ../scripts.nix { inherit pkgs lib; animatePit = config.myConfig.isDesktop; };

  # Power profile has no boolean on/off, so it's a picker rather than a
  # "toggle" — same shape as vpn-toggle.sh: list the profiles
  # actually available on this host's hardware (powerprofilesctl list
  # already filters this), mark the current one, powerprofilesctl set on
  # selection instead of blind-cycling with no visible state.
  powerProfilePickerBin = pkgs.writeShellScript "swaync-power-profile-picker" ''
    current=$(powerprofilesctl get 2>/dev/null || echo "balanced")
    mapfile -t available < <(powerprofilesctl list 2>/dev/null | awk '/^[* ] ?[a-z]/ { gsub(/[* :]/, ""); print $1 }')
    ordered=(power-saver balanced performance)

    entries=()
    for p in "''${ordered[@]}"; do
      printf '%s\n' "''${available[@]}" | grep -qx "$p" || continue
      if [[ "$p" == "$current" ]]; then
        entries+=("$p  [on]")
      else
        entries+=("$p")
      fi
    done

    choice=$(printf '%s\n' "''${entries[@]}" | menu --dmenu --prompt "Power Profile › " --width 30 --lines ''${#entries[@]}) || exit 0
    [[ -z "$choice" ]] && exit 0

    selected=$(echo "$choice" | sed 's/  \[on\]$//')
    [[ "$selected" == "$current" ]] && exit 0

    if powerprofilesctl set "$selected" 2>/dev/null; then
      notify-send -a power-profile -u low "Power Profile" "Switched to $selected" 2>/dev/null || true
    else
      notify-send -a power-profile -u normal "Power Profile" "Failed to set $selected — EPP locked (governor stuck?)" 2>/dev/null || true
    fi
  '';

  # Wing/ledger edge is independently switchable per slot via
  # `eww-panel-edge` (home/eww/scripts/panel-edge.sh, wired up by
  # home/eww/default.nix) but that's CLI-only — this menu is the
  # interactive front end for it. Reads state directly from the same files
  # ExecStartPost and eww-panel-edge already treat as the source of truth;
  # writes nothing itself.
  panelEdgePickerBin = pkgs.writeShellScript "swaync-panel-edge-picker" ''
    state_dir="''${EWW_PANEL_EDGE_STATE_DIR:-$HOME/.local/state}"

    read_edge() {
      cat "$state_dir/eww-panel-edge-$1" 2>/dev/null || true
    }

    labels=()
    slots=()
    edges=()

    add_row() {
      local label="$1" slot="$2" edge="$3" current="$4"
      if [[ "$edge" == "$current" ]]; then
        labels+=("$label  [on]")
      else
        labels+=("$label")
      fi
      slots+=("$slot")
      edges+=("$edge")
    }

    wing_edge=$(read_edge wing)
    ledger_edge=$(read_edge ledger)

    add_row "Wing → Left"     wing   left   "$wing_edge"
    add_row "Wing → Right"    wing   right  "$wing_edge"
    add_row "Ledger → Top"    ledger top    "$ledger_edge"
    add_row "Ledger → Bottom" ledger bottom "$ledger_edge"

    ${lib.optionalString config.myConfig.isDesktop ''
    wing_tv_edge=$(read_edge wing-tv)
    ledger_tv_edge=$(read_edge ledger-tv)
    add_row "Wing TV → Left"     wing-tv   left   "$wing_tv_edge"
    add_row "Wing TV → Right"    wing-tv   right  "$wing_tv_edge"
    add_row "Ledger TV → Top"    ledger-tv top    "$ledger_tv_edge"
    add_row "Ledger TV → Bottom" ledger-tv bottom "$ledger_tv_edge"
    ''}

    choice=$(printf '%s\n' "''${labels[@]}" | menu --dmenu --prompt "Panel Edges › " --width 30 --lines ''${#labels[@]}) || exit 0
    [[ -z "$choice" ]] && exit 0

    sel_slot=""
    sel_edge=""
    for i in "''${!labels[@]}"; do
      if [[ "''${labels[$i]}" == "$choice" ]]; then
        sel_slot="''${slots[$i]}"
        sel_edge="''${edges[$i]}"
        break
      fi
    done
    [[ -z "$sel_slot" ]] && exit 0

    current="$(read_edge "$sel_slot")"
    [[ "$sel_edge" == "$current" ]] && exit 0

    if err=$(eww-panel-edge "$sel_slot" "$sel_edge" 2>&1); then
      notify-send -a panel-edges -u low "Panel Edges" "$choice" 2>/dev/null || true
    else
      notify-send -a panel-edges -u normal "Panel Edges" "Failed to set $choice: $err" 2>/dev/null || true
    fi
  '';

  # DND uses swaync's own native toggle/query — no custom script needed.
  # (The waybar-era dnd-toggle.sh called makoctl, a daemon this system
  # doesn't run; that button silently never worked. swaync-client -d/-D
  # is the real, working mechanism.)
  systemActions = [
    {
      label = "󰝟  Silent Notifications";
      type = "toggle";
      command = "f=$HOME/.local/state/notify-quiet; mkdir -p $HOME/.local/state; [ -e $f ] && rm -f $f || touch $f";
      update-command = "[ -e $HOME/.local/state/notify-quiet ] && echo true || echo false";
    }
    {
      label = "󰂛  Do Not Disturb";
      type = "toggle";
      command = "${pkgs.swaynotificationcenter}/bin/swaync-client -d";
      update-command = "${pkgs.swaynotificationcenter}/bin/swaync-client -D";
    }
    {
      label = "󰒲  Screen Lock";
      type = "toggle";
      command = "systemctl --user is-active --quiet hypridle.service && systemctl --user stop hypridle.service || systemctl --user start hypridle.service";
      update-command = "systemctl --user is-active --quiet hypridle.service && echo true || echo false";
    }
    {
      label = "󰌌  NiriBridge";
      type = "toggle";
      command = "systemctl --user is-active --quiet niri-bridge.service && systemctl --user stop niri-bridge.service || { systemctl --user reset-failed niri-bridge.service; systemctl --user start niri-bridge.service; }";
      update-command = "systemctl --user is-active --quiet niri-bridge.service && echo true || echo false";
    }
  ]
  ++ lib.optional config.myConfig.hasTouch {
    label = "󰔃  Auto-Rotate";
    type = "toggle";
    command = "systemctl --user is-active --quiet niri-rotation.service && systemctl --user stop niri-rotation.service || systemctl --user start niri-rotation.service";
    update-command = "systemctl --user is-active --quiet niri-rotation.service && echo true || echo false";
  }
  ++ lib.optional config.myConfig.hasTouch {
    label = "󰍹  Desktop Mode";
    type = "toggle";
    command = "${s.surfaceMode}/bin/surface-mode toggle";
    update-command = "${s.surfaceMode}/bin/surface-mode status";
  }
  ++ [
    {
      label = "󰈐  Power Profile";
      command = "${powerProfilePickerBin}";
    }
    {
      label = "󰓡  Panel Edges";
      command = "${panelEdgePickerBin}";
    }
  ];

  appearanceActions = if restricted
    then map (slug: { label = slug; command = "drmis set ${slug}"; }) only
    else [
      {
        label = "󰔎  Pick Theme";
        command = "ghostty --class=dev.prepko.drmis-pick -e drmis pick";
      }
      {
        label = "Free Palestine";
        command = "drmis set free-palestine";
      }
    ];

  # quantum-bt-toggle is installed via home.packages by home/waybar/bluetooth.nix
  # (unconditionally enabled on both hosts) — referenced here by bare name since
  # swaync's systemd user service PATH already includes ~/.nix-profile/bin.
  # VPN is referenced by absolute path, matching how netstatus.nix itself calls
  # vpn-toggle.sh. Wi-Fi and Bluetooth's update-commands both read hardware
  # power state directly (nmcli/busctl) rather than shelling out to a script —
  # same inline shape as the Screen Lock/Auto-Rotate update-commands above.
  #
  # swaync runs every action through `Shell.parse_argv("/bin/sh -c \"%s\"")`
  # (functions.vala execute_command), so each string here must be a bare POSIX
  # sh snippet with NO literal double-quotes and NO wrapping `sh -c '...'` — an
  # embedded `"` collides with swaync's own `"%s"` and shreds the argv, and the
  # mangled command exits instantly, which used to trip an fd double-free in
  # execute_command and crash-loop swaync at boot. `[` not `[[` (dash), and
  # rely on the values being single tokens so `$(...)` needs no quoting.
  # BT Devices (quantum-btmenu) and full Wi-Fi network selection
  # (quantum-wifimenu) are intentionally not called from here — both stay
  # reachable via their waybar module's own on-click handler
  # (home/waybar/bluetooth.nix, home/waybar/netstatus.nix).
  connectivityActions = [
    {
      label = "󰖩  Wi-Fi";
      type = "toggle";
      command = "[ $(nmcli radio wifi) = enabled ] && nmcli radio wifi off || nmcli radio wifi on";
      update-command = "[ $(nmcli radio wifi) = enabled ] && echo true || echo false";
    }
    {
      label = "󰂯  Bluetooth";
      type = "toggle";
      command = "quantum-bt-toggle";
      update-command = "busctl get-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered 2>/dev/null | grep -q true && echo true || echo false";
    }
    {
      label = "󰖂  VPN";
      command = "bash ${config.home.homeDirectory}/.config/waybar/scripts/vpn-toggle.sh";
    }
    {
      label = "󰒍  Tunnel";
      command = "ssh-tunnel";
    }
  ];

  # Sounds on arrival (scripts/sfx.py renders assets/sounds). One entry per
  # urgency so each notification matches exactly one script; no `"` in exec.
  # These senders play their own sounds, so the generic ones skip them.
  notifySoundOnce = pkgs.writeShellScript "notify-sound-once" ''
    [ -e "''${XDG_STATE_HOME:-$HOME/.local/state}/notify-quiet" ] && exit 0
    stamp="''${XDG_RUNTIME_DIR:-/tmp}/notify-sound.stamp"
    exec 9>"$stamp.lock"
    ${pkgs.util-linux}/bin/flock 9
    now=$(${pkgs.coreutils}/bin/date +%s)
    last=$(${pkgs.coreutils}/bin/cat "$stamp" 2>/dev/null || echo 0)
    [ $((now - last)) -ge 15 ] || exit 0
    echo "$now" > "$stamp"
    exec ${pkgs.pipewire}/bin/pw-play "$1"
  '';
  noBattery = "^(?!(battery|usb|monitor|Tether)$).*";
  # Rate-limited: a burst (resume, reconnect) must ring once, not per
  # notification. Stamp is checked under flock so parallel script runs agree.
  playSound = wav: "${notifySoundOnce} ${wav}";
  notifySoundScripts = {
    low      = { app-name = noBattery; urgency = "Low";      exec = playSound ../../../assets/sounds/notify.wav; };
    normal   = { app-name = noBattery; urgency = "Normal";   exec = playSound ../../../assets/sounds/notify.wav; };
    critical = { app-name = noBattery; urgency = "Critical"; exec = playSound ../../../assets/sounds/alert.wav; };
  };

  # Static swaync config.json — palette-independent, only style.css carries colors.
  # keyboard-shortcuts=true gives the control center exclusive keyboard focus,
  # so on surface every open/close moves text focus away and back and squeekboard
  # hides/re-shows with it. Surface runs it off (KeyboardMode.NONE); desktop keeps Esc/arrow nav.
  swayncConfig = pkgs.writeText "swaync-config.json" ''
    {
      "positionX": "right",
      "positionY": "top",
      "control-center-margin-top": 8,
      "control-center-margin-bottom": 8,
      "control-center-margin-right": 8,
      "control-center-margin-left": 0,
      "notification-icon-size": 48,
      "notification-body-image-height": 100,
      "notification-body-image-width": 200,
      "timeout": 5,
      "timeout-low": 3,
      "timeout-critical": 0,
      "fit-to-screen": true,
      "control-center-width": 360,
      "notification-window-width": 300,
      "keyboard-shortcuts": ${lib.boolToString (!config.myConfig.hasTouch)},
      "image-visibility": "when-available",
      "transition-time": 100,
      "hide-on-clear": true,
      "hide-on-action": true,
      "notification-inline-replies": true,
      "script-fail-notify": true,
      "scripts": ${builtins.toJSON notifySoundScripts},
      "notification-visibility": {
        "tether": { "state": "ignored", "app-name": "^Tether$" }
      },
      "widgets": ${builtins.toJSON (
        [ "title" "notifications" "label#hdr-audio" "volume" ]
        ++ lib.optional config.myConfig.hasBacklight "backlight"
        ++ [
          "label#hdr-connectivity" "buttons-grid#connectivity"
          "label#hdr-system" "buttons-grid#system"
          "label#hdr-appearance" "buttons-grid#appearance"
        ]
      )},
      "widget-config": {
        "title": {
          "text": "Notifications",
          "clear-all-button": true,
          "button-text": "Clear All"
        },
        "label#hdr-audio": { "text": "Audio & Display" },
        "label#hdr-connectivity": { "text": "Connectivity" },
        "label#hdr-system": { "text": "System" },
        "label#hdr-appearance": { "text": "Appearance" },
        "volume": {},
        "backlight": { "device": "intel_backlight" },
        "buttons-grid#connectivity": { "actions": ${builtins.toJSON connectivityActions} },
        "buttons-grid#system": { "actions": ${builtins.toJSON systemActions} },
        "buttons-grid#appearance": { "actions": ${builtins.toJSON appearanceActions} },
        "notifications": { "vexpand": true }
      }
    }
  '';
in
{
  services.swaync.enable = true;
  xdg.configFile."swaync/config.json" = lib.mkForce { source = swayncConfig; force = true; };

  # notify-send sends no icon, so swaync falls back to the missing-image glyph;
  # it looks the app icon up by app name.
  xdg.dataFile."icons/hicolor/scalable/apps/notify-send.svg".source = ../../../assets/notify-send.svg;
}
