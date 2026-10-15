from __future__ import annotations
import json
import subprocess


def center_own_window(pid: int, run=subprocess.run) -> bool:
    """Re-centre this process's niri window. niri places a floating window once,
    at map time; the tablet CSS grows it afterwards, so it must be re-centred."""
    try:
        listed = run(["niri", "msg", "--json", "windows"],
                     capture_output=True, text=True, check=True)
        win = next((w for w in json.loads(listed.stdout) if w.get("pid") == pid), None)
        if win is None:
            return False
        run(["niri", "msg", "action", "center-window", "--id", str(win["id"])],
            capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError, ValueError):
        return False
    return True
