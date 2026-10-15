#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../tablet-state.sh"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/fx" "$TMP/bat"

# Each stub prints $FX/<name> and exits 1 (printing nothing) when $FX/<name>.fail exists.
for t in wpctl brightnessctl niri powerprofilesctl nmcli bluetoothctl swaync-client sqlch; do
  cat > "$TMP/bin/$t" <<STUB
#!/usr/bin/env bash
[ -e "$TMP/fx/$t.fail" ] && exit 1
cat "$TMP/fx/$t" 2>/dev/null
exit 0
STUB
  chmod +x "$TMP/bin/$t"
done
cat > "$TMP/bin/systemctl" <<STUB
#!/usr/bin/env bash
[ -e "$TMP/fx/systemctl.fail" ] && exit 3
exit 0
STUB
chmod +x "$TMP/bin/systemctl"

fx() { printf '%s\n' "$2" > "$TMP/fx/$1"; }
reset() {
  rm -rf "$TMP"/fx/* "$TMP/rt"; mkdir -p "$TMP/rt"
  fx wpctl "Volume: 0.40"
  fx brightnessctl "intel,backlight,48000,50%,96000"
  fx niri '[{"id":1,"idx":1,"name":"code","output":"eDP-1","is_active":true},{"id":2,"idx":2,"name":null,"output":"HDMI-A-1","is_active":true}]'
  fx powerprofilesctl balanced
  fx nmcli enabled
  fx bluetoothctl "Controller AA:BB Powered: yes"
  fx swaync-client false
  fx sqlch "Not playing"
  echo 87 > "$TMP/bat/capacity"; echo Discharging > "$TMP/bat/status"
  echo 30000000 > "$TMP/bat/energy_now"; echo 40000000 > "$TMP/bat/energy_full"; echo 6000000 > "$TMP/bat/power_now"
}
run() { XDG_RUNTIME_DIR="$TMP/rt" PATH="$TMP/bin:$PATH" TABLET_BAT_DIR="${BAT_DIR:-$TMP/bat}" bash "$SCRIPT"; }
check() { # <name> <jq filter>
  if run | jq -e "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

reset
check "healthy snapshot" '.vol==40 and .muted==false and .bright==50 and .ws=="code"
  and .profile=="balanced" and .bat.pct==87 and .bat.state=="Discharging"
  and .bat.eta_min==300 and .bat.eta_text=="5h 00m"
  and .sqlch.playing==false and .wifi_on and .bt_on and .rotate_on and (.dnd_on|not)'

reset; fx wpctl "Volume: 0.00 [MUTED]"; fx sqlch "Paused: Radio Paradise"
echo Charging > "$TMP/bat/status"
check "muted, sqlch paused, charging eta" '.vol==0 and .muted==true and .sqlch.playing and .sqlch.paused
  and .sqlch.text=="Paused: Radio Paradise" and .bat.eta_min==100 and .bat.eta_text=="1h 40m"'

reset; fx swaync-client true; fx nmcli disabled; fx bluetoothctl "Powered: no"; touch "$TMP/fx/systemctl.fail"
check "toggle states" '.dnd_on and (.wifi_on|not) and (.bt_on|not) and (.rotate_on|not)'

reset; for t in wpctl brightnessctl niri powerprofilesctl nmcli bluetoothctl swaync-client sqlch systemctl; do touch "$TMP/fx/$t.fail"; done
BAT_DIR="$TMP/nobat" check "every tool failing degrades to neutral defaults" '.vol==0 and .bright==0 and .ws==""
  and .profile=="" and .bat.pct==0 and .bat.eta_min==null and .bat.eta_text==""
  and (.sqlch.playing|not) and (.wifi_on|not) and (.bt_on|not) and (.rotate_on|not) and (.dnd_on|not)'

reset; run >/dev/null
for t in wpctl brightnessctl; do touch "$TMP/fx/$t.fail"; done
check "failed vol/bright reads re-emit the last good values" '.vol==40 and .bright==50'
fx wpctl "Volume: 0.25"; rm -f "$TMP/fx/wpctl.fail"
check "a good read replaces the cache" '.vol==25 and .bright==50'
touch "$TMP/fx/wpctl.fail"
check "cache updated by the good read" '.vol==25 and .bright==50'

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
