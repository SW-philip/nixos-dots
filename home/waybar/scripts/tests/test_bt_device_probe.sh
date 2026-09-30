#!/usr/bin/env bash
# Pure-function tests for bt-device-probe.sh.
# Each JBL block runs in a `( … )` subshell purely to keep its JBL_CACHE /
# CACHE_DIR overrides from leaking into later tests -- SC2030/SC2031 flag that
# containment as if it were a mistake; it's the intent.
# shellcheck disable=SC2030,SC2031
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bt-device-probe.sh"

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

assert_eq "manufacturer uuid" "manufacturer" "$(_dis_field_for_uuid "00002a29-0000-1000-8000-00805f9b34fb")"
assert_eq "model uuid" "model" "$(_dis_field_for_uuid "00002a24-0000-1000-8000-00805f9b34fb")"
assert_eq "serial uuid" "serial_number" "$(_dis_field_for_uuid "00002a25-0000-1000-8000-00805f9b34fb")"
assert_eq "firmware uuid" "firmware_revision" "$(_dis_field_for_uuid "00002a26-0000-1000-8000-00805f9b34fb")"
assert_eq "hardware uuid" "hardware_revision" "$(_dis_field_for_uuid "00002a27-0000-1000-8000-00805f9b34fb")"
assert_eq "software uuid" "software_revision" "$(_dis_field_for_uuid "00002a28-0000-1000-8000-00805f9b34fb")"
assert_eq "unknown uuid -> empty" "" "$(_dis_field_for_uuid "00002a19-0000-1000-8000-00805f9b34fb")"

# Real busctl --json=short ReadValue shape, verified live against the mug's
# GAP Device Name characteristic (a{sv} ReadValue -> {"type":"ay","data":[[bytes...]]}).
assert_eq "decode readvalue" "Ember" "$(_decode_readvalue_json '{"type":"ay","data":[[69,109,98,101,114]]}')"
assert_eq "decode readvalue with null padding" "Ember" "$(_decode_readvalue_json '{"type":"ay","data":[[69,109,98,101,114,0,0]]}')"
assert_eq "decode empty readvalue" "" "$(_decode_readvalue_json '{"type":"ay","data":[[]]}')"

# _paired_trusted_ok: both flags must be exactly "b true"
assert_eq "paired+trusted -> 1" "1" "$(_paired_trusted_ok "b true" "b true")"
assert_eq "paired, not trusted -> 0" "0" "$(_paired_trusted_ok "b true" "b false")"
assert_eq "trusted, not paired -> 0" "0" "$(_paired_trusted_ok "b false" "b true")"
assert_eq "missing device object -> 0" "0" "$(_paired_trusted_ok "" "")"

# _probe_decision: force bypasses everything
assert_eq "force always proceeds (unconfigured, untrusted)" "proceed" "$(_probe_decision force 0 0)"
assert_eq "force always proceeds (configured)" "proceed" "$(_probe_decision force 1 1)"
# non-force path
assert_eq "not paired+trusted -> skip" "skip" "$(_probe_decision "" 0 0)"
assert_eq "paired+trusted but configured -> refresh" "refresh" "$(_probe_decision "" 1 1)"
assert_eq "paired+trusted, unconfigured -> proceed" "proceed" "$(_probe_decision "" 1 0)"

# --- _jbl_fields_from_cache / _jbl_merge / _is_jbl ---
# `JBL_CACHE=… out=$(fn)` is two plain assignments (no command word), so
# JBL_CACHE would leak into every later test -- run each block in a subshell.
jbl_tmp=$(mktemp -d)
now=$(date +%s)

