#!/usr/bin/env python3
"""In portrait, open new tiled windows under the previous one instead of as a
new tall column, two per column. niri has no such layout option, so this
watches the event stream and moves a freshly opened window into the column on
its left.

usage: niri-portrait-stack.py [output]   (default eDP-1)
"""
import json
import subprocess
import sys
import time

MAX_PER_COLUMN = 2
SETTLE_SECONDS = 0.15


def is_portrait(transform):
    return transform.endswith(("90", "270"))


def _pos(window):
    return (window.get("layout") or {}).get("pos_in_scrolling_layout")


def should_stack(windows, new_id, max_per_column=MAX_PER_COLUMN):
    new = next((w for w in windows if w["id"] == new_id), None)
    if new is None or new.get("is_floating") or _pos(new) is None:
        return False
    col, row = _pos(new)
    if row != 1 or col <= 1:
        return False
    left = sum(1 for w in windows
               if w.get("workspace_id") == new.get("workspace_id")
               and not w.get("is_floating")
               and _pos(w) is not None and _pos(w)[0] == col - 1)
    return 0 < left < max_per_column


def niri_json(*args):
    out = subprocess.run(["niri", "msg", "--json", *args],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def portrait_now(output):
    try:
        return is_portrait(niri_json("outputs")[output]["logical"]["transform"])
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def stack(window_id):
    subprocess.run(["niri", "msg", "action", "consume-or-expel-window-left",
                    "--id", str(window_id)], capture_output=True, check=False)


def main(output):
    known = set()
    stream = subprocess.Popen(["niri", "msg", "--json", "event-stream"],
                              stdout=subprocess.PIPE, text=True)
    for line in stream.stdout:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if "WindowsChanged" in event:
            known = {w["id"] for w in event["WindowsChanged"]["windows"]}
        elif "WindowClosed" in event:
            known.discard(event["WindowClosed"]["id"])
        elif "WindowOpenedOrChanged" in event:
            wid = event["WindowOpenedOrChanged"]["window"]["id"]
            if wid in known:
                continue
            known.add(wid)
            time.sleep(SETTLE_SECONDS)
            try:
                if portrait_now(output) and should_stack(niri_json("windows"), wid):
                    stack(wid)
            except (OSError, subprocess.CalledProcessError, ValueError):
                continue
    return 1  # event-stream ended (niri restarted); systemd restarts us


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "eDP-1"))
