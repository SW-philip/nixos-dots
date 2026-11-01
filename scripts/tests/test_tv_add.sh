#!/usr/bin/env bash
# Fixture tests for scripts/tv-add.sh: temp list dir and media root, a fake
# yt-dlp that logs each download it's asked for. Nothing hits the network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT=$ROOT/scripts/tv-add.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}
assert_has() { # name haystack needle
  if [[ "$2" != *"$3"* ]]; then echo "FAIL: $1 — missing '$3' in: $2"; fail=1; else echo "PASS: $1"; fi
}

mkdir -p "$T/bin" "$T/lists" "$T/media" "$T/src"
# title lookups print a title; real fetches (--download-archive) log the URL
cat > "$T/bin/yt-dlp" <<EOF
#!/usr/bin/env bash
[[ " \$* " == *" --flat-playlist "* ]] && { echo "Some Title"; exit 0; }
echo "\${@: -1}" >> "$T/fetched"
EOF
chmod +x "$T/bin/yt-dlp"
echo 'query = folder "crafts";' > "$T/module.nix"
export PATH="$T/bin:$PATH" LIST_DIR="$T/lists" DEST_ROOT="$T/media" MODULE="$T/module.nix"

run() { "$SCRIPT" "$@" 2>&1; }
fetched() { cat "$T/fetched" 2>/dev/null; rm -f "$T/fetched"; }

# ---- URLs -----------------------------------------------------------------
out=$(run channels/crafts 'https://youtu.be/AAA?si=one')
assert_has "new list created" "$out" "new list: $T/lists/crafts.txt"
assert_eq "si= stripped when listed" "https://youtu.be/AAA  # Some Title" "$(tail -1 "$T/lists/crafts.txt")"
assert_eq "new URL fetched" "https://youtu.be/AAA" "$(fetched)"

out=$(run channels/crafts 'https://youtu.be/AAA?si=two')
assert_has "same video, other si= is a dupe" "$out" "already listed: https://youtu.be/AAA"
assert_eq "dupe not fetched" "" "$(fetched)"

printf '%s\n' 'https://www.youtube.com/playlist?list=PL1&si=old  # Old' >> "$T/lists/crafts.txt"
out=$(run channels/crafts 'https://www.youtube.com/playlist?list=PL1&si=new' 'https://youtu.be/BBB')
assert_has "si= on an existing line is ignored too" "$out" "already listed: https://www.youtube.com/playlist?list=PL1"
assert_eq "only the new URL is fetched, not the whole list" "https://youtu.be/BBB" "$(fetched)"

out=$(run channels/crafts 'https://youtu.be/CCC' 'https://youtu.be/CCC?si=x')
assert_eq "dupe within one call listed once" 1 "$(grep -c CCC "$T/lists/crafts.txt")"

# ---- list naming ----------------------------------------------------------
printf '# dest: channels/halloween\n' > "$T/lists/halloween.txt"
out=$(run commercials/halloween 'https://youtu.be/DDD')
assert_has "taken name falls back to the full path" "$out" "new list: $T/lists/commercials-halloween.txt"

# ---- files ----------------------------------------------------------------
echo a > "$T/src/a.mkv"; echo b > "$T/src/b.mkv"
out=$(run channels/crafts "$T/src/a.mkv")
assert_has "file copied" "$out" "copied: a.mkv"
echo changed > "$T/src/a.mkv"
out=$(run channels/crafts "$T/src")
assert_has "existing file skipped" "$out" "already there: a.mkv"
assert_has "new file in the folder copied" "$out" "copied: b.mkv"
assert_eq "skipped file left alone" a "$(cat "$T/media/channels/crafts/a.mkv")"

# ---- air note -------------------------------------------------------------
out=$(run channels/crafts "$T/src/b.mkv")
assert_eq "no note for a queried tag" "" "$(grep note: <<<"$out")"
out=$(NOTE_TAG=spots-halloween run commercials/halloween "$T/src/b.mkv")
assert_has "NOTE_TAG picks the tag checked" "$out" "queries \"spots-halloween\""

exit "$fail"
