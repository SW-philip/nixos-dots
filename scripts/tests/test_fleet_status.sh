#!/usr/bin/env bash
# Fixture tests for scripts/fleet-status.sh with fake tailscale and ssh.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/fleet-status.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
git config --global user.name test; git config --global user.email t@t

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

# a repo with commits c1 < c2 < c3: wip sits at c3, main is held back at c1, and nothing is checked
# out (detached) so the tests can move either branch with `branch -f`
R="$T/repo"; git init -q -b main "$R"
mkdir -p "$R/hosts/pi"
for n in 1 2 3; do echo $n > "$R/f"; echo $n > "$R/hosts/pi/config.nix"; git -C "$R" add -A; git -C "$R" commit -qm "c$n"; done
C1=$(git -C "$R" rev-parse HEAD~2); C2=$(git -C "$R" rev-parse HEAD~1); C3=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q -b wip
git -C "$R" branch -f main "$C1"
git -C "$R" checkout -q --detach

NOW=2000000000
OUT="$T/out.json"
mkdir -p "$T/shim" "$T/probe"

cat > "$T/shim/tailscale" <<'SHIM'
#!/usr/bin/env bash
[[ -f "$FAKE/ts.json" ]] && [[ "$1 $2" == "status --json" ]] && { cat "$FAKE/ts.json"; exit 0; }
exit 1
SHIM
cat > "$T/shim/ssh" <<'SHIM'
#!/usr/bin/env bash
# fake `ssh <opts> host cmd`: log the host, answer from $FAKE/probe/<host> or fail like a dead link
while [[ "$1" == -* ]]; do if [[ "$1" == -n ]]; then shift; else shift 2; fi; done
echo "$1" >> "$FAKE/ssh.log"
[[ -f "$FAKE/probe/$1" ]] || exit 255
cat "$FAKE/probe/$1"
SHIM
chmod +x "$T/shim/tailscale" "$T/shim/ssh"

cat > "$T/ts.json" <<'JSON'
{"BackendState":"Running","Self":{"HostName":"SWphil","Online":true},
 "Peer":{"k1":{"HostName":"SWsurface","Online":true},
         "k2":{"HostName":"retro","Online":false},
         "k3":{"HostName":"pi","Online":true}}}
JSON

run() {   # run the script with fakes; extra env via the caller
  rm -f "$OUT" "$T/ssh.log"
  FAKE="$T" PATH="$T/shim:$PATH" FLEET_ROOT="$R" FLEET_OUT="$OUT" FLEET_NOW=$NOW \
    FLEET_SELF=SWphil FLEET_PROBE_CMD="cat $T/probe/desktop" "$SCRIPT" "$@"
}
field() { jq -r --arg h "$1" ".hosts[] | select(.host==\$h) | .$2" "$OUT"; }

printf 'rev=%s\nbuilt=%s\n' "$C3" $((NOW - 1000)) > "$T/probe/desktop"
printf 'rev=%s\nbuilt=%s\n' "$C1" $((NOW - 86400)) > "$T/probe/surface"
printf 'rev=%s\nbuilt=%s\n' "$C2-dirty" $((NOW - 60)) > "$T/probe/pi"
run; rc=$?

echo "== normal fleet =="
assert_eq "exit code" "0" "$rc"
assert_ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "PASS: $d"; else echo "FAIL: $d"; fail=1; fi; }
assert_ok "output is valid json" jq -e . "$OUT"
assert_eq "hosts in configured order" "desktop surface retro pi" "$(jq -r '[.hosts[].host]|join(" ")' "$OUT")"
assert_eq "head is the wip tip" "$C3" "$(jq -r .head "$OUT")"
assert_eq "head_ref" "wip" "$(jq -r .head_ref "$OUT")"
assert_eq "generated_at" "$NOW" "$(jq -r .generated_at "$OUT")"
assert_eq "desktop (self) fresh: drift 0" "0" "$(field desktop drift)"
assert_eq "desktop build age" "1000" "$(field desktop built_age_s)"
assert_eq "desktop up" "true" "$(field desktop up)"
assert_eq "surface two commits behind" "2" "$(field surface drift)"
assert_eq "surface not dirty" "false" "$(field surface dirty)"
assert_eq "pi dirty flag" "true" "$(field pi dirty)"
assert_eq "pi dirty drift measured from the base commit" "1" "$(field pi drift)"
assert_eq "pi rev keeps the -dirty suffix" "$C2-dirty" "$(field pi rev)"
assert_eq "retro offline: up false" "false" "$(field retro up)"
assert_eq "retro offline: ssh_ok false" "false" "$(field retro ssh_ok)"
assert_eq "retro offline: rev null" "null" "$(field retro rev)"
assert_eq "retro offline was never ssh'd" "0" "$(grep -c '^retro$' "$T/ssh.log")"
assert_eq "self is probed locally, not over ssh" "0" "$(grep -c '^desktop$' "$T/ssh.log")"

