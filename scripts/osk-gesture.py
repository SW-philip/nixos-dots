#!/usr/bin/env python3
"""Touchscreen taps: three fingers toggles the on-screen keyboard, four fingers
asks to leave Pegasus.

Passive: reads the touchscreen's evdev node without grabbing it, so touches
still reach the compositor. Meant to run only while squeekboard is up (it is
bound to squeekboard.service in profiles/surface-tablet.nix).

usage: osk-gesture.py <path-to-toggle-osk> <path-to-pegasus-exit>
"""
import glob
import os
import struct
import subprocess
import sys
import time

EV_ABS = 3
ABS_MT_SLOT, ABS_MT_TRACKING_ID, ABS_MT_X, ABS_MT_Y = 0x2F, 0x39, 0x35, 0x36
EVENT_FMT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)
DEVICE_NAME = "IPTSD Virtual Touchscreen"
FINGERS = 3
EXIT_FINGERS = 4
MAX_TAP_SECONDS = 0.35
# Raw touch units: deliberate taps drift ~150, a swipe moves far more.
MAX_TRAVEL = 600


class TapDetector:
    """feed() returns True once, on the release that ends a qualifying tap."""

    def __init__(self, fingers=FINGERS, max_seconds=MAX_TAP_SECONDS,
                 max_travel=MAX_TRAVEL):
        self.fingers = fingers
        self.max_seconds = max_seconds
        self.max_travel = max_travel
        self.slot = 0
        self.down = {}  # slot -> [x0, y0]
        self.start = 0.0
        self.peak = 0
        self.moved = False

    def feed(self, etype, code, value, t):
        if etype != EV_ABS:
            return False
        if code == ABS_MT_SLOT:
            self.slot = value
        elif code == ABS_MT_TRACKING_ID:
            if value >= 0:
                if not self.down:
                    self.start, self.peak, self.moved = t, 0, False
                self.down[self.slot] = [None, None]
                self.peak = max(self.peak, len(self.down))
            else:
                self.down.pop(self.slot, None)
                if not self.down:
                    return (self.peak == self.fingers and not self.moved
                            and t - self.start <= self.max_seconds)
        elif code in (ABS_MT_X, ABS_MT_Y) and self.slot in self.down:
            origin = self.down[self.slot]
            i = 0 if code == ABS_MT_X else 1
            if origin[i] is None:
                origin[i] = value
            elif abs(value - origin[i]) > self.max_travel:
                self.moved = True
        return False


def find_device():
    for name_path in sorted(glob.glob("/sys/class/input/event*/device/name")):
        try:
            with open(name_path) as f:
                name = f.read().strip()
        except OSError:
            continue
        if name.startswith(DEVICE_NAME):
            return "/dev/input/" + name_path.split("/")[4]
    return None


def run(toggle_cmd, exit_cmd):
    while True:
        path = find_device()
        if path is None:
            time.sleep(2)
            continue
        detectors = ((TapDetector(FINGERS), toggle_cmd),
                     (TapDetector(EXIT_FINGERS), exit_cmd))
        fd = None
        try:
            fd = os.open(path, os.O_RDONLY)
            while True:
                data = os.read(fd, EVENT_SIZE * 64)
                if not data:
                    raise OSError("touchscreen node closed")
                for off in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    sec, usec, etype, code, value = struct.unpack_from(
                        EVENT_FMT, data, off)
                    for detector, cmd in detectors:
                        if detector.feed(etype, code, value, sec + usec / 1e6):
                            subprocess.run([cmd], check=False)
        except OSError:
            time.sleep(2)
        finally:
            if fd is not None:
                os.close(fd)


def parse_args(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    return argv[1], argv[2]


if __name__ == "__main__":
    run(*parse_args(sys.argv))
