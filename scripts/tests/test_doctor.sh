#!/usr/bin/env bash
# Fixture tests for scripts/doctor.sh.
set -uo pipefail

DOCTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/doctor.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}
assert_has() {
  if grep -qF -- "$2" <<<"$3"; then echo "PASS: $1"; else echo "FAIL: $1 — '$2' not in: $3"; fail=1; fi
}
assert_lacks() {
  if grep -qF -- "$2" <<<"$3"; then echo "FAIL: $1 — '$2' unexpectedly in: $3"; fail=1; else echo "PASS: $1"; fi
}

# a checkout with nothing scrubbed
mkdir -p "$T/clean/hosts"
echo 'user = "prepko";' > "$T/clean/hosts/a.nix"
out=$(bash "$DOCTOR" "$T/clean"); rc=$?
assert_eq "clean: exit 0" 0 "$rc"
assert_has "clean: says so" "Nothing left to replace" "$out"
assert_has "clean: counts the hardcoded username" "'prepko' is hardcoded in 1 files" "$out"

# a scrubbed checkout
mkdir -p "$T/dirty/hosts" "$T/dirty/secrets"
echo 'key = "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY";' > "$T/dirty/hosts/keys.nix"
echo 'host = "desktop.example.ts.net";' > "$T/dirty/hosts/net.nix"
echo 'ip = "100.64.0.2";' >> "$T/dirty/hosts/net.nix"
echo 'wifi_psk: ENC[REDACTED]' > "$T/dirty/secrets/wifi.yaml"
echo 'mac = "00:00:00:00:00:01";' > "$T/dirty/hosts/bt.nix"
out=$(bash "$DOCTOR" "$T/dirty"); rc=$?
assert_eq "dirty: exit 1" 1 "$rc"
assert_has "dirty: ssh keys flagged" "TODO  your SSH public keys" "$out"
assert_has "dirty: lists the file" "hosts/keys.nix" "$out"
assert_has "dirty: tailnet name flagged" "TODO  your tailnet name" "$out"
assert_has "dirty: tailnet ips flagged" "TODO  your hosts' Tailscale IPs" "$out"
assert_has "dirty: bluetooth flagged" "TODO  your Bluetooth device addresses" "$out"
assert_has "dirty: secrets flagged" "secrets/wifi.yaml" "$out"
assert_has "dirty: untouched check passes" "ok    your age public key" "$out"

# an IP that merely starts with the scrub range must not match
mkdir -p "$T/near"
echo 'ip = "100.64.0.20";' > "$T/near/net.nix"
out=$(bash "$DOCTOR" "$T/near"); rc=$?
assert_eq "100.64.0.20 is not a placeholder: exit 0" 0 "$rc"

# the README documents the placeholders; it must not trip the check
mkdir -p "$T/readme"
echo 'Search for AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY and example.ts.net' > "$T/readme/README.md"
out=$(bash "$DOCTOR" "$T/readme"); rc=$?
assert_eq "README is ignored: exit 0" 0 "$rc"
assert_lacks "README is ignored: no TODO" "TODO" "$out"

# the real repo: a private checkout has nothing scrubbed
out=$(bash "$DOCTOR"); rc=$?
assert_eq "real repo runs" 0 "$rc"

exit "$fail"
