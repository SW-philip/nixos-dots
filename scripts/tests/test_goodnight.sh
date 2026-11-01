#!/usr/bin/env bash
# Fixture tests for scripts/goodnight.sh: a real temp git repo with bare "origin" and "pi"
# remotes, fake ssh/hostname/systemctl/nixos-version, and a fake deploy-all.sh that records
# how it was called. No real host is touched.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT=$ROOT/scripts/goodnight.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}
assert_has() { # name haystack needle
  if [[ "$2" != *"$3"* ]]; then echo "FAIL: $1 — missing '$3' in: $2"; fail=1; else echo "PASS: $1"; fi
}

mkdir -p "$T/boot" "$T/never-back" "$T/uptime" "$T/bin" "$T/down" "$T/rev" "$T/btrbk" "$T/units" "$T/escrow" "$T/state"

# ---- fakes ----------------------------------------------------------------
printf '#!/bin/sh\ncat %s/me 2>/dev/null || echo SWsurface\n' "$T" > "$T/bin/hostname"
# never a real sudo: a self-reboot test must not be able to reboot this machine
printf '#!/bin/sh\necho "$*" >> %s/self-reboot.log\n' "$T" > "$T/bin/sudo"
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
T=$T
args=("\$@"); while [[ \${args[0]} == -o ]]; do args=("\${args[@]:2}"); done
host=\${args[0]#prepko@}; cmd=\${args[1]:-}
[[ -e \$T/down/\$host ]] && exit 255
case \$cmd in
  true) exit 0 ;;
  *boot_id*) cat "\$T/boot/\$host" 2>/dev/null || echo b0; exit 0 ;;
  *"systemctl reboot"*) echo "\$host" >> "\$T/reboot.log"; [[ -e \$T/sudo-refused ]] && exit 1
     [[ -e \$T/never-back/\$host ]] || echo "b\$(wc -l < "\$T/reboot.log")" > "\$T/boot/\$host"; exit 255 ;;
  "cut -d. -f1 /proc/uptime") cat "\$T/uptime/\$host" 2>/dev/null || echo 99999; exit 0 ;;
  *nixos-version*) cat "\$T/rev/\$host" 2>/dev/null; exit 0 ;;
  *"/mnt/backup/btrbk/"*) n=\$(sed -E 's#.*btrbk/([a-z]+).*#\1#' <<<"\$cmd"); cat "\$T/btrbk/\$n" 2>/dev/null; exit 0 ;;
  "systemctl show -p Result --value"*) u=\${cmd##* }; cat "\$T/units/\$host-\$u" 2>/dev/null || echo success; exit 0 ;;
  *key-escrow*) n=\$(grep -oE 'key-escrow/[A-Za-z]+' <<<"\$cmd" | cut -d/ -f2); cat "\$T/escrow/\$n" 2>/dev/null; exit 0 ;;
