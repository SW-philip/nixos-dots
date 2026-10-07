#!/usr/bin/env bash
# sync-status: summarise Syncthing health into one JSON snapshot for waybar, ff and sync-conflicts.
# An unreachable API or peer is data, not an error: the snapshot says so and the script exits 0.
set -euo pipefail

OUT=${SYNC_OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/sync-status.json}
URL=${SYNC_URL:-http://127.0.0.1:8384}
SOCK=${SYNC_SOCK:-/run/syncthing/gui.sock}
CONF=${SYNC_CONF:-$HOME/.config/syncthing/config.xml}
ROOT=${SYNC_ROOT:-$HOME}
FOLDERS=${SYNC_FOLDERS:-"Documents Projects"}
NOW=${SYNC_NOW:-$(date +%s)}
# a peer that is merely asleep stays quiet ("wait") until a problem is this old
WARN_S=${SYNC_WARN_S:-600}
NOTIFY=${SYNC_NOTIFY:-notify-send}
KEY=${SYNC_KEY:-$(sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' "$CONF" 2>/dev/null | head -n1 || true)}

api() {
  if [[ -S $SOCK ]]; then
    curl -fsS --max-time 5 --unix-socket "$SOCK" -H "X-API-Key: $KEY" "http://localhost$1"
  else
    curl -fsS --max-time 5 -H "X-API-Key: $KEY" "$URL$1"
  fi
}

prev_since=""; prev_paths=""
if [[ -r $OUT ]]; then
  prev_since=$(jq -r '.unsynced_since // empty' "$OUT" 2>/dev/null || true)
  prev_paths=$(jq -r '.conflicts[]?.path' "$OUT" 2>/dev/null || true)
fi

api_ok=false; my=""; peer=""; peer_name=""; connected=false; folders='[]'
if status=$(api /rest/system/status 2>/dev/null) \
   && devices=$(api /rest/config/devices 2>/dev/null) \
   && conns=$(api /rest/system/connections 2>/dev/null); then
  api_ok=true
  my=$(jq -r '.myID' <<<"$status")
  peer=$(jq -r --arg me "$my" '[.[] | select(.deviceID != $me)][0].deviceID // ""' <<<"$devices")
  peer_name=$(jq -r --arg me "$my" '[.[] | select(.deviceID != $me)][0].name // "peer"' <<<"$devices")
  connected=$(jq -r --arg p "$peer" '.connections[$p].connected // false' <<<"$conns")
  rows=()
  for f in $FOLDERS; do
    st=$(api "/rest/db/status?folder=$f" 2>/dev/null) || st='{}'
    comp='{}'
    if [[ -n $peer ]]; then comp=$(api "/rest/db/completion?device=$peer&folder=$f" 2>/dev/null) || comp='{}'; fi
    rows+=("$(jq -nc --arg id "$f" --argjson st "$st" --argjson comp "$comp" \
      '{id:$id, state:($st.state // "unknown"), need_bytes:($st.needBytes // 0), completion:($comp.completion // null), errors:(($st.errors // 0) + ($st.pullErrors // 0)), error:($st.error // "")}')")
  done
  folders=$(printf '%s\n' "${rows[@]}" | jq -s .)
fi

# the short device id in the name is the WINNER's (Syncthing names the conflict copy with the
# incoming file's ModifiedBy); with two devices the loser is the other one
conflicts=$(
  for f in $FOLDERS; do
    [[ -d $ROOT/$f ]] || continue
    find "$ROOT/$f" \( -name node_modules -o -name .stversions -o -name .git -o -name .venv -o -name target \) -prune \
      -o -type f -name '*.sync-conflict-*' -print
  done | jq -R -s --arg root "$ROOT/" --arg my "$my" '
    [split("\n")[] | select(length > 0) | . as $p
     | (capture("sync-conflict-(?<day>[0-9]{8})-(?<time>[0-9]{6})-(?<dev>[A-Z0-9]{7})") // {day: "", time: "", dev: ""}) as $c
     | {path: ($p | ltrimstr($root)), day: $c.day, time: $c.time,
        loser_is_local: ($my != "" and $c.dev != "" and $c.dev != $my[0:7])}]')

new_paths=()
while IFS= read -r p; do
  [[ -z $p ]] && continue
  grep -qxF -- "$p" <<<"$prev_paths" && continue
  new_paths+=("$p")
done < <(jq -r '.[].path' <<<"$conflicts")

if (( ${#new_paths[@]} > 3 )); then
  "$NOTIFY" "Sync conflict" "${#new_paths[@]} new sync conflicts — run sync-conflicts" || true
else
  for p in "${new_paths[@]}"; do
    side=$(jq -r --arg p "$p" '.[] | select(.path == $p) | if .loser_is_local then "your edit" else "the other host'\''s edit" end' <<<"$conflicts")
    "$NOTIFY" "Sync conflict" "$p — $side lost and was kept as a conflict copy" || true
  done
fi

reasons=()
if [[ $api_ok != true ]]; then
  reasons+=("syncthing is not running")
else
  if [[ -z $peer ]]; then
    reasons+=("no peer configured")
  elif [[ $connected != true ]]; then
    reasons+=("$peer_name offline")
  else
    while IFS= read -r id; do
      if [[ -n $id ]]; then reasons+=("$id behind"); fi
    done < <(jq -r '.[] | select(.need_bytes > 0 or ((.completion // 100) < 100)) | .id' <<<"$folders")
  fi
  while IFS= read -r id; do
    if [[ -n $id ]]; then reasons+=("$id has errors"); fi
  done < <(jq -r '.[] | select(.errors > 0) | .id' <<<"$folders")
  while IFS= read -r line; do
    if [[ -n $line ]]; then reasons+=("$line"); fi
  done < <(jq -r '.[] | select(.state == "error" or .state == "unknown" or .error != "")
                  | "\(.id) stopped: \(if .error != "" then .error else .state end)"' <<<"$folders")
fi

since=""
level=ok
if (( ${#reasons[@]} > 0 )); then
  since=${prev_since:-$NOW}
  if (( NOW - since >= WARN_S )); then
    if [[ $api_ok == true ]]; then level=warn; else level=bad; fi
  else
    level="wait"
  fi
fi
if [[ $(jq 'length' <<<"$conflicts") -gt 0 && ( $level == ok || $level == wait ) ]]; then level=warn; fi

mkdir -p "$(dirname "$OUT")"
tmp=$(mktemp "$OUT.XXXXXX")
jq -n --argjson now "$NOW" --argjson api_ok "$api_ok" --arg peer_name "$peer_name" \
  --argjson connected "$connected" --argjson folders "$folders" --argjson conflicts "$conflicts" \
  --arg since "$since" --arg level "$level" \
  '{generated_at:$now, api_ok:$api_ok, peer:{name:$peer_name, connected:$connected},
    folders:$folders, conflicts:$conflicts,
    unsynced_since:($since | if . == "" then null else tonumber end),
    level:$level, reasons:$ARGS.positional}' --args "${reasons[@]}" > "$tmp"
mv "$tmp" "$OUT"
