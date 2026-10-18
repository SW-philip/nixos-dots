#!/usr/bin/env bash
# Stateless ambient-light brightness: a fixed curve, no learning. A manual
# change pauses auto-adjust for AB_HOLD seconds, then the curve takes over
# again (the manual value is never remembered).
#
# Reads the apds9960 clear channel (raw counts, see pkgs/apds9960-mshw0184)
# straight from sysfs; iio-sensor-proxy's lux conversion isn't needed.

curve=${AB_CURVE:-"0:8 3:10 15:25 40:40 150:65 600:90 2000:100"} # "counts:percent" pairs
interval=${AB_INTERVAL:-2}    # seconds between sensor reads
window=${AB_WINDOW:-5}        # samples in the median
deadband=${AB_DEADBAND:-4}    # ignore target changes smaller than this (percent points)
nudge=${AB_NUDGE:-3}          # brightness drift beyond this = a manual change
hold=${AB_HOLD:-900}          # seconds auto-adjust stays paused after a manual change

dev=""
for d in /sys/bus/iio/devices/iio:device*; do
  if [ "$(cat "$d/name" 2>/dev/null)" = apds9960 ]; then
    dev=$d
    break
  fi
done
if [ -z "$dev" ]; then
  echo "autobrightness: no apds9960 iio device" >&2
  exit 1
fi

current() { brightnessctl -m | cut -d, -f4 | tr -d '%'; }

# Piecewise-linear in log(1+counts) between the curve points.
target_for() {
  awk -v lux="$1" -v pts="$curve" 'BEGIN {
    n = split(pts, p, " ")
    for (i = 1; i <= n; i++) { split(p[i], kv, ":"); x[i] = log(1 + kv[1]); y[i] = kv[2] }
    l = log(1 + lux)
    if (l <= x[1]) { print int(y[1] + 0.5); exit }
    if (l >= x[n]) { print int(y[n] + 0.5); exit }
    for (i = 2; i <= n; i++) if (l <= x[i]) {
      f = (l - x[i-1]) / (x[i] - x[i-1])
      print int(y[i-1] + f * (y[i] - y[i-1]) + 0.5); exit
    }
  }'
}

samples=()
last_set=-1
hold_until=0

while true; do
  if raw=$(cat "$dev/in_intensity_clear_raw" 2>/dev/null); then
    samples+=("$raw")
    if [ "${#samples[@]}" -gt "$window" ]; then samples=("${samples[@]:1}"); fi
    med=$(printf '%s\n' "${samples[@]}" | sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }')
    cur=$(current)
    now=$(date +%s)

    if [ "$last_set" -ge 0 ]; then
      drift=$((cur - last_set))
      if [ "${drift#-}" -gt "$nudge" ]; then
        hold_until=$((now + hold))
        last_set=$cur
      fi
    fi

    if [ "$now" -ge "$hold_until" ] && [ "${#samples[@]}" -ge "$window" ]; then
      target=$(target_for "$med")
      diff=$((target - cur))
      if [ "${diff#-}" -ge "$deadband" ]; then
        p=$cur
        while [ "$p" -ne "$target" ]; do
          if [ "$p" -lt "$target" ]; then p=$((p + 1)); else p=$((p - 1)); fi
          brightnessctl -q set "${p}%"
          sleep 0.03
        done
        last_set=$(current)
      elif [ "$last_set" -lt 0 ]; then
        last_set=$cur
      fi
    fi
  fi
  sleep "$interval"
done
