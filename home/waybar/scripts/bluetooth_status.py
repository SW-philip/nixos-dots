#!/usr/bin/env python3
"""Waybar Bluetooth chip, streaming.

  bluetooth_status.py stream   JSON line on every BlueZ change (waybar exec)
  bluetooth_status.py [show]   print one JSON line

Replaces the 5 s poll timer + quantum-bluetooth.sh + waybar-cache-read chain.
`gdbus monitor` is the event source (never a long-lived bluetoothctl REPL, which
caches every advertising device and balloons); one busctl GetManagedObjects call
per change gives adapter power and the connected device. Battery/type/model come
from ~/.cache/bt-device-info/<MAC>.json, written by bt-device-probe.sh, so its
mtime is watched too.
"""
from __future__ import annotations

import html
import json
import os
import random
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

from waybar_palette import Palette

ADAPTER = "/org/bluez/hci0"
INFO_DIR = Path.home() / ".cache/bt-device-info"
SNARK_FILE = Path.home() / ".config/waybar/snark.json"
ICON_OFF, ICON_ON, ICON_CONNECTED = "󰂲", "󰂯", "󰂱"
BOLT = "󰂄"
GLYPHS = {"speaker": "󰓃", "headphones": "󰋋", "headset": "󰋎", "earbuds": "󰟅",
          "gamepad": "󰊴", "phone": "󰄡", "watch": "󰖉", "keyboard": "󰌌", "mouse": "󰦋"}
FALLBACK_SNARK = {"off": "Radio silence.", "idle": "Scanning..."}
RULE = "────────────────────"
# Signals that change what we render; Battery1/MediaControl1 chatter is ignored.
WATCH = ("'org.bluez.Adapter1'", "'org.bluez.Device1'")


def busctl_objects() -> dict:
    try:
        out = subprocess.run(
            ["busctl", "--json=short", "call", "org.bluez", "/",
             "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"],
            capture_output=True, text=True, timeout=3).stdout
        return json.loads(out)["data"][0]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError):
        return {}


def snapshot(objs: dict) -> tuple[bool, tuple[str, str] | None]:
    """-> (powered, (mac, alias) of the first connected device or None)"""
    powered = bool(objs.get(ADAPTER, {}).get("org.bluez.Adapter1", {}).get("Powered", {}).get("data"))
    if not powered:
        return False, None
    for ifaces in objs.values():
        d = ifaces.get("org.bluez.Device1")
        if d and d.get("Connected", {}).get("data"):
            return True, (d["Address"]["data"], d.get("Alias", {}).get("data", ""))
    return True, None


def device_info(mac: str) -> dict:
    try:
        return json.loads((INFO_DIR / f"{mac}.json").read_text())
    except (OSError, ValueError):
        return {}


def esc(v) -> str:
    return html.escape(str(v), quote=False)


def render(powered: bool, dev: tuple[str, str] | None, info: dict, p: dict, snark) -> dict:
    """Pure: palette + state in, waybar frame out. `snark(bucket)` supplies the quip."""
    sm = lambda t: f"<span foreground='{p['REST']}' size='small'>{t}</span>"  # noqa: E731
    rule = f"<span foreground='{p['REST']}'>{RULE}</span>"
    if not powered:
        return {"text": ICON_OFF, "class": "off", "tooltip":
                f"Bluetooth <span foreground='{p['REST']}'>off</span>\n{rule}\n"
                f"<span foreground='{p['ROOT']}'>{esc(snark('off'))}</span>"}
    if dev is None:
        return {"text": ICON_ON, "class": "idle", "tooltip":
                f"Bluetooth <span foreground='{p['REST']}'>on</span> · no device\n{rule}\n"
                f"<span foreground='{p['ROOT']}'>{esc(snark('idle'))}</span>"}
    dtype = info.get("type") or ""
    battery = "" if info.get("battery") is None else str(info["battery"])
    charging = info.get("charging") is True or info.get("charging") == "true"
    model, fw = info.get("model") or "", info.get("firmware_revision") or ""
    channel = info.get("channel")
    lines = [f"<b>{esc(dev[1])}</b>"]
    if dtype:
        lines.append(sm(f"Type: {esc(dtype)}"))
    if battery:
        lines.append(sm(f"Battery: {esc(battery)}%{' (charging)' if charging else ''}"))
    if model:
        lines.append(sm(f"Model: {esc(model)}"))
    if fw:
        lines.append(sm(f"Firmware: {esc(fw)}"))
    if channel not in (None, "", 0, "0"):
        lines.append(sm(f"Channel: pair {esc(channel)}"))
    return {"text": GLYPHS.get(dtype, ICON_CONNECTED), "class": "on", "tooltip": "\n".join(lines)}


class Source:
    def __init__(self) -> None:
        self.palette = Palette()
        self._bucket, self._line = "", ""

    def snark(self, bucket: str) -> str:
        if bucket != self._bucket:  # re-roll on state change only
            self._bucket = bucket
            try:
                pool = json.loads(SNARK_FILE.read_text()).get("bluetooth", {}).get(bucket) or []
            except (OSError, ValueError, AttributeError):
                pool = []
            self._line = random.choice(pool) if pool else FALLBACK_SNARK[bucket]
        return self._line

    def frame(self) -> dict:
        powered, dev = snapshot(busctl_objects())
        info = device_info(dev[0]) if dev else {}
        return render(powered, dev, info, self.palette.get(), self.snark)


def info_mtime(mac_dir: Path = INFO_DIR) -> float:
    try:
        return max((f.stat().st_mtime for f in mac_dir.glob("*.json")), default=0.0)
    except OSError:
        return 0.0


def emit(frame: dict) -> None:
    print(json.dumps(frame, ensure_ascii=False), flush=True)


def stream() -> int:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    src = Source()
    proc = subprocess.Popen(["gdbus", "monitor", "--system", "--dest", "org.bluez"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=False)
    fd, buf, last, dirty, seen = proc.stdout.fileno(), b"", None, True, info_mtime()
    try:
        while True:
            ready, _, _ = select.select([fd], [], [], 0.1 if dirty else 2.0)
            if ready:
                chunk = os.read(fd, 1 << 16)
                if not chunk:
                    return 1  # bluetoothd restarted; restart-interval respawns us
                buf += chunk
                *lines, buf = buf.split(b"\n")
                for ln in lines:
                    s = ln.decode("utf-8", "replace")
                    if any(w in s for w in WATCH) and ("'Powered'" in s or "'Connected'" in s
                                                     or "InterfacesAdded" in s or "InterfacesRemoved" in s):
                        dirty = True
                continue
            # quiet: debounce window elapsed, or the 2 s idle wake
            m = info_mtime()
            if m != seen or src.palette.changed():
                seen, dirty = m, True
            if dirty:
                dirty = False
                frame = src.frame()
                if frame != last:
                    emit(frame)
                    last = frame
    except BrokenPipeError:
        return 0
    finally:
        proc.terminate()


def main(argv: list[str]) -> int:
    if len(argv) > 1 and argv[1] == "stream":
        return stream()
    emit(Source().frame())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
