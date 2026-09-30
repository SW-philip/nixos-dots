#!/usr/bin/env python3
"""Poll a JBL 'Portable'-app speaker (Go 4 / Clip 5 / Flip 6-7 / Charge 5) for
battery + status over its proprietary Harman 0xAA BLE control protocol, and
cache the result for waybar. Mirrors home/waybar/scripts/ember-mug-poll.py.

Protocol reverse-engineering: github.com/hudsonbrendon/jbl-charge5
Live capture that grounds the parser: SWjbl (JBL Go 4), 2026-08-28.
"""
import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path

# One custom GATT service, two characteristics. The Go 4 also mirrors this
# service under ...2e636e6c0000 ("cnl"); the ...636f6d ("com") copy is the one
# that answered AA 11 during the live probe.
SVC = "65786365-6c70-6f69-6e74-2e636f6d0000"
CHAR_WRITE = "65786365-6c70-6f69-6e74-2e636f6d0002"
CHAR_NOTIFY = "65786365-6c70-6f69-6e74-2e636f6d0001"
REQ_STATUS = bytes.fromhex("aa11")

HARMAN_COMPANY_ID = 0x0057

TOKEN_NAME = 0xC1
TOKEN_MODEL = 0xC2
TOKEN_BATTERY = 0x44
TOKEN_CHANNEL = 0x46
TOKEN_MAC = 0x48
TOKEN_FIRMWARE = 0x4D

CACHE = Path(
    os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))
) / "waybar" / "jbl-speaker" / "status.json"


class BluetoothUnavailable(Exception):
    """No usable adapter — rfkill-blocked, unplugged, or HCI init failed.
    Not a poll failure; the speaker just can't be reached right now."""


def parse_burst(buf: bytes) -> dict:
    """Walk concatenated `AA 12 <len> <payload>` frames. payload = 00 <token>
    <value...>, one token per frame, value = everything after the 00 <token>
    prefix. Best-effort: a short/garbled frame ends the walk, never raises."""
    out: dict = {"raw": {}}
    i = 0
    n = len(buf)
    while i + 3 <= n and buf[i] == 0xAA:
        ptype = buf[i + 1]
        ln = buf[i + 2]
        payload = buf[i + 3 : i + 3 + ln]
        if len(payload) < ln or ln < 2:
            break
        i += 3 + ln
        if ptype != 0x12:
            continue
        token = payload[1]
        value = payload[2:]
        if token in (TOKEN_NAME, TOKEN_MODEL) and value:
            slen = value[0]
            text = value[1 : 1 + slen].decode("utf-8", "replace")
            out["name" if token == TOKEN_NAME else "model"] = text
        elif token == TOKEN_BATTERY and value:
            # bit 7 of the battery byte = charging; low 7 bits = percent
            out["battery_pct"] = value[0] & 0x7F
            out["charging"] = bool(value[0] & 0x80)
        elif token == TOKEN_CHANNEL and value:
            out["channel"] = value[0]
        elif token == TOKEN_MAC and len(value) >= 6:
            out["mac"] = ":".join(f"{b:02X}" for b in value[:6])
        elif token == TOKEN_FIRMWARE and value:
            out["firmware"] = value.decode("ascii", "replace").strip("\x00").strip()
        else:
            out["raw"][f"{token:02x}"] = value.hex()
    return out


def hexdump_frames(buf: bytes) -> str:
    """One `AA 12 <len> …` frame per line, as space-separated hex. Trailing
    bytes that don't form a whole frame are printed on a `trailing:` line.
    --dump only; never on the normal cache path."""
    lines = []
    i, n = 0, len(buf)
    while i + 3 <= n and buf[i] == 0xAA:
        ln = buf[i + 2]
        frame = buf[i : i + 3 + ln]
        if len(frame) < 3 + ln:
            lines.append(frame.hex(" ") + "  (truncated)")
            i = n
            break
        lines.append(frame.hex(" "))
        i += 3 + ln
    if i < n:
        lines.append("trailing: " + buf[i:].hex(" "))
    return "\n".join(lines)


_PAYLOAD_KEYS = ("battery_pct", "charging", "name", "model", "firmware", "channel", "mac")


