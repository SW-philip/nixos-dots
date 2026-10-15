#!/usr/bin/env bash
# Fixture tests for scripts/nixfetch-sample.sh with a fake nix and fake generation links.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/nixfetch-sample.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

mkdir -p "$T/shim" "$T/gen-a" "$T/gen-b" "$T/profiles"
touch "$T/gen-a/kernel" "$T/gen-b/kernel"
ln -s "$T/gen-a" "$T/profiles/system-42-link"
ln -s system-42-link "$T/profiles/system"
touch -h -d @1999990000 "$T/profiles/system"
ln -s "$T/gen-a" "$T/booted"
ln -s "$T/gen-a" "$T/current"

cat > "$T/shim/nix" <<'SHIM'
#!/usr/bin/env bash
# fake `nix path-info -S <path>`; like retro/pi, refuses unless nix-command is enabled on the command line
if [[ "$*" != *"--extra-experimental-features nix-command"* ]]; then
  echo "error: experimental Nix feature 'nix-command' is disabled" >&2; exit 1
fi
printf '%s\t14500000000\n' "${!#}"
SHIM
cat > "$T/shim/nixos-version" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  --configuration-revision) echo "$FAKE_REV" ;;
  *) echo "26.05.20261001.abc" ;;
esac
SHIM
chmod +x "$T/shim/nix" "$T/shim/nixos-version"

cat > "$T/flake.lock" <<'JSON'
{"nodes":{"root":{"inputs":{"nixpkgs":"nixpkgs","home-manager":"hm_2"}},
 "nixpkgs":{"locked":{"lastModified":1790000000}},
 "hm_2":{"locked":{"lastModified":1791000000}}},"root":"root","version":7}
JSON

run() {
  rm -f "$T/out.json"
  PATH="$T/shim:$PATH" FAKE_REV="${FAKE_REV-abc123}" NIXFETCH_OUT="$T/out.json" NIXFETCH_LOCK="${NIXFETCH_LOCK-$T/flake.lock}" \
    NIXFETCH_PROFILE="$T/profiles/system" NIXFETCH_BOOTED="$T/booted" NIXFETCH_CURRENT="$T/current" \
    NIXFETCH_NOW=2000000000 NIXFETCH_HOST=SWtest NIXFETCH_NIXOS_VERSION="$T/shim/nixos-version" "$SCRIPT"
}
f() { jq -r "$1" "$T/out.json"; }

run
assert_eq "host"            "SWtest"     "$(f .host)"
assert_eq "generated_at"    "2000000000" "$(f .generated_at)"
assert_eq "rev"             "abc123"     "$(f .rev)"
assert_eq "version"         "26.05.20261001.abc" "$(f .version)"
assert_eq "generation"      "42"         "$(f .generation)"
assert_eq "built_at"        "1999990000" "$(f .built_at)"
assert_eq "booted_same"     "true"       "$(f .booted_same)"
assert_eq "kernel_same"     "true"       "$(f .kernel_same)"
assert_eq "closure_bytes"   "14500000000" "$(f .closure_bytes)"
assert_eq "input count"     "2"          "$(f '.inputs | length')"
assert_eq "input resolved through node alias" "1791000000" "$(f '.inputs[] | select(.name=="home-manager") | .last_modified')"

# a switch that changed the system and kernel: booted differs, kernel differs
ln -sfn "$T/gen-b" "$T/current"
run
assert_eq "booted_same false after switch" "false" "$(f .booted_same)"
assert_eq "kernel_same false"              "false" "$(f .kernel_same)"

# unstamped host and a missing lock still produce valid JSON
FAKE_REV="" NIXFETCH_LOCK="$T/none" run
assert_eq "empty rev becomes null" "null" "$(f .rev)"
assert_eq "missing lock gives empty inputs" "0" "$(f '.inputs | length')"

# file mode is world-readable so the collector can ssh-cat it as an ordinary user
assert_eq "mode" "644" "$(stat -c %a "$T/out.json")"

exit $fail