esac
exit 0
EOF
printf '#!/bin/sh\ncat %s/rev/surface 2>/dev/null\n' "$T" > "$T/bin/nixos-version"
cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
u=\$(echo "\$@" | awk '{print \$NF}')
cat $T/units/surface-\$u 2>/dev/null || echo success
EOF
printf '#!/bin/sh\necho "NOTIFY: $*" >> %s/notify.log\n' "$T" > "$T/bin/notify-send"
cat > "$T/audit-stub" <<EOF
#!/bin/sh
[ "\$1" = --report ] && { echo "audit report stub"; exit 0; }
exit \$(cat $T/audit.rc 2>/dev/null || echo 0)
EOF
chmod +x "$T"/bin/* "$T/audit-stub"
echo 0 > "$T/audit.rc"

# ---- repo: A <- B (main). origin and pi mirror both at B ------------------
git init -q --bare "$T/origin.git"; git init -q --bare "$T/pi.git"
git init -q -b main "$T/repo"
git -C "$T/repo" config user.email t@t; git -C "$T/repo" config user.name t
mkdir -p "$T/repo/scripts"
cat > "$T/repo/scripts/deploy-all.sh" <<EOF
#!/usr/bin/env bash
echo "NONINTERACTIVE=\${NONINTERACTIVE:-} args=\$*" >> $T/deploy.log
rc=\$(cat $T/deploy.rc 2>/dev/null || echo 0); exit \$rc
EOF
printf '#!/bin/sh\necho flake-check-ran >> %s/flake.log\n' "$T" > "$T/repo/scripts/flake-check.sh"
chmod +x "$T/repo/scripts/"*.sh
echo a > "$T/repo/f"; git -C "$T/repo" add -A; git -C "$T/repo" commit -qm A
A=$(git -C "$T/repo" rev-parse HEAD)
echo b >> "$T/repo/f"; git -C "$T/repo" commit -qam B
B=$(git -C "$T/repo" rev-parse HEAD)
git -C "$T/repo" remote add origin "$T/origin.git"; git -C "$T/repo" remote add pi "$T/pi.git"
git -C "$T/repo" push -q origin main; git -C "$T/repo" push -q pi main
echo c >> "$T/repo/f"; git -C "$T/repo" commit -qam C-unshipped
C=$(git -C "$T/repo" rev-parse HEAD)   # ahead of main, only local (wip)

stamp() { date -d "$1 hours ago" +%Y%m%dT%H%M; }
fresh_world() {
  rm -rf "$T/me" "$T/self-reboot.log" "$T/boot"/* "$T/never-back"/* "$T/uptime"/* "$T/reboot.log" "$T/sudo-refused" "$T/down"/* "$T/rev"/* "$T/units"/* "$T/deploy.log" "$T/deploy.rc" "$T/flake.log" "$T/notify.log" "$T/state"/* "$T/escrow"/*
  for h in pi retro desktop surface; do echo "$A" > "$T/rev/$h"; done   # everyone one commit behind main
  { echo "home.$(stamp 3)"; } > "$T/btrbk/home"; { echo "persist.$(stamp 3)"; } > "$T/btrbk/persist"
  date +%s > "$T/escrow/SWphil"; date +%s > "$T/escrow/SWsurface"
  echo 0 > "$T/audit.rc"
}
gn() { # args... ; runs goodnight against the fixture, prints combined output
  PATH="$T/bin:$PATH" GOODNIGHT_STATE="$T/state" GOODNIGHT_REPO="$T/repo" GOODNIGHT_WAKE_WAIT=0 GOODNIGHT_STREAM_WAIT=0 \
    GOODNIGHT_AUDIT="$T/audit-stub" GOODNIGHT_NOTIFY=1 FLEET_JSON="$ROOT/hosts/inventory.json" \
    bash "$SCRIPT" "$@" 2>&1
}
# a planner stub: canned plan per host from $T/plan/<host> (default fine)
mkdir -p "$T/plan"
cat > "$T/plan-stub" <<STUB
#!/usr/bin/env bash
shift; [ "\${1:-}" = --json ] && shift
if [ \$# -gt 0 ]; then hosts="\$*"; else hosts="surface retro pi desktop"; fi
for h in \$hosts; do a=\$(cat $T/plan/\$h 2>/dev/null || echo fine); printf '{"host":"%s","action":"%s","reasons":["test"],"blocks":[],"facts":{"uptime_days":1}}\\n' "\$h" "\$a"; done | jq -s .
STUB
chmod +x "$T/plan-stub"
gnr() { echo SWphil > "$T/me"; GOODNIGHT_REBOOT_PLAN="$T/plan-stub" GOODNIGHT_REBOOT_WAIT=3 GOODNIGHT_REBOOT_SETTLE=${SETTLE:-0} GOODNIGHT_REBOOT_POLL=1 gn "$@"; }
phase_status() { jq -r ".phases.$1.status" "$T/state/report.json"; }

# ---- 1. deploy disabled: reports, never calls deploy-all -------------------
fresh_world
out=$(gn run deploy); rc=$?
assert_eq "disabled: rc 0" 0 "$rc"
assert_eq "disabled: status skipped" skipped "$(phase_status deploy)"
assert_has "disabled: lists hosts it would deploy" "$out" "would deploy: pi retro desktop surface"
[[ ! -e $T/deploy.log ]] && echo "PASS: disabled: deploy-all not called" || { echo "FAIL: disabled: deploy-all was called"; fail=1; }

# ---- 2. enabled: non-interactive, only hosts that need it ------------------
fresh_world
echo "$B" > "$T/rev/retro"            # current
echo "$C" > "$T/rev/desktop"          # ahead of main: unshipped work
echo "$(printf 'f%.0s' {1..40})" > "$T/rev/pi"   # commit this repo has never seen
out=$(GOODNIGHT_DEPLOY=1 gn run deploy); rc=$?
assert_eq "enabled: rc 0" 0 "$rc"
assert_eq "enabled: status ok" ok "$(phase_status deploy)"
assert_eq "enabled: only surface deployed, non-interactively" "NONINTERACTIVE=1 args=surface" "$(cat "$T/deploy.log")"
assert_has "enabled: ahead host left alone" "$out" "desktop: ahead of main"
assert_has "enabled: unknown commit left alone" "$out" "pi: running ffffffff, not in this repo"
assert_has "enabled: current host noted" "$out" "retro: current"

# ---- 3. unreachable host is excluded and reported by wake -------------------
fresh_world; touch "$T/down/retro"
out=$(GOODNIGHT_DEPLOY=1 gn run wake deploy)
assert_eq "wake: warn" warn "$(phase_status wake)"
assert_has "wake: names the host" "$out" "unreachable after 0s: retro"
assert_eq "wake: deploy skips retro" "NONINTERACTIVE=1 args=pi desktop surface" "$(cat "$T/deploy.log")"
assert_has "wake: pending note" "$out" "retro: unreachable, pending"

# ---- 4. hold skips once and clears itself -----------------------------------
fresh_world
gn hold >/dev/null
out=$(GOODNIGHT_DEPLOY=1 gn run deploy)
assert_has "hold: skipped" "$out" "held (goodnight hold)"
[[ ! -e $T/deploy.log && ! -e $T/state/hold ]] && echo "PASS: hold: nothing deployed, hold cleared" || { echo "FAIL: hold: deploy ran or hold remains"; fail=1; }

# ---- 5. live stream (exit 4) postpones; failure (exit 1) fails and notifies -
fresh_world; echo 4 > "$T/deploy.rc"
out=$(GOODNIGHT_DEPLOY=1 gn run deploy); rc=$?
assert_eq "stream: rc 0 (postponed is not a failure)" 0 "$rc"
assert_has "stream: postponed" "$out" "postponed: a Sunshine stream stayed live"
fresh_world; echo 1 > "$T/deploy.rc"
out=$(GOODNIGHT_DEPLOY=1 gn run deploy); rc=$?
assert_eq "failure: rc 1" 1 "$rc"
assert_eq "failure: status fail" fail "$(phase_status deploy)"
assert_has "failure: notification sent" "$(cat "$T/notify.log")" "goodnight: a phase failed"

# ---- 6. dry run builds only --------------------------------------------------
fresh_world
out=$(gn run --dry-run deploy)
assert_has "dry-run: build-only call" "$(cat "$T/deploy.log")" "args=--build-only pi retro desktop surface"
assert_has "dry-run: announces itself" "$out" "dry run: pi retro desktop surface build cleanly"

# ---- 7. backups ---------------------------------------------------------------
fresh_world
out=$(gn run backups)
assert_eq "backups: all fresh = ok" ok "$(phase_status backups)"
fresh_world; echo "home.$(stamp 60)" > "$T/btrbk/home"; rm "$T/escrow/SWsurface"
git -C "$T/repo" push -q --force pi "$A:refs/heads/main"     # mirror now behind GitHub
out=$(gn run backups)
assert_eq "backups: stale + missing = fail" fail "$(phase_status backups)"
assert_has "backups: stale btrbk" "$out" "btrbk home: newest backup snapshot is 60h old"
assert_has "backups: mirror mismatch" "$out" "mirror: pi main"
assert_has "backups: missing escrow" "$out" "key-escrow surface: no bundle on the pi"
git -C "$T/repo" push -q --force pi "$B:refs/heads/main"

# ---- 8. housekeeping ------------------------------------------------------------
fresh_world; echo failed > "$T/units/surface-nh-clean.service"
out=$(gn run housekeeping)
assert_eq "housekeeping: failed unit = warn" warn "$(phase_status housekeeping)"
assert_has "housekeeping: names it" "$out" "surface nh-clean.service: failed"
fresh_world
out=$(GOODNIGHT_FLAKE_CHECK=1 gn run housekeeping)
assert_eq "housekeeping: flake-check ran from the main checkout" "flake-check-ran" "$(cat "$T/flake.log")"

# ---- 9. audit phase and report merge ---------------------------------------------
fresh_world; echo '{"generated_at": 1, "hosts": {"surface": {"grade": "A"}}}' > "$T/state/report.json"
echo 1 > "$T/audit.rc"
out=$(gn run audit); rc=$?
assert_eq "audit: new failures -> rc 1" 1 "$rc"
assert_eq "audit: phase fail" fail "$(phase_status audit)"
assert_eq "report keeps the audit's hosts" A "$(jq -r .hosts.surface.grade "$T/state/report.json")"
fresh_world
gn run wake >/dev/null; gn run audit >/dev/null
assert_eq "a later partial run keeps earlier phases" "ok ok" "$(phase_status wake) $(phase_status audit)"

# ---- 6. reboot phase (desktop drives, as at 02:30) --------------------------
fresh_world; echo SWphil > "$T/me"
fresh_world; rm -f "$T/plan"/*; echo reboot > "$T/plan/surface"; echo reboot > "$T/plan/pi"
out=$(gnr run reboot); rc=$?
assert_eq "reboot off: nothing rebooted" "" "$(cat "$T/reboot.log" 2>/dev/null)"
assert_has "reboot off: report only" "$out" "would reboot: surface pi"

fresh_world; rm -f "$T/plan"/*; echo reboot > "$T/plan/surface"; echo reboot > "$T/plan/pi"
out=$(GOODNIGHT_REBOOT=1 gnr run reboot); rc=$?
assert_eq "reboot on: rc 0" 0 "$rc"
assert_eq "reboot on: one at a time, in plan order" "surface pi" "$(tr '\n' ' ' < "$T/reboot.log" | sed 's/ $//')"
assert_has "reboot on: summary" "$out" "rebooted: surface pi"

fresh_world; rm -f "$T/plan"/*; echo reboot > "$T/plan/surface"; echo reboot > "$T/plan/pi"; touch "$T/never-back/surface"
out=$(GOODNIGHT_REBOOT=1 gnr run reboot); rc=$?
assert_eq "no-show: rc 1" 1 "$rc"
assert_eq "no-show: stops the chain" "surface" "$(tr '\n' ' ' < "$T/reboot.log" | sed 's/ $//')"
assert_has "no-show: says which host" "$out" "surface did not come back"

fresh_world; rm -f "$T/plan"/*; echo reboot > "$T/plan/pi"; touch "$T/sudo-refused"
out=$(GOODNIGHT_REBOOT=1 gnr run reboot); rc=$?
assert_eq "sudo refused: fails fast, rc 1" 1 "$rc"

fresh_world; rm -f "$T/plan"/*; echo reboot > "$T/plan/pi"
out=$(GOODNIGHT_REBOOT=1 gnr run --dry-run reboot)
assert_eq "dry run: nothing rebooted" "" "$(cat "$T/reboot.log" 2>/dev/null)"

# the driving host reboots last, after the report, and only with every other host settled
fresh_world; echo SWphil > "$T/me"; rm -f "$T/plan"/*; echo reboot > "$T/plan/surface"; echo reboot > "$T/plan/desktop"
out=$(GOODNIGHT_REBOOT=1 gnr run reboot)
assert_eq "self: others first" "surface" "$(cat "$T/reboot.log")"
assert_has "self: reboot issued last" "$(cat "$T/self-reboot.log")" "systemctl reboot"
assert_eq "self: report written first" ok "$(phase_status reboot)"
fresh_world; echo SWphil > "$T/me"; rm -f "$T/plan"/*; echo reboot > "$T/plan/desktop"; echo 30 > "$T/uptime/surface"
out=$(GOODNIGHT_REBOOT=1 SETTLE=120 gnr run reboot)
assert_has "self: waits out a host still booting" "$out" "surface is down or still booting"
[[ ! -s $T/self-reboot.log ]] && echo "PASS: self: not rebooted" || { echo "FAIL: self rebooted over a booting host"; fail=1; }

exit $fail
