#!/usr/bin/env bash
# goodnight-reboot: decide which hosts are worth a reboot tonight. Report only; it never reboots.
#   goodnight-reboot plan [--json] [host...]   evaluate hosts (default: all, this one last)
#   goodnight-reboot probe                     what plan runs on each host: key=value facts
# A host is worth rebooting when any REASON holds, and safe to when no BLOCK does:
#   reasons: uptime >= REBOOT_DAYS · kernel/initrd differ from the running ones · MemAvailable <=
#            REBOOT_MEM_PCT or swap >= REBOOT_SWAP_PCT · reaper saw stuck processes in REBOOT_STRIKES
#            sweeps in a row (zombies that survive its nudge, D state; failed units don't count)
#   blocks:  unreachable · a shutdown inhibitor · a build/backup/sync job · a live Sunshine stream ·
#            battery below REBOOT_MIN_BATTERY, default 30 (a firmware hang with a flat battery is unrecoverable)
# Page cache is deliberately not a reason: Linux fills it on purpose and gives it back on demand.
#   GOODNIGHT_STATE=dir  state dir (default ~/.local/state/goodnight)
#   REAPER_JSON=path     reaper's sweep result (default ~/.cache/reaper.json)
set -euo pipefail

REBOOT_DAYS=${REBOOT_DAYS:-30}
REBOOT_MEM_PCT=${REBOOT_MEM_PCT:-10}
REBOOT_SWAP_PCT=${REBOOT_SWAP_PCT:-50}
REBOOT_STRIKES=${REBOOT_STRIKES:-2}
REBOOT_MIN_BATTERY=${REBOOT_MIN_BATTERY:-30}
REBOOT_ORDER=${REBOOT_ORDER:-surface retro pi desktop}

