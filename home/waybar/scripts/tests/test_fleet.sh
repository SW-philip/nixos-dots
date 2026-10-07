#!/usr/bin/env bash
# Fixture tests for fleet.sh, plus parity of per-host state with scripts/ff-fleet.sh.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLEET="$DIR/fleet.sh"
FFFLEET="$(cd "$DIR/../../.." && pwd)/scripts/ff-fleet.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

NOW=2000000000
fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

cat > "$T/palette.sh" <<'EOF'
FIFTH=OKCOL; FERMATA=WARNCOL; FORTE=BADCOL; REST=DIMCOL; ROOT=ROOTCOL
EOF
cat > "$T/snark.json" <<'EOF'
{"fleet":{"ok":["snark-ok"],"behind":["snark-behind"],"down":["snark-down"],"stale":["snark-stale"],"diverged":["snark-diverged"]}}
EOF

# host_json <host> <up> <ssh_ok> <rev|null> <dirty> <drift|null> <ahead|null> <built_age|null>
host_json() {
  jq -nc --arg host "$1" --argjson up "$2" --argjson ssh "$3" --argjson rev "$4" --argjson dirty "$5" \
    --argjson drift "$6" --argjson ahead "$7" --argjson age "$8" \
    '{host:$host,up:$up,ssh_ok:$ssh,rev:$rev,dirty:$dirty,built_at:null,built_age_s:$age,drift:$drift,ahead:$ahead}'
}
REV='"387ed4b3db54ae73070d24ff52c6203b013aaeec"'
okhost() { host_json "$1" true true "$REV" false 0 0 120; }

# snap <generated_at> <host-json>...  -> $T/snap.json
snap() {
  local gen=$1; shift
  printf '%s\n' "$@" | jq -s --argjson g "$gen" '{generated_at:$g, hosts:.}' > "$T/snap.json"
}
run() {   # prints fleet.sh output for $T/snap.json
  FLEET_FILE="$T/snap.json" FLEET_NOW=$NOW FLEET_PALETTE="$T/palette.sh" SNARK_FILE="$T/snark.json" "$FLEET" "$@" 2>"$T/stderr"
}
field() { run | jq -r ".$1"; }
plain() { sed 's/<[^>]*>//g'; }

echo "== all in step =="
snap "$NOW" "$(okhost desktop)" "$(okhost surface)" "$(okhost retro)" "$(okhost pi)"
assert_eq "class ok" "ok" "$(field class)"
assert_eq "idle text keeps the count slot" "󰒋 0" "$(field text | plain)"
assert_eq "idle count slot is invisible" "1" "$(field text | grep -c 'alpha="1%">0<')"
assert_eq "tooltip has all four hosts" "4" "$(field tooltip | plain | grep -c -E '^● (desktop|surface|retro|pi) ')"
assert_eq "ok snark" "1" "$(field tooltip | grep -c snark-ok)"
assert_eq "no stderr" "" "$(cat "$T/stderr")"

echo "== one behind =="
snap "$NOW" "$(okhost desktop)" "$(host_json surface true true "$REV" false 3 0 300)" "$(okhost retro)" "$(okhost pi)"
assert_eq "class warn" "warn" "$(field class)"
assert_eq "count 1" "󰒋 1" "$(field text | plain)"
assert_eq "visible count has no alpha span" "0" "$(field text | grep -c 'alpha=')"
assert_eq "label says 3 behind" "1" "$(field tooltip | plain | grep -c 'surface .*3 behind')"
assert_eq "behind snark" "1" "$(field tooltip | grep -c snark-behind)"

echo "== down beats behind =="
snap "$NOW" "$(host_json desktop true true "$REV" false 2 0 60)" "$(okhost surface)" "$(host_json retro false false null false null null null)" "$(okhost pi)"
assert_eq "class bad" "bad" "$(field class)"
assert_eq "count 2" "󰒋 2" "$(field text | plain)"
assert_eq "down snark" "1" "$(field tooltip | grep -c snark-down)"

echo "== diverged =="
snap "$NOW" "$(okhost desktop)" "$(okhost surface)" "$(okhost retro)" "$(host_json pi true true "$REV" false 1 1 60)"
assert_eq "class bad" "bad" "$(field class)"
assert_eq "diverged snark" "1" "$(field tooltip | grep -c snark-diverged)"

echo "== stale snapshot =="
snap $((NOW - 1000)) "$(okhost desktop)" "$(okhost surface)" "$(okhost retro)" "$(okhost pi)"
assert_eq "class stale" "stale" "$(field class)"
assert_eq "stale snark" "1" "$(field tooltip | grep -c snark-stale)"
assert_eq "tooltip shows the age" "1" "$(field tooltip | plain | grep -c 'snapshot 17m old')"

echo "== missing and malformed =="
rm -f "$T/snap.json"
assert_eq "missing: class" "nosnap" "$(field class)"
assert_eq "missing: keeps the count slot" "󰒋 0" "$(field text | plain)"
assert_eq "missing: tooltip" "no snapshot yet" "$(field tooltip | plain)"
assert_eq "missing: stderr empty" "" "$(cat "$T/stderr")"
echo 'not json' > "$T/snap.json"
assert_eq "malformed: class" "nosnap" "$(field class)"
assert_eq "malformed: tooltip" "unreadable snapshot" "$(field tooltip | plain)"
echo '{"generated_at":1}' > "$T/snap.json"
assert_eq "no hosts key: class" "nosnap" "$(field class)"

echo "== parity with ff-fleet.sh =="
snap "$NOW" \
  "$(okhost h-ok)" \
  "$(host_json h-behind true true "$REV" false 3 0 60)" \
  "$(host_json h-ahead true true "$REV" false 0 2 60)" \
  "$(host_json h-diverged true true "$REV" false 1 1 60)" \
  "$(host_json h-dirty true true "$REV" true 0 0 60)" \
  "$(host_json h-dirty-behind true true "$REV" true 2 0 60)" \
  "$(host_json h-down false false null false null null null)" \
  "$(host_json h-nossh true false null false null null null)" \
  "$(host_json h-unstamped true true null false null null 60)" \
  "$(host_json h-unknown true true "$REV" false null null 60)"
mapfile -t states < <(run --states)
assert_eq "ten states printed" "10" "${#states[@]}"
for line in "${states[@]}"; do
  host=${line%%$'\t'*}; cls=${line##*$'\t'}
  out=$(FF_FLEET_FILE="$T/snap.json" FF_NOW=$NOW FF_OK=O FF_WARN=W FF_BAD=B FF_DIM=D FF_RS='' "$FFFLEET" "$host")
  case ${out:0:1} in O) want=ok ;; W) want=warn ;; B) want=bad ;; *) want="?" ;; esac
  assert_eq "parity: $host" "$want" "$cls"
done

if (( fail == 0 )); then echo "All tests passed."; else echo "Some tests failed."; fi
exit $fail
