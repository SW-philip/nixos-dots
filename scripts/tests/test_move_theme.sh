#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script=$here/../move-theme.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
t=$tmp/themes
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$t/Dark/x"
echo p >"$t/Dark/x/palette-x.nix"; echo w >"$t/Dark/x/wallpaper-x.png"
THEMES_ROOT=$t "$script" x Light >/dev/null
[[ -f $t/Light/x/palette-x.nix && -f $t/Light/x/wallpaper-x.png ]] || fail "x not moved with its png"
[[ ! -e $t/Dark/x ]]                                               || fail "old dir left behind"
THEMES_ROOT=$t "$script" x Light >/dev/null                        || fail "not idempotent"

# a host that already pulled the move: git created Light/y with the tracked file,
# the ignored PNG is still under Dark/y
mkdir -p "$t/Dark/y" "$t/Light/y"
echo stale >"$t/Dark/y/palette-y.nix"; echo w >"$t/Dark/y/wallpaper-y.png"
echo tracked >"$t/Light/y/palette-y.nix"
THEMES_ROOT=$t "$script" y Light >/dev/null
[[ -f $t/Light/y/wallpaper-y.png ]]                                || fail "leftover png not merged"
[[ $(cat "$t/Light/y/palette-y.nix") == tracked ]]                 || fail "existing file overwritten"
echo "ok"
