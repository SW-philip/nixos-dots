#!/usr/bin/env bash
# Runs the detail sampler on fixture /proc trees, rewriting the counters mid-interval.
set -uo pipefail

SAMPLER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/quivr-detail.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P="$T/proc"
mkdir -p "$P/net" "$P/1234" "$P/77" "$P/9"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

# stat <pid> <comm> <utime> <stime> <rss pages>: 22 fields after the closing paren, utime is f12, rss f22
write_proc() {
  printf '%s (%s) S 1 %s %s 0 -1 4194560 100 0 0 0 %s %s 0 0 20 0 1 0 100 1000000 %s\n' "$1" "$2" "$1" "$1" "$3" "$4" "$5" > "$P/$1/stat"
}
write_counters() { # 1 or 2
  if [[ $1 == 1 ]]; then
    printf 'cpu  100 0 200 1700 0 0 0 0 0 0\ncpu0 100 0 100 800 0 0 0 0 0 0\ncpu1 0 0 100 900 0 0 0 0 0 0\n' > "$P/stat"
    printf '   8 0 nvme0n1 100 0 1000 0 100 0 5000 0\n   8 1 nvme0n1p1 1 0 1 0 1 0 1 0\n' > "$P/diskstats"
    nets="  eth0: 1000 10 0 0 0 0 0 0 500 5 0 0 0 0 0 0
    lo: 99999 10 0 0 0 0 0 0 99999 10 0 0 0 0 0 0
  veth1: 77777 1 0 0 0 0 0 0 77777 1 0 0 0 0 0 0"
    write_proc 1234 "my prog" 150 50 500
    write_proc 77 "kworker/0:1" 0 5 10
    write_proc 9 "idle (thing)" 0 0 50000
  else
    printf 'cpu  200 0 300 2500 100 0 0 0 0 0\ncpu0 200 0 200 1500 100 0 0 0 0 0\ncpu1 100 0 100 1700 0 0 0 0 0 0\n' > "$P/stat"
    printf '   8 0 nvme0n1 100 0 3048 0 100 0 9096 0\n   8 1 nvme0n1p1 1 0 1 0 1 0 1 0\n' > "$P/diskstats"
    nets="  eth0: 3000 10 0 0 0 0 0 0 1500 5 0 0 0 0 0 0
    lo: 199999 10 0 0 0 0 0 0 199999 10 0 0 0 0 0 0
  veth1: 877777 1 0 0 0 0 0 0 877777 1 0 0 0 0 0 0"
    write_proc 1234 "my prog" 250 50 500
    write_proc 77 "kworker/0:1" 0 15 10
    write_proc 9 "idle (thing)" 0 0 50000
  fi
  printf 'Inter-|   Receive |  Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n%s\n' "$nets" > "$P/net/dev"
}
before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)
write_counters 1
printf 'Name:\tx\nUid:\t1000\t1000\t1000\t1000\n' > "$P/1234/status"
printf 'Name:\tx\nUid:\t0\t0\t0\t0\n' > "$P/77/status"
printf 'Name:\tx\nUid:\t4242\t4242\t4242\t4242\n' > "$P/9/status"
printf 'root:x:0:0::/root:/bin/sh\nalice:x:1000:100::/home/alice:/bin/sh\n' > "$T/passwd"
cat > "$T/fakedf" <<'EOF'
#!/bin/sh
cat <<'OUT'
Filesystem        1024-blocks   Used Available Capacity Mounted on
/dev/mapper/root      1000000 500000    500000      50% /
/dev/mapper/root      1000000 500000    500000      50% /nix
/dev/sda1              200000  20000    180000      10% /mnt/my disk
OUT
EOF
chmod +x "$T/fakedf"

export PROC_ROOT="$P" QUIVR_DETAIL_INTERVAL=1 QUIVR_COUNT=1 QUIVR_HZ=100 QUIVR_PAGE=4096 QUIVR_DF="$T/fakedf" PASSWD_FILE="$T/passwd"
sh "$SAMPLER" > "$T/out" 2> "$T/err" &
pid=$!
sleep 0.4
write_counters 2
wait "$pid"

out=$(cat "$T/out")
assert_eq "no stderr" "" "$(cat "$T/err")"
assert_eq "frame starts with @frame <epoch>" "1" "$(head -1 "$T/out" | grep -c -E '^@frame [0-9]+$')"
assert_eq "frame ends with @end" "@end" "$(tail -1 "$T/out")"
assert_eq "core 0" "core 0 20" "$(grep '^core 0 ' <<<"$out")"
assert_eq "core 1" "core 1 11" "$(grep '^core 1 ' <<<"$out")"
assert_eq "net eth0 rates" "net eth0 2000 1000" "$(grep '^net eth0 ' <<<"$out")"
assert_eq "no lo or veth in net" "0" "$(grep -c -E '^net (lo|veth)' <<<"$out")"
assert_eq "io whole device only" "io nvme0n1 1048576 2097152" "$(grep '^io ' <<<"$out")"
assert_eq "mounts deduplicated by device" "2" "$(grep -c '^mount ' <<<"$out")"
assert_eq "root mount" "mount 50 500000 1000000 /" "$(grep '^mount 50 ' <<<"$out")"
assert_eq "mountpoint with spaces kept" "mount 10 20000 200000 /mnt/my disk" "$(grep '^mount 10 ' <<<"$out")"
assert_eq "top cpu process, name with spaces, user from passwd" "pcpu 1234 alice 100.0 2000 my prog" "$(grep '^pcpu ' <<<"$out" | head -1)"
assert_eq "second cpu process, root" "pcpu 77 root 10.0 40 kworker/0:1" "$(grep '^pcpu ' <<<"$out" | sed -n 2p)"
assert_eq "ten at most" "1" "$(( $(grep -c '^pcpu ' <<<"$out") <= 10 ))"
assert_eq "top mem process, unknown uid kept, parens in name" "pmem 9 4242 0.0 200000 idle (thing)" "$(grep '^pmem ' <<<"$out" | head -1)"
after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)
assert_eq "no temp dir left after a normal run" "$before" "$after"

echo "== killed sampler cleans up =="
export QUIVR_COUNT=0
before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)
sh "$SAMPLER" > /dev/null 2>&1 &
pid=$!
sleep 0.5
kill "$pid"; wait "$pid" 2>/dev/null
after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)
assert_eq "no temp dir left after SIGTERM" "$before" "$after"

if (( fail == 0 )); then echo "All tests passed."; else echo "Some tests failed."; fi
exit $fail
