#!/usr/bin/env bash
# Fixture tests for scripts/nixfetch.sh. Output is piped, so colour and the scroll delay are off.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/nixfetch.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export NIXFETCH_SRC="$T/no-local-sample"   # keep a real /var/lib/nixfetch out of the fixtures
unset NIXFETCH_SNARK NIXFETCH_SNARK_SEED NIXFETCH_COLS COLUMNS
git config --global user.name test; git config --global user.email t@t

fail=0
assert_has() {   # name, pattern — pattern is a fixed string
  if grep -qF -- "$2" <<<"$OUTPUT"; then echo "PASS: $1"; else echo "FAIL: $1 — no '$2' in:"; echo "$OUTPUT"; fail=1; fi
}
assert_lacks() {
  if grep -qF -- "$2" <<<"$OUTPUT"; then echo "FAIL: $1 — found '$2'"; fail=1; else echo "PASS: $1"; fi
}

NOW=2000000000
R="$T/repo"; git init -q -b main "$R"
mkdir -p "$R/hosts/desktop" "$R/hosts/pi" "$R/themes/Dark/a" "$R/themes/Dark/b" "$R/themes/Light/c"
cat > "$R/hosts/desktop/config.nix" <<'NIX'
{ imports = [ ./hardware.nix ../../roles/niri.nix ../../modules/sunshine.nix ../../identities/prepko.nix ]; }
NIX
echo '{}' > "$R/hosts/pi/config.nix"
GIT_COMMITTER_DATE="@$((NOW - 7200))" git -C "$R" add -A
GIT_COMMITTER_DATE="@$((NOW - 7200))" git -C "$R" commit -qm c1 --date="@$((NOW - 7200))"
git -C "$R" tag 2026.10.01

C="$T/cache"; mkdir -p "$C"
cat > "$C/desktop.json" <<JSON
{"host":"SWphil","generated_at":$((NOW - 600)),"rev":"acf82cfdf67cea00b248810ca13d148e904d2f0f",
 "version":"26.11.2026abc","generation":412,"built_at":$((NOW - 9600)),"booted_same":false,"kernel_same":false,
 "closure_bytes":14500000000,
 "inputs":[{"name":"nixpkgs","last_modified":$((NOW - 86400)) },{"name":"lix","last_modified":$((NOW - 864000))}]}
JSON
cat > "$C/pi.json" <<JSON
{"host":"SWpi","generated_at":$((NOW - 40000)),"rev":null,"version":"26.05.x","generation":null,"built_at":null,
 "booted_same":true,"kernel_same":true,"closure_bytes":null,"inputs":[]}
JSON
cat > "$T/fleet.json" <<'JSON'
{"generated_at":1,"hosts":[{"host":"desktop","drift":2,"ahead":0,"dirty":false},
                           {"host":"pi","drift":null,"ahead":null,"dirty":false}]}
JSON

run() {
  OUTPUT=$(NIXFETCH_ROOT="$R" NIXFETCH_CACHE="$C" NIXFETCH_FLEET_FILE="$T/fleet.json" NIXFETCH_PALETTE="$T/none" \
    NIXFETCH_NOW=$NOW NIXFETCH_SELF=SWphil NIXFETCH_HOSTS="desktop pi" "$SCRIPT" "$@" 2>&1)
}

run   # defaults to the current host, desktop
assert_has "header names host"        "SWphil"
assert_has "short rev"                "acf82cfd"
assert_has "drift note"               "2 behind"
assert_has "generation"               "#412"
assert_has "reboot pending"           "reboot pending"
assert_has "channel"                  "26.11.2026abc"
assert_has "closure human size"       "14G"
assert_has "imports summarised by group" "hosts 1 · roles 1 · modules 1 · identities 1"
assert_lacks "full import list is behind --imports" "roles/niri.nix"
assert_has "release tag"              "2026.10.01"
assert_has "oldest input"             "lix"
assert_has "theme count"              "3 themes"
assert_has "host count"               "2 hosts"
assert_lacks "fresh cache has no stale footer" "stale"

run pi
assert_has "other host by name"       "SWpi"
assert_has "unstamped rev is a dash"  "rev       —"
assert_has "stale footer"             "stale"
assert_has "no repo imports file still renders" "SWpi"

run --all
assert_has "all shows desktop"        "SWphil"
assert_has "all shows pi"             "SWpi"

