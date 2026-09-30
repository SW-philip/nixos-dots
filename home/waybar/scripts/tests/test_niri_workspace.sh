#!/usr/bin/env bash
# Pure-function tests for niri-workspace.sh. Needs `jq` on PATH.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export NIRI_WS_ICONS='{"code":"C","browse":"B","media":"M","fallback":"F"}'
# Neutralize ambient snark env so a caller's exports can't spuriously fail the
# non-snark assertions (which run against the parent shell's top-level state).
unset NIRI_WS_SNARK_FILE NIRI_WS_NOW_EPOCH NIRI_WS_NOW_HOUR

# shellcheck source=/dev/null
source "$SCRIPT_DIR/niri-workspace.sh"

WS='[
 {"id":1,"idx":1,"name":"code","output":"eDP-1","is_active":true},
 {"id":2,"idx":2,"name":"browse","output":"eDP-1","is_active":false},
 {"id":3,"idx":3,"name":"media","output":"eDP-1","is_active":false},
 {"id":6,"idx":6,"name":null,"output":"eDP-1","is_active":false},
 {"id":9,"idx":1,"name":null,"output":"DP-2","is_active":true}
]'

WS_MEDIA_ACTIVE='[
 {"id":1,"idx":1,"name":"code","output":"eDP-1","is_active":false},
 {"id":2,"idx":2,"name":"browse","output":"eDP-1","is_active":false},
 {"id":3,"idx":3,"name":"media","output":"eDP-1","is_active":true}
]'

fail=0
assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: $desc — expected '$expected', got '$actual'"
    fail=1
  else
    echo "PASS: $desc"
  fi
}

assert_eq "render: named active workspace" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3","class":"code"}' \
  "$(_render_line "$WS" eDP-1)"

assert_eq "render: unnamed active workspace" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">F</span> 1","tooltip":"workspace 1","class":"unnamed"}' \
  "$(_render_line "$WS" DP-2)"

assert_eq "render: output with no active workspace" \
  '{"text":"","class":"empty"}' \
  "$(_render_line "$WS" HDMI-A-1)"

assert_eq "pick: next from first wraps forward" \
  "browse" "$(_pick_target "$WS" eDP-1 next)"

assert_eq "pick: prev from first wraps to last named" \
  "media" "$(_pick_target "$WS" eDP-1 prev)"

assert_eq "pick: next from last named wraps to first" \
  "code" "$(_pick_target "$WS_MEDIA_ACTIVE" eDP-1 next)"

assert_eq "pick: output with <2 named workspaces is a no-op" \
  "" "$(_pick_target "$WS" DP-2 next)"

assert_eq "render: missing NIRI_WS_ICONS falls back to name-only" \
  '{"text":"code","tooltip":"code — 1/3","class":"code"}' \
  "$(env -u NIRI_WS_ICONS bash -c "source '$SCRIPT_DIR/niri-workspace.sh'; _render_line '$WS' eDP-1")"

# --- snark (tooltip-only, appended as \n<i>…</i>) ---------------------------

# One dir for every snark fixture, cleaned up once even on interrupt.
SNARK_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$SNARK_TMPDIR"' EXIT

SNARK_FIXTURE="$SNARK_TMPDIR/snark.json"
cat >"$SNARK_FIXTURE" <<'JSON'
{
  "rotateSeconds": 60,
  "persona": {
    "code": ["dry code jab"],
    "_default": ["dry default jab"]
  },
  "time": [
    { "from": 0, "to": 12, "lines": ["morning jab"] },
    { "from": 12, "to": 24, "lines": ["evening jab"] }
  ]
}
JSON

# Re-source in a subshell so the top-level SNARK_JSON load picks up the env,
# mirroring the "missing NIRI_WS_ICONS" case above.
snark_render() { # $1=ws json  $2=output   (env vars already exported inline)
  bash -c "source '$SCRIPT_DIR/niri-workspace.sh'; _render_line '$1' '$2'"
}

