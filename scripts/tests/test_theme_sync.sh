#!/usr/bin/env bash
# Fixture tests for scripts/theme-sync.sh with shim ssh and drmis.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/theme-sync.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shim"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

# ssh shim: prints $PEER_REPLY, or fails when PEER_DOWN is set
cat > "$T/shim/ssh" <<'SHIM'
#!/usr/bin/env bash
[[ -n "${PEER_DOWN:-}" ]] && exit 255
[[ -n "${PEER_REPLY:-}" ]] && echo "$PEER_REPLY"
exit 0
SHIM
# drmis shim: logs the call and writes the state file like the real one
cat > "$T/shim/drmis" <<'SHIM'
#!/usr/bin/env bash
echo "drmis $*" >> "$FAKE_LOG"
[[ -n "${DRMIS_RC:-}" ]] && exit "$DRMIS_RC"
echo "$2" > "$THEME_SYNC_STATE"
SHIM
chmod +x "$T/shim/ssh" "$T/shim/drmis"

export PATH="$T/shim:$PATH" FAKE_LOG="$T/log"
export THEME_SYNC_STATE="$T/theme" THEME_SYNC_PEER=peer THEME_SYNC_DRMIS="$T/shim/drmis"

run() { : > "$FAKE_LOG"; bash "$SCRIPT" >/dev/null 2>&1; RC=$?; }
state_mtime() { stat -c %Y "$THEME_SYNC_STATE"; }

# peer newer and different: follows, and takes the peer's mtime
echo olive-plum > "$THEME_SYNC_STATE"; touch -d @1000 "$THEME_SYNC_STATE"
PEER_REPLY="2000 teal-indigo" run
assert_eq "newer peer applied" "drmis set teal-indigo" "$(cat "$FAKE_LOG")"
assert_eq "mtime copied from peer" "2000" "$(state_mtime)"

# now equal: no echo back
PEER_REPLY="2000 teal-indigo" run
assert_eq "equal mtime is a no-op" "" "$(cat "$FAKE_LOG")"

# local newer: leaves it for the peer to pull
touch -d @3000 "$THEME_SYNC_STATE"
PEER_REPLY="2000 something-else" run
assert_eq "older peer ignored" "" "$(cat "$FAKE_LOG")"

# peer newer but same slug: nothing to apply
PEER_REPLY="4000 teal-indigo" run
assert_eq "same slug is a no-op" "" "$(cat "$FAKE_LOG")"

# no local state yet: follows the peer
rm -f "$THEME_SYNC_STATE"
PEER_REPLY="500 moss-violet" run
assert_eq "no local state follows peer" "drmis set moss-violet" "$(cat "$FAKE_LOG")"

# peer down or empty: quiet success
PEER_DOWN=1 run
assert_eq "peer down exits 0" "0" "$RC"
assert_eq "peer down applies nothing" "" "$(cat "$FAKE_LOG")"
PEER_REPLY="" run
assert_eq "peer without state exits 0" "0" "$RC"

# drmis failure: non-zero, and the local mtime is not stamped
echo teal-indigo > "$THEME_SYNC_STATE"; touch -d @1000 "$THEME_SYNC_STATE"
PEER_REPLY="2000 nope" DRMIS_RC=1 run
assert_eq "drmis failure surfaces" "1" "$RC"
assert_eq "drmis was tried" "drmis set nope" "$(cat "$FAKE_LOG")"
assert_eq "failed apply leaves mtime" "1000" "$(state_mtime)"

exit $fail
