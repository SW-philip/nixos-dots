#!/usr/bin/env python3
"""Waybar volume module, streaming.

  volume.py stream        one JSON line per change (waybar exec, no interval)
  volume.py [show]        print one JSON line
  volume.py up|down|toggle  adjust the default sink; the stream sees PipeWire's
                            own event, so nothing needs to signal waybar

Replaces volume.sh + volume_watch.sh. One `pw-dump -m` feed tells us about sink
volume/mute changes from any source (media keys, pavucontrol, a Bluetooth
remote), so there is no per-change pw-dump/jq/dbus-send fan-out.
"""
from __future__ import annotations

import json
import os
import random
import re
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

from waybar_palette import Palette

SNARK_FILE = Path.home() / ".config/waybar/snark.json"
GLYPH = "󰕾"
CODECS = {0: "SBC", 2: "AAC", 4: "aptX"}
BT_PROBE_EVERY = 10.0  # BlueZ transport state has no PipeWire event; re-ask this often
BT_MAC_RE = re.compile(r"^bluez_output\.([0-9A-Fa-f]{2}(?:_[0-9A-Fa-f]{2}){5})")


def run(*cmd: str, timeout: float = 2.0) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


# ── PipeWire graph ────────────────────────────────────────────

class Graph:
    """Audio sinks seen on the PipeWire graph, kept current from pw-dump -m."""

    def __init__(self) -> None:
        self.sinks: dict[int, dict] = {}

    def feed(self, objs: list) -> bool:
        """Apply one pw-dump array; True if anything volume-relevant moved."""
        relevant = False
        for o in objs:
            oid = o.get("id")
            info = o.get("info")
            props = (info or {}).get("props") or {}
            if "info" in o and info is None:
                relevant |= self.sinks.pop(oid, None) is not None
            elif props.get("media.class") == "Audio/Sink":
                self.sinks[oid] = {"name": props.get("node.name", ""),
                                   "desc": props.get("node.description", "")}
                relevant = True
            elif oid in self.sinks or str(o.get("type", "")).endswith("Metadata"):
                relevant = True  # sink Props changed, or the default sink moved
        return relevant

    def best_sink(self) -> tuple[str, str | None]:
        """-> (wpctl target, bluez device path or None). A Bluetooth sink wins
        over the default (a JBL-ish one over any other); else the default sink."""
        bt = sorted((i, s) for i, s in self.sinks.items() if s["name"].startswith("bluez_output"))
        if not bt:
            return "@DEFAULT_AUDIO_SINK@", None
        pick = next((x for x in bt if "jbl" in (x[1]["desc"] + x[1]["name"]).lower()), bt[0])
        m = BT_MAC_RE.match(pick[1]["name"])
        return str(pick[0]), (f"/org/bluez/hci0/dev_{m.group(1)}" if m else None)


def read_volume(sink: str) -> tuple[int, bool]:
    raw = run("wpctl", "get-volume", sink)
    m = re.search(r"Volume:\s*([\d.]+)", raw)
    vol = min(int(float(m.group(1)) * 100), 100) if m else 0
    return vol, "[MUTED]" in raw


def bt_info(dev: str | None) -> tuple[str, str, str] | None:
    """-> (alias, transport state, codec name) for a connected device, else None."""
    if not dev:
        return None
    try:
        objs = json.loads(run("busctl", "--json=short", "call", "org.bluez", "/",
                              "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"))["data"][0]
        d = objs[dev]["org.bluez.Device1"]
        if not d["Connected"]["data"]:
            return None
    except (ValueError, KeyError, IndexError):
        return None
    state, codec = "connected", ""
    for path, ifaces in objs.items():
        t = ifaces.get("org.bluez.MediaTransport1")
        if t and path.startswith(dev + "/"):
            state = t["State"]["data"]
            codec = CODECS.get(t["Codec"]["data"], "BT")
            break
    return d["Alias"]["data"], state, codec


# ── Rendering ─────────────────────────────────────────────────

