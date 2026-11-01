#!/usr/bin/env bash
# overnight: record the outcome of unattended services and surface it as a notification whose
# "Open" action pages that run's journal, like whats-new does for builds.
#   overnight                      recent runs (same as `list`)
#   overnight list [N]             the last N runs (default 20)
#   overnight log [N|unit]         page the journal of the Nth most recent run (1 = latest) or of a unit's latest
# Plumbing, called by the units themselves (home/overnight-notify.nix, modules/overnight-notify.nix):
#   overnight record <system|user> <unit> <ok|fail> [hint]   drop a run record in the spool
#   overnight consume                                        notify about spooled runs not yet seen
# System services can't reach the session bus, so they only write to /var/lib/overnight; the user
# session picks the records up (immediately, or at next login).
#   OVERNIGHT_STATE=dir         user state dir (default ~/.local/state/overnight)
#   OVERNIGHT_SYSTEM_SPOOL=dir  where system-scope units record (default /var/lib/overnight)
set -euo pipefail

state=${OVERNIGHT_STATE:-${HOME:-/nonexistent}/.local/state/overnight}
user_spool=$state/spool
sys_spool=${OVERNIGHT_SYSTEM_SPOOL:-/var/lib/overnight}
history=$state/runs.jsonl
seen=$state/seen
self=$(readlink -f "$0")

record() { # scope unit ok|fail [hint]
  local scope=$1 unit=${2%.service} outcome=$3 hint=${4:-}
  local sc=() dir=$sys_spool k v id="" res="" st=0 t0=0 t1=0 dur=null tail='[]'
  if [[ $scope == user ]]; then sc=(--user); dir=$user_spool; fi
  mkdir -p "$dir"
  while IFS='=' read -r k v; do
    case $k in
      InvocationID) id=$v ;;
      Result) res=$v ;;
      ExecMainStatus) st=$v ;;
      ExecMainStartTimestampMonotonic) t0=$v ;;
      ExecMainExitTimestampMonotonic) t1=$v ;;
    esac
  done < <(systemctl "${sc[@]}" show "$unit.service" -p InvocationID -p Result -p ExecMainStatus \
    -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestampMonotonic)
  if (( t0 > 0 && t1 >= t0 )); then dur=$(( (t1 - t0) / 1000000 )); fi
  if [[ $outcome == fail && -n $id ]]; then
    tail=$(journalctl "${sc[@]}" "_SYSTEMD_INVOCATION_ID=$id" -n 3 -o cat --no-pager 2>/dev/null \
      | cut -c1-200 | jq -R . | jq -s .) || tail='[]'
  fi
  jq -n --arg scope "$scope" --arg unit "$unit" --arg ok "$outcome" --arg res "$res" --argjson st "$st" \
    --arg id "$id" --argjson dur "$dur" --arg hint "$hint" --argjson tail "$tail" --argjson ts "$(date +%s)" \
    '{ts: $ts, scope: $scope, unit: $unit, ok: ($ok == "ok"), result: $res, status: $st, invocation: $id,
      duration: $dur, hint: $hint, tail: $tail}' > "$dir/.tmp.$$"
  mv "$dir/.tmp.$$" "$dir/$(date +%s%N)-$unit.json"
}

fmt_dur() { # seconds or null -> 1h02m / 3m12s / 9s
  local s=$1
  if [[ $s == null ]]; then echo "?"
  elif (( s >= 3600 )); then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif (( s >= 60 )); then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}

# Blocks until the notification is dismissed or clicked, so it runs as its own transient unit.
notify_run() { # json
  local json=$1 unit ok dur title body urgency act
  unit=$(jq -r .unit <<<"$json"); ok=$(jq -r .ok <<<"$json"); dur=$(fmt_dur "$(jq -r .duration <<<"$json")")
  if [[ $ok == true ]]; then
    title="$unit finished"; body="ok in $dur"; urgency=low
  else
    title="$unit FAILED"; urgency=critical
    body="$(jq -r '.result + " (exit " + (.status | tostring) + ") after '"$dur"'"' <<<"$json")"
    body+=$(jq -r 'if .hint != "" then "\n" + .hint else "" end, (.tail[]? | "\n  " + .)' <<<"$json")
  fi
  act=$(notify-send -a overnight -u "$urgency" -A open=Open "$title" "$body" 2>/dev/null || true)
  [[ $act == open ]] || return 0
  exec ghostty --class=dev.prepko.overnight -e "$self" show "$json"
}

show() { # json
  local json=$1 scope id unit ts sc=()
  scope=$(jq -r .scope <<<"$json"); id=$(jq -r .invocation <<<"$json")
  unit=$(jq -r .unit <<<"$json"); ts=$(jq -r .ts <<<"$json")
  [[ $scope == user ]] && sc=(--user)
  {
    jq -r '"== \(.unit) (\(.scope)) \(.ts | strftime("%F %T")): " + (if .ok then "ok" else "FAILED, \(.result), exit \(.status)" end)' <<<"$json"
    if [[ -n $id ]]; then journalctl "${sc[@]}" "_SYSTEMD_INVOCATION_ID=$id" --no-pager
    else journalctl "${sc[@]}" -u "$unit.service" --since "@$((ts - 3600))" --until "@$((ts + 60))" --no-pager; fi
  } 2>&1 | less -R +G
}

consume() {
  mkdir -p "$user_spool"; touch "$seen"
  local f key
  for f in "$sys_spool"/*.json "$user_spool"/*.json; do
    [[ -e $f ]] || continue
    key=${f##*/}
    grep -qxF -- "$key" "$seen" && continue
    echo "$key" >> "$seen"
    jq -c . "$f" >> "$history"
    systemd-run --user --collect --quiet "$self" notify "$(jq -c . "$f")" || true
  done
  find "$user_spool" -name '*.json' -mtime +7 -delete
  tail -n 500 "$seen" > "$seen.tmp" && mv "$seen.tmp" "$seen"
}

pick() { # N|unit -> the matching history line
  [[ -r $history ]] || { echo "overnight: no runs recorded yet" >&2; return 1; }
  if [[ ${1:-1} =~ ^[0-9]+$ ]]; then tail -n "${1:-1}" "$history" | head -n 1
  else grep -F "\"unit\":\"$1\"" "$history" | tail -n 1; fi
}

case ${1:-list} in
  record) shift; record "$@" ;;
  consume) consume ;;
  notify) notify_run "$2" ;;
  show) show "$2" ;;
  list)
    [[ -r $history ]] || { echo "overnight: no runs recorded yet"; exit 0; }
    tail -n "${2:-20}" "$history" | jq -r '"\(.ts | strftime("%m-%d %H:%M"))  \(if .ok then "ok  " else "FAIL" end)  \(.unit)  (\(.duration // "?")s)"' ;;
  log)
    line=$(pick "${2:-1}") && [[ -n $line ]] || { echo "overnight: no such run" >&2; exit 1; }
    show "$line" ;;
  *) echo "usage: overnight [list [N] | log [N|unit]]" >&2; exit 2 ;;
esac
