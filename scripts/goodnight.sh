#!/usr/bin/env bash
# goodnight: the nightly fleet batch. Runs on desktop from a user timer (home/goodnight.nix).
#   goodnight run [--dry-run] [phase...]   phases: wake deploy audit housekeeping backups (default: all)
#   goodnight status                       last report: hosts and phases
#   goodnight hold | release               skip (or stop skipping) tonight's deploy
# Deploy only acts when GOODNIGHT_DEPLOY=1; otherwise it reports what it would do. It deploys the
# newest origin/main, never wip, and never touches a host already at or ahead of main (a host
# rebuilt from unshipped wip work is live work).
#   GOODNIGHT_STATE=dir      state dir (default ~/.local/state/goodnight)
#   GOODNIGHT_REPO=dir       the repo to fetch and take the main checkout from (default ~/nixos)
#   GOODNIGHT_WAKE_WAIT=s    how long to keep retrying an unreachable host (default 300)
#   GOODNIGHT_STREAM_WAIT=s  how long to wait out a live Sunshine stream before skipping (default 10800)
#   GOODNIGHT_NOTIFY=1       desktop notification when a phase fails
set -euo pipefail

state=${GOODNIGHT_STATE:-$HOME/.local/state/goodnight}
report=$state/report.json
repo=${GOODNIGHT_REPO:-$HOME/nixos}
checkout=$state/main
wake_wait=${GOODNIGHT_WAKE_WAIT:-300}
stream_wait=${GOODNIGHT_STREAM_WAIT:-10800}
all_phases=(wake deploy audit housekeeping backups)

here=$(cd "$(dirname "$0")" && pwd)
FLEET_JSON=${FLEET_JSON:-/etc/fleet.json}
[[ -r $FLEET_JSON ]] || FLEET_JSON=$here/../hosts/inventory.json
fleet_self() { jq -r --arg n "${1,,}" 'to_entries[] | select(.key == $n or (.value.nick | ascii_downcase) == $n) | .key' "$FLEET_JSON" | head -n1; }
nick_of() { jq -r --arg h "$1" '.[$h].nick' "$FLEET_JSON"; }
me=$(fleet_self "$(hostname)")

audit_cmd=${GOODNIGHT_AUDIT:-$(command -v goodnight-audit || echo "$here/goodnight-audit.sh")}

run_on() { # host cmd — locally if it is this host
  if [[ $1 == "$me" ]]; then bash -c "$2"
  else ssh -o BatchMode=yes -o ConnectTimeout=8 "prepko@$1" "$2"; fi
}
reachable() { run_on "$1" true >/dev/null 2>&1; }

# Each phase leaves $sums/<name>.json = {status: ok|warn|fail|skipped, summary, details[]}.
sums=""
log=/dev/null
rank() { case $1 in fail) echo 3 ;; warn) echo 2 ;; ok) echo 1 ;; *) echo 0 ;; esac; }
finish() { # name status summary [detail...]
  local name=$1 status=$2 summary=$3; shift 3
  jq -n --arg s "$status" --arg m "$summary" '{status: $s, summary: $m, details: $ARGS.positional}' --args "$@" > "$sums/$name.json"
}

# One checkout of origin/main to deploy from and to run flake-check in; never the working tree.
ensure_checkout() {
  # explicit `|| return 1`: callers use this in an `if`, where set -e does not apply
  git -C "$repo" fetch -q origin main || return 1
  local target
  target=$(git -C "$repo" rev-parse origin/main) || return 1
  # a deleted state dir leaves the worktree registered, and `worktree add` then refuses forever
  git -C "$repo" worktree prune || return 1
  if [[ -e $checkout/.git ]]; then
    git -C "$checkout" checkout -q --detach "$target" || return 1
  else
    git -C "$repo" worktree add -q --detach "$checkout" "$target" || return 1
  fi
  echo "$target"
}