class Renderer:
    def __init__(self) -> None:
        self.palette = Palette()
        self._snark_bucket = ""
        self._snark = "Volume exists."

    def snark(self, bucket: str) -> str:
        # Re-roll only when the bucket changes, not on every heartbeat refresh.
        if bucket != self._snark_bucket:
            self._snark_bucket = bucket
            try:
                pool = json.loads(SNARK_FILE.read_text()).get("volume", {}).get(bucket) or []
            except (OSError, ValueError, AttributeError):
                pool = []
            self._snark = random.choice(pool) if pool else "Volume exists."
        return self._snark

    def frame(self, vol: int, muted: bool, bt: tuple[str, str, str] | None) -> dict:
        p = self.palette.get()
        if muted or vol == 0:
            bucket, cls = "mute", "muted"
        else:
            bucket = "low" if vol < 30 else "medium" if vol < 70 else "high" if vol < 100 else "full"
            cls = bucket
        color = {"mute": p["BAR"], "low": p["FIFTH"], "medium": p["SCORE"],
                 "high": p["PIANO"], "full": p["FORTE"]}[bucket]
        rule = f"<span foreground='{p['REST']}'>────────────────────</span>"
        lines = [f"<span foreground='{p['REST']}'>Volume:</span> <span foreground='{color}'>{vol}%</span>"]
        if bt:
            alias, state, codec = bt
            codec_span = (f"<span foreground='{p['REST']}'> · </span>"
                          f"<span foreground='{p['SEVENTH']}'>{codec}</span>") if codec else ""
            lines.append(f"<span foreground='{p['SOTTO']}'>󰓃 {alias}</span>  "
                         f"<span foreground='{p['FIFTH']}'>{state}</span>{codec_span}")
        lines += [rule, f"<span foreground='{p['ROOT']}'>{self.snark(bucket)}</span>"]
        return {"text": f"{GLYPH} {vol}%", "tooltip": "\n".join(lines),
                "class": [cls, f"vol-{vol // 5 * 5}"]}


def emit(frame: dict) -> None:
    print(json.dumps(frame, ensure_ascii=False), flush=True)


def render_now(graph: Graph, r: Renderer) -> dict:
    sink, dev = graph.best_sink()
    vol, muted = read_volume(sink)
    return r.frame(vol, muted, bt_info(dev))


# ── Commands ──────────────────────────────────────────────────

def stream() -> int:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    graph, r = Graph(), Renderer()
    proc = subprocess.Popen(["pw-dump", "-m", "-N"], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=False)
    fd, buf, dec = proc.stdout.fileno(), "", json.JSONDecoder()
    dirty, last, last_bt = True, None, 0.0
    try:
        while True:
            ready, _, _ = select.select([fd], [], [], 0.05 if dirty else 2.0)
            if ready:
                chunk = os.read(fd, 1 << 16)
                if not chunk:
                    return 1  # pw-dump died; restart-interval respawns us
                buf += chunk.decode("utf-8", "replace")
                while True:
                    buf = buf.lstrip()
                    if not buf:
                        break
                    try:
                        objs, end = dec.raw_decode(buf)
                    except ValueError:
                        break  # partial array; wait for more bytes
                    buf = buf[end:]
                    dirty |= graph.feed(objs)
                continue
            # Quiet for the debounce window (or the 2 s idle wake):
            now = time.monotonic()
            if graph.best_sink()[1] and now - last_bt >= BT_PROBE_EVERY:
                dirty = True
            if r.palette.changed():
                dirty = True
            if dirty:
                dirty, last_bt = False, now
                frame = render_now(graph, r)
                if frame != last:
                    emit(frame)
                    last = frame
    except BrokenPipeError:
        return 0
    finally:
        proc.terminate()


def one_shot() -> None:
    graph = Graph()
    graph.feed(json.loads(run("pw-dump", timeout=5.0) or "[]"))
    emit(render_now(graph, Renderer()))


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "show"
    if cmd == "stream":
        return stream()
    if cmd in ("up", "right"):
        run("wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "1%+")
    elif cmd in ("down", "left"):
        run("wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "1%-")
    elif cmd == "toggle":
        run("wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle")
    else:
        one_shot()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
