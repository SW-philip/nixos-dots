#!/usr/bin/env bash
# Fixture tests for scripts/sync-status.sh with a fake curl serving canned Syncthing API JSON.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sync-status.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shim" "$T/api" "$T/home"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

ME=MYMYMYM-BBBBBBB
PEER=PEERPEE-CCCCCCC

# curl shim: the URL's path+query, with / ? & = turned into _, names a fixture file; missing = HTTP failure
cat > "$T/shim/curl" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CURL_ARGS"
u="${*: -1}"; u="${u#http://127.0.0.1:8384/}"; u="${u#http://localhost/}"; n=$(tr '/?&=' '____' <<<"$u")
[[ -r "$FAKE_API/$n" ]] || exit 22
cat "$FAKE_API/$n"
SHIM
cat > "$T/shim/notify-send" <<'SHIM'
#!/usr/bin/env bash
echo "notify $*" >> "$FAKE_LOG"
SHIM
chmod +x "$T/shim"/*
export FAKE_API="$T/api" FAKE_LOG="$T/log" FAKE_CURL_ARGS="$T/curl-args" SYNC_SOCK="$T/none.sock"
export PATH="$T/shim:$PATH"
export HOME="$T/home" SYNC_OUT="$T/out.json" SYNC_KEY=k SYNC_ROOT="$T/home" SYNC_FOLDERS="Documents Pictures"

# healthy fixture: connected peer, both folders idle and complete
healthy() {
  rm -rf "$T/api"; mkdir -p "$T/api"; : > "$T/log"; rm -f "$T/out.json"
  echo "{\"myID\":\"$ME\"}" > "$T/api/rest_system_status"
  echo "[{\"deviceID\":\"$ME\",\"name\":\"SWsurface\"},{\"deviceID\":\"$PEER\",\"name\":\"SWphil\"}]" > "$T/api/rest_config_devices"
  echo "{\"connections\":{\"$PEER\":{\"connected\":true}}}" > "$T/api/rest_system_connections"
  for f in Documents Pictures; do
    echo '{"state":"idle","needBytes":0,"errors":0,"pullErrors":0}' > "$T/api/rest_db_status_folder_$f"
    echo '{"completion":100,"needBytes":0}' > "$T/api/rest_db_completion_device_${PEER}_folder_$f"
  done
  mkdir -p "$T/home/Documents" "$T/home/Pictures"; find "$T/home" -name '*.sync-conflict-*' -delete
}
run() { SYNC_NOW=$1 bash "$SCRIPT"; }
snap() { jq -r "$1" "$T/out.json"; }

healthy; run 2000000000
assert_eq "healthy: level ok"          ok   "$(snap .level)"
assert_eq "healthy: not unsynced"      null "$(snap .unsynced_since)"
assert_eq "healthy: peer name"         SWphil "$(snap .peer.name)"
assert_eq "healthy: two folders"       2    "$(snap '.folders | length')"
assert_eq "healthy: no reasons"        0    "$(snap '.reasons | length')"

# socket branch: an existing unix socket makes the script go through curl --unix-socket
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T/gui.sock"
healthy; : > "$T/curl-args"; SYNC_SOCK="$T/gui.sock" run 2000000000
assert_eq "socket: level ok"           ok   "$(snap .level)"
assert_eq "socket: curl got --unix-socket" 1 "$(grep -q -- "--unix-socket $T/gui.sock " "$T/curl-args" && echo 1 || echo 0)"
healthy; : > "$T/curl-args"; run 2000000000
assert_eq "no socket: tcp url used"    1    "$(grep -q -- '--unix-socket' "$T/curl-args" && echo 0 || echo 1)"

healthy; echo "{\"connections\":{\"$PEER\":{\"connected\":false}}}" > "$T/api/rest_system_connections"
run 2000000000
assert_eq "offline young: level wait"  wait "$(snap .level)"
assert_eq "offline young: since set"   2000000000 "$(snap .unsynced_since)"
assert_eq "offline young: reason"      "SWphil offline" "$(snap '.reasons[0]')"
run 2000000700
assert_eq "offline old: level warn"    warn "$(snap .level)"
assert_eq "offline old: since kept"    2000000000 "$(snap .unsynced_since)"
echo "{\"connections\":{\"$PEER\":{\"connected\":true}}}" > "$T/api/rest_system_connections"
run 2000000800
assert_eq "recovered: level ok"        ok   "$(snap .level)"
assert_eq "recovered: since cleared"   null "$(snap .unsynced_since)"

healthy; echo '{"completion":80,"needBytes":5}' > "$T/api/rest_db_completion_device_${PEER}_folder_Documents"
run 2000000000
assert_eq "behind: reason"             "Documents behind" "$(snap '.reasons[0]')"
assert_eq "behind: folder untouched"   1 "$(snap '.reasons | length')"

healthy; echo '{"state":"error","needBytes":0,"errors":2,"pullErrors":0}' > "$T/api/rest_db_status_folder_Pictures"
run 2000000000
assert_eq "errors: reason"             "Pictures has errors" "$(snap '.reasons[0]')"

healthy; echo '{"state":"error","error":"folder marker missing","needBytes":0,"errors":0}' > "$T/api/rest_db_status_folder_Documents"
run 2000000000
assert_eq "stopped: reason"            "Documents stopped: folder marker missing" "$(snap '.reasons[0]')"
assert_eq "stopped young: wait"        wait "$(snap .level)"
run 2000000700
assert_eq "stopped old: warn"          warn "$(snap .level)"

healthy; rm "$T/api/rest_db_status_folder_Pictures"
run 2000000000
assert_eq "unknown state: reason"      "Pictures stopped: unknown" "$(snap '.reasons[0]')"

healthy; for i in 1 2 3 4; do : > "$T/home/Documents/f$i.sync-conflict-20261007-12000$i-MYMYMYM.txt"; done
run 2000000000
assert_eq "conflict flood: one notify" 1 "$(grep -c '^notify' "$T/log")"
assert_eq "conflict flood: summary"    1 "$(grep -c '4 new sync conflicts' "$T/log")"

healthy; : > "$T/home/Documents/report.sync-conflict-20261007-120000-MYMYMYM.txt"
run 2000000000
assert_eq "conflict: level warn"       warn "$(snap .level)"
assert_eq "conflict: counted"          1    "$(snap '.conflicts | length')"
assert_eq "conflict: relative path"    "Documents/report.sync-conflict-20261007-120000-MYMYMYM.txt" "$(snap '.conflicts[0].path')"
assert_eq "conflict: local won, peer lost" false "$(snap '.conflicts[0].loser_is_local')"
assert_eq "conflict: notified once"    1    "$(grep -c '^notify' "$T/log")"
run 2000000100
assert_eq "conflict: not re-notified"  1    "$(grep -c '^notify' "$T/log")"

healthy; : > "$T/home/Pictures/cat.sync-conflict-20261007-120000-PEERPEE.jpg"
run 2000000000
assert_eq "conflict: peer won, local lost" true "$(snap '.conflicts[0].loser_is_local')"

healthy; mkdir -p "$T/home/Documents/node_modules/x"; : > "$T/home/Documents/node_modules/x/a.sync-conflict-20261007-120000-MYMYMYM.js"
run 2000000000
assert_eq "conflict: node_modules pruned" 0 "$(snap '.conflicts | length')"

healthy; rm -rf "$T/api"; mkdir -p "$T/api"
run 2000000000
assert_eq "api down: api_ok false"     false "$(snap .api_ok)"
assert_eq "api down young: wait"       wait "$(snap .level)"
run 2000000700
assert_eq "api down old: bad"          bad  "$(snap .level)"

exit $fail