phase_wake() {
  local down=() h deadline
  for h in pi retro desktop surface; do
    [[ $h == "$me" ]] && continue
    deadline=$((SECONDS + wake_wait))
    until reachable "$h"; do
      if (( SECONDS >= deadline )); then down+=("$h"); break; fi
      sleep 30
    done
  done
  printf '%s\n' "${down[@]}" > "$sums/unreachable"
  if (( ${#down[@]} == 0 )); then
    finish wake ok "every host answered"
  else
    finish wake warn "unreachable after ${wake_wait}s: ${down[*]} (none of these wake over Wi-Fi; they catch up when next seen)" "${down[@]}"
  fi
}

phase_deploy() {
  if [[ -e $state/hold ]]; then
    rm -f "$state/hold"
    finish deploy skipped "held (goodnight hold); the hold is now cleared"
    return 0
  fi
  local target
  if ! target=$(ensure_checkout 2>&1); then
    finish deploy fail "could not fetch origin/main or prepare the checkout" "$target"
    return 0
  fi

  local need=() notes=() h rev
  for h in pi retro desktop surface; do
    if grep -qx "$h" "$sums/unreachable" 2>/dev/null; then notes+=("$h: unreachable, pending"); continue; fi
    rev=$(run_on "$h" 'nixos-version --configuration-revision' 2>/dev/null || true)
    rev=${rev%-dirty}
    if [[ ! $rev =~ ^[0-9a-f]{40}$ ]]; then
      need+=("$h"); notes+=("$h: no revision stamp, will deploy")
    elif ! git -C "$repo" cat-file -e "$rev^{commit}" 2>/dev/null; then
      notes+=("$h: running ${rev:0:8}, not in this repo (unshipped work?), left alone")
    elif [[ $rev == "$target" ]]; then
      notes+=("$h: current")
    elif git -C "$repo" merge-base --is-ancestor "$target" "$rev"; then
      notes+=("$h: ahead of main at ${rev:0:8}, left alone")
    else
      need+=("$h"); notes+=("$h: ${rev:0:8} -> ${target:0:8}")
    fi
  done

  if (( ${#need[@]} == 0 )); then
    finish deploy ok "nothing to deploy (main is ${target:0:8})" "${notes[@]}"
    return 0
  fi
  if [[ ${GOODNIGHT_DRY:-0} == 1 ]]; then
    if "$checkout/scripts/deploy-all.sh" --build-only "${need[@]}" >> "$log" 2>&1; then
      finish deploy ok "dry run: ${need[*]} build cleanly, nothing activated" "${notes[@]}"
    else
      finish deploy fail "dry run: build FAILED for ${need[*]} (see log)" "${notes[@]}"
    fi
    return 0
  fi
  if [[ ${GOODNIGHT_DEPLOY:-0} != 1 ]]; then
    finish deploy skipped "deploy disabled (goodnight.deploy.enable); would deploy: ${need[*]}" "${notes[@]}"
    return 0
  fi

  local deadline=$((SECONDS + stream_wait)) rc
  while :; do
    rc=0
    NONINTERACTIVE=1 "$checkout/scripts/deploy-all.sh" "${need[@]}" >> "$log" 2>&1 || rc=$?
    [[ $rc -eq 4 ]] || break
    if (( SECONDS >= deadline )); then
      finish deploy skipped "postponed: a Sunshine stream stayed live for ${stream_wait}s" "${notes[@]}"
      return 0
    fi
    echo "deploy: stream live, retrying in 10 min" >> "$log"
    sleep 600
  done
  if (( rc == 0 )); then
    finish deploy ok "deployed ${need[*]} to ${target:0:8}" "${notes[@]}"
  else
    finish deploy fail "deploy FAILED (exit $rc); the summary at the end of the log says where it stopped" "${notes[@]}" "$(tail -n 12 "$log")"
  fi
}

phase_audit() {
  local rc=0
  "$audit_cmd" >> "$log" 2>&1 || rc=$?
  case $rc in
    0) finish audit ok "no new failures (details in the report's hosts)" ;;
    1) finish audit fail "new failing findings on at least one host" ;;
    *) finish audit fail "the audit itself broke (exit $rc)" ;;
  esac
}

phase_housekeeping() {
  local problems=() h u res units checked=0
  for h in pi retro desktop surface; do
    grep -qx "$h" "$sums/unreachable" 2>/dev/null && continue
    case $h in
      desktop|surface) units="nh-clean.service nix-optimise.service" ;;
      retro) units="nix-gc.service nix-optimise.service" ;;
      pi) units="nix-gc.service" ;;
    esac
    for u in $units; do
      res=$(run_on "$h" "systemctl show -p Result --value $u" 2>/dev/null || echo "unreadable")
      checked=$((checked + 1))
      [[ -z $res || $res == success ]] || problems+=("$h $u: $res")
    done
  done

  local fc=""
  if [[ ${GOODNIGHT_FLAKE_CHECK:-0} == 1 || $(date +%u) == 7 ]]; then
    if ! ensure_checkout >/dev/null 2>&1; then
      problems+=("flake-check skipped: could not prepare the main checkout")
    elif [[ -x $checkout/scripts/flake-check.sh ]]; then
      if (cd "$checkout" && ./scripts/flake-check.sh) >> "$log" 2>&1; then
        fc="flake-check ran: ${XDG_STATE_HOME:-$HOME/.local/state}/flake-check/latest.md"
      else
        problems+=("flake-check failed (see log)")
      fi
    fi
  fi

  if (( ${#problems[@]} == 0 )); then
    finish housekeeping ok "$checked maintenance units succeeded${fc:+; $fc}"
  else
    finish housekeeping warn "${#problems[@]} problem(s)" "${problems[@]}"
  fi
}

# `age_hours` of a YYYYMMDDTHHMM stamp
age_hours() { local d=$1; echo $(( ($(date +%s) - $(date -d "${d:0:4}-${d:4:2}-${d:6:2} ${d:9:2}:${d:11:2}" +%s)) / 3600 )); }

phase_backups() {
  local lines=() worst=ok d name newest hrs
  note() { lines+=("$1: $2"); [[ $(rank "$1") -gt $(rank "$worst") ]] && worst=$1; return 0; }

  # btrbk: judge by the newest snapshot on the backup disk, not the unit (a lock clash leaves
  # the unit failed until its next run although the data is fine).
  for name in home persist; do
    newest=$(run_on desktop "ls -1 /mnt/backup/btrbk/$name 2>/dev/null | sort | tail -n1" 2>/dev/null || true)
    if [[ $newest =~ \.([0-9]{8}T[0-9]{4})$ ]]; then
      hrs=$(age_hours "${BASH_REMATCH[1]}")
      if (( hrs > 48 )); then note fail "btrbk $name: newest backup snapshot is ${hrs}h old"
      elif (( hrs > 30 )); then note warn "btrbk $name: newest backup snapshot is ${hrs}h old"
      else note ok "btrbk $name: newest backup snapshot ${hrs}h old"; fi
    else
      note fail "btrbk $name: no backup snapshots found (is /mnt/backup mounted?)"
    fi
  done

  # The pi mirror is the failsafe if GitHub is unreachable; main must match.
  local gh pi
  gh=$(git -C "$repo" ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
  pi=$(git -C "$repo" ls-remote pi refs/heads/main 2>/dev/null | cut -f1)
  if [[ -z $gh || -z $pi ]]; then note warn "mirror: could not read ${gh:+pi}${pi:+GitHub}${gh:-${pi:-both remotes}}"
  elif [[ $gh == "$pi" ]]; then note ok "mirror: pi main == GitHub main (${gh:0:8})"
  else note warn "mirror: pi main ${pi:0:8} differs from GitHub main ${gh:0:8}"; fi

  # Key bundles need a passphrase to open, so an unattended check can only prove they exist and are fresh.
  local h nick mt age
  for h in ${GOODNIGHT_ESCROW_HOSTS:-desktop surface}; do
    nick=$(nick_of "$h")
    mt=$(ssh -o BatchMode=yes -o ConnectTimeout=8 prepko@pi "f=\$(ls -1t key-escrow/$nick-*.tar.age 2>/dev/null | head -n1); [ -n \"\$f\" ] && stat -c %Y \"\$f\"" 2>/dev/null || true)
    if [[ -z $mt ]]; then note fail "key-escrow $h: no bundle on the pi (run scripts/key-escrow.sh on $h)"
    else
      age=$(( ($(date +%s) - mt) / 86400 ))
      if (( age > 90 )); then note warn "key-escrow $h: newest bundle is ${age}d old"
      else note ok "key-escrow $h: newest bundle ${age}d old"; fi
    fi
  done

  local count_bad
  count_bad=$(printf '%s\n' "${lines[@]}" | grep -cv '^ok:' || true)
  finish backups "$worst" "$count_bad of ${#lines[@]} backup checks need attention" "${lines[@]}"
}

print_status() {
  "$audit_cmd" --report
  [[ -r $report ]] || return 0
  jq -r '(.phases // {}) | to_entries[] | "  [\(.value.status)] \(.key): \(.value.summary)"' "$report"
}

cmd_run() {
  GOODNIGHT_DRY=0
  local phases=() a
  for a in "$@"; do
    case $a in
      --dry-run) GOODNIGHT_DRY=1 ;;
      wake|deploy|audit|housekeeping|backups) phases+=("$a") ;;
      *) echo "goodnight: unknown argument: $a" >&2; exit 2 ;;
    esac
  done
  export GOODNIGHT_DRY
  [[ ${#phases[@]} -gt 0 ]] || phases=("${all_phases[@]}")

  mkdir -p "$state/log"
  exec 9>"$state/lock"
  flock -n 9 || { echo "goodnight: already running"; exit 0; }
  log=$state/log/$(date +%Y%m%dT%H%M%S).log
  sums=$(mktemp -d)
  trap 'rm -rf "$sums"' EXIT
  : > "$sums/unreachable"
  echo "goodnight $(date) on $me; log: $log"
  [[ ${GOODNIGHT_DRY} == 1 ]] && echo "(dry run: nothing is activated)"

  local ph worst=ok
  for ph in "${phases[@]}"; do
    echo "== $ph"
    "phase_$ph" || finish "$ph" fail "the phase script itself failed"
    jq -r '"  [\(.status)] \(.summary)", (.details[]? | "      " + .)' "$sums/$ph.json"
    [[ $(rank "$(jq -r .status "$sums/$ph.json")") -gt $(rank "$worst") ]] && worst=$(jq -r .status "$sums/$ph.json")
  done

  # merge into the report the audit keeps; phases not run tonight keep their last result
  local base='{}'
  jq -e . "$report" >/dev/null 2>&1 && base=$(cat "$report")
  local ph_json='{}' f
  for f in "$sums"/*.json; do
    [[ -e $f ]] || continue
    ph_json=$(jq -c --arg n "$(basename "$f" .json)" --slurpfile v "$f" --argjson now "$(date +%s)" '.[$n] = ($v[0] + {ts: $now})' <<<"$ph_json")
  done
  jq -n --argjson base "$base" --argjson ph "$ph_json" '$base + {phases: (($base.phases // {}) + $ph)}' > "$report.tmp"
  mv "$report.tmp" "$report"

  find "$state/log" -name '*.log' | sort | head -n -30 | xargs -r rm --
  if [[ $worst == fail && ${GOODNIGHT_NOTIFY:-} == 1 ]] && command -v notify-send >/dev/null; then
    notify-send -u critical "goodnight: a phase failed" "$(jq -r '.phases | to_entries[] | select(.value.status == "fail") | "\(.key): \(.value.summary)"' "$report")" || true
  fi
  [[ $worst != fail ]]
}

case ${1:-} in
  run) shift; cmd_run "$@" ;;
  status) print_status ;;
  hold) mkdir -p "$state"; touch "$state/hold"; echo "goodnight: tonight's deploy is on hold" ;;
  release) rm -f "$state/hold"; echo "goodnight: hold released" ;;
  *) echo "usage: goodnight run [--dry-run] [phase...] | status | hold | release" >&2; exit 2 ;;
esac
