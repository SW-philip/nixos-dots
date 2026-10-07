#!/bin/sh
# quivr-sampler: one stats line per interval on stdout, for the quivr viewer to read over ssh.
# POSIX sh + awk only: retro and pi have no python3, retro has no jq.
# PROC_ROOT / SYS_ROOT let the tests point it at fixture trees.
PROC=${PROC_ROOT:-/proc}
SYS=${SYS_ROOT:-/sys}
INTERVAL=${QUIVR_INTERVAL:-1}
COUNT=${QUIVR_COUNT:-0}

read_cpu() { # total idle (jiffies)
  awk '/^cpu /{t=0; for (i = 2; i <= 9; i++) t += $i; print t, $5 + $6; exit}' "$PROC/stat"
}

read_net() { # rx tx bytes over physical interfaces
  awk '{
    n = index($0, ":"); if (n == 0) next
    name = substr($0, 1, n - 1); gsub(/ /, "", name)
    split(substr($0, n + 1), f, " ")
    if (name ~ /^(en|eth|wl)/) { rx += f[1]; tx += f[9] }
  } END { print rx + 0, tx + 0 }' "$PROC/net/dev"
}

read_temp() { # hottest sensor in whole degrees, or -
  for f in "$SYS"/class/hwmon/hwmon*/temp*_input "$SYS"/class/thermal/thermal_zone*/temp; do
    [ -r "$f" ] && cat "$f" 2>/dev/null
  done | awk 'BEGIN { m = -1 } $1 + 0 > m { m = $1 + 0 } END { if (m < 0) print "-"; else printf "%d\n", m / 1000 }'
}

main() {
  prev_cpu=$(read_cpu)
  prev_net=$(read_net)
  n=0
  step=${QUIVR_FIRST_STEP:-0.2} # short first interval so the viewer has a row almost at once
  while :; do
    sleep "$step"
    cur_cpu=$(read_cpu)
    cur_net=$(read_net)
    cpu=$(echo "$prev_cpu $cur_cpu" | awk '{ dt = $3 - $1; di = $4 - $2; if (dt <= 0) print 0; else printf "%d\n", (dt - di) * 100 / dt }')
    net=$(echo "$prev_net $cur_net" | awk -v i="$step" '{ r = ($3 - $1) / i; t = ($4 - $2) / i; if (r < 0) r = 0; if (t < 0) t = 0; printf "%d %d\n", r, t }')
    mem=$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { print t + 0, t - a }' "$PROC/meminfo")
    load=$(awk '{ print $1 }' "$PROC/loadavg")
    up=$(awk '{ print int($1) }' "$PROC/uptime")
    disk=$(df -P / 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 + 0 }')
    cpus=$(grep -c '^processor' "$PROC/cpuinfo" 2>/dev/null)
    # shellcheck disable=SC2086  # $mem and $net are two space-separated numbers each
    set -- $mem $net
    printf 'cpu=%s mem_used=%s mem_total=%s load=%s temp=%s rx=%s tx=%s disk=%s up=%s cpus=%s\n' \
      "$cpu" "$2" "$1" "$load" "$(read_temp)" "$3" "$4" "${disk:-0}" "$up" "${cpus:-1}"
    prev_cpu=$cur_cpu
    prev_net=$cur_net
    step=$INTERVAL
    n=$((n + 1))
    if [ "$COUNT" -gt 0 ] && [ "$n" -ge "$COUNT" ]; then exit 0; fi
  done
}

# stdin is the script itself under `sh -s`; nothing in the loop may read it
main </dev/null
