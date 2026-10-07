#!/usr/bin/env bash
# Fixture tests for scripts/app-launch.sh with shim on/picker/notify-send and fake apps.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/app-launch.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shim"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

# every shim appends one line per call: name + args
for s in on notify-send localapp; do
  cat > "$T/shim/$s" <<SHIM
#!/usr/bin/env bash
echo "$s\${*:+ \$*}" >> "\$FAKE_LOG"
[[ "$s" == on && -n "\${ON_RC:-}" ]] && exit "\$ON_RC"
exit 0
SHIM
  chmod +x "$T/shim/$s"
done
# picker: record stdin, answer with $PICK (empty = cancel)
cat > "$T/shim/picker" <<'SHIM'
#!/usr/bin/env bash
{ echo "picker"; cat; } >> "$FAKE_LOG"
[[ -n "${PICK:-}" ]] && echo "$PICK"
SHIM
chmod +x "$T/shim/picker"

export PATH="$T/shim:$PATH" FAKE_LOG="$T/log"
export APP_LAUNCH_REGISTRY="$T/registry.json" APP_LAUNCH_FLEET="$T/fleet.json"
export APP_LAUNCH_STATE="$T/state" APP_LAUNCH_PICKER="$T/shim/picker"

registry() { # $1 = self
  cat > "$T/registry.json" <<JSON
{"self":"$1","apps":{"demo":{"exec":["localapp","--local"],"remoteExec":["remoteapp","--flag","a b"],"hosts":["desktop","surface"]}}}
JSON
}
fleet() { # $1 = desktop up/ssh_ok flag
  cat > "$T/fleet.json" <<JSON
{"hosts":[{"host":"desktop","up":$1,"ssh_ok":$1},{"host":"surface","up":true,"ssh_ok":true}]}
JSON
}
run() { : > "$T/log"; bash "$SCRIPT" "$@" >"$T/out" 2>&1; echo $?; }
log() { cat "$T/log"; }

registry surface; fleet true

# NB: env prefixes go inside the $(...) so they are exported to the script and don't leak into later cases
# picking a host runs `on <host> <remoteExec>` and remembers the choice
rc=$(PICK=desktop run demo)
assert_eq "remote launch" $'picker\nhere\ndesktop\non desktop remoteapp --flag a b' "$(log)"
assert_eq "exit status" 0 "$rc"
assert_eq "choice remembered" desktop "$(cat "$T/state/demo")"

# last choice (desktop) is listed first next time
rc=$(PICK=here run demo)
assert_eq "last choice first, here runs local" $'picker\ndesktop\nhere\nlocalapp --local' "$(log)"

# the host picked before that is now down: no picker, local launch
fleet false
rc=$(run demo)
assert_eq "down host hidden, no picker" "localapp --local" "$(log)"
fleet true

# arguments (a URL or file from xdg-open) always run locally, never ask
rc=$(run demo https://example.com)
assert_eq "args run local" "localapp --local https://example.com" "$(log)"

# on the only host that has the app, there is nothing to choose
cat > "$T/registry.json" <<JSON
{"self":"desktop","apps":{"demo":{"exec":["localapp"],"remoteExec":["localapp"],"hosts":["desktop"]}}}
JSON
rc=$(run demo)
assert_eq "self is only host" "localapp" "$(log)"

# cancelling the picker launches nothing
registry surface
rc=$(PICK= run demo)
assert_eq "cancel runs nothing" $'picker\nhere\ndesktop' "$(log)"
assert_eq "cancel exit" 0 "$rc"

# a missing fleet snapshot still offers the host (ssh will report)
rm "$T/fleet.json"
rc=$(PICK=here run demo)
assert_eq "no snapshot offers hosts" $'picker\nhere\ndesktop\nlocalapp --local' "$(log)"
fleet true

# `on` failing fast notifies and propagates the status
rc=$(PICK=desktop ON_RC=3 run demo)
assert_eq "fast failure status" 3 "$rc"
grep -q '^notify-send .*demo on desktop failed (exit 3)' "$T/log"; assert_eq "fast failure notifies" 0 $?

# unknown id and missing id
rc=$(run nonesuch); assert_eq "unknown id exit" 2 "$rc"
grep -q "'nonesuch' is not in the registry" "$T/out"; assert_eq "unknown id message" 0 $?
rc=$(run); assert_eq "no args exit" 2 "$rc"

# --- an app only another host has (kdenlive on desktop) ---
only_surface() { # $1 = surface up/ssh_ok flag
  cat > "$T/registry.json" <<JSON
{"self":"desktop","apps":{"demo":{"exec":["localapp"],"remoteExec":["remoteapp","--r"],"hosts":["surface"]}}}
JSON
  cat > "$T/fleet.json" <<JSON
{"hosts":[{"host":"desktop","up":true,"ssh_ok":true},{"host":"surface","up":$1,"ssh_ok":$1}]}
JSON
}
rm -rf "$T/state"
only_surface true
rc=$(PICK=here run demo)
assert_eq "remote-only app goes straight to the host, no picker" "on surface remoteapp --r" "$(log)"
[[ ! -e "$T/state/demo" ]]; assert_eq "no choice saved when nothing was asked" 0 $?

only_surface false
rc=$(run demo)
assert_eq "remote-only app, host down: exit 1" 1 "$rc"
grep -q 'notify-send .*demo is not installed on desktop and no host that has it is reachable' "$T/log"
assert_eq "remote-only app, host down: notifies" 0 $?
! grep -q '^localapp' "$T/log"; assert_eq "remote-only app never launches locally" 0 $?

only_surface true
rc=$(run demo https://example.com)
assert_eq "args on a host without the app: exit 1" 1 "$rc"
grep -q "notify-send .*demo is not installed on desktop" "$T/log"
assert_eq "args on a host without the app: notifies" 0 $?
! grep -q '^localapp' "$T/log"; assert_eq "args on a host without the app: no local launch" 0 $?

# a host that is up but whose ssh is not ok is hidden (up and ssh_ok are both required)
registry surface
cat > "$T/fleet.json" <<JSON
{"hosts":[{"host":"desktop","up":true,"ssh_ok":false},{"host":"surface","up":true,"ssh_ok":true}]}
JSON
rc=$(PICK=desktop run demo)
assert_eq "up but ssh not ok is hidden" "localapp --local" "$(log)"

exit "$fail"