# persona: named workspace, hour 9, epoch 0 => rotation index 0 => persona pool.
assert_eq "snark: persona line appended for named workspace" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3\n<i>dry code jab</i>","class":"code"}' \
  "$(NIRI_WS_SNARK_FILE="$SNARK_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=9 snark_render "$WS" eDP-1)"

# unnamed active workspace falls back to persona._default
assert_eq "snark: _default persona line for unnamed workspace" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">F</span> 1","tooltip":"workspace 1\n<i>dry default jab</i>","class":"unnamed"}' \
  "$(NIRI_WS_SNARK_FILE="$SNARK_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=9 snark_render "$WS" DP-2)"

# time bucket is half-open: hour 12 belongs to the 12..24 bucket, not 0..12.
# Fixture with no persona pool so only `time` is applicable.
TIME_ONLY_FIXTURE="$SNARK_TMPDIR/time-only.json"
cat >"$TIME_ONLY_FIXTURE" <<'JSON'
{ "time": [
    { "from": 0, "to": 12, "lines": ["morning jab"] },
    { "from": 12, "to": 24, "lines": ["evening jab"] } ] }
JSON
assert_eq "snark: time bucket boundary is half-open (hour==to excluded)" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3\n<i>evening jab</i>","class":"code"}' \
  "$(NIRI_WS_SNARK_FILE="$TIME_ONLY_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=12 snark_render "$WS" eDP-1)"

# rotation: both categories apply; index flips at each rotateSeconds step.
ROT_FIXTURE="$SNARK_TMPDIR/rot.json"
cat >"$ROT_FIXTURE" <<'JSON'
{ "rotateSeconds": 60,
  "persona": { "code": ["PERSONA"] },
  "time": [ { "from": 0, "to": 24, "lines": ["TIME"] } ] }
JSON
assert_eq "snark: rotation index 0 -> persona" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3\n<i>PERSONA</i>","class":"code"}' \
  "$(NIRI_WS_SNARK_FILE="$ROT_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=9 snark_render "$WS" eDP-1)"
assert_eq "snark: rotation index 1 -> time" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3\n<i>TIME</i>","class":"code"}' \
  "$(NIRI_WS_SNARK_FILE="$ROT_FIXTURE" NIRI_WS_NOW_EPOCH=60 NIRI_WS_NOW_HOUR=9 snark_render "$WS" eDP-1)"

# malformed file: no snark line, factual tooltip only.
BAD_FIXTURE="$SNARK_TMPDIR/bad.json"
printf 'not json at all\n' >"$BAD_FIXTURE"
assert_eq "snark: malformed file falls back to no snark line" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3","class":"code"}' \
  "$(NIRI_WS_SNARK_FILE="$BAD_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=9 snark_render "$WS" eDP-1)"

# empty output stays tooltip-less even with a valid snark file.
assert_eq "snark: empty output has no tooltip" \
  '{"text":"","class":"empty"}' \
  "$(NIRI_WS_SNARK_FILE="$SNARK_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=9 snark_render "$WS" HDMI-A-1)"

# --- snark: deterministic line pick across a real (3-line) pool -------------

# Pool of 3 distinct lines so `csum % len` is genuinely exercised (all the
# fixtures above have 1-line pools, index is always 0).
DET_FIXTURE="$SNARK_TMPDIR/det.json"
cat >"$DET_FIXTURE" <<'JSON'
{ "rotateSeconds": 60,
  "persona": { "code": ["persona alpha", "persona bravo", "persona charlie"] } }
JSON

# Same (workspace name, hour) => same line on every call (no persistent counter).
det_1="$(NIRI_WS_SNARK_FILE="$DET_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=9 snark_render "$WS" eDP-1)"
det_2="$(NIRI_WS_SNARK_FILE="$DET_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=9 snark_render "$WS" eDP-1)"
assert_eq "snark: deterministic pick is stable across calls (name=code hour=9)" \
  "$det_1" "$det_2"
