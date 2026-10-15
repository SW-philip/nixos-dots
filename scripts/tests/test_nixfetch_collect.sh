#!/usr/bin/env bash
# Fixture tests for scripts/nixfetch-collect.sh with a fake ssh.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/nixfetch-collect.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shim" "$T/remote" "$T/cache"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

cat > "$T/shim/ssh" <<'SHIM'
#!/usr/bin/env bash
# fake `ssh <opts> host cat <path>`: answer from $FAKE/remote/<host>.json or fail like a dead link
while [[ "$1" == -* ]]; do if [[ "$1" == -n ]]; then shift; else shift 2; fi; done
echo "$1" >> "$FAKE/ssh.log"
[[ -f "$FAKE/remote/$1.json" ]] || exit 255
cat "$FAKE/remote/$1.json"
SHIM
chmod +x "$T/shim/ssh"

echo '{"host":"SWsurface","generation":7,"generated_at":1}' > "$T/remote/surface.json"
echo '{"host":"SWpi","generation":3,"generated_at":1}'      > "$T/remote/pi.json"
echo 'not json'                                             > "$T/remote/retro.json"
echo '{"host":"SWphil","generation":9,"generated_at":1}'    > "$T/self.json"
echo '{"host":"SWretro","generation":1,"generated_at":1}'   > "$T/cache/retro.json"   # previous good copy

rm -f "$T/ssh.log"
FAKE="$T" PATH="$T/shim:$PATH" NIXFETCH_CACHE="$T/cache" NIXFETCH_SELF=SWphil \
  NIXFETCH_SRC="$T/self.json" NIXFETCH_HOSTS="desktop surface retro pi" "$SCRIPT"

assert_eq "self host read locally"          "9" "$(jq -r .generation "$T/cache/desktop.json")"
assert_eq "remote host fetched"             "7" "$(jq -r .generation "$T/cache/surface.json")"
assert_eq "pi fetched"                      "3" "$(jq -r .generation "$T/cache/pi.json")"
assert_eq "invalid json keeps previous copy" "1" "$(jq -r .generation "$T/cache/retro.json")"
assert_eq "self never ssh'd" "0" "$(grep -c '^desktop$' "$T/ssh.log")"

# an unreachable host (no remote file) must not delete or blank the old cache, and the run still exits 0
rm "$T/remote/pi.json"
FAKE="$T" PATH="$T/shim:$PATH" NIXFETCH_CACHE="$T/cache" NIXFETCH_SELF=SWphil \
  NIXFETCH_SRC="$T/self.json" NIXFETCH_HOSTS="desktop pi" "$SCRIPT"
assert_eq "exit 0 with a dead host" "0" "$?"
assert_eq "dead host keeps old cache" "3" "$(jq -r .generation "$T/cache/pi.json")"

exit $fail
