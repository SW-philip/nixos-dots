#!/usr/bin/env bash
# Fixture tests for scripts/ff-fleet.sh (colours are replaced by readable tags).
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ff-fleet.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
NOW=2000000000
export FF_FLEET_FILE="$T/snap.json" FF_NOW=$NOW FF_OK='<ok>' FF_WARN='<warn>' FF_BAD='<bad>' FF_DIM='<dim>' FF_RS='</>'

fail=0
assert_eq() { if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi; }
row() { "$SCRIPT" "$1"; }

cat > "$FF_FLEET_FILE" <<JSON
{"generated_at": $NOW, "head": "aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee", "head_ref": "wip", "hosts": [
 {"host":"inst","up":true,"ssh_ok":true,"rev":"1234567890abcdef","dirty":false,"built_at":1,"built_age_s":720,"drift":0,"ahead":0},
 {"host":"behind","up":true,"ssh_ok":true,"rev":"1234567890abcdef","dirty":false,"built_at":1,"built_age_s":7200,"drift":3,"ahead":0},
 {"host":"ahead","up":true,"ssh_ok":true,"rev":"1234567890abcdef","dirty":false,"built_at":1,"built_age_s":30,"drift":0,"ahead":2},
 {"host":"div","up":true,"ssh_ok":true,"rev":"1234567890abcdef","dirty":false,"built_at":1,"built_age_s":200000,"drift":1,"ahead":1},
 {"host":"dirty","up":true,"ssh_ok":true,"rev":"1234567890abcdef-dirty","dirty":true,"built_at":1,"built_age_s":720,"drift":0,"ahead":0},
 {"host":"noahead","up":true,"ssh_ok":true,"rev":"1234567890abcdef","dirty":false,"built_at":1,"built_age_s":720,"drift":2},
 {"host":"unstamped","up":true,"ssh_ok":true,"rev":null,"dirty":false,"built_at":1,"built_age_s":100000,"drift":null,"ahead":null},
 {"host":"unknown","up":true,"ssh_ok":true,"rev":"1234567890abcdef","dirty":false,"built_at":1,"built_age_s":720,"drift":null,"ahead":null},
 {"host":"nossh","up":true,"ssh_ok":false,"rev":null,"dirty":false,"built_at":null,"built_age_s":null,"drift":null,"ahead":null},
 {"host":"down","up":false,"ssh_ok":false,"rev":null,"dirty":false,"built_at":null,"built_age_s":null,"drift":null,"ahead":null}
]}
JSON

assert_eq "in step"            "<ok>●</> 12345678 <ok>in step</> · 12m"                         "$(row inst)"
assert_eq "behind"             "<warn>●</> 12345678 <warn>3 behind</> · 2h"                      "$(row behind)"
assert_eq "drift set, ahead absent" "<warn>●</> 12345678 <warn>2 behind</> · 12m"                 "$(row noahead)"
assert_eq "ahead"              "<warn>●</> 12345678 <warn>2 ahead</> · 30s"                      "$(row ahead)"
assert_eq "diverged is bad"    "<bad>●</> 12345678 <bad>diverged</> · 2d"                        "$(row div)"
assert_eq "dirty"              "<warn>●</> 12345678 <warn>dirty</> · 12m"                        "$(row dirty)"
assert_eq "unstamped"          "<warn>●</> <warn>unstamped</> · 28h"                             "$(row unstamped)"
assert_eq "unknown commit"     "<warn>●</> 12345678 <warn>unknown commit</> · 12m"               "$(row unknown)"
assert_eq "ssh not answering"  "<warn>●</> <warn>up, ssh not answering</>"                       "$(row nossh)"
assert_eq "down"               "<bad>●</> <bad>down</>"                                          "$(row down)"
assert_eq "host not in file"   "<dim>not in snapshot</>"                                         "$(row ghost)"

echo "== stale snapshot =="
sed -i "s/\"generated_at\": $NOW/\"generated_at\": $((NOW - 900))/" "$FF_FLEET_FILE"
assert_eq "stale annotation (15m)" "<ok>●</> 12345678 <ok>in step</> · 12m <dim>(snapshot 15m old)</>" "$(row inst)"
assert_eq "stale down row"         "<bad>●</> <bad>down</> <dim>(snapshot 15m old)</>"              "$(row down)"

echo "== no snapshot =="
rm "$FF_FLEET_FILE"
assert_eq "missing file" "<dim>no snapshot yet</>" "$(row inst)"

echo "== unreadable snapshot =="
: > "$FF_FLEET_FILE"
assert_eq "empty file" "<dim>unreadable snapshot</>" "$(row inst)"
echo '{"x":1}' > "$FF_FLEET_FILE"
assert_eq "no hosts key" "<dim>unreadable snapshot</>" "$(row inst)"

echo "== plain output without colour env =="
unset FF_OK FF_WARN FF_BAD FF_DIM FF_RS
cat > "$FF_FLEET_FILE" <<JSON
{"generated_at": $NOW, "hosts": [{"host":"inst","up":true,"ssh_ok":true,"rev":"1234567890abcdef","dirty":false,"built_age_s":5,"drift":0,"ahead":0}]}
JSON
assert_eq "no colour env still works" "● 12345678 in step · 5s" "$(row inst)"

exit "$fail"
