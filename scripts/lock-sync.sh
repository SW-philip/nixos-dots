#!/usr/bin/env bash
# lock-sync: surface drives desktop's hyprlock (lock and unlock) while both sit behind the same
# gateway; desktop never sends. `watch` runs on surface and forwards lock edges to desktop over
# ssh; `recv <lock|unlock|gw>` is what desktop runs. Tailscale reachability is only the control
# channel, never the test for "same network" — that is the default gateway (IP + MAC) matching on
# both ends. Everything worth knowing goes to the journal: `journalctl -t lock-sync`.
set -euo pipefail

SELF=${LOCK_SYNC_SELF:-$(uname -n)}
PEER=${LOCK_SYNC_PEER:-desktop}
KEY=${LOCK_SYNC_KEY:-$HOME/.ssh/id_locksync}
RUN=${XDG_RUNTIME_DIR:-/run/user/$UID}
# pid of the hyprlock that a synced lock started; only that lock may be synced-unlocked
OWNER=$RUN/lock-sync.owner
# -F /dev/null: the fleet ssh config would also offer id_fleet, an unrestricted shell key.
# timeout: ConnectTimeout only bounds the connect, not a peer that accepts and then stalls.
SSH=(timeout 8 ssh -n -F /dev/null -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none
     -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=3)

log() { logger -t lock-sync -- "$*"; }

# gateway IP and MAC: two hosts agree on both only when they're on the same LAN
gw_id() {
  local gw mac
  gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
  [[ -n $gw ]] || return 1
  mac=$(ip neigh show "$gw" 2>/dev/null | awk '/lladdr/ {print $5; exit}')
  [[ -n $mac ]] || return 1
  echo "$gw $mac"
}

hyprlock_pid() { pidof -s hyprlock 2>/dev/null || true; }
is_locked()    { [[ -n $(hyprlock_pid) ]]; }

recv() {
  local sid pid
  case ${1:-} in
    lock)
      if is_locked; then log "recv lock: already locked, not taking ownership"; return 0; fi
      # `if`, not `[[ ]] && echo`: a failed test on the manager/tty sessions would trip pipefail
      sid=$(loginctl list-sessions --no-legend | awk -v u="$USER" '$3 == u {print $1}' | while read -r s; do
              if [[ $(loginctl show-session "$s" -p Type --value) == wayland ]]; then echo "$s"; fi
            done | head -n1)
      if [[ -z $sid ]]; then log "recv lock: no wayland session for $USER"; return 1; fi
      loginctl lock-session "$sid"
      for _ in 1 2 3 4 5 6; do
        pid=$(hyprlock_pid); [[ -n $pid ]] && break; sleep 0.5
      done
      if [[ -n $pid ]]; then echo "$pid" > "$OWNER"; log "recv lock: locked (hyprlock $pid)"
      else log "recv lock: asked session $sid to lock but no hyprlock appeared"; return 1; fi ;;
    unlock)
      pid=$(hyprlock_pid)
      if [[ -z $pid ]]; then rm -f "$OWNER"; log "recv unlock: not locked"; return 0; fi
      # a lock the user made here (or one that relocked since) has a different pid
      if [[ ! -r $OWNER || $(cat "$OWNER") != "$pid" ]]; then
        log "recv unlock: refused, hyprlock $pid wasn't started by a synced lock"; return 1
      fi
      rm -f "$OWNER"
      pkill -USR1 -u "$UID" hyprlock
      log "recv unlock: unlocked (hyprlock $pid)" ;;
    gw) gw_id ;;
    *) echo "usage: lock-sync recv lock|unlock|gw" >&2; return 2 ;;
  esac
}

push() {
  local mine theirs
  if [[ ! -r $KEY ]]; then log "push $1: no key at $KEY"; return 0; fi
  mine=$(gw_id) || { log "push $1: no gateway on this network, not syncing"; return 0; }
  theirs=$("${SSH[@]}" "$PEER" gw 2>/dev/null) || { log "push $1: desktop unreachable or refused gw"; return 0; }
  if [[ $mine != "$theirs" ]]; then log "push $1: different network (here '$mine', desktop '$theirs'), not syncing"; return 0; fi
  if "${SSH[@]}" "$PEER" "$1" >/dev/null 2>&1; then log "push $1: synced"
  else log "push $1: desktop failed (see its journal: journalctl -t lock-sync)"; fi
}

watch_loop() {
  local prev=unlock cur last=""
  is_locked && prev=lock
  log "watching (hyprlock ${prev}ed)"
  while sleep 1; do
    is_locked && cur=lock || cur=unlock
    [[ $cur == "$prev" ]] && continue
    prev=$cur
    # one push at a time: a quick lock+unlock must reach desktop in that order
    if [[ -n $last ]]; then wait "$last" 2>/dev/null || true; fi
    push "$cur" &
    last=$!
  done
}

case ${1:-watch} in
  watch) [[ $SELF == SWsurface ]] || { echo "lock-sync: watch only runs on surface" >&2; exit 1; }
         watch_loop ;;
  recv)  shift; recv "${1:-}" ;;
  # forced command of the authorized key: the client's words are data, only these three pass
  recv-ssh) case ${SSH_ORIGINAL_COMMAND:-} in
              lock|unlock|gw) recv "$SSH_ORIGINAL_COMMAND" ;;
              *) log "refused command from ${SSH_CLIENT%% *}: ${SSH_ORIGINAL_COMMAND:0:40}"; exit 1 ;;
            esac ;;
  *) echo "usage: lock-sync [watch|recv lock|unlock|gw|recv-ssh]" >&2; exit 2 ;;
esac