echo "== ahead =="
printf 'rev=%s\nbuilt=%s\n' "$C3" $((NOW - 5)) > "$T/probe/surface"
git -C "$R" branch -f wip "$C2"
run >/dev/null
assert_eq "deployed commit newer than wip counts as ahead" "1" "$(field surface ahead)"
assert_eq "...and drift is 0" "0" "$(field surface drift)"
git -C "$R" branch -f wip "$C3"

echo "== unstamped host =="
printf 'rev=\nbuilt=%s\n' $((NOW - 7)) > "$T/probe/pi"
run >/dev/null
assert_eq "empty rev becomes null" "null" "$(field pi rev)"
assert_eq "unstamped drift null" "null" "$(field pi drift)"
assert_eq "unstamped host still has a build age" "7" "$(field pi built_age_s)"

echo "== rev not in local history =="
printf 'rev=%s\nbuilt=%s\n' "0123456789abcdef0123456789abcdef01234567" $((NOW - 7)) > "$T/probe/pi"
run >/dev/null
assert_eq "unknown commit gives null drift" "null" "$(field pi drift)"

echo "== renamed tailscale devices (SWretro / SWpi) =="
sed -e 's/"retro"/"SWretro"/' -e 's/"pi"/"SWpi"/' "$T/ts.json" > "$T/ts.new" && mv "$T/ts.json" "$T/ts.old" && mv "$T/ts.new" "$T/ts.json"
printf 'rev=%s\nbuilt=%s\n' "$C3" $((NOW - 7)) > "$T/probe/pi"
run >/dev/null
assert_eq "renamed retro still reads as offline" "false" "$(field retro up)"
assert_eq "renamed pi still reads as online" "true" "$(field pi up)"
mv "$T/ts.old" "$T/ts.json"

echo "== online but ssh dead =="
rm "$T/probe/surface"
run >/dev/null
assert_eq "up from tailscale" "true" "$(field surface up)"
assert_eq "ssh_ok false" "false" "$(field surface ssh_ok)"

echo "== tailscale unavailable =="
mv "$T/ts.json" "$T/ts.off"
printf 'rev=%s\nbuilt=%s\n' "$C3" $((NOW - 5)) > "$T/probe/surface"
run >/dev/null
assert_eq "ssh success implies up when tailscale is silent" "true" "$(field surface up)"
assert_eq "dead host is still down" "false" "$(field retro up)"
assert_eq "ssh is attempted for every non-self host" "3" "$(wc -l < "$T/ssh.log")"
mv "$T/ts.off" "$T/ts.json"

echo "== tailscaled not Running =="
mv "$T/ts.json" "$T/ts.off"
sed -e 's/"Running"/"Stopped"/' -e 's/"Online":true}/"Online":false}/g' "$T/ts.off" > "$T/ts.json"
printf 'rev=%s\nbuilt=%s\n' "$C3" $((NOW - 5)) > "$T/probe/surface"
run >/dev/null
assert_eq "stopped daemon: ssh is attempted for every non-self host" "3" "$(wc -l < "$T/ssh.log")"
assert_eq "stopped daemon: host with a probe reads up" "true" "$(field surface up)"
mv "$T/ts.off" "$T/ts.json"

echo "== tailscale prints json then fails =="
mkdir -p "$T/shim2"; cp "$T/shim/ssh" "$T/shim2/ssh"
cat > "$T/shim2/tailscale" <<'SHIM'
#!/usr/bin/env bash
cat "$FAKE/ts.json"; exit 1
SHIM
chmod +x "$T/shim2/tailscale"
rm -f "$OUT" "$T/ssh.log"
FAKE="$T" PATH="$T/shim2:$PATH" FLEET_ROOT="$R" FLEET_OUT="$OUT" FLEET_NOW=$NOW \
  FLEET_SELF=SWphil FLEET_PROBE_CMD="cat $T/probe/desktop" "$SCRIPT" >/dev/null 2>&1
rc=$?
assert_eq "json-then-fail: exit code" "0" "$rc"
assert_ok "json-then-fail: output is valid json" jq -e . "$OUT"
assert_eq "json-then-fail: four hosts" "4" "$(jq '.hosts|length' "$OUT")"

echo "== no repo =="
FAKE="$T" PATH="$T/shim:$PATH" FLEET_ROOT="$T/nonexistent" FLEET_OUT="$OUT" FLEET_NOW=$NOW \
  FLEET_SELF=SWphil FLEET_PROBE_CMD="cat $T/probe/desktop" "$SCRIPT" >/dev/null 2>&1
