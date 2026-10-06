#!/usr/bin/env bash
set -uo pipefail

MUG_MAC="00:00:00:00:00:01"
MUG_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/waybar/ember-mug/status.json"
# Overridable for tests; real path matches home/waybar/jbl-speaker.nix.
JBL_CACHE="${JBL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/waybar/jbl-speaker/status.json}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/bt-device-info"
PREFS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/bt-device-info/prefs"

# _dis_field_for_uuid <uuid, lowercase 128-bit form>
# Pure: standard BLE Device Information Service characteristic UUIDs ->
# the field key we cache them under. Anything else -> empty (not this
# service's concern -- skipped by the caller).
_dis_field_for_uuid() {
  case "$1" in
    00002a29-0000-1000-8000-00805f9b34fb) echo "manufacturer" ;;
    00002a24-0000-1000-8000-00805f9b34fb) echo "model" ;;
    00002a25-0000-1000-8000-00805f9b34fb) echo "serial_number" ;;
    00002a26-0000-1000-8000-00805f9b34fb) echo "firmware_revision" ;;
    00002a27-0000-1000-8000-00805f9b34fb) echo "hardware_revision" ;;
    00002a28-0000-1000-8000-00805f9b34fb) echo "software_revision" ;;
    *) echo "" ;;
  esac
}

# _decode_readvalue_json <busctl --json=short ReadValue output>
# Pure: {"type":"ay","data":[[byte,byte,...]]} -> decoded UTF-8 text with
# any trailing NUL padding stripped. Empty/malformed input -> "".
_decode_readvalue_json() {
  jq -r '.data[0] // [] | implode' <<<"$1" 2>/dev/null | tr -d '\0'
}

