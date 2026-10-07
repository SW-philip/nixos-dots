#!/usr/bin/env bash
# Fixture tests for scripts/hide-apps.sh in temp dirs.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hide-apps.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}
MARK='# hide-apps: generated, do not edit'

export HIDE_APPS_OUT="$T/out" HIDE_APPS_SEARCH="$T/sys1/share:$T/sys2/share"
mkdir -p "$T/out" "$T/sys1/share/applications" "$T/sys2/share/applications"

cat > "$T/sys1/share/applications/mpv.desktop" <<'EOF'
[Desktop Entry]
Name=mpv Media Player
Exec=/nix/store/abc-mpv/bin/mpv --player-operation-mode=pseudo-gui -- %U
MimeType=video/mp4;audio/mpeg;
NoDisplay=false
Type=Application

[Desktop Action Foo]
Name=Foo
Exec=mpv --foo
EOF
cat > "$T/sys2/share/applications/mpv.desktop" <<'EOF'
[Desktop Entry]
Name=second
Exec=/nix/store/other/bin/mpv
EOF
cat > "$T/sys1/share/applications/Stardew Valley.desktop" <<'EOF'
[Desktop Entry]
Name=Stardew Valley
Exec=steam steam://rungameid/413150
EOF
cat > "$T/sys1/share/applications/mine.desktop" <<'EOF'
[Desktop Entry]
Name=system mine
Exec=system-mine
EOF

OUT_MPV="$T/out/mpv.desktop"

bash "$SCRIPT" mpv; assert_eq "exit status" 0 $?
assert_eq "marker is the first line" "$MARK" "$(head -n1 "$OUT_MPV")"
assert_eq "NoDisplay=true exactly once" 1 "$(grep -c '^NoDisplay=true$' "$OUT_MPV")"
assert_eq "old NoDisplay=false gone" 0 "$(grep -c '^NoDisplay=false' "$OUT_MPV")"
grep -q '^Exec=/nix/store/abc-mpv/bin/mpv --player-operation-mode=pseudo-gui -- %U$' "$OUT_MPV"; assert_eq "real Exec kept (earlier search dir wins)" 0 $?
grep -q '^MimeType=video/mp4;audio/mpeg;$' "$OUT_MPV"; assert_eq "MimeType kept" 0 $?
grep -q '^Exec=mpv --foo$' "$OUT_MPV"; assert_eq "action group kept" 0 $?
awk '/^NoDisplay=true/{a=NR} /^\[Desktop Action/{b=NR} END{exit !(a<b)}' "$OUT_MPV"; assert_eq "NoDisplay is in the main group" 0 $?

sum1=$(md5sum "$OUT_MPV" | cut -d' ' -f1)
bash "$SCRIPT" mpv
assert_eq "idempotent" "$sum1" "$(md5sum "$OUT_MPV" | cut -d' ' -f1)"

bash "$SCRIPT" nonesuch; assert_eq "unknown id is not an error" 0 $?
[[ ! -e "$T/out/nonesuch.desktop" ]]; assert_eq "unknown id writes nothing" 0 $?

bash "$SCRIPT" "Stardew Valley" mpv
[[ -f "$T/out/Stardew Valley.desktop" ]]; assert_eq "id with a space" 0 $?

# a user's own file (no marker) is never overwritten or removed
printf '[Desktop Entry]\nName=mine\nExec=mine\n' > "$T/out/mine.desktop"
printf '[Desktop Entry]\nName=steam shortcut\nExec=steam x\n' > "$T/out/Incredibox.desktop"
bash "$SCRIPT" mine mpv
assert_eq "user file not overwritten" "Exec=mine" "$(grep '^Exec=' "$T/out/mine.desktop")"
[[ -f "$T/out/Incredibox.desktop" ]]; assert_eq "unlisted user file left alone" 0 $?

# removing an id from the list un-hides it, only for files we wrote
bash "$SCRIPT" mpv
[[ ! -e "$T/out/Stardew Valley.desktop" ]]; assert_eq "unlisted generated file removed" 0 $?
[[ -e "$OUT_MPV" ]]; assert_eq "still-listed file kept" 0 $?
bash "$SCRIPT"
[[ ! -e "$OUT_MPV" ]]; assert_eq "empty list removes all generated files" 0 $?
[[ -f "$T/out/mine.desktop" && -f "$T/out/Incredibox.desktop" ]]; assert_eq "user files survive the cleanup" 0 $?

exit "$fail"