(
  export JBL_CACHE="$jbl_tmp/status.json"
  cat >"$JBL_CACHE" <<EOF
{"ok":true,"ts":$now,"battery_pct":75,"name":"SWjbl","model":"DH0082-GP0552095","firmware":"0640","channel":0,"charging":false}
EOF
  out=$(_jbl_fields_from_cache)
  assert_eq "jbl battery mapped"   "75"               "$(jq -r .battery <<<"$out")"
  assert_eq "jbl firmware mapped"  "0640"             "$(jq -r .firmware_revision <<<"$out")"
  assert_eq "jbl model mapped"     "DH0082-GP0552095" "$(jq -r .model <<<"$out")"
  assert_eq "jbl charging mapped"  "false"            "$(jq -r .charging <<<"$out")"

  echo '{"ok":false,"ts":'"$now"'}' >"$JBL_CACHE"
  assert_eq "jbl not-ok -> empty obj" "{}" "$(jq -c . <<<"$(_jbl_fields_from_cache)")"

  # FIX 5: a stale cache is "no JBL data" on the connect-probe path too.
  echo '{"ok":true,"ts":'"$((now - 100000))"',"battery_pct":75}' >"$JBL_CACHE"
  assert_eq "jbl stale ts -> empty obj" "{}" "$(jq -c . <<<"$(_jbl_fields_from_cache)")"
  exit $fail
) || fail=1

# FIX 4: _is_jbl is .mac-authoritative once the poller cache carries a mac.
(
  export JBL_CACHE="$jbl_tmp/status.json"
  echo '{"ok":true,"ts":'"$now"',"mac":"00:00:00:00:00:02","battery_pct":60}' >"$JBL_CACHE"
  if _is_jbl "00:00:00:00:00:02"; then r=yes; else r=no; fi
  assert_eq "_is_jbl matching mac -> true" "yes" "$r"
  if _is_jbl "AA:BB:CC:DD:EE:FF"; then r=yes; else r=no; fi
  assert_eq "_is_jbl different mac -> false" "no" "$r"
  exit $fail
) || fail=1
# no-cache path falls through to `bt-classify type` (live) -- left untested,
# same as the mug/probe live paths.

# FIX 2: _jbl_merge writes the FULL field set into the render cache, merging
# onto whatever is already there, and no-ops on a bad/stale poller cache.
(
  export JBL_CACHE="$jbl_tmp/status.json"
  export CACHE_DIR="$jbl_tmp/bt-device-info"
  mkdir -p "$CACHE_DIR"
  mac="00:00:00:00:00:02"
  render="$CACHE_DIR/$mac.json"
  echo '{"type":"audio","stale_key":"keep"}' >"$render"
  echo '{"ok":true,"ts":'"$now"',"battery_pct":60,"model":"DH0082-GP0552095","firmware":"0640","channel":0,"charging":true}' >"$JBL_CACHE"
  # shellcheck disable=SC2329  # invoked indirectly via _jbl_merge
  bt-classify() { echo speaker; }   # stub the live classifier
  _jbl_merge "$mac"
  assert_eq "_jbl_merge battery"  "60"     "$(jq -r .battery "$render")"
  assert_eq "_jbl_merge charging" "true"   "$(jq -r .charging "$render")"
  assert_eq "_jbl_merge model"    "DH0082-GP0552095" "$(jq -r .model "$render")"
  assert_eq "_jbl_merge firmware" "0640"   "$(jq -r .firmware_revision "$render")"
  assert_eq "_jbl_merge channel"  "0"      "$(jq -r .channel "$render")"
  assert_eq "_jbl_merge type"     "speaker" "$(jq -r .type "$render")"
  assert_eq "_jbl_merge keeps prior keys" "keep" "$(jq -r .stale_key "$render")"

  # stale poller cache -> render cache untouched
  echo '{"ok":true,"ts":'"$((now - 100000))"',"battery_pct":99}' >"$JBL_CACHE"
  _jbl_merge "$mac"
  assert_eq "_jbl_merge stale -> no overwrite" "60" "$(jq -r .battery "$render")"
  exit $fail
) || fail=1

rm -rf "$jbl_tmp"

if [[ $fail -eq 0 ]]; then
  echo "All tests passed."
else
  echo "Some tests failed."
fi
exit $fail