OUTPUT=$(NIXFETCH_ROOT="$R" NIXFETCH_CACHE="$T/empty" NIXFETCH_FLEET_FILE="$T/none" NIXFETCH_PALETTE="$T/none" \
  NIXFETCH_NOW=$NOW NIXFETCH_SELF=SWphil NIXFETCH_HOSTS="desktop" "$SCRIPT" 2>&1)
rc=$?
assert_has "missing cache degrades with a message" "no data yet"
if [[ $rc == 0 ]]; then echo "PASS: missing cache exits 0"; else echo "FAIL: exit $rc"; fail=1; fi

# odd inputs must degrade, never abort
mkdir -p "$T/odd"
cat > "$T/odd/desktop.json" <<JSON
{"host":"SWphil","generated_at":"soon","rev":"acf82cfdf67cea00b248810ca13d148e904d2f0f","generation":412.0,
 "built_at":1.9999e9,"booted_same":true,"kernel_same":true,"closure_bytes":null,
 "inputs":[{"name":"nixpkgs","last_modified":1.99999e9},{"name":"lix","last_modified":"x"}]}
JSON
R2="$T/bare"; git init -q -b main "$R2"
odd() {   # cache dir, repo
  OUTPUT=$(NIXFETCH_ROOT="$2" NIXFETCH_CACHE="$1" NIXFETCH_FLEET_FILE="$T/fleet.json" NIXFETCH_PALETTE="$T/none" \
    NIXFETCH_NOW=$NOW NIXFETCH_SELF=SWphil NIXFETCH_HOSTS="desktop pi" "$SCRIPT" 2>&1); rc=$?
}
odd "$T/odd" "$R2"
assert_has "float/non-numeric values still render the tree row" "0 themes"
assert_has "float built_at renders generation" "#412"
assert_has "float last_modified still picks oldest input" "nixpkgs"
if [[ $rc == 0 ]]; then echo "PASS: odd values exit 0"; else echo "FAIL: odd values exit $rc"; fail=1; fi

mkdir -p "$T/huge"
cat > "$T/huge/desktop.json" <<JSON
{"host":"SWphil","generated_at":1e300,"rev":null,"generation":3,"built_at":1e19,"booted_same":true,"kernel_same":true,
 "closure_bytes":1e30,"inputs":[{"name":"nixpkgs","last_modified":1e19}]}
JSON
odd "$T/huge" "$R"
assert_has "huge values still render the tree row" "3 themes"
if [[ $rc == 0 ]]; then echo "PASS: huge values exit 0"; else echo "FAIL: huge values exit $rc"; fail=1; fi

mkdir -p "$T/arr"; echo '[1]' > "$T/arr/desktop.json"
odd "$T/arr" "$R"
assert_has "non-object cache is no data" "no data yet"
if [[ $rc == 0 ]]; then echo "PASS: non-object cache exits 0"; else echo "FAIL: non-object cache exit $rc"; fail=1; fi

# fleet rev beats the cache's rev; offline host says offline; local sample wins for self only
cat > "$T/fleet2.json" <<'JSON'
{"generated_at":1,"hosts":[{"host":"desktop","rev":"1111111122222222","drift":0,"ahead":0,"dirty":false,"ssh_ok":true},
                           {"host":"pi","rev":"3333333344444444","drift":null,"ahead":null,"dirty":false,"ssh_ok":false}]}
JSON
mkdir -p "$T/src"
cat > "$T/src/host.json" <<JSON
{"host":"SWphil","generated_at":$((NOW - 10)),"rev":"9999999900000000","version":"fresh-ver","generation":500,"built_at":$((NOW - 30)),
 "booted_same":true,"kernel_same":true,"closure_bytes":null,"inputs":[]}
JSON
run2() {
  OUTPUT=$(NIXFETCH_ROOT="$R" NIXFETCH_CACHE="$C" NIXFETCH_FLEET_FILE="$T/fleet2.json" NIXFETCH_PALETTE="$T/none" \
    NIXFETCH_NOW=$NOW NIXFETCH_SELF=SWphil NIXFETCH_HOSTS="desktop pi" NIXFETCH_SRC="$T/src/host.json" "$SCRIPT" "$@" 2>&1)
}
run2 pi
assert_has   "fleet rev shown over cache rev" "33333333"
assert_has   "offline host is marked offline" "offline"
assert_lacks "offline host is not unknown commit" "unknown commit"
assert_lacks "other host ignores local sample" "fresh-ver"
run2
assert_has   "self uses newer local sample" "fresh-ver"
assert_has   "fleet rev wins over local sample rev" "11111111"
assert_lacks "stale cache rev not shown" "acf82cfd"
OUTPUT=$(NIXFETCH_ROOT="$R" NIXFETCH_CACHE="$C" NIXFETCH_FLEET_FILE="$T/none" NIXFETCH_PALETTE="$T/none" \
  NIXFETCH_NOW=$NOW NIXFETCH_SELF=SWphil NIXFETCH_HOSTS="desktop pi" NIXFETCH_SRC="$T/none" "$SCRIPT" 2>&1)
