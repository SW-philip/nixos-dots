#!/usr/bin/env bash
# Fixture tests for scripts/goodnight-reboot.sh `plan`: a fake ssh serves canned probe facts per
# host, so the reason/block decisions and reaper's strike counting run without touching a host.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT=$ROOT/scripts/goodnight-reboot.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

mkdir -p "$T/bin" "$T/facts" "$T/state"
printf '#!/bin/sh\necho SWphil\n' > "$T/bin/hostname"
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
args=("\$@"); while [[ \${args[0]} == -o ]]; do args=("\${args[@]:2}"); done
host=\${args[0]#prepko@}
[[ -e $T/facts/\$host ]] || exit 255
cat $T/facts/\$host
EOF
chmod +x "$T"/bin/*

facts() { # host uptime kernel mem swap battery blockers
  printf 'uptime_days=%s\nkernel_pending=%s\nmem_avail_pct=%s\nswap_used_pct=%s\nbattery=%s\nac=0\nblockers=%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" > "$T/facts/$1"
}
plan() { PATH=$T/bin:$PATH GOODNIGHT_STATE=$T/state REAPER_JSON=$T/reaper.json bash "$SCRIPT" plan --json "$@"; }
field() { jq -r ".[] | select(.host == \"$1\") | $2" <<<"$PLAN"; }

echo '{"checked":1,"hosts":{}}' > "$T/reaper.json"

facts surface 3 1 60 0 80 ""        # kernel changed, battery fine
facts retro 31 0 60 0 none "stream" # old enough, but a stream is live
facts pi 3 0 60 0 none ""           # nothing to do
PLAN=$(plan surface retro pi nope)

assert_eq "kernel change on a healthy host reboots" reboot "$(field surface .action)"
assert_eq "its reason names the kernel" "kernel or initrd changed since boot" "$(field surface '.reasons[0]')"
assert_eq "old host with a live stream waits" wait "$(field retro .action)"
assert_eq "the wait names the stream" stream "$(field retro '.blocks[0]')"
assert_eq "a quiet young host is fine" fine "$(field pi .action)"
assert_eq "an unreachable host is skipped" skip "$(field nope .action)"

facts surface 3 1 60 0 29 ""
PLAN=$(plan surface)
assert_eq "low battery blocks even a needed reboot" wait "$(field surface .action)"
assert_eq "the block says why" "battery 29% < 50%" "$(field surface '.blocks[0]')"

facts surface 3 0 5 0 80 ""
PLAN=$(plan surface)
assert_eq "low available memory is a reason" reboot "$(field surface .action)"

# reaper: one sweep with a stuck process is a blip, a second sweep makes it a reason
facts pi 3 0 60 0 none ""
stuck='{"zombies":[{"persists":true}],"dstate":[],"failed":[],"reachable":true}'
echo "{\"checked\":100,\"hosts\":{\"pi\":$stuck}}" > "$T/reaper.json"
PLAN=$(plan pi)
assert_eq "one stuck sweep is not enough" fine "$(field pi .action)"
PLAN=$(plan pi)
assert_eq "planning twice in one sweep adds no strike" fine "$(field pi .action)"
echo "{\"checked\":200,\"hosts\":{\"pi\":$stuck}}" > "$T/reaper.json"
PLAN=$(plan pi)
assert_eq "a second stuck sweep reboots" reboot "$(field pi .action)"
clean='{"zombies":[],"dstate":[],"failed":[{"scope":"user","unit":"x"}],"reachable":true}'
echo "{\"checked\":300,\"hosts\":{\"pi\":$clean}}" > "$T/reaper.json"
PLAN=$(plan pi)
assert_eq "a clean sweep resets the count (failed units don't count)" fine "$(field pi .action)"

# default order: surface, retro, pi, then the driving host (desktop here) last
for h in surface retro pi desktop; do facts $h 3 0 60 0 none ""; done
PLAN=$(plan)
assert_eq "default order, driver last" "surface retro pi desktop" "$(jq -r '[.[].host] | join(" ")' <<<"$PLAN")"
facts surface 3 1 60 0 37 ""
PLAN=$(plan surface)
assert_eq "37% battery no longer blocks surface" reboot "$(field surface .action)"

exit $fail
