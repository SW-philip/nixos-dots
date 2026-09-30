#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0

need() {
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then echo "ok   - $1"
  else echo "FAIL - $1 (filter $3)"; echo "  $2"; fails=$((fails+1)); fi
}

V=$(bash "$DIR/../vitals.sh" --selftest)
need "vitals is valid JSON"        "$V" '.'
need "vitals.cpu_pct is a number"  "$V" '.cpu_pct | numbers'
need "vitals.mem_pct 0..100"       "$V" '.mem_pct | numbers | select(. >= 0 and . <= 100)'
need "vitals.temp_max_c is number" "$V" '.temp_max_c | numbers'
need "vitals.hist_cpu present"     "$V" 'has("hist_cpu")'

S=$(bash "$DIR/../storage.sh" --selftest)
need "storage is valid JSON"              "$S" '.'
need "storage.mounts nonempty array"      "$S" '.mounts | arrays | select(length > 0)'
need "each mount has target+pct"          "$S" '.mounts | all(has("target") and has("pct"))'
need "storage.generation is a number"     "$S" '.generation | numbers'

B=$(bash "$DIR/../boot.sh" --selftest)
need "boot is valid JSON"           "$B" '.'
need "boot.uptime_h is a number"    "$B" '.uptime_h | numbers'
need "boot.kernel non-empty string" "$B" '.kernel | strings | select(length > 0)'
need "boot.gen_drift is a boolean"  "$B" '.gen_drift | type == "boolean"'
RS=$(jq -r '.rebuild_state' <<<"$B")
case "$RS" in
  fresh|ok|aging|stale|unknown) echo "ok   - boot.rebuild_state enum ($RS)" ;;
  *) echo "FAIL - boot.rebuild_state=[$RS]"; fails=$((fails+1)) ;;
esac
need "boot has sleep_drain_pct key"  "$B" 'has("sleep_drain_pct")'
need "boot has sleep_hours key"      "$B" 'has("sleep_hours")'
need "boot.sleep_drain_pct null|num" "$B" '.sleep_drain_pct | (type == "null") or (type == "number")'

P=$(bash "$DIR/../purity.sh" --selftest)
need "purity is valid JSON"       "$P" '.'
need "purity.clients is a number"  "$P" '.clients | numbers'
need "purity.pure is a boolean"    "$P" '.pure | type == "boolean"'
need "purity pure iff clients==0"  "$P" 'select((.clients == 0) == .pure)'

N=$(bash "$DIR/../net.sh" --selftest)
need "net is valid JSON"          "$N" '.'
need "net.kind enum"              "$N" '.kind | . == "wifi" or . == "wired" or . == "none"'
need "net.signal_pct 0..100"      "$N" '.signal_pct | numbers | select(. >= 0 and . <= 100)'
need "net.vpn is a boolean"       "$N" '.vpn | type == "boolean"'
need "net has ssid + vpn_name"    "$N" 'has("ssid") and has("vpn_name")'

NT=$(NET_TEST_IFACE=wg0 bash "$DIR/../net.sh" --selftest)
need "net tunnel route -> kind is 'wifi'"   "$NT" '.kind | . == "wifi"'
need "net still valid JSON on tunnel route"  "$NT" '.'

T=$(bash "$DIR/../bt.sh" --selftest)
need "bt is valid JSON"           "$T" '.'
need "bt.available is a boolean"  "$T" '.available | type == "boolean"'
need "bt.count is a number"       "$T" '.count | numbers'
need "bt.devices is an array"     "$T" '.devices | type == "array"'
need "bt.count == devices length" "$T" 'select(.count == (.devices | length))'
need "each device has name+batt"  "$T" '.devices | all(has("name") and has("battery"))'

# device-enumeration path via canned transcript (adapter is off, so the plain
# --selftest above only ever sees the empty case)
BTTMP=$(mktemp -d)
printf 'AA:BB:CC:DD:EE:01\nAA:BB:CC:DD:EE:02\n' > "$BTTMP/macs"
printf 'Pixel Buds Pro' > "$BTTMP/AA_BB_CC_DD_EE_01.alias"
printf '73'             > "$BTTMP/AA_BB_CC_DD_EE_01.battery"
printf 'Kitchen Speaker' > "$BTTMP/AA_BB_CC_DD_EE_02.alias"
TF=$(BT_TEST_TRANSCRIPT="$BTTMP" bash "$DIR/../bt.sh" --selftest)
need "bt fixture: valid JSON"       "$TF" '.'
need "bt fixture: available true"   "$TF" '.available == true'
need "bt fixture: count == 2"       "$TF" '.count == 2'
need "bt fixture: count==length"    "$TF" 'select(.count == (.devices | length))'
need "bt fixture: dev0 name clean"  "$TF" '.devices[0].name == "Pixel Buds Pro"'
need "bt fixture: dev0 battery int" "$TF" '.devices[0].battery | numbers | select(. == 73)'
need "bt fixture: dev1 battery null" "$TF" '.devices[1].battery == null'
rm -rf "$BTTMP"

W=$(bash "$DIR/../power.sh" --selftest)
need "power is valid JSON"         "$W" '.'
need "power.present is a boolean"   "$W" '.present | type == "boolean"'
need "power.pct 0..100"            "$W" '.pct | numbers | select(. >= 0 and . <= 100)'
need "power has state + draw_w"    "$W" 'has("state") and (.draw_w | numbers)'

M=$(bash "$DIR/../myln.sh" --selftest)
need "myln is valid JSON"          "$M" '.'
need "myln.available is a boolean"  "$M" '.available | type == "boolean"'
need "myln.count is a number"       "$M" '.count | numbers'

G=$(bash "$DIR/../mug.sh" --selftest)
need "mug is valid JSON"            "$G" '.'
need "mug.available is a boolean"   "$G" '.available | type == "boolean"'
need "mug has temp_c + battery_pct" "$G" '(.temp_c | numbers) and (.battery_pct | numbers)'

MUGTMP=$(mktemp -d); mkdir -p "$MUGTMP/waybar/ember-mug"; echo '{"ok": broken' > "$MUGTMP/waybar/ember-mug/status.json"
GM=$(XDG_CACHE_HOME="$MUGTMP" bash "$DIR/../mug.sh" --selftest) && rc=0 || rc=$?
need "mug survives malformed cache (valid JSON)" "$GM" '.available == false'
if [ "$rc" -eq 0 ]; then echo "ok   - mug exits 0 on malformed cache"; else echo "FAIL - mug rc=$rc"; fails=$((fails+1)); fi
rm -rf "$MUGTMP"

echo
if [[ $fails -eq 0 ]]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