assert_eq "snark: deterministic pick, name=code hour=9 -> pool index 1" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3\n<i>persona bravo</i>","class":"code"}' \
  "$det_1"

# A different hour lands on a different index -> proves csum % len drives it.
assert_eq "snark: deterministic pick, name=code hour=10 -> pool index 2" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3\n<i>persona charlie</i>","class":"code"}' \
  "$(NIRI_WS_SNARK_FILE="$DET_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=10 snark_render "$WS" eDP-1)"
assert_eq "snark: deterministic pick, name=code hour=11 -> pool index 0" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3\n<i>persona alpha</i>","class":"code"}' \
  "$(NIRI_WS_SNARK_FILE="$DET_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=11 snark_render "$WS" eDP-1)"

# --- snark: rotateSeconds edge / guard -------------------------------------

# rotateSeconds:0 is valid JSON but a bad divisor; the >=1 clamp keeps
# _render_line producing a well-formed line (no blank output, no jq error).
ROT0_FIXTURE="$SNARK_TMPDIR/rot0.json"
cat >"$ROT0_FIXTURE" <<'JSON'
{ "rotateSeconds": 0,
  "persona": { "code": ["zero rot jab"] },
  "time": [ { "from": 0, "to": 24, "lines": ["zero rot time"] } ] }
JSON
assert_eq "snark: rotateSeconds 0 is clamped, line still rendered" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3\n<i>zero rot jab</i>","class":"code"}' \
  "$(NIRI_WS_SNARK_FILE="$ROT0_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=9 snark_render "$WS" eDP-1)"

# non-numeric rotateSeconds in otherwise-valid JSON: `numbers` guard drops it,
# falls back to 60, line still rendered (no `$now / "x"` throw -> blank module).
ROTX_FIXTURE="$SNARK_TMPDIR/rotx.json"
cat >"$ROTX_FIXTURE" <<'JSON'
{ "rotateSeconds": "x",
  "persona": { "code": ["nonnum rot jab"] } }
JSON
assert_eq "snark: non-numeric rotateSeconds falls back to 60, line still rendered" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3\n<i>nonnum rot jab</i>","class":"code"}' \
  "$(NIRI_WS_SNARK_FILE="$ROTX_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=9 snark_render "$WS" eDP-1)"

# --- snark: valid JSON, wrong shape => degrade to no snark line -----------

# `jq -e .` passes (syntax is fine) but the shape is wrong. Without the
# try/catch these abort _render_line mid-program -> blank module forever.
SHAPE_STR_FIXTURE="$SNARK_TMPDIR/shape-string-pool.json"
printf '%s\n' '{"persona":{"code":"nope"}}' >"$SHAPE_STR_FIXTURE"
assert_eq "snark: persona pool as a string degrades to factual tooltip" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3","class":"code"}' \
  "$(NIRI_WS_SNARK_FILE="$SHAPE_STR_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=9 snark_render "$WS" eDP-1)"

SHAPE_NUM_FIXTURE="$SNARK_TMPDIR/shape-numeric-entries.json"
printf '%s\n' '{"persona":{"code":[1,2]}}' >"$SHAPE_NUM_FIXTURE"
assert_eq "snark: non-string pool entries degrade to factual tooltip" \
  '{"text":"<span font_family=\"Hack Nerd Font Mono\">C</span> code","tooltip":"code — 1/3","class":"code"}' \
  "$(NIRI_WS_SNARK_FILE="$SHAPE_NUM_FIXTURE" NIRI_WS_NOW_EPOCH=0 NIRI_WS_NOW_HOUR=9 snark_render "$WS" eDP-1)"

if [[ $fail -eq 0 ]]; then echo "All tests passed."; else echo "Some tests failed."; fi
exit $fail
