#!/usr/bin/env bash
# One JSON line with what the tablet strip and sheet show that the shared eww
# feeds (net, bt, power) don't. A value that can't be read degrades to a
# neutral default so the sheet never renders a hole.
set -uo pipefail
export LC_ALL=C

num() { [[ "$1" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }

# eww's scale echoes a programmatic :value back through :onchange, so a failed
# read must not publish 0 (that would silence the sink / black the screen).
cache="${XDG_RUNTIME_DIR:-/tmp}/tablet-state.last"
c_vol=0; c_bright=0
if [[ -r "$cache" ]]; then
  { read -r c_vol; read -r c_bright; } <"$cache" 2>/dev/null || true
  c_vol=$(num "$c_vol"); c_bright=$(num "$c_bright")
fi

vol=$c_vol; muted=false; vol_ok=false
if out=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null); then
  vol=$(awk '{ printf "%d", $2 * 100 + 0.5 }' <<<"$out")
  vol=$(num "$vol"); vol_ok=true
  [[ "$out" == *MUTED* ]] && muted=true
fi

bright=$c_bright; bright_ok=false
if out=$(brightnessctl -m 2>/dev/null); then
  b=$(cut -d, -f4 <<<"$out" | tr -d '%')
  if [[ "$b" =~ ^[0-9]+$ ]]; then bright=$b; bright_ok=true; fi
fi

if { $vol_ok || $bright_ok; } && [[ "$vol $bright" != "$c_vol $c_bright" ]]; then
  tmp=$(mktemp "$cache.XXXXXX" 2>/dev/null) &&
    { printf '%s\n%s\n' "$vol" "$bright" >"$tmp" && mv -f "$tmp" "$cache"; } || true
fi

ws=$(niri msg --json workspaces 2>/dev/null | jq -r '
  [.[] | select(.output == "eDP-1" and .is_active)][0]
  | if . == null then "" else (.name // (.idx | tostring)) end' 2>/dev/null) || ws=""

profile=$(powerprofilesctl get 2>/dev/null) || profile=""

bat_dir="${TABLET_BAT_DIR:-$(find /sys/class/power_supply -maxdepth 1 -name 'BAT*' 2>/dev/null | head -1)}"
pct=0; state=Unknown; eta=null; eta_text=""
if [[ -n "$bat_dir" && -r "$bat_dir/capacity" ]]; then
  pct=$(num "$(<"$bat_dir/capacity")")
  state=$(<"$bat_dir/status")
  rd() { local f; for f in "$@"; do [[ -r "$bat_dir/$f" ]] && { num "$(<"$bat_dir/$f")"; return; }; done; echo 0; }
  now=$(rd energy_now charge_now); full=$(rd energy_full charge_full); rate=$(rd power_now current_now)
  case "$state" in
    Discharging) want=$now ;;
    Charging)    want=$((full - now)) ;;
    *)           want=0 ;;
  esac
  if (( rate > 0 && want > 0 )); then
    eta=$(( want * 60 / rate ))
    eta_text=$(printf '%dh %02dm' $((eta / 60)) $((eta % 60)))
  fi
fi

playing=false; paused=false; stext=""
line=$(timeout 2 sqlch status 2>/dev/null | head -1) || line=""
if [[ -n "$line" && "$line" != "Not playing"* ]]; then
  playing=true; stext="$line"
  [[ "${line,,}" == *paused* ]] && paused=true
fi

wifi_on=false; [[ "$(timeout 2 nmcli radio wifi 2>/dev/null)" == enabled ]] && wifi_on=true
bt_on=false; timeout 2 bluetoothctl show 2>/dev/null | grep -q 'Powered: yes' && bt_on=true
rotate_on=false; systemctl --user is-active --quiet niri-rotation.service && rotate_on=true
dnd_on=false; [[ "$(timeout 2 swaync-client -D 2>/dev/null)" == true ]] && dnd_on=true

jq -nc \
  --argjson vol "$vol" --argjson muted "$muted" --argjson bright "$bright" \
  --arg ws "$ws" --arg profile "$profile" \
  --argjson pct "$pct" --arg state "$state" --argjson eta "$eta" --arg eta_text "$eta_text" \
  --argjson playing "$playing" --argjson paused "$paused" --arg stext "$stext" \
  --argjson wifi_on "$wifi_on" --argjson bt_on "$bt_on" \
  --argjson rotate_on "$rotate_on" --argjson dnd_on "$dnd_on" \
  '{vol:$vol, muted:$muted, bright:$bright, ws:$ws, profile:$profile,
    bat:{pct:$pct, state:$state, eta_min:$eta, eta_text:$eta_text},
    sqlch:{playing:$playing, paused:$paused, text:$stext},
    wifi_on:$wifi_on, bt_on:$bt_on, rotate_on:$rotate_on, dnd_on:$dnd_on}'