assert_has   "no local sample falls back to cache" "26.11.2026abc"

OUTPUT=$(NIXFETCH_HOSTS="desktop pi" NIXFETCH_SELF=SWphil "$SCRIPT" nonesuch 2>&1); rc=$?
if [[ $rc == 2 ]]; then echo "PASS: unknown host exits 2"; else echo "FAIL: unknown host exit $rc"; fail=1; fi

# --- task 4: borders, glyphs, imports, snark, gradient ---
xrun() {   # fleet file, then VAR=val... -- args
  local fl=$1; shift; local envs=()
  while [[ $# -gt 0 && $1 != -- ]]; do envs+=("$1"); shift; done; shift
  OUTPUT=$(env NIXFETCH_ROOT="$R" NIXFETCH_CACHE="$C" NIXFETCH_FLEET_FILE="$fl" NIXFETCH_PALETTE="$T/none" \
    NIXFETCH_NOW=$NOW NIXFETCH_SELF=SWphil NIXFETCH_HOSTS="desktop pi" "${envs[@]}" "$SCRIPT" "$@" 2>&1); rc=$?
}
width_of() { grep -m1 "$1" <<<"$OUTPUT" | awk '{ print length($0) }'; }

xrun "$T/fleet2.json" NIXFETCH_COLS=40 --
assert_has   "box top STATE"    "╭─ STATE ─"
assert_has   "box top SYSTEM"   "╭─ SYSTEM ─"
assert_has   "box top FLAKE"    "╭─ FLAKE ─"
assert_has   "box row prefix"   "│ rev"
assert_has   "box bottom"       "╰───"
if [[ $(width_of '╭─ STATE') == 40 ]]; then echo "PASS: rule fills NIXFETCH_COLS"; else echo "FAIL: width $(width_of '╭─ STATE')"; fail=1; fi
xrun "$T/fleet2.json" NIXFETCH_COLS=200 --
if [[ $(width_of '╭─ STATE') == 78 ]]; then echo "PASS: width capped at 78"; else echo "FAIL: cap $(width_of '╭─ STATE')"; fail=1; fi
xrun "$T/fleet2.json" NIXFETCH_COLS=0 --
if [[ $(width_of '╭─ STATE') == 78 ]]; then echo "PASS: zero columns falls back to 78"; else echo "FAIL: zero cols $(width_of '╭─ STATE')"; fail=1; fi
xrun "$T/fleet2.json" NIXFETCH_COLS=junk --
if [[ $rc == 0 && $(width_of '╭─ STATE') -gt 0 ]]; then echo "PASS: junk columns survives"; else echo "FAIL: junk columns rc=$rc"; fail=1; fi
xrun "$T/fleet2.json" --
assert_has   "rule under header" "───"
assert_has   "current glyph"     "● current"

cat > "$T/fleet3.json" <<'JSON'
{"generated_at":1,"hosts":[{"host":"desktop","rev":"1111111122222222","drift":2,"ahead":0,"dirty":false,"ssh_ok":true},
                           {"host":"pi","rev":"3333333344444444","drift":1,"ahead":1,"dirty":false,"ssh_ok":true}]}
JSON
xrun "$T/fleet3.json" --
assert_has   "behind glyph and bar" "▲ 2 behind ▰▰▱▱▱"
assert_has   "reboot glyph"         "↻ reboot pending"
xrun "$T/fleet3.json" -- pi
assert_has   "diverged glyph"       "✖ diverged"
xrun "$T/fleet2.json" -- pi
assert_has   "offline glyph"        "○ offline"
cat > "$T/fleet4.json" <<'JSON'
{"generated_at":1,"hosts":[{"host":"desktop","rev":"1111111122222222","drift":9,"ahead":0,"dirty":false,"ssh_ok":true}]}
JSON
xrun "$T/fleet4.json" --
assert_has   "bar caps at five"     "▰▰▰▰▰"
cat > "$T/fleet5.json" <<'JSON'
{"generated_at":1,"hosts":[{"host":"desktop","rev":"1111111122222222","drift":0,"ahead":3,"dirty":false,"ssh_ok":true}]}
JSON
xrun "$T/fleet5.json" --
assert_has   "ahead glyph and bar"  "▲ 3 ahead ▰▰▰▱▱"

xrun "$T/fleet2.json" -- --imports
assert_has   "--imports lists a path"   "    roles/niri.nix"
assert_has   "--imports lists local file" "    hosts/desktop/hardware.nix"
assert_has   "--imports keeps summary"  "hosts 1 · roles 1"
R3="$T/noimp"; git init -q -b main "$R3"; mkdir -p "$R3/hosts/desktop"; echo '{}' > "$R3/hosts/desktop/config.nix"
OUTPUT=$(NIXFETCH_ROOT="$R3" NIXFETCH_CACHE="$C" NIXFETCH_FLEET_FILE="$T/fleet2.json" NIXFETCH_PALETTE="$T/none" NIXFETCH_NOW=$NOW \
  NIXFETCH_SELF=SWphil NIXFETCH_HOSTS="desktop" "$SCRIPT" --imports 2>&1); rc=$?
assert_lacks "empty imports prints no row" "imports"
if [[ $rc == 0 ]]; then echo "PASS: empty imports exits 0"; else echo "FAIL: empty imports exit $rc"; fail=1; fi
mkdir -p "$R3/hosts/desktop"
echo '{ imports = [ ./a.nix ./a.nix ../../secrets/x.yaml ../../roles/r.nix ../../weird/q.nix ]; }' > "$R3/hosts/desktop/config.nix"
OUTPUT=$(NIXFETCH_ROOT="$R3" NIXFETCH_CACHE="$C" NIXFETCH_FLEET_FILE="$T/fleet2.json" NIXFETCH_PALETTE="$T/none" NIXFETCH_NOW=$NOW \
  NIXFETCH_SELF=SWphil NIXFETCH_HOSTS="desktop" "$SCRIPT" 2>&1)
assert_has   "unique counts, fixed order, secrets group" "hosts 1 · roles 1 · secrets 1"
assert_has   "unknown dirs are not dropped" "weird 1"

SN="$T/snark.txt"
cat > "$SN" <<'TXT'
current: cur zero.
current: cur one.
behind: beh zero.
behind: beh one.
behind: beh two.
reboot: reb zero.
diverged: div zero.
offline: off zero.
nodata: nod zero.
TXT
xrun "$T/fleet3.json" NIXFETCH_SNARK="$SN" NIXFETCH_SNARK_SEED=1 --
assert_has   "reboot outranks behind in snark" "reb zero."
assert_lacks "snark lacks other states" "beh one."
xrun "$T/fleet3.json" NIXFETCH_SNARK="$SN" -- pi
assert_has   "diverged snark" "div zero."
xrun "$T/fleet2.json" NIXFETCH_SNARK="$SN" -- pi
assert_has   "offline snark" "off zero."
cat > "$T/fleet6.json" <<'JSON'
{"generated_at":1,"hosts":[{"host":"desktop","rev":"1111111122222222","drift":2,"ahead":0,"dirty":false,"ssh_ok":true}]}
JSON
mkdir -p "$T/boot"; cp "$C/desktop.json" "$T/boot/desktop.json"
sed -i 's/"booted_same":false,"kernel_same":false/"booted_same":true,"kernel_same":true/' "$T/boot/desktop.json"
xrun "$T/fleet6.json" NIXFETCH_CACHE="$T/boot" NIXFETCH_SNARK="$SN" NIXFETCH_SNARK_SEED=4 --
assert_has   "seed picks modulo count (4 % 3 = 1)" "beh one."
xrun "$T/fleet6.json" NIXFETCH_CACHE="$T/boot" NIXFETCH_SNARK="$SN" NIXFETCH_SNARK_SEED=3 --
assert_has   "seed 3 % 3 = 0" "beh zero."
xrun "$T/fleet6.json" NIXFETCH_CACHE="$T/boot" NIXFETCH_SNARK="$SN" --
if grep -qE 'beh (zero|one|two)\.' <<<"$OUTPUT"; then echo "PASS: daily pick lands in the state"; else echo "FAIL: daily pick"; fail=1; fi
OUTPUT2=$OUTPUT; xrun "$T/fleet6.json" NIXFETCH_CACHE="$T/boot" NIXFETCH_SNARK="$SN" --
if [[ $OUTPUT == "$OUTPUT2" ]]; then echo "PASS: daily pick is stable"; else echo "FAIL: daily pick unstable"; fail=1; fi
xrun "$T/fleet2.json" NIXFETCH_CACHE="$T/empty" NIXFETCH_SNARK="$SN" NIXFETCH_SNARK_SEED=0 --
assert_has   "nodata snark when no cache" "nod zero."
xrun "$T/fleet2.json" NIXFETCH_SNARK="$T/missing" --
if [[ $rc == 0 ]]; then echo "PASS: missing snark file exits 0"; else echo "FAIL: missing snark exit $rc"; fail=1; fi
xrun "$T/fleet6.json" NIXFETCH_CACHE="$T/boot" NIXFETCH_SNARK=/ NIXFETCH_SNARK_SEED=x --
if [[ $rc == 0 ]]; then echo "PASS: unreadable snark and junk seed exit 0"; else echo "FAIL: unreadable snark exit $rc"; fail=1; fi
mkdir -p "$HOME/.local/share/nixfetch"; echo 'behind: user line.' > "$HOME/.local/share/nixfetch/snark.txt"
xrun "$T/fleet6.json" NIXFETCH_CACHE="$T/boot" NIXFETCH_SNARK="$SN" --
assert_has   "user snark file takes precedence" "user line."
rm -rf "$HOME/.local/share/nixfetch"

# colour paths need a tty
cat > "$T/pal.sh" <<'PAL'
ROOT="#000000"; FIFTH="#600000"; FERMATA="#010203"; FORTE="#040506"; REST="#070809"
PAL
pty() {   # fleet file, cache dir, args...
  local fl=$1 ca=$2; shift 2
  OUTPUT=$(NIXFETCH_ROOT="$R" NIXFETCH_CACHE="$ca" NIXFETCH_FLEET_FILE="$fl" NIXFETCH_PALETTE="$T/pal.sh" NIXFETCH_NOW=$NOW \
    NIXFETCH_SELF=SWphil NIXFETCH_HOSTS="desktop pi" NIXFETCH_DELAY=0 NIXFETCH_COLS=60 \
    script -qc "$SCRIPT $*" /dev/null | tr -d '\r')
}
pty "$T/fleet2.json" "$C"
for e in '38;2;0;0;0m' '38;2;16;0;0m' '38;2;32;0;0m' '38;2;48;0;0m' '38;2;64;0;0m' '38;2;80;0;0m' '38;2;96;0;0m'; do
  assert_has "gradient step $e" "$e"
done
if grep -m1 'SWphil' <<<"$OUTPUT" | grep -qF $'\033'; then echo "PASS: header coloured under a tty"; else echo "FAIL: no colour under tty"; fail=1; fi
OUTPUT=$(NO_COLOR=1 NIXFETCH_ROOT="$R" NIXFETCH_CACHE="$C" NIXFETCH_FLEET_FILE="$T/fleet2.json" NIXFETCH_PALETTE="$T/pal.sh" NIXFETCH_NOW=$NOW \
  NIXFETCH_SELF=SWphil NIXFETCH_HOSTS="desktop pi" NIXFETCH_DELAY=0 script -qc "$SCRIPT" /dev/null | tr -d '\r')
assert_lacks "NO_COLOR prints plain art" $'\033'
# oldest-input age colour: 10d ok (FIFTH), 200d warn (FERMATA), 400d bad (FORTE)
for case in "10:38;2;96;0;0m" "200:38;2;1;2;3m" "400:38;2;4;5;6m"; do
  d=${case%%:*}; esc=${case#*:}
  mkdir -p "$T/age$d"
  echo "{\"host\":\"SWphil\",\"generated_at\":$((NOW - 60)),\"rev\":null,\"generation\":1,\"built_at\":$((NOW - 60)),\"booted_same\":true,\"kernel_same\":true,\"inputs\":[{\"name\":\"zzz\",\"last_modified\":$((NOW - d * 86400))}]}" > "$T/age$d/desktop.json"
  pty "$T/fleet2.json" "$T/age$d"
  if grep zzz <<<"$OUTPUT" | grep -qF "$esc"; then echo "PASS: oldest ${d}d colour"; else echo "FAIL: oldest ${d}d colour"; fail=1; fi
done

exit $fail
