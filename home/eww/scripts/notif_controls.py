#!/usr/bin/env python3
"""Controls tab backend for the eww notif-center. Reads the toggle/button
actions swaync's generated config already defines, so there is one list."""
import json
import os
import re
import subprocess
import sys
import time

import notif_search


def run_sh(cmd, timeout=2.0):
    try:
        done = subprocess.run(["sh", "-c", cmd], capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return done.stdout if done.returncode == 0 else ""


def load_grids(path):
    try:
        with open(path) as f:
            widgets = json.load(f).get("widget-config", {})
    except (OSError, ValueError):
        return {}
    return {k.split("#", 1)[1]: v.get("actions", [])
            for k, v in widgets.items() if k.startswith("buttons-grid#")}


def read_state(grids, runner=run_sh):
    out = {}
    for name, actions in grids.items():
        rows = []
        for i, a in enumerate(actions):
            toggle = a.get("type") == "toggle"
            on = toggle and runner(a.get("update-command", ""), timeout=2.0).strip() == "true"
            rows.append({"i": i, "label": a.get("label", ""), "toggle": toggle, "on": bool(on)})
        out[name] = rows
    return {"grids": out}


def spawn_sh(cmd, timeout=None):
    # Detached so GUI actions (theme picker) don't hold the eww click open.
    try:
        subprocess.Popen(["sh", "-c", cmd], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass
    return ""


def run_action(grids, name, idx, runner=spawn_sh):
    actions = grids.get(name, [])
    if 0 <= idx < len(actions):
        runner(actions[idx].get("command", ""), timeout=5.0)


def apply_query(state, q):
    grids = {name: [{**r, "match": notif_search.row_matches(r["label"], q)} for r in rows]
             for name, rows in state["grids"].items()}
    matches = []
    if q["terms"]:
        matches = [{"grid": name, "i": r["i"], "label": r["label"], "on": r["on"]}
                   for name, rows in grids.items() for r in rows if r["match"]]
    return {**state, "grids": grids, "focus": q["focus"], "matches": matches}


def run_first_match(grids, q, runner=spawn_sh):
    if not q["terms"]:
        return
    for actions in grids.values():
        for a in actions:
            if notif_search.row_matches(a.get("label", ""), q):
                runner(a.get("command", ""), timeout=5.0)
                return


def levels():
    vol, muted = 0, False
    m = re.search(r"([\d.]+)(\s+\[MUTED\])?", run_sh("wpctl get-volume @DEFAULT_AUDIO_SINK@"))
    if m:
        vol, muted = round(float(m.group(1)) * 100), bool(m.group(2))
    bright = 0
    m = re.search(r",(\d+)%", run_sh("brightnessctl -m"))
    if m:
        bright = int(m.group(1))
    return {"vol": vol, "muted": muted, "bright": bright}


def pct(arg):
    return max(0, min(100, round(float(arg))))


def set_level(kind, arg, runner=run_sh, current=levels):
    # eww fires :onchange on programmatic updates too; skip no-op writes so a fresh state doesn't fight a drag.
    want = pct(arg)
    if kind == "bright":
        want = max(1, want)
    if current()[kind] == want:
        return
    if kind == "vol":
        runner(f"wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ {want}%")
    else:
        runner(f"brightnessctl set {want}%")


class Snapshot:
    """Toggle/level state cached between refreshes: a search-query change re-flags the
    cache (line) instead of re-running every status command (full)."""

    def __init__(self, path):
        self.path = path
        self.base = None
        self.lv = None

    def refresh(self):
        self.base = read_state(load_grids(self.path))
        self.lv = levels()

    def line(self):
        if self.base is None:
            self.refresh()
        q = notif_search.parse_query(notif_search.read_query())
        return json.dumps({**apply_query(self.base, q), **self.lv})

    def full(self):
        self.refresh()
        return self.line()


def full_state(path):
    return Snapshot(path).full()


def feed(state, exists, now, sleep, interval=5.0, query=lambda: "", tick=1.0, rerender=None, prime=False):
    """Yield a state line when the panel flag appears, then every `interval`
    seconds while it stays; a search-query change yields `rerender()` (cached
    state, default `state()`). `prime` yields one state at start so the eww
    variables are never zeros on the first open. Idle (one exists() call per
    tick) otherwise."""
    last = None
    last_q = query()
    if prime:
        yield state()
    while True:
        if exists():
            t = now()
            q = query()
            if last is None or t - last >= interval:
                last, last_q = t, q
                yield state()
            elif q != last_q:
                last_q = q
                yield (rerender or state)()
        else:
            last = None
        sleep(tick)


def main(argv):
    path = os.environ.get("NOTIF_SWAYNC_CONFIG", "")
    cmd = argv[1] if len(argv) > 1 else "state"
    if cmd == "state":
        print(full_state(path), flush=True)
    elif cmd == "feed":
        flag = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "notif-center-open")
        snap = Snapshot(path)
        for line in feed(snap.full, lambda: os.path.exists(flag), time.monotonic, time.sleep,
                         query=notif_search.read_query, tick=0.25, rerender=snap.line, prime=True):
            print(line, flush=True)
    elif cmd == "act" and len(argv) == 4:
        run_action(load_grids(path), argv[2], int(argv[3]))
    elif cmd in ("vol", "bright") and len(argv) == 3:
        set_level(cmd, argv[2])
    elif cmd == "enter":
        run_first_match(load_grids(path), notif_search.parse_query(notif_search.read_query()))
    else:
        sys.exit("usage: notif_controls.py state | feed | act GRID IDX | vol N | bright N | enter")


if __name__ == "__main__":
    main(sys.argv)
