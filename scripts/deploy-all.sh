#!/usr/bin/env bash
# Deploy the whole fleet from any host (meant for surface): build every host on
# desktop first, activate nothing until all builds pass, then switch pi -> retro
# -> desktop -> surface (the headless pi goes first as the canary, the device in
# hand goes last) and verify each. Phase 2
# activates the exact store paths phase 1 built; nothing is re-evaluated.
#
#   deploy-all.sh [--build-only] [host...]     hosts: pi retro desktop surface
#   FORCE=1             skip the live-work guards
#   ALLOW_DIRTY=1       deploy a tree with uncommitted changes
#   DEPLOY_TIMEOUT=n    seconds to wait for a detached switch (default 1200)
#
# Never `nixos-rebuild test` here: reverting it orphans ROOT_ITEM refs on the
# impermanence roots. The safety net is the build-everything-first phase.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
root="$PWD"

die() { echo "deploy-all: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

build_only=0
hosts=()
for a in "$@"; do
  case "$a" in
    --build-only) build_only=1 ;;
    pi|retro|desktop|surface) hosts+=("$a") ;;
    *) die "unknown argument: $a" ;;
  esac
done
# Fixed order regardless of argument order.
order=()
for h in pi retro desktop surface; do
  if [[ ${#hosts[@]} -eq 0 ]] || [[ " ${hosts[*]} " == *" $h "* ]]; then order+=("$h"); fi
done

here="$(hostname)"
case "${here,,}" in
  *surface*) me=surface ;;
  *swphil*|desktop) me=desktop ;;
  *) me="$here" ;;
esac

# The surface step activates locally; anywhere else it would put surface's
# closure on the wrong machine (it once dropped desktop to emergency mode).
if [[ $build_only -eq 0 && " ${order[*]} " == *" surface "* && "$me" != surface ]]; then
  die "surface is switched locally — run this on surface, or name hosts explicitly (pi retro desktop)"
fi

# builds run on desktop in its own checkout of this repo (kept in sync by tree-sync), so
# there is no worktree to sync.
host_run() { # host cmd — run on a host, locally if it is this one
  if [[ "$1" == "$me" ]]; then bash -c "$2"; else ssh -o BatchMode=yes "prepko@$1" "$2"; fi
}
# Same, but with a tty so sudo can prompt (desktop has no NOPASSWD, roles/base.nix).
host_run_tty() { # host cmd
  if [[ "$1" == "$me" ]]; then bash -c "$2"; else ssh -t "prepko@$1" "$2"; fi
}
on_desktop() { host_run desktop "$1"; }

# Any one of: an established RTSP connection, Sunshine's per-session UDP
# sockets (unbound when idle), or the current Sunshine run's last client
# event being a connect.
stream_live() {
  on_desktop '
    ss -H -tn state established "( sport = :48010 )" | grep -q . && exit 0
    ss -H -uan | grep -qE ":(47998|47999|48000) " && exit 0
    systemctl --user is-active --quiet sunshine || exit 1
    id=$(systemctl --user show -p InvocationID --value sunshine)
    last=$(journalctl --user "_SYSTEMD_INVOCATION_ID=$id" --no-pager -o cat 2>/dev/null \
      | grep -E "CLIENT (CONNECTED|DISCONNECTED)" | tail -n1)
    [[ "$last" == *"CLIENT CONNECTED"* ]] && exit 0
    exit 1'
}

say "preflight"
[[ "${ALLOW_DIRTY:-}" == 1 || -z "$(git status --porcelain)" ]] \
  || die "uncommitted changes — commit first (or ALLOW_DIRTY=1)"
on_desktop true || die "cannot reach desktop"

if [[ "${FORCE:-}" != 1 ]]; then
  pgrep -x nixos-rebuild >/dev/null && die "a nixos-rebuild is already running here"
  pgrep -x nh >/dev/null && die "nh is already running here"
  if stream_live; then
    die "a Sunshine stream is live on desktop (FORCE=1 to override)"
  fi
fi
echo "ok"

say "phase 1: build ${order[*]} on desktop (nothing is activated)"
args=""
for h in "${order[@]}"; do
  args+=" '.#nixosConfigurations.$h.config.system.build.toplevel'"
done
built="$(on_desktop "cd '$root' && nix build --no-link --print-out-paths$args" | grep '^/nix/store/')" \
  || die "build FAILED — nothing was activated anywhere"