probe() {
  shopt -s nullglob
  local up kp mem swap bat=none ac=none d f j jobs=() blockers=()
  up=$(( $(cut -d. -f1 /proc/uptime) / 86400 ))
  kp=0
  for f in kernel initrd kernel-modules; do
    [[ $(readlink -f "/run/booted-system/$f") == "$(readlink -f "/run/current-system/$f")" ]] || kp=1
  done
  mem=$(awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} END {printf "%d", a * 100 / t}' /proc/meminfo)
  swap=$(awk '/^SwapTotal/ {t=$2} /^SwapFree/ {f=$2} END {printf "%d", t ? (t - f) * 100 / t : 0}' /proc/meminfo)
  for d in /sys/class/power_supply/*; do
    [[ -r $d/type ]] || continue
    case $(<"$d/type") in
      Battery) [[ -r $d/capacity ]] && bat=$(<"$d/capacity") ;;
      Mains) [[ -r $d/online ]] && ac=$(<"$d/online") ;;
    esac
  done

  if systemd-inhibit --list --no-legend 2>/dev/null | awk '$NF == "block" && /shutdown/' | grep -q .; then
    blockers+=(inhibitor)
  fi
  for j in nixos-rebuild nh nix-build home-manager btrfs btrbk rsync rclone; do
    ! pgrep -x "$j" >/dev/null || jobs+=("$j")
  done
  (( ${#jobs[@]} == 0 )) || blockers+=("job:$(IFS=+; echo "${jobs[*]}")")
  # tree-sync and ship.sh hold this lock while they move work between hosts
  exec 8>>"${XDG_RUNTIME_DIR:-/tmp}/tree-sync.lock"
  flock -n 8 || blockers+=(tree-sync)
  if ss -H -tn state established '( sport = :48010 )' 2>/dev/null | grep -q . \
    || ss -H -uan 2>/dev/null | grep -qE ':(47998|47999|48000) '; then
    blockers+=(stream)
  fi

  printf 'uptime_days=%s\nkernel_pending=%s\nmem_avail_pct=%s\nswap_used_pct=%s\nbattery=%s\nac=%s\nblockers=%s\n' \
    "$up" "$kp" "$mem" "$swap" "$bat" "$ac" "$(IFS=,; echo "${blockers[*]:-}")"
}

if [[ ${1:-} == probe ]]; then probe; exit 0; fi
[[ ${1:-} == plan ]] || { echo "usage: goodnight-reboot plan [--json] [host...] | probe" >&2; exit 2; }
shift

json=0; hosts=()
for a in "$@"; do
  if [[ $a == --json ]]; then json=1; else hosts+=("$a"); fi
done

here=$(cd "$(dirname "$0")" && pwd)
self_path=$(readlink -f "$0")
state=${GOODNIGHT_STATE:-$HOME/.local/state/goodnight}
reaper_json=${REAPER_JSON:-$HOME/.cache/reaper.json}
strikes_file=$state/reboot-strikes.json
FLEET_JSON=${FLEET_JSON:-/etc/fleet.json}
[[ -r $FLEET_JSON ]] || FLEET_JSON=$here/../hosts/inventory.json
fleet_self() { jq -r --arg n "${1,,}" 'to_entries[] | select(.key == $n or (.value.nick | ascii_downcase) == $n) | .key' "$FLEET_JSON" | head -n1; }
me=$(fleet_self "$(hostname)")

# REBOOT_ORDER first, then any other fleet host. This host goes last regardless: if it reboots
# first, nothing is left to drive the others.
if (( ${#hosts[@]} == 0 )); then
  mapfile -t fleet < <(jq -r 'keys[]' "$FLEET_JSON")
  for h in $REBOOT_ORDER "${fleet[@]}"; do
    [[ $h != "$me" && " ${fleet[*]} " == *" $h "* && " ${hosts[*]} " != *" $h "* ]] && hosts+=("$h")
  done
  hosts+=("$me")
fi

probe_host() {
  if [[ $1 == "$me" ]]; then bash "$self_path" probe
  else timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=8 "prepko@$1" 'bash -s -- probe' < "$self_path"; fi
}

# Consecutive sweeps in which reaper found something it could not fix. Counted per sweep
# (reaper's `checked` stamp), so planning twice between sweeps does not add a strike.
reaper_strikes() {
  local host=$1 stuck ts prev_ts prev_n n
  [[ -r $reaper_json ]] || { echo 0; return; }
  ts=$(jq -r '.checked // 0' "$reaper_json")
  stuck=$(jq -r --arg h "$host" '.hosts[$h] | if (.reachable // false) then ([.zombies[]? | select(.persists)] | length) + (.dstate | length) else "unreachable" end' "$reaper_json")
  mkdir -p "$state"
  [[ -r $strikes_file ]] || echo '{}' > "$strikes_file"
  prev_ts=$(jq -r --arg h "$host" '.[$h].ts // 0' "$strikes_file")
  prev_n=$(jq -r --arg h "$host" '.[$h].n // 0' "$strikes_file")
  n=$prev_n
  if [[ $stuck != unreachable && $ts != "$prev_ts" ]]; then
    if (( stuck > 0 )); then n=$((prev_n + 1)); else n=0; fi
    jq --arg h "$host" --argjson ts "$ts" --argjson n "$n" '.[$h] = {ts: $ts, n: $n}' "$strikes_file" > "$strikes_file.tmp"
    mv "$strikes_file.tmp" "$strikes_file"
  fi
  echo "$n"
}

plan_host() {
  local host=$1 facts k v reasons=() blocks=() action
  local uptime_days=0 kernel_pending=0 mem_avail_pct=100 swap_used_pct=0 battery=none ac=none blocker_list=""
  if ! facts=$(probe_host "$host" 2>/dev/null); then
    jq -n --arg h "$host" '{host: $h, action: "skip", reasons: [], blocks: ["unreachable"], facts: {}}'
    return
  fi
  while IFS='=' read -r k v; do
    case $k in
      uptime_days|kernel_pending|mem_avail_pct|swap_used_pct|battery|ac) printf -v "$k" '%s' "$v" ;;
      blockers) blocker_list=$v ;;
    esac
  done <<<"$facts"

  (( uptime_days >= REBOOT_DAYS )) && reasons+=("up ${uptime_days}d")
  (( kernel_pending == 1 )) && reasons+=("kernel or initrd changed since boot")
  (( mem_avail_pct <= REBOOT_MEM_PCT )) && reasons+=("only ${mem_avail_pct}% memory available")
  (( swap_used_pct >= REBOOT_SWAP_PCT )) && reasons+=("swap ${swap_used_pct}% used")
  local strikes; strikes=$(reaper_strikes "$host")
  (( strikes >= REBOOT_STRIKES )) && reasons+=("reaper: stuck processes in $strikes sweeps running")

  [[ -z $blocker_list ]] || IFS=, read -ra blocks <<<"$blocker_list"
  if [[ $battery != none ]] && (( battery < REBOOT_MIN_BATTERY )); then
    blocks+=("battery ${battery}% < ${REBOOT_MIN_BATTERY}%")
  fi

  if (( ${#reasons[@]} == 0 )); then action=fine
  elif (( ${#blocks[@]} == 0 )); then action=reboot
  else action="wait"; fi
  jq -n --arg h "$host" --arg a "$action" --argjson days "$uptime_days" --arg bat "$battery" \
    '{host: $h, action: $a, reasons: $ARGS.positional, blocks: [], facts: {uptime_days: $days, battery: $bat}}' \
    --args "${reasons[@]}" \
    | jq --argjson b "$(printf '%s\n' "${blocks[@]}" | jq -R . | jq -s 'map(select(. != ""))')" '.blocks = $b'
}

plans=$(for h in "${hosts[@]}"; do plan_host "$h"; done | jq -s .)
if (( json )); then echo "$plans"; exit 0; fi
jq -r '.[] | "  \(.host | .[0:8] + (" " * (9 - length)))\(.action | .[0:6] + (" " * (7 - length)))"
  + (if .action == "skip" then (.blocks | join(", "))
     elif .action == "fine" then "up \(.facts.uptime_days)d"
     else (.reasons | join("; ")) + (if (.blocks | length) > 0 then "  [blocked: " + (.blocks | join(", ")) + "]" else "" end) end)' <<<"$plans"
