from __future__ import annotations
import json
import subprocess


def resize_own_window(pid: int, width: int, run=subprocess.run) -> bool:
    """Set this process's floating niri window to a fixed logical width. niri grows a
    floating window to fit new minimum-size hints but never shrinks it, so both the
    channels pane opening and closing set the width explicitly."""
    try:
        listed = run(["niri", "msg", "--json", "windows"],
                     capture_output=True, text=True, check=True)
        win = next((w for w in json.loads(listed.stdout) if w.get("pid") == pid), None)
        if win is None:
            return False
        run(["niri", "msg", "action", "set-window-width", "--id", str(win["id"]), str(int(width))],
            capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError, ValueError):
        return False
    return True