mapfile -t paths <<<"$built"
[[ ${#paths[@]} -eq ${#order[@]} ]] \
  || die "expected ${#order[@]} store paths, got ${#paths[@]} — nothing was activated anywhere"
declare -A out
for i in "${!order[@]}"; do
  out[${order[$i]}]="${paths[$i]}"
  echo "  ${order[$i]} -> ${paths[$i]}"
done
echo "all builds passed"
[[ $build_only -eq 0 ]] || { say "build-only: stopping"; exit 0; }

# Closures are built on desktop; every other host pulls them from there.
copy_closure() { # host path
  local from=() to=()
  [[ "$me" == desktop ]] || from=(--from ssh-ng://prepko@desktop)
  [[ "$1" == "$me" ]] || to=(--to "ssh-ng://prepko@$1")
  nix copy --no-check-sigs "${from[@]}" "${to[@]}" "$2"
}

activate_cmd() { # path
  echo "nix-env -p /nix/var/nix/profiles/system --set $1 && $1/bin/switch-to-configuration switch"
}

# Waits on a transient unit; prints its log, tolerates dropped connections.
# Returns 0 on success (or if the unit vanished, e.g. the host rebooted — the
# generation probe decides), 1 on failure/timeout/long outage.
poll_unit() { # host unit invocation-id
  local host=$1 unit=$2 inv=$3 cursor="" lines c props ls as ss res unreachable=0 start=$SECONDS
  while :; do
    sleep 3
    (( SECONDS - start < ${DEPLOY_TIMEOUT:-1200} )) || { echo "deploy-all: $unit timed out" >&2; return 1; }
    if lines="$(host_run "$host" "journalctl _SYSTEMD_INVOCATION_ID=$inv -o cat --no-pager --show-cursor ${cursor:+--after-cursor='$cursor'}" 2>/dev/null)"; then
      grep -v '^-- cursor:' <<<"$lines" || true
      c="$(sed -n 's/^-- cursor: //p' <<<"$lines" | tail -n1)"; [[ -z "$c" ]] || cursor="$c"
    fi
    # Activation can bounce the network; a failed read just retries next tick.
    if ! props="$(host_run "$host" "systemctl show -p LoadState -p ActiveState -p SubState -p Result $unit" 2>/dev/null)"; then
      (( ++unreachable * 3 < 600 )) || { echo "deploy-all: $host unreachable for 10 min" >&2; return 1; }
      continue
    fi
    unreachable=0
    ls="$(sed -n 's/^LoadState=//p' <<<"$props")"; as="$(sed -n 's/^ActiveState=//p' <<<"$props")"
    ss="$(sed -n 's/^SubState=//p' <<<"$props")";  res="$(sed -n 's/^Result=//p' <<<"$props")"
    if [[ "$ls" == not-found ]]; then
      echo "deploy-all: $unit is gone — $host probably rebooted; checking its generation" >&2
      return 0
    fi
    case "$as" in
      activating) ;;
      active) [[ "$ss" == exited ]] && { host_run "$host" "sudo systemctl stop $unit" || true; return 0; } ;;
      failed) return 1 ;;
      inactive) [[ "$res" == success ]] && return 0; return 1 ;;
    esac
  done
}

# Activation restarts sunshine/tailscale/session units (and NetworkManager on
# retro), which kills the SSH or Moonlight session the switch was launched from
# and aborts it half-way (black screen). Run it as a transient system unit and
# poll instead.
switch_detached() { # host path
  local host=$1 unit="deploy-switch-$1" st inv=""
  st="$(host_run "$host" "systemctl show -p ActiveState -p SubState $unit")" || return 1
  if grep -qE '^(ActiveState=activating|SubState=running)$' <<<"$st"; then
    echo "deploy-all: $unit is still running on $host — a previous switch is in flight" >&2
    return 1
  fi
  host_run_tty "$host" "sudo systemctl stop $unit 2>/dev/null; sudo systemctl reset-failed $unit 2>/dev/null; \
    sudo systemd-run --quiet --unit=$unit --property=RemainAfterExit=yes \
    --setenv=HOME=/root --setenv=PATH=/run/current-system/sw/bin \
    --setenv=LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive \
    sh -c '$(activate_cmd "$2")'" || return 1
  for _ in 1 2 3 4 5; do
    inv="$(host_run "$host" "systemctl show -p InvocationID --value $unit" 2>/dev/null)" && [[ -n "$inv" ]] && break
    sleep 1
  done
  [[ -n "$inv" ]] || { echo "deploy-all: could not find $unit's invocation" >&2; return 1; }
  poll_unit "$host" "$unit" "$inv"
}

switch_host() { # host
  local p="${out[$1]}"
  case "$1" in
    pi|retro|desktop)
      [[ "$1" == desktop ]] || copy_closure "$1" "$p"
      switch_detached "$1" "$p" ;;
    surface)
      copy_closure surface "$p"
      sudo bash -c "$(activate_cmd "$p")" ;;
  esac
}

# Prints the host's active system path, profile path, then failed units.
probe() {
  host_run "$1" 'readlink -f /run/current-system; readlink -f /nix/var/nix/profiles/system; systemctl --failed --no-legend --plain | cut -d" " -f1'
}

# The host may still be bouncing sshd/network right after a switch.
probe_retry() {
  local i res
  for i in $(seq 24); do
    if res="$(probe "$1" 2>/dev/null)" && [[ "$(wc -l <<<"$res")" -ge 2 ]]; then
      printf '%s\n' "$res"; return 0
    fi
    sleep 5
  done
  return 1
}

declare -A status
fail=0
for h in "${order[@]}"; do
  say "phase 2: switch $h"
  if ! switch_host "$h"; then
    status[$h]="SWITCH FAILED"; fail=1
    echo "deploy-all: stopping — $h failed, remaining hosts untouched" >&2
    break
  fi
  if ! probed="$(probe_retry "$h")"; then
    status[$h]="PROBE FAILED (could not read its generation)"; fail=1
    echo "deploy-all: stopping — cannot verify $h" >&2
    break
  fi
  mapfile -t got <<<"$probed"
  if [[ "${got[0]}" != "${out[$h]}" || "${got[1]}" != "${out[$h]}" ]]; then
    status[$h]="WRONG GENERATION (running ${got[0]}, profile ${got[1]})"; fail=1
    echo "deploy-all: stopping — $h is not on the built generation" >&2
    break
  fi
  failed_units="${got[*]:2}"
  status[$h]="ok${failed_units:+ — failed units: $failed_units}"
done

say "summary"
for h in "${order[@]}"; do printf '%-8s %s\n' "$h" "${status[$h]:-not attempted}"; done
exit "$fail"
