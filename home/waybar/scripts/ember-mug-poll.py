#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_MAC = "00:00:00:00:00:01"
# python-ember-mug only exposes the "name" attribute once it has resolved a
# concrete DeviceModel for the mug, which needs the model number from a scan
# advertisement -- a direct `-m <mac>` connect (no discovery step) never
# populates that, so model stays unknown and the library raises
# NotImplementedError ("The mug does not have the name attribute") on every
# single request, aborting the whole batch read (confirmed live: dropping
# just this one attribute from the request, every other field succeeds
# cleanly). The mug's name is static and already known, so read it directly
# instead of over BLE.
MUG_NAME = "Work Mug"
CACHE_PATH = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "waybar" / "ember-mug" / "status.json"


def parse_get_output(raw):
    """Parse `ember-mug get --imperial -r battery current-temp target-temp
    led-colour liquid-state meta firmware` output (one line per attribute, in
    that order) into a dict. meta/firmware are read defensively -- a short
    reply (fewer than 7 lines) must not sacrifice the core 5 fields that used
    to be all this parsed."""
    lines = raw.strip("\n").split("\n")
    battery_raw, temp_raw, target_temp_raw, led_raw, liquid_raw = lines[:5]
    pct_str, _, status = battery_raw.partition(",")
    result = {
        "battery_pct": float(pct_str.strip().rstrip("%")),
        "charging": status.strip() == "on charging base",
        "current_temp": float(temp_raw.strip()),
        "target_temp": float(target_temp_raw.strip()),
        "led_colour": led_raw.strip(),
        "name": MUG_NAME,
        "liquid_state": liquid_raw.strip(),
        "serial_number": "",
        "firmware_version": "",
    }
    extra = lines[5:7]
    if len(extra) >= 1:
        _, _, serial = extra[0].partition("Serial Number:")
        result["serial_number"] = serial.strip()
    if len(extra) >= 2:
        version, _, _ = extra[1].partition(",")
        _, _, version = version.partition("Version:")
        result["firmware_version"] = version.strip()
    return result


# Observed live: a real connect+read (5 attributes) typically takes ~9.7-9.8s
# -- right at the edge of a 10s timeout, so normal jitter (D-Bus latency, BLE
# handshake variance) intermittently timed this out even on a fully
# reachable, already-connected mug. 20s gives real margin; two more
# attributes (meta, firmware) add more read round-trips, not less margin.
def fetch_fields(mac, timeout=20):
    try:
        result = subprocess.run(
            ["ember-mug", "get", "-m", mac, "--imperial", "-r", "battery",
             "current-temp", "target-temp", "led-colour", "liquid-state",
             "meta", "firmware"],
            capture_output=True, text=True, timeout=timeout, check=True,
        )
        return parse_get_output(result.stdout)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError, IndexError):
        return None


def write_cache(fields, path=CACHE_PATH, now=None):
    """Write the poll result to the cache, atomically (tmp file + rename) so
    a concurrent reader never sees a half-written file."""
    now = time.time() if now is None else now
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"ok": fields is not None, "fetched_at": now}
    if fields is not None:
        payload.update(fields)
    tmp = path.with_suffix(f".json.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(payload))
    tmp.replace(path)


def main():
    mac = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MAC
    fields = fetch_fields(mac)
    write_cache(fields)


if __name__ == "__main__":
    main()
