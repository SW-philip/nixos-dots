#!/usr/bin/env bash
# reaper: one pass over the whole fleet for stale processes.
#   reaper           sweep every host (this one locally, the rest over ssh) -> ~/.cache/reaper.json
#   reaper probe     what the sweep runs on each host: print findings as TSV, nothing else
# A zombie can't be killed, only reaped by its parent, so the one action taken is a SIGCHLD nudge to the
# parent (own processes only). Anything that survives the nudge, or is wedged in D state, is reported:
# never SIGKILL'd, since the parent may be mid-write to something that matters.
set -euo pipefail

MIN_AGE=${REAPER_MIN_AGE:-600}

probe() {
  local sample1 sample2 pid ppid age comm pcomm nudged still zpids=()
  # D-state: first sample now, second after the nudge pause below
  sample1=$(ps -eo pid=,ppid=,stat=,etimes=,comm= | awk -v m="$MIN_AGE" '$3 ~ /^D/ && $2 != 2 && $1 != 2 && $4 >= m {print $1 "\t" $4 "\t" $5}')
  # stat=Z lines: pid ppid age comm
  while read -r pid ppid age comm; do
    (( age >= MIN_AGE )) || continue
    pcomm=$(ps -o comm= -p "$ppid" 2>/dev/null || echo '?')
    nudged=0; kill -CHLD "$ppid" 2>/dev/null && nudged=1
    printf 'Z\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$age" "${comm%% *}" "$pcomm" "$nudged"
    zpids+=("$pid")
  done < <(ps -eo pid=,ppid=,stat=,etimes=,comm= | awk '$3 ~ /^Z/ {print $1, $2, $4, $5}')
  sleep 3
  # a zombie that outlived the nudge is the finding
  for pid in "${zpids[@]}"; do
    still=0; [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" == Z* ]] && still=1
    printf 'S\t%s\t%s\n' "$pid" "$still"
  done
  # same pid in D in both samples 3s apart: wedged on I/O, not just briefly waiting
  sample2=$(ps -eo pid= -o stat= | awk '$2 ~ /^D/ {print $1}')
  while IFS=$'\t' read -r pid age comm; do
    [[ -n "$pid" ]] && grep -qx "$pid" <<<"$sample2" && printf 'D\t%s\t%s\t%s\n' "$pid" "$age" "$comm"
  done <<<"$sample1"
  # failed units (reported only: some, like a wifi rescan, fail by design)
  systemctl --failed --no-legend --plain 2>/dev/null | awk '{print "F\tsystem\t" $1}' || true
  systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print "F\tuser\t" $1}' || true
}

if [[ "${1:-}" == probe ]]; then probe; exit 0; fi

OUT=${REAPER_OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/reaper.json}
HOSTS=${REAPER_HOSTS:-"desktop surface retro pi"}
SELF=${REAPER_SELF:-$(uname -n)}
SSH_TIMEOUT=${REAPER_SSH_TIMEOUT:-5}
SELF_PATH=$(readlink -f "$0")

nix_name() { case $1 in desktop) echo swphil ;; surface) echo swsurface ;; retro) echo swretro ;; pi) echo swpi ;; *) echo "$1" ;; esac; }

findings_json() { # TSV on stdin -> {zombies,stuck,dstate,failed}
  jq -Rn '
    [inputs | split("\t")] as $r
    | ($r | map(select(.[0] == "S") | {(.[1]): (.[2] == "1")}) | add // {}) as $still
    | {
        zombies: [$r[] | select(.[0] == "Z") | {pid: .[1], ppid: .[2], age: (.[3] | tonumber), comm: .[4], parent: .[5], nudged: (.[6] == "1"), persists: ($still[.[1]] // true)}],
        dstate:  [$r[] | select(.[0] == "D") | {pid: .[1], age: (.[2] | tonumber), comm: .[3]}],
        failed:  [$r[] | select(.[0] == "F") | {scope: .[1], unit: .[2]}]
      }'
}

sweep_host() {
  local host=$1 tsv rc=0
  if [[ "${SELF,,}" == "$(nix_name "$host")" ]]; then
    tsv=$(REAPER_MIN_AGE=$MIN_AGE bash "$SELF_PATH" probe 2>/dev/null) || rc=$?
  else
    tsv=$(timeout "$((SSH_TIMEOUT + 15))" ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" \
      "REAPER_MIN_AGE=$MIN_AGE bash -s -- probe" <"$SELF_PATH" 2>/dev/null) || rc=$?
  fi
  if (( rc != 0 )); then
    jq -n --arg h "$host" '{($h): {reachable: false}}'
  else
    findings_json <<<"$tsv" | jq --arg h "$host" '{($h): (. + {reachable: true})}'
  fi
}

mkdir -p "$(dirname "$OUT")"
merged=$(for h in $HOSTS; do sweep_host "$h"; done | jq -s --arg t "$(date +%s)" 'add | {checked: ($t | tonumber), hosts: .}')
printf '%s\n' "$merged" >"$OUT.tmp" && mv "$OUT.tmp" "$OUT"

# alert only on what a nudge didn't fix, or on I/O-wedged processes; failed units live in the JSON alone
problems=$(jq -r '.hosts | to_entries[]
  | .key as $h | .value
  | select(.reachable)
  | ((.zombies | map(select(.persists)) | group_by(.parent)[]
      | "\($h): \(length) zombie(s) under \(.[0].parent), oldest \(map(.age) | max / 60 | floor) min"),
     (.dstate[] | "\($h): \(.comm) (\(.pid)) stuck in D state \(.age / 60 | floor) min"))' <<<"$merged")

if [[ -n "$problems" ]]; then
  printf '%s\n' "$problems"
  notify-send -a reaper -u normal "reaper: stale processes" "$problems" 2>/dev/null || true
else
  echo "reaper: fleet clean"
fi