# _paired_trusted_ok <paired_out> <trusted_out>
# Pure. Prints 1 only when both args are "b true" (the form
# `busctl get-property ... Device1 Paired` prints); a missing device object
# comes through as an empty string, so it prints 0.
_paired_trusted_ok() {
  if [[ "$1" == "b true" && "$2" == "b true" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

# _probe_decision <force> <pt_ok> <prefs_exists>
# Pure. Prints one of:
#   proceed - full DIS + battery probe, write cache, maybe open the menu
#   refresh - configured device: update only the battery field, no menu
#   skip    - not paired+trusted: do nothing, no cache
# `force` (a manual re-probe) always proceeds.
_probe_decision() {
  local force="$1" pt_ok="$2" prefs_exists="$3"
  if [[ "$force" == "force" ]]; then echo "proceed"; return; fi
  if [[ "$pt_ok" != "1" ]]; then echo "skip"; return; fi
  if [[ "$prefs_exists" == "1" ]]; then echo "refresh"; return; fi
  echo "proceed"
}

# _is_paired_trusted <mac> -- live check via busctl. Assumes adapter hci0
# (single adapter on both hosts). Exit 0 iff the device object exists and both
# org.bluez.Device1 Paired and Trusted are true.
_is_paired_trusted() {
  local mac="$1" path p t
  path="/org/bluez/hci0/dev_${mac//:/_}"
  p=$(busctl get-property org.bluez "$path" org.bluez.Device1 Paired 2>/dev/null)
  t=$(busctl get-property org.bluez "$path" org.bluez.Device1 Trusted 2>/dev/null)
  [[ "$(_paired_trusted_ok "$p" "$t")" == "1" ]]
}

# _probe_dis_fields <mac> -- best-effort walk of the standard Device
# Information Service over D-Bus. Requires the device to be connected
# (GATT ReadValue fails otherwise) -- only ever called right after a
# Connected: yes event. Prints a JSON object of whatever fields were
# actually read; missing/unresolved/denied characteristics are silently
# skipped, never fatal.
_probe_dis_fields() {
  local mac="$1" dev_frag objects_json fields_json="{}"
  dev_frag="dev_${mac//:/_}"
  objects_json=$(busctl call org.bluez / org.freedesktop.DBus.ObjectManager \
    GetManagedObjects --json=short 2>/dev/null) || { echo "$fields_json"; return; }

  while IFS=$'\t' read -r uuid_json char_path; do
    [[ -z "$char_path" ]] && continue
    local uuid field value
    uuid="$uuid_json"
    [[ -z "$uuid" ]] && continue
    field=$(_dis_field_for_uuid "$uuid")
    [[ -z "$field" ]] && continue
    value=$(_decode_readvalue_json "$(busctl call org.bluez "$char_path" \
      org.bluez.GattCharacteristic1 ReadValue 'a{sv}' 0 --json=short 2>/dev/null)")
    [[ -z "$value" ]] && continue
    fields_json=$(jq --arg k "$field" --arg v "$value" '. + {($k): $v}' <<<"$fields_json")
  done < <(jq -r --arg dev "$dev_frag" '
      .data[0] | to_entries[]
      | select(.key | contains($dev))
      | select(.value["org.bluez.GattCharacteristic1"] != null)
      | [.value["org.bluez.GattCharacteristic1"].UUID.data, .key] | @tsv
    ' <<<"$objects_json" 2>/dev/null)

  echo "$fields_json"
}

# _battery_field <mac> -- best-effort read of bluez's Battery1 interface via
# bluetoothctl info, same proven expression as bluetooth-battery-notify.nix.
# Not every device exposes it (grep on "Battery Percentage:" just won't
# match) -- prints "" rather than treating that as an error.
_battery_field() {
  local mac="$1" pct mac_lower supply
  pct=$(printf "info %s\nquit\n" "$mac" | bluetoothctl 2>/dev/null | \
    grep -oP 'Battery Percentage:.*\(\K[0-9]+(?=\))')
  if [[ -n "$pct" ]]; then
    echo "$pct"
    return
  fi

  # Some HID gamepads (e.g. hid-playstation for DS4/DS5) report battery via a
  # kernel power_supply node keyed by MAC -- entirely separate from bluez's
  # own Battery1 interface, which bluetoothctl never sees. Confirmed live: a
  # DS4 (84:30:95:71:B5:79) has no "Battery Percentage:" line at all despite
  # /sys/class/power_supply/ps-controller-battery-<mac> reading correctly.
  mac_lower="${mac,,}"
  for supply in /sys/class/power_supply/*; do
    [[ -f "$supply/capacity" ]] || continue
    case "${supply,,}" in
      *"$mac_lower"*|*"${mac_lower//:/_}"*)
        cat "$supply/capacity"
        return
        ;;
    esac
  done
}

# _mug_fields_from_cache -- read whatever ember-mug-poll.py's own cache
# already has, mapped onto our generic field names. The mug speaks a
# proprietary GATT protocol (verified live: no standard Device Information
# or Battery service resolves at all), so its info comes from the tool
# that already knows how to talk to it, not from _probe_dis_fields.
_mug_fields_from_cache() {
  [[ -f "$MUG_CACHE" ]] || { echo "{}"; return; }
  jq -c '
    (if .ok then . else {} end) as $f
    | {}
    + (if ($f.battery_pct // null) != null then {battery: ($f.battery_pct | tostring)} else {} end)
    + (if ($f.serial_number // "") != "" then {serial_number: $f.serial_number} else {} end)
    + (if ($f.firmware_version // "") != "" then {firmware_revision: $f.firmware_version} else {} end)
  ' "$MUG_CACHE" 2>/dev/null || echo "{}"
}

# _jbl_fields_from_cache -- map jbl-speaker-poll.py's cache onto our generic
# field names. The speaker speaks a proprietary Harman 0xAA BLE protocol (no
# standard Battery or Device Information service resolves), so its info comes
# from the poller that already knows how to talk to it. Empty object unless
# the cache exists and is a good read. `charging` is kept only when the poller
# actually wrote it -- and a literal `false` survives (a plain `.charging //
# empty` would collapse the whole object construction to nothing).
# A cache older than 15min is stale -- the speaker dropped its BLE link long
# ago and the numbers no longer reflect reality. This is the staleness gate
# for both the connect-probe path (here) and the merge path (_jbl_merge bails
# on the resulting `{}`).
_JBL_MAX_AGE=900
_jbl_fields_from_cache() {
  [[ -f "$JBL_CACHE" ]] || { echo "{}"; return; }
  jq -c --argjson maxage "$_JBL_MAX_AGE" '
    if .ok != true or .battery_pct == null or ((.ts // 0) < (now - $maxage)) then {}
    else
      {battery: (.battery_pct | tostring)}
      + (if (.model // "")    != "" then {model: .model}                else {} end)
      + (if (.firmware // "") != "" then {firmware_revision: .firmware} else {} end)
      + (if .channel  != null      then {channel: .channel}            else {} end)
      + (if .charging != null      then {charging: .charging}          else {} end)
    end
  ' "$JBL_CACHE" 2>/dev/null || echo "{}"
}

# _jbl_poll_throttled -- run jbl-speaker-poll unless it already ran recently.
# The poll opens a BLE scan + GATT session to the speaker, and that bounces the
# A2DP link on this adapter; the bounce emits a fresh Connected event, which
# used to re-run the poll and loop forever. The poll rewrites $JBL_CACHE on every
# run (failures included), so its mtime is the last-attempt time.
_JBL_POLL_MIN_GAP=${_JBL_POLL_MIN_GAP:-300}
_jbl_poll_throttled() {
  local last now
  if [[ -f "$JBL_CACHE" ]]; then
    last=$(stat -c %Y "$JBL_CACHE" 2>/dev/null || echo 0)
    now=$(date +%s)
    (( now - last < _JBL_POLL_MIN_GAP )) && return 0
  fi
  jbl-speaker-poll 2>/dev/null || true
}

# _is_jbl <mac> -- is this the JBL speaker? Authoritative once jbl-speaker-poll
# has cached a `.mac` (a known-good JBL address): true iff it matches, so a
# different Bluetooth speaker no longer inherits the JBL's battery/model from
# the shared $JBL_CACHE. Before any successful poll, fall back to bt-classify
# calling it a "speaker" -- a first-connect best guess.
_is_jbl() {
  local mac="$1" jbl_mac
  if [[ -f "$JBL_CACHE" ]]; then
    jbl_mac=$(jq -r '.mac // empty' "$JBL_CACHE" 2>/dev/null)
    if [[ -n "$jbl_mac" ]]; then
      [[ "$jbl_mac" == "$mac" ]]
      return
    fi
  fi
  [[ "$(bt-classify type "$mac" 2>/dev/null)" == "speaker" ]]
}

# _jbl_merge <mac> -- the single writer of the JBL field set into the render
# cache ($CACHE_DIR/<mac>.json). Called from probe_cmd's first-connect branch,
# _refresh_battery's configured-device branch, and jbl-speaker-poll.timer's
# ExecStartPost. Merges the FULL set (battery/charging/channel/model/
# firmware_revision/type) from jbl-speaker-poll's own cache; no-op (cache
# untouched) when that cache is missing, not-ok, battery-less, or stale.
# Deliberately NOT gated by a prefs file or _probe_decision.
_jbl_merge() {
  local mac="$1" fields type cache_file merged
  fields=$(_jbl_fields_from_cache)
  [[ "$fields" == "{}" ]] && return 0
  type=$(bt-classify type "$mac" 2>/dev/null)
  [[ -n "$type" ]] || type="speaker"
  fields=$(jq -c --arg t "$type" '. + {type: $t}' <<<"$fields") || return 0
  cache_file="$CACHE_DIR/${mac}.json"
  mkdir -p "$CACHE_DIR"
  if [[ -f "$cache_file" ]]; then
    merged=$(jq -c --argjson f "$fields" '. + $f' "$cache_file" 2>/dev/null) || return 0
  else
    merged="$fields"
  fi
  [[ -n "$merged" ]] && printf '%s\n' "$merged" > "$cache_file"
  return 0
}

# _refresh_battery <mac> -- configured-device path: rewrite only the `battery`
# key of the existing cache so bluetooth_status.py's tooltip stays current,
# skipping the DIS walk and the menu. No-op for the mug (ember-mug.nix owns
# its cache), when there is no cache file, and when no battery reading is
# available.
_refresh_battery() {
  local mac="$1" cache_file battery updated
  [[ "$mac" == "$MUG_MAC" ]] && return 0
  cache_file="$CACHE_DIR/${mac}.json"
  [[ -f "$cache_file" ]] || return 0

  # JBL speaker: bluez exposes no Battery1, so re-poll over the Harman
  # protocol (the connect event means it's up now -- the timer often last
  # fired after it dropped) and merge the full field set, not just battery.
  if _is_jbl "$mac"; then
    _jbl_poll_throttled
    _jbl_merge "$mac"
    return 0
  fi

  battery=$(_battery_field "$mac")
  [[ -n "$battery" ]] || return 0
  updated=$(jq --arg v "$battery" '.battery = $v' "$cache_file" 2>/dev/null) || return 0
  [[ -n "$updated" ]] || return 0
  printf '%s\n' "$updated" > "$cache_file"
}

# probe_cmd <mac> -- classify + gather whatever's available, write the
# cache, and report (via stdout: 1/0) whether this is the device's
# first-ever probe (no prefs file yet).
probe_cmd() {
  local mac="$1" force="${2:-}" type fields_json first=0 battery
  local pt_ok=0 prefs_exists=0
  _is_paired_trusted "$mac" && pt_ok=1
  [[ -f "$PREFS_DIR/$mac" ]] && prefs_exists=1
  local decision
  decision=$(_probe_decision "$force" "$pt_ok" "$prefs_exists")
  if [[ "$decision" == "skip" ]]; then
    echo 0
    return
  fi
  if [[ "$decision" == "refresh" ]]; then
    _refresh_battery "$mac"
    echo 0
    return
  fi

  type=$(bt-classify type "$mac")

  if [[ "$mac" == "$MUG_MAC" ]]; then
    # Don't trust whatever ember-mug-poll.timer's independent 60s cycle last
    # wrote -- the mug's BLE connection is short-lived (bluetoothd logs
    # repeated "No route to host" reconnect failures), so the timer's next
    # fire routinely lands after the mug has already dropped again. Force a
    # fresh read right now, while we know it's actually connected.
    ember-mug-poll "$mac" 2>/dev/null || true
    fields_json=$(_mug_fields_from_cache)
  elif _is_jbl "$mac"; then
    # Fresh read while we know it's connected -- the timer routinely last
    # fired after the speaker dropped its BLE link. _jbl_merge is the sole
    # writer of the JBL field set; read it back so the common tail's rewrite
    # is a no-op, and fall through to a bare {type} when the poll produced
    # nothing usable.
    _jbl_poll_throttled
    _jbl_merge "$mac"
    if [[ -f "$CACHE_DIR/${mac}.json" ]]; then
      fields_json=$(cat "$CACHE_DIR/${mac}.json")
    else
      fields_json="{}"
    fi
  else
    fields_json=$(_probe_dis_fields "$mac")
    battery=$(_battery_field "$mac")
    [[ -n "$battery" ]] && fields_json=$(jq --arg v "$battery" '. + {battery: $v}' <<<"$fields_json")
  fi
  fields_json=$(jq --arg t "$type" '. + {type: $t}' <<<"$fields_json")

  mkdir -p "$CACHE_DIR" "$PREFS_DIR"
  echo "$fields_json" > "$CACHE_DIR/${mac}.json"

  [[ -f "$PREFS_DIR/$mac" ]] || first=1
  echo "$first"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    probe)
      if [[ "${2:-}" == "--force" ]]; then
        probe_cmd "${3:?mac required}" force
      else
        probe_cmd "${2:?mac required}"
      fi
      ;;
    # Battery-only cache update, no connect-state gate and no menu, ever.
    # `_refresh_battery` itself no-ops unless a cache file already exists, so
    # this only ever touches devices that have been probed at least once.
    refresh-battery) _refresh_battery "${2:?mac required}" ;;
    # Merge jbl-speaker-poll's full field set into the render cache. Invoked by
    # jbl-speaker-poll.timer's ExecStartPost; no connect-state or prefs gate.
    jbl-merge) _jbl_merge "${2:?mac required}" ;;
    *) echo "usage: bt-device-probe.sh {probe [--force]|refresh-battery|jbl-merge} <mac>" >&2; exit 1 ;;
  esac
fi
