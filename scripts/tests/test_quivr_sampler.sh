#!/usr/bin/env bash
# Runs the sampler against fixture /proc and /sys trees, rewriting the counters mid-interval.
set -uo pipefail

SAMPLER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/quivr-sampler.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P="$T/proc"; S="$T/sys"
mkdir -p "$P/net" "$S/class/hwmon/hwmon0" "$S/class/hwmon/hwmon1" "$S/class/thermal/thermal_zone0"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

write_counters() { # 1 or 2
  if [[ $1 == 1 ]]; then
    echo "cpu  100 0 100 800 0 0 0 0 0 0" > "$P/stat"
    nets="  eth0: 1000 10 0 0 0 0 0 0 500 5 0 0 0 0 0 0
  wlan0: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    lo: 99999 10 0 0 0 0 0 0 99999 10 0 0 0 0 0 0
  tailscale0: 5000 1 0 0 0 0 0 0 5000 1 0 0 0 0 0 0"
  else
    echo "cpu  200 0 200 1500 100 0 0 0 0 0" > "$P/stat"
    nets="  eth0: 3000 10 0 0 0 0 0 0 1500 5 0 0 0 0 0 0
  wlan0: 1000 0 0 0 0 0 0 0 500 0 0 0 0 0 0 0
    lo: 199999 10 0 0 0 0 0 0 199999 10 0 0 0 0 0 0
  tailscale0: 905000 1 0 0 0 0 0 0 905000 1 0 0 0 0 0 0"
  fi
  printf 'Inter-|   Receive |  Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n%s\n' "$nets" > "$P/net/dev"
}
write_counters 1
printf 'MemTotal:        8000000 kB\nMemFree:          100000 kB\nMemAvailable:    6000000 kB\n' > "$P/meminfo"
echo "0.52 0.40 0.30 1/200 999" > "$P/loadavg"
echo "3600.55 100.00" > "$P/uptime"
echo 45000 > "$S/class/hwmon/hwmon0/temp1_input"
echo 61000 > "$S/class/hwmon/hwmon1/temp1_input"
echo 52000 > "$S/class/thermal/thermal_zone0/temp"
printf 'processor\t: 0\n\nprocessor\t: 1\n' > "$P/cpuinfo"

PROC_ROOT="$P" SYS_ROOT="$S" QUIVR_INTERVAL=1 QUIVR_FIRST_STEP=1 QUIVR_COUNT=1 sh "$SAMPLER" > "$T/out" 2> "$T/err" &
pid=$!
sleep 0.4
write_counters 2
wait "$pid"

line=$(cat "$T/out")
assert_eq "exactly one line" "1" "$(wc -l < "$T/out" | tr -d ' ')"
assert_eq "no stderr" "" "$(cat "$T/err")"
assert_eq "cpu from the stat delta" "20" "$(grep -o 'cpu=[0-9]*' <<<"$line" | cut -d= -f2)"
assert_eq "mem_used is total minus available" "2000000" "$(grep -o 'mem_used=[0-9]*' <<<"$line" | cut -d= -f2)"
assert_eq "mem_total" "8000000" "$(grep -o 'mem_total=[0-9]*' <<<"$line" | cut -d= -f2)"
assert_eq "load" "0.52" "$(grep -o 'load=[0-9.]*' <<<"$line" | cut -d= -f2)"
assert_eq "temp is the hottest sensor" "61" "$(grep -o 'temp=[0-9-]*' <<<"$line" | cut -d= -f2)"
assert_eq "rx counts physical interfaces only" "3000" "$(grep -o 'rx=[0-9]*' <<<"$line" | cut -d= -f2)"
assert_eq "tx counts physical interfaces only" "1500" "$(grep -o 'tx=[0-9]*' <<<"$line" | cut -d= -f2)"
assert_eq "uptime is whole seconds" "3600" "$(grep -o 'up=[0-9]*' <<<"$line" | cut -d= -f2)"
assert_eq "cpus counts processors" "2" "$(grep -o 'cpus=[0-9]*' <<<"$line" | cut -d= -f2)"
disk=$(grep -o 'disk=[0-9]*' <<<"$line" | cut -d= -f2)
if [[ "$disk" =~ ^[0-9]+$ ]] && (( disk >= 0 && disk <= 100 )); then echo "PASS: disk is a percentage"; else echo "FAIL: disk is '$disk'"; fail=1; fi

echo "== no sensors =="
rm -rf "$S/class"
mkdir -p "$S/class"
PROC_ROOT="$P" SYS_ROOT="$S" QUIVR_INTERVAL=1 QUIVR_COUNT=1 sh "$SAMPLER" > "$T/out2" 2> "$T/err2"
assert_eq "temp is - without sensors" "-" "$(grep -o 'temp=[0-9-]*' "$T/out2" | cut -d= -f2)"
assert_eq "no stderr without sensors" "" "$(cat "$T/err2")"

if (( fail == 0 )); then echo "All tests passed."; else echo "Some tests failed."; fi
exit $fail
