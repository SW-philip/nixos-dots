#!/usr/bin/env bash
# Fixture tests for scripts/secrets-lint.sh.
set -uo pipefail

LINT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/secrets-lint.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}
assert_has() {
  if grep -qF -- "$2" <<<"$3"; then echo "PASS: $1"; else echo "FAIL: $1 — '$2' not in: $3"; fail=1; fi
}

R="$T/repo"
mkdir -p "$R/secrets"
git -C "$R" init -q
cat > "$R/.sops.yaml" <<'EOF'
keys:
  - &desktop age1desktop
  - &pi age1pi
EOF
# new sops layout (bare `recipient:`) and the older one (`- recipient:`)
cat > "$R/secrets/shared.yaml" <<'EOF'
api_key: ENC[ciphertext]
scrubbed: ENC[REDACTED]
sops:
    age:
        - recipient: age1desktop
          enc: |
EOF
cat > "$R/secrets/wifi.yaml" <<'EOF'
wifi_env: ENC[ciphertext]
sops:
    age:
        recipient: age1pi
EOF
touch "$R/secrets/untracked.yaml"
git -C "$R" add .sops.yaml secrets/shared.yaml secrets/wifi.yaml

run() {
  printf '%b' "$1" > "$T/decls"
  out=$(SECRETS_LINT_DECLS="$T/decls" bash "$LINT" "$R" 2>&1); rc=$?
}

run 'desktop\tsecrets/shared.yaml\tapi_key\npi\tsecrets/wifi.yaml\twifi_env\n'
assert_eq "valid: exit 0" 0 "$rc"
assert_has "valid: counts" "ok (2 declarations)" "$out"

run 'desktop\tsecrets/shared.yaml\tapi_key/nested\n'
assert_eq "nested key checks its top level: exit 0" 0 "$rc"

run 'pi\tsecrets/shared.yaml\tapi_key\n'
assert_eq "not a recipient: exit 1" 1 "$rc"
assert_has "not a recipient: says so" "pi: can't decrypt secrets/shared.yaml" "$out"

run 'desktop\tsecrets/shared.yaml\tmissing\n'
assert_eq "missing key: exit 1" 1 "$rc"
assert_has "missing key: says so" "has no missing" "$out"

run 'desktop\tsecrets/shared.yaml\tscrubbed\n'
assert_eq "placeholder: exit 1" 1 "$rc"
assert_has "placeholder: says so" "scrubbed placeholder" "$out"

run 'desktop\tsecrets/untracked.yaml\tapi_key\n'
assert_eq "untracked: exit 1" 1 "$rc"
assert_has "untracked: says so" "not git-tracked" "$out"

run 'retro\tsecrets/wifi.yaml\twifi_env\n'
assert_eq "host without an anchor: exit 1" 1 "$rc"
assert_has "host without an anchor: says so" "no &retro age key" "$out"

run ''
assert_eq "no declarations: exit 1" 1 "$rc"

# a recipient .sops.yaml no longer names
printf '        - recipient: age1retired\n' >> "$R/secrets/wifi.yaml"
run 'pi\tsecrets/wifi.yaml\twifi_env\n'
assert_eq "retired recipient: exit 1" 1 "$rc"
assert_has "retired recipient: says so" "secrets/wifi.yaml: recipient age1retired" "$out"

exit "$fail"
