#!/usr/bin/env bash
# Tests for scripts/commands.sh, plus a drift check that every registered
# command in assets/commands.json is still defined somewhere in the flake.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CMD="$ROOT/scripts/commands.sh"
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

cat > "$T/reg.json" <<'JSON'
[
  {"group": "Zed", "name": "zz", "desc": "last alphabetically, first in file"},
  {"group": "Alpha", "name": "aa", "host": "desktop", "desc": "Hello there"},
  {"group": "Zed", "name": "zy", "desc": "second zed"}
]
JSON
export COMMANDS_JSON="$T/reg.json"

out=$(bash "$CMD")
assert_eq "groups keep registry order" "Zed" "$(grep -E '^[A-Za-z]' <<<"$out" | head -1)"
assert_has "host shown" "Hello there [desktop]" "$out"
assert_eq "entries stay under their group" "Zed
  zz                         last alphabetically, first in file
  zy                         second zed

Alpha
  aa                         Hello there [desktop]" "$out"

out=$(bash "$CMD" hello)
assert_has "filter matches desc, case-insensitive" "aa" "$out"
assert_lacks "filter drops others" "zz" "$out"
out=$(bash "$CMD" zed)
assert_has "filter matches group" "zy" "$out"

bash "$CMD" nothing-matches 2>/dev/null; rc=$?
assert_eq "no match: exit 1" 1 "$rc"
bash "$CMD" --bogus 2>/dev/null; rc=$?
assert_eq "bad flag: exit 2" 2 "$rc"
assert_eq "--json passes the registry through" "$(cat "$T/reg.json")" "$(bash "$CMD" --json)"

# drift: the real registry
REAL="$ROOT/assets/commands.json"
jq -e 'type == "array" and length > 0 and all(.[]; .group and .name and .desc)' "$REAL" >/dev/null
assert_eq "registry: every entry has group, name, desc" 0 $?
dups=$(jq -r '[.[].name] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$REAL")
assert_eq "registry: no duplicate names" "" "$dups"

missing=
while IFS= read -r name; do
  if [[ "$name" == scripts/* ]]; then
    [[ -f "$ROOT/$name" ]] || missing+=" $name"
  else
    # a package/alias/script name: quoted in some .nix file, an alias key, or scripts/<name>.{sh,py}
    grep -rqE --include='*.nix' "\"$name\"|^[[:space:]]+$name = " "$ROOT/home" "$ROOT/profiles" "$ROOT/modules" "$ROOT/hosts" "$ROOT/roles" "$ROOT/pkgs" \
      || [[ -f "$ROOT/scripts/$name.sh" || -f "$ROOT/scripts/$name.py" ]] \
      || missing+=" $name"
  fi
done < <(jq -r '.[].name' "$REAL")
assert_eq "registry: every command is still defined in the flake" "" "$missing"

exit "$fail"
