#!/bin/sh
# quivr-detail: framed per-host detail for the quivr detail view, streamed over ssh while a host is open.
# POSIX sh + awk only (retro/pi have no python3, retro no jq). PROC_ROOT, QUIVR_DF, PASSWD_FILE,
# QUIVR_PAGE and QUIVR_HZ exist so the tests can use fixtures.
PROC=${PROC_ROOT:-/proc}
INTERVAL=${QUIVR_DETAIL_INTERVAL:-2}
COUNT=${QUIVR_COUNT:-0}
PAGE=${QUIVR_PAGE:-$(getconf PAGESIZE 2>/dev/null || echo 4096)}
HZ=${QUIVR_HZ:-$(getconf CLK_TCK 2>/dev/null || echo 100)}
D=$(mktemp -d) || exit 1
trap 'rm -rf "$D"' EXIT
trap 'exit 0' INT TERM HUP

snap_cpu() { awk '/^cpu[0-9]/ { t = 0; for (i = 2; i <= 9; i++) t += $i; print substr($1, 4), t, $5 + $6 }' "$PROC/stat"; }

snap_net() {
  awk '{
    n = index($0, ":"); if (n == 0) next
    name = substr($0, 1, n - 1); gsub(/ /, "", name)
    if (name == "lo" || name ~ /^veth/) next
    split(substr($0, n + 1), f, " "); print name, f[1], f[9]
  }' "$PROC/net/dev"
}

snap_io() { awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+|vd[a-z]+)$/ { print $3, $6, $10 }' "$PROC/diskstats"; }

# pid, utime+stime ticks, rss pages, command: the command sits between the first "(" and the last ")"
snap_proc() {
  awk '{
    s = $0; i = index(s, "("); j = length(s)
    while (j > i && substr(s, j, 1) != ")") j--
    pid = substr(s, 1, i - 2); comm = substr(s, i + 1, j - i - 1)
    split(substr(s, j + 2), f, " ")
    print pid, f[12] + f[13], f[22], comm
  }' "$PROC"/[0-9]*/stat 2>/dev/null
}

rate_cpu() {
  awk 'NR == FNR { pt[$1] = $2; pi[$1] = $3; next }
    { dt = $2 - pt[$1]; di = $3 - pi[$1]; p = (dt > 0) ? (dt - di) * 100 / dt : 0; printf "core %s %d\n", $1, p }' \
    "$D/cpu" "$D/cpu.new"
}

rate_net() {
  awk -v i="$INTERVAL" 'NR == FNR { r[$1] = $2; t[$1] = $3; next }
    { dr = 0; dt = 0
      if ($1 in r) { dr = ($2 - r[$1]) / i; dt = ($3 - t[$1]) / i }
      if (dr < 0) dr = 0; if (dt < 0) dt = 0
      printf "net %s %d %d\n", $1, dr, dt }' "$D/net" "$D/net.new"
}

rate_io() {
  awk -v i="$INTERVAL" 'NR == FNR { r[$1] = $2; w[$1] = $3; next }
    { dr = 0; dw = 0
      if ($1 in r) { dr = ($2 - r[$1]) * 512 / i; dw = ($3 - w[$1]) * 512 / i }
      if (dr < 0) dr = 0; if (dw < 0) dw = 0
      printf "io %s %d %d\n", $1, dr, dw }' "$D/io" "$D/io.new"
}

# btrfs/impermanence repeat one device under many mountpoints: keep the first
mounts() {
  ${QUIVR_DF:-df} -P -k -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk '
    NR > 1 && !seen[$1]++ {
      gsub("%", "", $5); mp = $6
      for (i = 7; i <= NF; i++) mp = mp " " $i
      printf "mount %d %d %d %s\n", $5, $3, $2, mp
    }'
}

procs() {
  awk -v hz="$HZ" -v i="$INTERVAL" -v page="$PAGE" 'NR == FNR { t[$1] = $2; next }
    { cpu = ($1 in t) ? ($2 - t[$1]) * 100 / (hz * i) : 0; if (cpu < 0) cpu = 0
      comm = $4; for (k = 5; k <= NF; k++) comm = comm " " $k
      printf "%.1f %d %d %s\n", cpu, $1, $3 * page / 1024, comm }' "$D/proc" "$D/proc.new" > "$D/rates"
  {
    sort -k1,1 -rn "$D/rates" | head -n 10 | sed 's/^/pcpu /'
    sort -k3,3 -rn "$D/rates" | head -n 10 | sed 's/^/pmem /'
  } | awk -v proc="$PROC" -v passwd="${PASSWD_FILE:-/etc/passwd}" '
    BEGIN { while ((getline l < passwd) > 0) { split(l, p, ":"); name[p[3]] = p[1] } }
    { st = proc "/" $3 "/status"; uid = ""
      while ((getline l < st) > 0) if (l ~ /^Uid:/) { split(l, u, " "); uid = u[2] }
      close(st)
      user = (uid in name) ? name[uid] : (uid == "" ? "?" : uid)
      cmd = $5; for (k = 6; k <= NF; k++) cmd = cmd " " $k
      printf "%s %s %s %s %s %s\n", $1, $3, user, $2, $4, cmd }'
}

main() {
  snap_cpu > "$D/cpu"; snap_net > "$D/net"; snap_io > "$D/io"; snap_proc > "$D/proc"
  n=0
  while :; do
    sleep "$INTERVAL"
    snap_cpu > "$D/cpu.new"; snap_net > "$D/net.new"; snap_io > "$D/io.new"; snap_proc > "$D/proc.new"
    printf '@frame %s\n' "$(date +%s)"
    rate_cpu; rate_net; rate_io; mounts; procs
    printf '@end\n'
    for f in cpu net io proc; do mv "$D/$f.new" "$D/$f"; done
    n=$((n + 1))
    if [ "$COUNT" -gt 0 ] && [ "$n" -ge "$COUNT" ]; then exit 0; fi
  done
}

# stdin is the script itself under `sh -s`; nothing in the loop may read it
main </dev/null
