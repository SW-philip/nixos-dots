{ pkgs, ... }:
let
  openrgb = "${pkgs.openrgb-with-all-plugins}/bin/openrgb";

  rgb-reactive = pkgs.writeShellScriptBin "rgb-reactive" ''
    # waybar/palette.sh: the file drmis actually keeps live on every
    # "drmis set" — theme/palette.sh is a stale, unrelated file frozen
    # to whatever theme was hardcoded into home/waybar/default.nix.
    PALETTE="$HOME/.config/waybar/palette.sh"
    [[ -f "$PALETTE" ]] || exit 0
    # shellcheck source=/dev/null
    source "$PALETTE"

    STATE="/run/user/$(id -u)/rgb-reactive.state"

    hex()   { printf '%s' "''${1:1}"; }
    lerp()  { echo $(( $1 + ($2 - $1) * $3 / 100 )); }
    clamp() { local v=$1; (( v < $2 )) && v=$2; (( v > $3 )) && v=$3; echo $v; }

    # interpolate between two #RRGGBB colors, t=0..100
    interp() {
      local a="''${1:1}" b="''${2:1}" t=$3 r g bl
      r=$(lerp  "0x''${a:0:2}" "0x''${b:0:2}" $t)
      g=$(lerp  "0x''${a:2:2}" "0x''${b:2:2}" $t)
      bl=$(lerp "0x''${a:4:2}" "0x''${b:4:2}" $t)
      printf '%02x%02x%02x' $r $g $bl
    }

    # ── sensors ──────────────────────────────────────────────────────────────
    CPU_TEMP=$(cat /sys/class/hwmon/hwmon*/temp*_input 2>/dev/null | sort -rn | head -1)
    CPU_TEMP=$(( ''${CPU_TEMP:-45000} / 1000 ))

    read -r RAM_TOTAL RAM_AVAIL < <(
      awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t" "a}' /proc/meminfo
    )
    RAM_PCT=$(( (RAM_TOTAL - RAM_AVAIL) * 100 / RAM_TOTAL ))

    # ── thresholds ────────────────────────────────────────────────────────────
    TEMP_IDLE=50   # °C — below this AND ram idle → firmware effect
    TEMP_HOT=82    # °C — full FORTE red
    RAM_IDLE=35    # % — below this AND temp idle → firmware effect

    ACTIVE=0
    (( CPU_TEMP >= TEMP_IDLE || RAM_PCT >= RAM_IDLE )) && ACTIVE=1

    # ── idle: set firmware effect once, then bail ─────────────────────────────
    if (( ACTIVE == 0 )); then
      [[ "$(cat "$STATE" 2>/dev/null)" == "hardware" ]] && exit 0
      for d in 0 1 2 3; do
        ${openrgb} --device $d --mode "Color Pulse" --color "$(hex "$FIFTH")"
      done
      echo "hardware" > "$STATE"
      exit 0
    fi

    # ── active: heat map per stick ────────────────────────────────────────────
    # temp → hue: FIFTH (cool) → PIANO (warm) → FORTE (hot), two-segment gradient
    T=$(clamp $(( (CPU_TEMP - TEMP_IDLE) * 100 / (TEMP_HOT - TEMP_IDLE) )) 0 100)
    if (( T <= 50 )); then
      HEAT=$(interp "$FIFTH" "$PIANO" $(( T * 2 )))
    else
      HEAT=$(interp "$PIANO" "$FORTE" $(( (T - 50) * 2 )))
    fi

    # very faint SEVENTH tint for unfilled quartile sticks
    DIM=$(interp "#000000" "$SEVENTH" 12)

    # sticks 0-3 fill left-to-right with RAM usage (each stick = one 25% quartile)
    for d in 0 1 2 3; do
      lo=$(( d * 25 ))
      hi=$(( (d + 1) * 25 ))
      if (( RAM_PCT >= hi )); then
        COLOR=$HEAT
      elif (( RAM_PCT >= lo )); then
        partial=$(( (RAM_PCT - lo) * 4 ))
        COLOR=$(interp "#$DIM" "#$HEAT" $partial)
      else
        COLOR=$DIM
      fi
      ${openrgb} --device $d --mode Direct --color "$COLOR"
    done

    echo "direct" > "$STATE"
  '';
in
{
  home.packages = [ rgb-reactive ];

  systemd.user.services.rgb-reactive = {
    Unit = {
      Description = "Hardware-reactive RAM RGB";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${rgb-reactive}/bin/rgb-reactive";
    };
  };

  systemd.user.timers.rgb-reactive = {
    Unit = {
      Description = "Hardware-reactive RAM RGB timer";
    };
    Timer = {
      OnBootSec = "30s";
      OnUnitActiveSec = "5s";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