def fields_to_payload(fields: "dict | None", now: float) -> dict:
    if fields is None:
        return {"ok": False, "ts": now}
    if fields.get("unavailable"):
        return {"ok": False, "ts": now, "error": fields["unavailable"]}
    if "battery_pct" not in fields:
        return {"ok": False, "ts": now, "error": "no battery frame in burst"}
    payload = {"ok": True, "ts": now}
    for k in _PAYLOAD_KEYS:
        if k in fields:
            payload[k] = fields[k]
    return payload


def write_cache(fields: "dict | None", path: "Path | None" = None,
                now: "float | None" = None) -> None:
    path = CACHE if path is None else path
    now = time.time() if now is None else now
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(fields_to_payload(fields, now)))
    os.replace(tmp, path)


def advert_matches(name, mfr_data, service_uuids, want_names) -> bool:
    harman = HARMAN_COMPANY_ID in (mfr_data or {})
    has_svc = any(u.lower() == SVC for u in (service_uuids or []))
    if not (harman or has_svc):
        return False
    if name is None:
        return True
    low = name.lower()
    return any(w.lower() in low for w in want_names)


async def read_status(names, scan_timeout=8.0, burst_timeout=6.0, idle_gap=1.5,
                      dump=False):
    from bleak import BleakClient, BleakScanner
    from bleak.exc import BleakError

    found = {}
    stop = asyncio.Event()

    def _cb(dev, adv):
        if not found and advert_matches(
            adv.local_name or dev.name, adv.manufacturer_data,
            list(adv.service_uuids), names,
        ):
            found["dev"] = dev
            stop.set()

    scanner = BleakScanner(detection_callback=_cb)
    try:
        await scanner.start()
    except BleakError as e:
        # "No Bluetooth adapters found" and friends: rfkill block, dongle
        # unplugged, or the controller failed HCI init. Nothing to poll.
        raise BluetoothUnavailable(str(e)) from None
    try:
        await asyncio.wait_for(stop.wait(), scan_timeout)
    except asyncio.TimeoutError:
        return None
    finally:
        await scanner.stop()
    if "dev" not in found:
        return None

    chunks = bytearray()
    last_rx = 0.0
    loop = asyncio.get_event_loop()

    def _notify(_char, data: bytearray):
        nonlocal last_rx
        chunks.extend(data)
        last_rx = loop.time()

    # The status burst arrives as ~12 separate notifications; battery is frame 5,
    # with mac/firmware/channel/charge tokens after it. Wait for the stream to go
    # quiet (idle_gap) once a battery frame has parsed, not for the first one.
    try:
        async with BleakClient(found["dev"]) as client:
            await client.start_notify(CHAR_NOTIFY, _notify)
            await client.write_gatt_char(CHAR_WRITE, REQ_STATUS, response=False)
            deadline = loop.time() + burst_timeout
            while loop.time() < deadline:
                await asyncio.sleep(0.2)
                if last_rx and loop.time() - last_rx >= idle_gap \
                        and "battery_pct" in parse_burst(bytes(chunks)):
                    break
            # No stop_notify: bleak stops notifications on context exit, and the
            # speaker often drops the link during the idle_gap wait -- an
            # explicit stop_notify there raises BleakError("Not connected").
    except Exception:
        pass  # any bleak/transport error after we already have the bytes is fine to swallow

    if not chunks:
        return None
    if dump:
        print(hexdump_frames(bytes(chunks)))
    return parse_burst(bytes(chunks))


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--names", action="append", default=None)
    ap.add_argument("--dump", action="store_true")
    ap.add_argument("--scan-timeout", type=float, default=8.0)
    ap.add_argument("--burst-timeout", type=float, default=6.0)
    args = ap.parse_args(argv)
    names = args.names or ["JBL", "SWjbl"]

    try:
        fields = asyncio.run(read_status(
            names, args.scan_timeout, args.burst_timeout, dump=args.dump))
    except BluetoothUnavailable as e:
        # Exit 0: no adapter is an expected resting state (radio off / no
        # dongle), not a failure worth a systemd unit going red every 2 min.
        if args.dump:
            print(json.dumps({"unavailable": str(e)}, indent=2, sort_keys=True))
            return 0
        write_cache({"unavailable": f"bluetooth unavailable: {e}"})
        return 0
    except Exception:
        fields = None  # scan/connect failure -> {ok:false} cache, never a traceback
    if args.dump:
        print(json.dumps(fields, indent=2, sort_keys=True))
        return 0 if fields and "battery_pct" in fields else 1

    write_cache(fields)
    return 0 if (fields and "battery_pct" in fields) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
