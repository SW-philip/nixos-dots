#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script=$here/../migrate-theme-families.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
t=$tmp/themes
mkdir -p "$t/Custom/a" "$t/Custom/c" "$t/Rose-Pine/b" "$t/Dark/c"
echo p >"$t/Custom/a/palette-a.nix"; echo w >"$t/Custom/a/wallpaper-a.png"
echo p >"$t/Rose-Pine/b/palette-b.nix"
# c: git already created Dark/c with the tracked file; only the ignored PNG is left behind
echo tracked >"$t/Dark/c/palette-c.nix"; echo w >"$t/Custom/c/wallpaper-c.png"
echo stale >"$t/Custom/c/palette-c.nix"

THEMES_ROOT=$t "$script" >/dev/null

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f $t/Dark/a/palette-a.nix && -f $t/Dark/a/wallpaper-a.png ]] || fail "a not moved with its png"
[[ -f $t/Dark/b/palette-b.nix ]]                                 || fail "rose-pine theme not moved"
[[ -f $t/Dark/c/wallpaper-c.png ]]                               || fail "leftover png not merged"
[[ $(cat "$t/Dark/c/palette-c.nix") == tracked ]]                || fail "existing file was overwritten"
[[ ! -e $t/Custom/a && ! -e $t/Rose-Pine/b ]]                    || fail "old dirs left behind"
THEMES_ROOT=$t "$script" >/dev/null                              || fail "not idempotent"
echo "ok"
