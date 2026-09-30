#!/usr/bin/env python3
"""Print how many fingers each touch on the touchscreen peaked at, and how long
it lasted. For checking what the gesture detector will actually see.

Run with the Type Cover detached, tap, Ctrl-C to stop.
"""
import importlib.util
import os
import struct
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "osk_gesture", Path(__file__).with_name("osk-gesture.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

path = g.find_device()
if path is None:
    raise SystemExit("no IPTSD touchscreen found")
print("reading", path, "- tap away, Ctrl-C to stop", flush=True)

fd = os.open(path, os.O_RDONLY)
down, peak, start = set(), 0, 0.0
slot = 0
while True:
    data = os.read(fd, g.EVENT_SIZE * 64)
    for off in range(0, len(data) - g.EVENT_SIZE + 1, g.EVENT_SIZE):
        sec, usec, etype, code, value = struct.unpack_from(g.EVENT_FMT, data, off)
        t = sec + usec / 1e6
        if etype != g.EV_ABS:
            continue
        if code == g.ABS_MT_SLOT:
            slot = value
        elif code == g.ABS_MT_TRACKING_ID:
            if value >= 0:
                if not down:
                    start, peak = t, 0
                down.add(slot)
                peak = max(peak, len(down))
            else:
                down.discard(slot)
                if not down:
                    print(f"peak {peak} finger(s), {int((t - start) * 1000)} ms", flush=True)
