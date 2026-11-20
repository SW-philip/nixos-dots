#!/usr/bin/env bash
# Fixture tests for scripts/deploy-all.sh: a temp git repo holding a copy of the script, fake
# ssh/nix/hostname/sleep, and per-host fixture files saying what each switch does. No real host
# is touched. Only pi and retro are deployed: surface activates locally and desktop is the builder.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_eq() { if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi; }
assert_has() { if [[ "$2" != *"$3"* ]]; then echo "FAIL: $1 — missing '$3' in: $2"; fail=1; else echo "PASS: $1"; fi; }

mkdir -p "$T/bin" "$T/repo/scripts"
cp "$ROOT/scripts/deploy-all.sh" "$T/repo/scripts/"
echo '{"surface":{"nick":"SWsurface"},"desktop":{"nick":"SWphil"},"retro":{"nick":"SWretro"},"pi":{"nick":"SWpi"}}' > "$T/fleet.json"

# ---- fakes ------------------------------------------------------------------
printf '#!/bin/sh\necho SWsurface\n' > "$T/bin/hostname"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
cat > "$T/bin/nix" <<EOF
#!/bin/sh
echo "nix \$*" >> $T/nix.log
EOF
# Per-host fixtures, all optional (defaults = a clean successful switch to /nix/store/fake-<h>):
#   $T/switch-rc/<h>   "fail" -> the transient switch unit ends failed
#   $T/cur/<h>  $T/prof/<h>   running / profile path the probe reports
#   $T/failed/<h>      failed unit names the probe reports (one per line)
#   $T/buildfail       the desktop build fails
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
T=$T
args=("\$@"); while [[ \${args[0]} == -o || \${args[0]} == -t ]]; do
  if [[ \${args[0]} == -o ]]; then args=("\${args[@]:2}"); else args=("\${args[@]:1}"); fi; done
host=\${args[0]#prepko@}; cmd=\${args[1]:-}
new=/nix/store/fake-\$host
case \$cmd in
  true) exit 0 ;;
  *"nix build"*)
    [[ -e \$T/buildfail ]] && exit 1
    for h in \$(grep -o 'nixosConfigurations\.[a-z]*' <<<"\$cmd" | cut -d. -f2); do echo /nix/store/fake-\$h; done; exit 0 ;;
  *systemd-run*) echo "\$host \$cmd" >> \$T/switch.log; exit 0 ;;
  *"InvocationID"*) echo inv1; exit 0 ;;
  *journalctl*) exit 0 ;;
  *"-p LoadState"*)
    if [[ \$(cat \$T/switch-rc/\$host 2>/dev/null) == fail ]]; then
      printf 'LoadState=loaded\nActiveState=failed\nSubState=failed\nResult=exit-code\n'
    else printf 'LoadState=loaded\nActiveState=active\nSubState=exited\nResult=success\n'; fi; exit 0 ;;
  *"-p ActiveState -p SubState"*) printf 'ActiveState=inactive\nSubState=dead\n'; exit 0 ;;
  *"systemctl stop"*) exit 0 ;;
  *"readlink -f /run/current-system"*)
    cat \$T/cur/\$host 2>/dev/null || echo \$new
    cat \$T/prof/\$host 2>/dev/null || echo \$new
    cat \$T/failed/\$host 2>/dev/null; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T"/bin/*

git -C "$T/repo" init -q -b main
git -C "$T/repo" config user.email t@t; git -C "$T/repo" config user.name t
git -C "$T/repo" add -A; git -C "$T/repo" commit -qm init

run() { # args... — runs deploy-all in the fixture repo, sets $out and $rc
  rm -f "$T/switch.log" "$T/nix.log"
  out=$(cd "$T/repo" && PATH="$T/bin:$PATH" FLEET_JSON="$T/fleet.json" FORCE=1 bash scripts/deploy-all.sh "$@" 2>&1)
  rc=$?
}
reset() { rm -rf "$T/switch-rc" "$T/cur" "$T/prof" "$T/failed" "$T/buildfail"; mkdir -p "$T/switch-rc" "$T/cur" "$T/prof" "$T/failed"; }
switched() { cut -d' ' -f1 "$T/switch.log" 2>/dev/null | xargs; }

# 1. clean run
reset; run pi retro
assert_eq "clean run exits 0" 0 "$rc"
assert_eq "clean run switches pi then retro" "pi retro" "$(switched)"
assert_has "clean run summary" "$out" "pi       ok"

# 2. build failure activates nothing
reset; touch "$T/buildfail"; run pi retro
assert_eq "build failure exits 1" 1 "$rc"
assert_eq "build failure switches nothing" "" "$(switched)"
assert_has "build failure says nothing activated" "$out" "nothing was activated"
rm -f "$T/buildfail"

# 3. build-only never switches
reset; run --build-only pi retro
assert_eq "build-only exits 0" 0 "$rc"
assert_eq "build-only switches nothing" "" "$(switched)"

# 4. dirty tree is refused
reset; echo x > "$T/repo/dirty"; run pi retro
assert_eq "dirty tree exits 1" 1 "$rc"
assert_has "dirty tree message" "$out" "uncommitted changes"
rm -f "$T/repo/dirty"

# 5. unit failed, but host is on the built generation with no failed units: tolerated (the exit-4 race)
reset; echo fail > "$T/switch-rc/pi"; run pi retro
assert_eq "benign switch exit continues" 0 "$rc"
assert_eq "benign switch exit still reaches retro" "pi retro" "$(switched)"
assert_has "benign switch exit is flagged" "$out" "switch exit tolerated"

# 6. unit failed and the host is NOT on the built generation: stop
reset; echo fail > "$T/switch-rc/pi"; echo /nix/store/old > "$T/cur/pi"
run pi retro
assert_eq "wrong generation exits 1" 1 "$rc"
assert_eq "wrong generation leaves retro alone" "pi" "$(switched)"
assert_has "wrong generation reported as SWITCH FAILED" "$out" "SWITCH FAILED"

# 7. unit failed, right generation, but a real unit is down: stop
reset; echo fail > "$T/switch-rc/pi"; echo sshd.service > "$T/failed/pi"
run pi retro
assert_eq "failed unit exits 1" 1 "$rc"
assert_eq "failed unit leaves retro alone" "pi" "$(switched)"
assert_has "failed unit named" "$out" "sshd.service"

# 8. switch succeeded but the host reports the old generation: stop
reset; echo /nix/store/old > "$T/prof/pi"
run pi retro
assert_eq "profile mismatch exits 1" 1 "$rc"
assert_has "profile mismatch reported" "$out" "WRONG GENERATION"

# 9. a failed unit after a clean switch is reported, not fatal
reset; echo foo.service > "$T/failed/pi"; run pi retro
assert_eq "post-switch failed unit does not abort" 0 "$rc"
assert_has "post-switch failed unit shown" "$out" "failed units: foo.service"

exit "$fail"
