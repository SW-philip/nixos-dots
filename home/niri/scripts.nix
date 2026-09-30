# Niri session utility scripts — shell derivations for Wayland tools, screen capture,
# MPRIS, and waybar mode. Extracted from home/niri/default.nix for modularity.
{ pkgs, lib }:
{
  swaybgLauncher = pkgs.writeShellScript "swaybg-launcher" ''
    exec ${pkgs.swaybg}/bin/swaybg -o '*' -i "$(cat "$HOME/.local/state/wallpaper")" -m fill
  '';

  toggleDisplayMode = pkgs.writeShellScriptBin "toggle-display-mode" ''
    STATE="$HOME/.local/state/monitor-mode"
    mkdir -p "$HOME/.local/state"
    CURRENT=$(cat "$STATE" 2>/dev/null || echo "dual")

    if [ "$CURRENT" = "dual" ]; then
      kanshictl switch desktop-solo && echo "single" > "$STATE"
    else
      kanshictl switch desktop-dual && echo "dual" > "$STATE"
    fi
  '';

  mprisWatch = pkgs.writeShellScriptBin "mpris-watch" ''
    export PATH="${lib.makeBinPath [ pkgs.playerctl pkgs.jq pkgs.coreutils pkgs.gnused ]}:$PATH"

    SNARK_FILE="$HOME/.config/waybar/snark.json"
    SNARK_CACHE="''${XDG_RUNTIME_DIR:-/tmp}/mpris-watch-snark"

    STATUS=$(playerctl status 2>/dev/null)
    TITLE=$(playerctl metadata --format '{{title}}' 2>/dev/null)
    ARTIST=$(playerctl metadata --format '{{artist}}' 2>/dev/null)

    if [[ "$STATUS" == "Playing" || "$STATUS" == "Paused" ]] && [[ -n "$TITLE" ]]; then
      rm -f "$SNARK_CACHE"

      _icy_f1='^title="([^"]*)".*,artist="([^"]*)"'
      _icy_spot=' song_spot="([^"]*)"'
      _icy_text=' text="([^"]*)"'
      is_ad=false
      if [[ "$TITLE" =~ $_icy_f1 ]]; then
        TITLE="''${BASH_REMATCH[1]}"
        [[ -z "$ARTIST" ]] && ARTIST="''${BASH_REMATCH[2]}"
      elif [[ "$TITLE" =~ song_spot= || "$TITLE" =~ MediaBaseId= ]]; then
        icy_spot=""; [[ "$TITLE" =~ $_icy_spot ]] && icy_spot="''${BASH_REMATCH[1]}"
        icy_text=""; [[ "$TITLE" =~ $_icy_text ]] && icy_text="''${BASH_REMATCH[1]}"
        icy_pre="$(echo "$TITLE" | sed 's/ [A-Za-z_][A-Za-z0-9_]*=.*//')"
        icy_pre="''${icy_pre% -}"; icy_pre="''${icy_pre% }"
        if [[ "$icy_spot" == "M" ]]; then
          TITLE="''${icy_text:-$icy_pre}"
          [[ -z "$ARTIST" && -n "$icy_pre" ]] && ARTIST="$icy_pre"
        else
          TITLE="$icy_pre"
          [[ -z "$ARTIST" && -n "$icy_text" ]] && ARTIST="$icy_text"
          is_ad=true
        fi
      fi

      if [[ -z "$ARTIST" && "$TITLE" == *" - "* ]]; then
        ARTIST="''${TITLE%% - *}"
        TITLE="''${TITLE#* - }"
      fi

      AD_MARK=""
      [[ "$is_ad" == true ]] && AD_MARK=" ·ad"

      case "$STATUS" in
        Playing) echo "󰎆 $TITLE — $ARTIST''${AD_MARK}" ;;
        Paused)  echo "󰏤 $TITLE — $ARTIST''${AD_MARK}" ;;
      esac
    else
      if [[ ! -f "$SNARK_CACHE" ]]; then
        jq -r '.mpris.stopped[]' "$SNARK_FILE" 2>/dev/null | shuf -n1 \
          > "$SNARK_CACHE" || echo "The silence judges you." > "$SNARK_CACHE"
      fi
      cat "$SNARK_CACHE"
    fi
  '';

  # Manual show/hide for squeekboard (swaync toggle, Mod+Shift+W, three-finger tap);
  # "hide" is for the focus policy (leaving a browser). No-op unless squeekboard.service is up, i.e.
  # unless the Type Cover is detached.
  toggleOsk = pkgs.writeShellScriptBin "toggle-osk" ''
    SC=${pkgs.systemd}/bin/systemctl
    BC=${pkgs.systemd}/bin/busctl

    visible() {
      $BC --user get-property sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 Visible 2>/dev/null | grep -q true
    }

    if [ "$1" = status ]; then
      $SC --user is-active --quiet squeekboard.service && visible && echo true || echo false
      exit 0
    fi

    if [ "$1" = hide ]; then
      $SC --user is-active --quiet squeekboard.service || exit 0
      exec $BC --user call sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 SetVisible b false
    fi

    $SC --user is-active --quiet squeekboard.service || exit 0
    if visible; then want=false; else want=true; fi
    exec $BC --user call sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 SetVisible b $want
  '';

  # Four-finger tap (osk-gesture.py) with Pegasus focused: touchscreens have no
  # keyboard to quit with. Ask first via a fuzzel dmenu (touch-tappable), then
  # close the window. Any other focused window: do nothing.
  pegasusExit = pkgs.writeShellScriptBin "pegasus-exit" ''
    NIRI=/run/current-system/sw/bin/niri
    win=$($NIRI msg --json focused-window 2>/dev/null) || exit 0
    id=$(echo "$win" | ${pkgs.jq}/bin/jq -r '.id // empty')
    echo "$win" | ${pkgs.jq}/bin/jq -e '(.app_id // "") | ascii_downcase | contains("pegasus")' >/dev/null || exit 0
    ${pkgs.procps}/bin/pgrep -x fuzzel >/dev/null && exit 0
    pick=$(printf 'Quit Pegasus\nCancel\n' | ${pkgs.fuzzel}/bin/fuzzel --dmenu --prompt 'Leave Pegasus? ')
    [ "$pick" = "Quit Pegasus" ] && exec $NIRI msg action close-window --id "$id"
  '';

  # Cover detached: the tablet tile grid (eww window launcher-tablet). Otherwise fuzzel's
  # drun list, with a random dry placeholder line. Desktop has no cover-state file, so it
  # always gets fuzzel. PATH is appended so a caller's own PATH wins (tests stub fuzzel
  # that way); fuzzel lives in the user profile. Fuzzel isn't single-instance, so a second
  # press kills the open one (toggle).
  launcher = pkgs.writeShellScriptBin "launcher" ''
    export PATH="$PATH:/etc/profiles/per-user/$(id -un)/bin"
    state="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/surface-cover"
    if [ "$(cat "$state" 2>/dev/null)" = detached ]; then
      exec "''${LAUNCHER_EWW:-${pkgs.eww}/bin/eww}" open --toggle launcher-tablet
    fi
    pkill -x fuzzel && exit 0
    exec fuzzel --placeholder "$(shuf -n1 ${../../assets/launcher-lines.txt})"
  '';

  shootAnnotate = pkgs.writeShellScriptBin "shoot-annotate" ''
    export PATH="${lib.makeBinPath [ pkgs.grim pkgs.slurp pkgs.satty pkgs.coreutils ]}:$PATH"
    geom=$(slurp) || exit 0
    grim -g "$geom" - | satty --filename - --copy-command wl-copy \
      --output-filename "$HOME/Pictures/Screenshots/annotated-$(date +%Y%m%d-%H%M%S).png"
  '';

  screenRecordToggle = pkgs.writeShellScriptBin "screen-record-toggle" ''
    # Helpers go in PATH; gpu-screen-recorder is left to resolve from the system
    # PATH so it uses the setuid-wrapped build (its gsr-kms-server needs it).
    export PATH="${lib.makeBinPath [ pkgs.procps pkgs.coreutils pkgs.libnotify pkgs.losslesscut-bin ]}:$PATH"
    # Match the command line, not -x: comm truncates to 15 chars
    # ("gpu-screen-reco") so -x against the 19-char name never matched and
    # every press started a new recorder instead of stopping the running one.
    if pkill -INT -f 'gpu-screen-recorder -w screen'; then
      notify-send "Screen recording" "Stopped — opening in LosslessCut"
      exit 0
    fi
    out="$HOME/Videos/recording-$(date +%Y%m%d-%H%M%S).mp4"
    notify-send "Screen recording" "Started"
    gpu-screen-recorder -w screen -f 60 -a default_output -o "$out"
    losslesscut "$out"
  '';

  # Resolve a PipeWire sink by node.name and make it the default. kanshi fires
  # this on display hotplug (home/niri/default.nix): the NVIDIA HDMI sink only
  # exists while the TV is connected — and can linger as a phantom default when
  # it isn't — so the DP-monitor profiles fire it too, to revert to S/PDIF.
  setDefaultSink = pkgs.writeShellScript "set-default-sink" ''
    export PATH="${lib.makeBinPath [ pkgs.wireplumber pkgs.pipewire pkgs.jq pkgs.coreutils ]}:$PATH"
    target="$1"
    # The ALSA sink can lag the display hotplug by a beat — retry briefly.
    for _ in $(seq 1 10); do
      id=$(pw-dump 2>/dev/null | jq -r --arg n "$target" \
        '.[] | select(.type == "PipeWire:Interface:Node"
                      and .info.props."media.class" == "Audio/Sink"
                      and .info.props."node.name" == $n) | .id' | head -n1)
      [ -n "$id" ] && break
      sleep 0.5
    done
    if [ -z "$id" ]; then
      echo "set-default-sink: '$target' not present — leaving default alone" >&2
      exit 0
    fi
    wpctl set-default "$id"
    echo "set-default-sink: default sink -> $target (id $id)" >&2
  '';

  # Writes waybar mode state and restarts waybar. Idempotent: skips restart if mode unchanged.
  setWaybarMode = pkgs.writeShellScript "waybar-set-mode" ''
    MODE_FILE="$HOME/.local/state/waybar-mode"
    [ "$(cat "$MODE_FILE" 2>/dev/null)" = "$1" ] && exit 0
    mkdir -p "$(dirname "$MODE_FILE")"
    printf '%s' "$1" > "$MODE_FILE"
    /run/current-system/sw/bin/systemctl --user restart waybar
  '';
}
