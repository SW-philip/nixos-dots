#!/usr/bin/env bash
# Fixture tests for scripts/sops-editor-key.sh, with throwaway age keys and
# the passphrase step swapped for plain files.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sops-editor-key.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}
assert_has() {
  if grep -qF -- "$2" <<<"$3"; then echo "PASS: $1"; else echo "FAIL: $1 — '$2' not in: $3"; fail=1; fi
}

age-keygen -o "$T/host.txt" 2>/dev/null
age-keygen -o "$T/other.txt" 2>/dev/null
HOST=$(age-keygen -y "$T/host.txt")
OTHER=$(age-keygen -y "$T/other.txt")

R="$T/repo"
mkdir -p "$R/secrets"
cat > "$R/.sops.yaml" <<EOF
keys:
  - &host $HOST
  - &other $OTHER
creation_rules:
  - path_regex: secrets/mine\.yaml\$
    key_groups:
      - age: [*host]
  - path_regex: secrets/theirs\.yaml\$
    key_groups:
      - age: [*other]
EOF
# sops finds .sops.yaml from the cwd, so encrypt from a dir that has none
printf 'api_key: hunter2\n' > "$T/mine.yaml"
printf 'token: swordfish\n' > "$T/theirs.yaml"
(cd "$T" && sops encrypt --age "$HOST" mine.yaml) > "$R/secrets/mine.yaml"
(cd "$T" && sops encrypt --age "$OTHER" theirs.yaml) > "$R/secrets/theirs.yaml"

# A fake HOME holding a host key that can open everything proves verify ignores it.
FAKEHOME="$T/home"
mkdir -p "$FAKEHOME/.config/sops/age"
cat "$T/host.txt" "$T/other.txt" > "$FAKEHOME/.config/sops/age/keys.txt"

run() {
  out=$(HOME="$FAKEHOME" SOPS_EDITOR_REPO="$R" SOPS_EDITOR_KEY="$T/editor.txt" \
    SOPS_AGE_KEY_FILE="$2" SOPS_EDITOR_DECRYPT=cat SOPS_EDITOR_ENCRYPT=tee \
    SOPS_EDITOR_LINT=true bash "$SCRIPT" "$1" 2>&1); rc=$?
}

run init "$T/host.txt"
assert_eq "init: exit 0" 0 "$rc"
EDITOR_PUB=$(age-keygen -y "$T/editor.txt")
assert_has "init: anchor added" "- &editor $EDITOR_PUB" "$(cat "$R/.sops.yaml")"
assert_eq "init: every rule gets *editor" 2 "$(grep -c 'age: \[\*[a-z]*, \*editor\]' "$R/.sops.yaml")"
assert_eq "init: key file is private" 600 "$(stat -c %a "$T/editor.txt")"

run init "$T/host.txt"
assert_eq "init twice: refuses" 1 "$rc"

run verify "$T/host.txt"
assert_eq "verify before rotate: exit 1" 1 "$rc"
assert_has "verify before rotate: lists todo" "todo  secrets/mine.yaml" "$out"

run rotate "$T/host.txt"
assert_eq "rotate on host: exit 0" 0 "$rc"
assert_has "rotate: does what it can" "done  secrets/mine.yaml" "$out"
assert_has "rotate: skips what it can't" "skip  secrets/theirs.yaml (this host can't decrypt it)" "$out"
assert_eq "rotate: host key still opens it" "hunter2" \
  "$(SOPS_AGE_KEY_FILE="$T/host.txt" sops decrypt --extract '["api_key"]' "$R/secrets/mine.yaml")"

run verify "$T/host.txt"
assert_eq "verify half done: exit 1" 1 "$rc"
assert_has "verify half done: mine ok" "ok    secrets/mine.yaml" "$out"
assert_has "verify half done: theirs todo" "todo  secrets/theirs.yaml" "$out"

# the other host's turn
run rotate "$T/other.txt"
assert_has "rotate elsewhere: skips finished file" "skip  secrets/mine.yaml (editor already a recipient)" "$out"
assert_has "rotate elsewhere: does its file" "done  secrets/theirs.yaml" "$out"

run verify "$T/host.txt"
assert_eq "verify all: exit 0" 0 "$rc"
assert_has "verify all: says so" "editor key opens every file" "$out"

# sync: a new recipient in .sops.yaml lands in the file, from the editor key alone
age-keygen -o "$T/new.txt" 2>/dev/null
NEW=$(age-keygen -y "$T/new.txt")
sed -i "s|^  - &other .*|&\n  - \&new $NEW|; s|age: \[\*host, \*editor\]|age: [*host, *new, *editor]|" "$R/.sops.yaml"
run sync /nonexistent
assert_eq "sync add: exit 0" 0 "$rc"
assert_has "sync add: re-keys the changed file" "done  secrets/mine.yaml" "$out"
assert_has "sync add: leaves the rest" "same  secrets/theirs.yaml" "$out"
assert_eq "sync add: new key opens it" "hunter2" \
  "$(cd "$T" && SOPS_AGE_KEY_FILE="$T/new.txt" sops decrypt --extract '["api_key"]' "$R/secrets/mine.yaml")"

# sync: dropping the old host key from the rule removes it from the file
sed -i "s|age: \[\*host, \*new, \*editor\]|age: [*new, *editor]|" "$R/.sops.yaml"
run sync /nonexistent
assert_has "sync drop: re-keys" "done  secrets/mine.yaml" "$out"
assert_eq "sync drop: old key locked out" "" \
  "$(cd "$T" && SOPS_AGE_KEY_FILE="$T/host.txt" sops decrypt --extract '["api_key"]' "$R/secrets/mine.yaml" 2>/dev/null)"
assert_eq "sync drop: new key still opens it" "hunter2" \
  "$(cd "$T" && SOPS_AGE_KEY_FILE="$T/new.txt" sops decrypt --extract '["api_key"]' "$R/secrets/mine.yaml")"

run sync /nonexistent
assert_has "sync again: nothing to do" "every file already matches .sops.yaml" "$out"

# a wrong editor key must not pass, even with keys.txt able to open everything
age-keygen -o "$T/editor.txt.bad" 2>/dev/null
cp "$T/editor.txt" "$T/editor.txt.good"
cp "$T/editor.txt.bad" "$T/editor.txt"
run verify "$T/host.txt"
assert_eq "wrong editor key: exit 1" 1 "$rc"
assert_has "wrong editor key: says so" "is not the &editor key" "$out"
cp "$T/editor.txt.good" "$T/editor.txt"

# editor key in the anchor but dropped as a file recipient: verify must not fall back to keys.txt
sed -i '/recipient: '"$EDITOR_PUB"'/,/-----END AGE ENCRYPTED FILE-----/d' "$R/secrets/mine.yaml"
run verify "$T/host.txt"
assert_eq "editor dropped from a file: exit 1" 1 "$rc"

exit "$fail"
