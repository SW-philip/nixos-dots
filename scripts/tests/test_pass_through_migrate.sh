#!/usr/bin/env bash
# Fixture tests for scripts/pass-through-migrate.sh (sudo and the NFS mount are stubbed out).
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pass-through-migrate.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}
run() { PT_HOME="$T/home" PT_ROOT="$T/root" PT_SUDO="" PT_REQUIRE_MOUNT="" PT_SKIP_MOUNT=1 PT_DATE=20261007 PT_SELF=$1 bash "$SCRIPT" >/dev/null 2>&1; }

# desktop: real dirs move onto the shared root, the old dir is kept as .migrated-<date>
mkdir -p "$T/home/Pictures/sub" "$T/home/Downloads" "$T/root"
echo a > "$T/home/Pictures/sub/a.jpg"; echo b > "$T/home/Downloads/b.zip"
run desktop; assert_eq "desktop: exit 0" 0 $?
assert_eq "desktop: link left to home-manager" absent "$([[ -e $T/home/Pictures || -L $T/home/Pictures ]] && echo present || echo absent)"
assert_eq "desktop: file moved"        a "$(cat "$T/root/Pictures/sub/a.jpg")"
assert_eq "desktop: old dir kept"      a "$(cat "$T/home/Pictures.migrated-20261007/sub/a.jpg")"
assert_eq "desktop: downloads moved"   b "$(cat "$T/root/Downloads/b.zip")"

run desktop; assert_eq "desktop: second run is a no-op" 0 $?
assert_eq "desktop: still one migrated dir" 1 "$(find "$T/home" -maxdepth 1 -name 'Pictures.migrated-*' | wc -l)"

# surface: merge into the (already populated) shared copy, keep both on a name clash
rm -rf "${T:?}/home" "${T:?}/root"; mkdir -p "$T/home/Pictures" "$T/home/Downloads" "$T/root/Pictures" "$T/root/Downloads"
echo desk > "$T/root/Pictures/clash.jpg"; echo surf > "$T/home/Pictures/clash.jpg"; echo only > "$T/home/Pictures/only.jpg"
mkdir "$T/home/Pictures/emptydir"
run surface; assert_eq "surface: exit 0" 0 $?
assert_eq "surface: desktop copy wins the name" desk "$(cat "$T/root/Pictures/clash.jpg")"
assert_eq "surface: clash preserved"            surf "$(cat "$T/root/Pictures/clash.jpg.from-surface")"
assert_eq "surface: unique file merged"         only "$(cat "$T/root/Pictures/only.jpg")"
assert_eq "surface: link left to home-manager" absent "$([[ -e $T/home/Pictures || -L $T/home/Pictures ]] && echo present || echo absent)"
assert_eq "surface: old dir kept"               surf "$(cat "$T/home/Pictures.migrated-20261007/clash.jpg")"
assert_eq "surface: empty dir merged"           dir "$([[ -d $T/root/Pictures/emptydir ]] && echo dir || echo none)"
assert_eq "surface: no temp leftovers"          0 "$(find "$T/root" -name '*.pt-tmp.*' | wc -l)"

# a symlink that points somewhere else is never touched
rm -rf "${T:?}/home"; mkdir -p "$T/home" "$T/elsewhere"; ln -s "$T/elsewhere" "$T/home/Pictures"; mkdir "$T/home/Downloads"
run desktop; assert_eq "foreign symlink: refused" 1 $?
assert_eq "foreign symlink: untouched" "$T/elsewhere" "$(readlink "$T/home/Pictures")"

# already linked to the target: no-op
rm -rf "${T:?}/home" "${T:?}/root"; mkdir -p "$T/home" "$T/root/Pictures" "$T/root/Downloads"
ln -s "$T/root/Pictures" "$T/home/Pictures"; ln -s "$T/root/Downloads" "$T/home/Downloads"
run desktop; assert_eq "already linked: exit 0" 0 $?

# a foreign symlink on the second name must stop the run before the first is touched
rm -rf "${T:?}/home" "${T:?}/root"; mkdir -p "$T/home/Pictures" "$T/root"; ln -s "$T/elsewhere" "$T/home/Downloads"
echo p > "$T/home/Pictures/p.jpg"
run desktop; assert_eq "prevalidate: refused" 1 $?
assert_eq "prevalidate: first dir untouched" p "$(cat "$T/home/Pictures/p.jpg")"

# the 3 TB drive not mounted: refuse and change nothing
rm -rf "${T:?}/home" "${T:?}/root"; mkdir -p "$T/home/Pictures" "$T/home/Downloads"
PT_HOME="$T/home" PT_ROOT="$T/root" PT_SUDO="" PT_DATE=20261007 PT_SELF=desktop PT_REQUIRE_MOUNT=/definitely/not/a/mount bash "$SCRIPT" >/dev/null 2>&1
assert_eq "unmounted: refused" 1 $?
assert_eq "unmounted: nothing created" 0 "$(find "$T/root" "$T/home" -name '*migrated*' 2>/dev/null | wc -l)"
assert_eq "unmounted: root not created" absent "$([[ -e $T/root ]] && echo present || echo absent)"

exit $fail
