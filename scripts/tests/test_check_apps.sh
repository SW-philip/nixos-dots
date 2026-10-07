#!/usr/bin/env bash
# Fixture tests for scripts/check-apps.sh with a shim ssh.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-apps.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shim"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

# ssh shim: log the host, succeed unless SSH_RC says otherwise
cat > "$T/shim/ssh" <<'SHIM'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do if [[ "$1" == -n ]]; then shift; else shift 2; fi; done
echo "ssh $1" >> "$FAKE_LOG"
exit "${SSH_RC:-0}"
SHIM
chmod +x "$T/shim/ssh"
export PATH="$T/shim:$PATH" FAKE_LOG="$T/log" APP_LAUNCH_REGISTRY="$T/registry.json"

cat > "$T/registry.json" <<'JSON'
{"self":"desktop","apps":{
 "here-ok":{"exec":["bash"],"remoteExec":["bash"],"hosts":["desktop"]},
 "here-missing":{"exec":["no-such-binary-xyz"],"remoteExec":["x"],"hosts":["desktop"]},
 "far":{"exec":["bash"],"remoteExec":["bash"],"hosts":["surface"]}}}
JSON

: > "$T/log"; out=$(bash "$SCRIPT" 2>&1); rc=$?
assert_eq "exit 1 when anything is missing" 1 "$rc"
grep -q '^ok       here-ok on desktop (bash)$' <<<"$out"; assert_eq "local app found" 0 $?
grep -q '^MISSING  here-missing on desktop (no-such-binary-xyz)$' <<<"$out"; assert_eq "local app missing" 0 $?
grep -q '^ok       far on surface (bash)$' <<<"$out"; assert_eq "remote app found via ssh" 0 $?
assert_eq "remote probed over ssh, local one not" "ssh surface" "$(cat "$T/log")"

out=$(SSH_RC=1 bash "$SCRIPT" 2>&1)
grep -q '^MISSING  far on surface (bash)$' <<<"$out"; assert_eq "remote app missing when ssh probe fails" 0 $?

# all present: exit 0
cat > "$T/registry.json" <<'JSON'
{"self":"desktop","apps":{"a":{"exec":["bash"],"remoteExec":["bash"],"hosts":["desktop","surface"]}}}
JSON
bash "$SCRIPT" >/dev/null 2>&1; assert_eq "exit 0 when everything is present" 0 $?

exit "$fail"
