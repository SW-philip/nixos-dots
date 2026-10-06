#!/usr/bin/env bash
# Fixture tests for scripts/ff-session.sh with fake tailscale and who.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ff-session.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shim"
fail=0
assert_eq() { if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi; }

cat > "$T/shim/tailscale" <<'SHIM'
#!/usr/bin/env bash
# fake tailscale: `status --json` and `whois --json <ip>` (only 100.77.7.7); FAKE_TS_DOWN=1 fails everything
[[ -n "${FAKE_TS_DOWN:-}" ]] && exit 1
[[ "$1 $2" == "status --json" ]] && { echo '{"Self":{"HostName":"SWphil","TailscaleIPs":["100.64.0.1"]},"Peer":{"k1":{"HostName":"SWsurface","TailscaleIPs":["100.64.0.2"]},"k2":{"HostName":"SWpi","TailscaleIPs":["100.64.0.4"]}}}'; exit 0; }
[[ "$1 $2" == "whois --json" && "$3" == 100.77.7.7 ]] && { echo '{"Node":{"ComputedName":"fallbackname","Name":"x.ts.net."}}'; exit 0; }
exit 1
SHIM
cat > "$T/shim/who" <<'SHIM'
#!/usr/bin/env bash
cat "$FAKE_WHO"
SHIM
chmod +x "$T/shim/tailscale" "$T/shim/who"
run() { PATH="$T/shim:$PATH" FAKE_WHO="$T/who.txt" "$SCRIPT" "$@"; }

echo "== from =="
assert_eq "tailnet client resolves to its device name" "SWsurface (100.64.0.2)" \
  "$(SSH_CONNECTION='100.64.0.2 51234 100.64.0.1 22' run from)"
assert_eq "case preserved from status"                 "SWpi (100.64.0.4)" \
  "$(SSH_CONNECTION='100.64.0.4 51234 100.64.0.1 22' run from)"
assert_eq "whois fallback when status lacks the ip"    "fallbackname (100.77.7.7)" \
  "$(SSH_CONNECTION='100.77.7.7 51234 100.64.0.1 22' run from)"
assert_eq "tailscale down falls back to the address"   "100.64.0.2" \
  "$(FAKE_TS_DOWN=1 SSH_CONNECTION='100.64.0.2 51234 100.64.0.1 22' run from)"
assert_eq "unknown client falls back to the address"   "10.0.0.57" \
  "$(SSH_CONNECTION='10.0.0.57 51234 10.0.0.224 22' run from)"
assert_eq "no ssh connection"                          "local session" \
  "$(env -u SSH_CONNECTION PATH="$T/shim:$PATH" FAKE_WHO="$T/who.txt" "$SCRIPT" from)"

echo "== others =="
cat > "$T/who.txt" <<'WHO'
prepko   pts/1        2026-10-05 22:10 (100.64.0.2)
prepko   pts/3        2026-10-05 22:12 (100.88.1.5)
phil     tty2         2026-10-05 20:00 (tty2)
guest    :0           2026-10-05 20:01 (:0)
WHO
assert_eq "other sessions, own tty excluded" "prepko ← 100.88.1.5, phil (local), guest (local)" \
  "$(FF_SELF_TTY=pts/1 run others)"
printf 'prepko   pts/1        2026-10-05 22:10 (100.64.0.2)\n' > "$T/who.txt"
assert_eq "only me" "just you" "$(FF_SELF_TTY=pts/1 run others)"
: > "$T/who.txt"
assert_eq "nobody (empty who)" "just you" "$(FF_SELF_TTY=pts/1 run others)"

echo "== usage =="
rc=0; run bogus >/dev/null 2>&1 || rc=$?
assert_eq "unknown subcommand exits 64" "64" "$rc"

exit "$fail"
