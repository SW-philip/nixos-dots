#!/usr/bin/env python3
"""Let squeekboard auto-show only while a browser has focus.

Squeekboard reads screen-keyboard-enabled live from its keyfile gsettings
backend, and the setting is inverted: true = auto-show on text-field focus,
false = never auto-show (manual SetVisible still works). This follows niri's
focused window and rewrites that key. Leaving a browser also hides a keyboard
that is still up, so it doesn't linger over a terminal.

usage: osk-focus-policy.py <keyfile> <path-to-toggle-osk> <path-to-niri>
"""
import json
import subprocess
import sys

BROWSER_APP_IDS = {
    "firefox", "firefox-esr", "librewolf", "zen", "floorp",
    "chromium-browser", "google-chrome", "brave-browser",
}

KEYFILE_FMT = "[org/gnome/desktop/a11y/applications]\nscreen-keyboard-enabled=%s\n"


class FocusTracker:
    """feed() takes one niri event dict, returns the focused app-id or None."""

    def __init__(self):
        self.apps = {}
        self.focused = None

    def feed(self, event):
        if "WindowsChanged" in event:
            wins = event["WindowsChanged"]["windows"]
            self.apps = {w["id"]: w["app_id"] for w in wins}
            self.focused = next((w["id"] for w in wins if w["is_focused"]), None)
        elif "WindowOpenedOrChanged" in event:
            w = event["WindowOpenedOrChanged"]["window"]
            self.apps[w["id"]] = w["app_id"]
            if w["is_focused"]:
                self.focused = w["id"]
        elif "WindowClosed" in event:
            wid = event["WindowClosed"]["id"]
            self.apps.pop(wid, None)
            if self.focused == wid:
                self.focused = None
        elif "WindowFocusChanged" in event:
            self.focused = event["WindowFocusChanged"]["id"]
        return self.apps.get(self.focused)


def run(keyfile, toggle_osk, niri):
    tracker = FocusTracker()
    in_browser = None
    proc = subprocess.Popen([niri, "msg", "--json", "event-stream"],
                            stdout=subprocess.PIPE, text=True)
    for line in proc.stdout:
        now = tracker.feed(json.loads(line)) in BROWSER_APP_IDS
        if now == in_browser:
            continue
        # In-place write: squeekboard's keyfile monitor reacts to the close.
        with open(keyfile, "w") as f:
            f.write(KEYFILE_FMT % ("true" if now else "false"))
        if in_browser and not now:
            subprocess.run([toggle_osk, "hide"], check=False)
        in_browser = now
    sys.exit(proc.wait() or 1)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    run(*sys.argv[1:])