rc=$?
assert_eq "no repo: exit code" "0" "$rc"
assert_eq "no repo: head null" "null" "$(jq -r .head "$OUT")"
assert_eq "no repo: drift null" "null" "$(field desktop drift)"

echo "== garbled / old-format output =="
printf '%s\n' 1791252437 > "$T/probe/pi"
run >/dev/null
assert_eq "garbled: ssh_ok true" "true" "$(field pi ssh_ok)"
assert_eq "garbled: bare number is not a rev" "null" "$(field pi rev)"
assert_eq "garbled: built_at null" "null" "$(field pi built_at)"
assert_eq "garbled: drift null" "null" "$(field pi drift)"

echo "== leading-zero build time =="
printf 'rev=%s\nbuilt=%s\n' "$C1" 0123 > "$T/probe/surface"
run >/dev/null; rc=$?
assert_eq "leading zeros: exit code" "0" "$rc"
assert_eq "leading zeros read as decimal" "$((NOW - 123))" "$(field surface built_age_s)"

echo "== drift ignores docs-only commits =="
git -C "$R" checkout -q -b docs-scratch "$C3"
mkdir -p "$R/docs"; echo n > "$R/docs/note.md"; git -C "$R" add -A; git -C "$R" commit -qm "docs only"
echo 4 > "$R/f"; git -C "$R" commit -qam "real change"
git -C "$R" branch -f wip HEAD; git -C "$R" checkout -q --detach
printf 'rev=%s\nbuilt=%s\n' "$C3" $((NOW - 100)) > "$T/probe/surface"
run >/dev/null
assert_eq "docs commit + real commit = 1 behind" "1" "$(field surface drift)"
git -C "$R" checkout -q -b docs-tip "$C3"; mkdir -p "$R/docs"; echo n2 > "$R/docs/note.md"; git -C "$R" add -A; git -C "$R" commit -qm "docs tip"
git -C "$R" branch -f wip HEAD; git -C "$R" checkout -q --detach
run >/dev/null
assert_eq "docs-only range = 0 behind" "0" "$(field surface drift)"
echo "== retro and pi only count commits on their own paths =="
git -C "$R" checkout -q -b scoped wip; mkdir -p "$R/modules"; echo m > "$R/modules/x.nix"; git -C "$R" add -A; git -C "$R" commit -qm "modules only"
git -C "$R" branch -f wip HEAD; git -C "$R" checkout -q --detach
printf 'rev=%s\nbuilt=%s\n' "$C3" $((NOW - 100)) > "$T/probe/pi"
run >/dev/null
assert_eq "modules-only commit: surface 1 behind" "1" "$(field surface drift)"
assert_eq "modules-only commit: pi 0 behind" "0" "$(field pi drift)"
git -C "$R" checkout -q -b scoped2 wip; mkdir -p "$R/hosts/pi"; echo p > "$R/hosts/pi/config.nix"; git -C "$R" add -A; git -C "$R" commit -qm "pi config"
git -C "$R" branch -f wip HEAD; git -C "$R" checkout -q --detach
run >/dev/null
assert_eq "pi config commit: pi 1 behind" "1" "$(field pi drift)"
assert_eq "pi config commit: surface 2 behind" "2" "$(field surface drift)"
echo "== output hygiene =="
printf 'rev=%s\nbuilt=%s\n' "$C1" $((NOW - 86400)) > "$T/probe/surface"
run >/dev/null
assert_eq "no leftover temp files" "0" "$(compgen -G "$OUT.*" | wc -l)"
assert_eq "output is world-readable" "644" "$(stat -c %a "$OUT")"

echo "== default probe command, run for real =="
if [[ -e /run/current-system ]]; then
  rm -f "$OUT"
  env -u FLEET_PROBE_CMD FAKE="$T" PATH="$T/shim:$PATH" FLEET_ROOT="$R" FLEET_OUT="$OUT" FLEET_NOW=$NOW \
    FLEET_SELF=SWphil "$SCRIPT" >/dev/null 2>&1
  assert_eq "real probe: ssh_ok true" "true" "$(field desktop ssh_ok)"
  assert_ok "real probe: built_at is a positive integer" jq -e '.hosts[] | select(.host=="desktop") | .built_at > 0' "$OUT"
  assert_ok "real probe: rev is null or not purely numeric" jq -e '.hosts[] | select(.host=="desktop") | .rev == null or (.rev | test("^[0-9]+$") | not)' "$OUT"
  if [[ -e /nix/var/nix/profiles/system ]]; then
    assert_eq "real probe: built_at is the system profile link mtime" "$(stat -c %Y /nix/var/nix/profiles/system)" "$(field desktop built_at)"
  fi
else
  echo "SKIP: /run/current-system missing"
fi

exit "$fail"
