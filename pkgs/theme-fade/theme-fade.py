#!/usr/bin/env python3
"""Fade-to-black over a display change, so it reads as the screen powering off and on.

`theme-fade daemon` stays resident (GTK4 start-up costs over a second, far too
slow to spawn per fade). `out` signals it to fade a layer-shell overlay in and
`in` to fade it out; exclusive zone -1 puts it over waybar, which eww can't do.
Each command returns once its fade has finished painting. A watchdog fades back
out if `in` never arrives.
"""
import os
import signal
import sys
import time
from pathlib import Path

RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
PID_FILE = RUNTIME / "theme-fade.pid"
STATE_FILE = RUNTIME / "theme-fade.state"
DURATION = float(os.environ.get("THEME_FADE_MS", "450")) / 1000
# dark beat between the change and the fade back up: the "screen off" moment
HOLD = float(os.environ.get("THEME_FADE_HOLD_MS", "250")) / 1000
WATCHDOG = float(os.environ.get("THEME_FADE_WATCHDOG", "8"))


def daemon():
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    gi.require_version("Gtk4LayerShell", "1.0")
    from gi.repository import Gdk, GLib, GLibUnix, Gtk, Gtk4LayerShell as LS

    wins = []
    # t0 None = clock starts on the next painted frame: a new layer surface takes a
    # few hundred ms to map, and starting at the signal would spend the fade unseen
    st = {"target": 0.0, "from": 0.0, "t0": None, "wd": 0, "hold": 0, "done": False}
    css = Gtk.CssProvider()

    def opacity():
        if st["t0"] is None:
            return st["from"], 0.0
        k = min(1.0, (time.monotonic() - st["t0"]) / DURATION)
        e = k * k * (3 - 2 * k)
        return st["from"] + (st["target"] - st["from"]) * e, k

    def tick(widget, clock):
        if st["t0"] is None:
            st["t0"] = time.monotonic()
        op, k = opacity()
        for w in wins:
            w.set_opacity(max(op, 0.01))
        if k >= 1.0 and not st["done"]:
            st["done"] = True
            STATE_FILE.write_text("black" if st["target"] else "clear")
            if st["target"] == 0.0:
                hide()
                return GLib.SOURCE_REMOVE
        return GLib.SOURCE_CONTINUE

    def hide():
        for w in wins:
            w.destroy()
        wins.clear()

    def retarget(t):
        st["from"], _ = opacity() if wins else (0.0, 1.0)
        st["target"], st["t0"], st["done"] = t, None, False
        STATE_FILE.write_text("fading")

    def show():
        if wins:
            return
        mons = Gdk.Display.get_default().get_monitors()
        for i in range(mons.get_n_items()):
            w = Gtk.Window(application=app)
            w.add_css_class("fade")
            w.set_child(Gtk.Box())
            w.set_opacity(0.01)
            LS.init_for_window(w)
            LS.set_layer(w, LS.Layer.OVERLAY)
            LS.set_monitor(w, mons.get_item(i))
            for edge in (LS.Edge.TOP, LS.Edge.BOTTOM, LS.Edge.LEFT, LS.Edge.RIGHT):
                LS.set_anchor(w, edge, True)
            LS.set_exclusive_zone(w, -1)
            LS.set_keyboard_mode(w, LS.KeyboardMode.NONE)
            w.present()
            wins.append(w)
        wins[0].add_tick_callback(tick)

    def cancel_hold():
        if st["hold"]:
            GLib.source_remove(st["hold"])
            st["hold"] = 0

    def lift():
        st["hold"] = 0
        retarget(0.0)
        return GLib.SOURCE_REMOVE

    def fade_out():
        if not wins:
            STATE_FILE.write_text("clear")
            return GLib.SOURCE_REMOVE
        if st["wd"]:
            GLib.source_remove(st["wd"])
            st["wd"] = 0
        cancel_hold()
        STATE_FILE.write_text("fading")
        st["hold"] = GLib.timeout_add(int(HOLD * 1000), lift)
        return GLib.SOURCE_REMOVE

    def fade_in():
        cancel_hold()
        show()
        retarget(1.0)
        if st["wd"]:
            GLib.source_remove(st["wd"])
        st["wd"] = GLib.timeout_add(int(WATCHDOG * 1000), lambda: (st.update(wd=0), fade_out(), False)[2])
        return GLib.SOURCE_REMOVE

    def startup(a):
        # black, not a palette colour: the overlay stands in for the panel going dark
        css.load_from_string("window.fade { background-color: black; }")
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_USER)
        a.hold()
        # a handler returning SOURCE_REMOVE is uninstalled after one delivery, and the
        # next SIGUSR1 then hits the default action and kills the daemon (every other fade)
        GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, lambda: (fade_in(), GLib.SOURCE_CONTINUE)[1])
        GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR2, lambda: (fade_out(), GLib.SOURCE_CONTINUE)[1])
        PID_FILE.write_text(str(os.getpid()))

    app = Gtk.Application(application_id="local.theme-fade")
    app.connect("startup", startup)
    app.connect("activate", lambda a: None)
    app.run([])


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "daemon":
        daemon()
        return 0
    if cmd not in ("out", "in"):
        print("usage: theme-fade daemon|out|in", file=sys.stderr)
        return 2
    want = "black" if cmd == "out" else "clear"
    try:
        STATE_FILE.write_text("fading")
        os.kill(int(PID_FILE.read_text()), signal.SIGUSR1 if cmd == "out" else signal.SIGUSR2)
    except (OSError, ValueError):
        return 0
    deadline = time.monotonic() + HOLD + DURATION + 1.0
    while time.monotonic() < deadline:
        try:
            if STATE_FILE.read_text() == want:
                break
        except OSError:
            break
        time.sleep(0.02)
    return 0


if __name__ == "__main__":
    sys.exit(main())
