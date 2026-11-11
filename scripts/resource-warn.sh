#!/usr/bin/env bash
# Warn (toast + sound) when the machine is under strain: hot, memory-starved,
# or stalled on disk. Memory uses kernel pressure-stall info (PSI): the
# percentage of the last 10 s that tasks spent stalled. Disk uses real device
# busy time, not PSI io: threads parked in io_uring_enter (every Ghostty
# window) count as iowait, so PSI io/vmstat wa read 40-90% on an idle SSD.
# Thresholds are env-overridable and UNTUNED first guesses.
set -euo pipefail

TEMP_C=${TEMP_C:-90}
MEM_PCT=${MEM_PCT:-40}
IO_PCT=${IO_PCT:-95}
COOLDOWN=${COOLDOWN:-300}
INTERVAL=${INTERVAL:-15}
WARN_WAV=${WARN_WAV:?WARN_WAV must point at the warning sound}

state="${XDG_RUNTIME_DIR:-/tmp}/resource-warn"
mkdir -p "$state"

# warn <key> <title> <body>: toast + sound, at most once per COOLDOWN per key.
warn() {
  local now last
  now=$(date +%s)
  last=$(cat "$state/$1" 2>/dev/null || echo 0)
  if (( now - last >= COOLDOWN )); then
    echo "$now" > "$state/$1"
    notify-send -a monitor -u normal "$2" "$3" 2>/dev/null || true
    pw-play "$WARN_WAV" >/dev/null 2>&1 || true
  fi
}

# psi <resource> <some|full>: avg10 as an integer percent (0 if unavailable).
psi() {
  local v
  v=$(awk -v k="$2" '$1 == k { split($2, a, "="); printf "%d", a[2] }' "/proc/pressure/$1" 2>/dev/null || true)
  echo "${v:-0}"
}

# disk_busy_ms: highest io_ticks (ms spent with I/O in flight) across physical disks.
disk_busy_ms() {
  local d m=0 t
  for d in /sys/block/nvme*n* /sys/block/sd* /sys/block/mmcblk*; do
    [ -r "$d/stat" ] || continue
    t=$(awk '{print $10}' "$d/stat")
    if (( t > m )); then m=$t; fi
  done
  echo "$m"
}

prev_busy=$(disk_busy_ms)
prev_t=$(date +%s%3N)

while :; do
  hot=0
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$z" ] || continue
    t=$(( $(cat "$z" 2>/dev/null || echo 0) / 1000 ))
    if (( t > hot )); then hot=$t; fi
  done
  if (( hot >= TEMP_C )); then warn temp "Running hot" "${hot}°C"; fi

  mem=$(psi memory some)
  if (( mem >= MEM_PCT )); then warn mem "Memory pressure" "tasks stalled ${mem}% of the last 10s"; fi

  cur_busy=$(disk_busy_ms)
  cur_t=$(date +%s%3N)
  io=$(( (cur_busy - prev_busy) * 100 / (cur_t - prev_t) ))
  prev_busy=$cur_busy
  prev_t=$cur_t
  if (( io >= IO_PCT )); then warn io "Disk saturated" "disk busy ${io}% of the last ${INTERVAL}s"; fi

  sleep "$INTERVAL"
done
