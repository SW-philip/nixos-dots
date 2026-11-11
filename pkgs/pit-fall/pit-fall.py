#!/usr/bin/env python3
"""Animated overview pit: the static wallpaper-pit.png plus the loose shards
pit_bg.py left out of it (wallpaper-pit.json), which crack, tumble off the
crumbling edge, and later fade back in, while dust drifts down.

One layer-shell BACKGROUND surface per monitor in the `wallpaper` namespace,
so niri's place-within-backdrop rule pins it exactly as it did swaybg. niri keeps
frame callbacks flowing to the backdrop even when nothing shows it, so the
animation runs only while niri's event stream reports the overview open;
otherwise the surfaces sit on their last frame and cost nothing.

  pit-fall [png] [json]     defaults: ~/.local/state/wallpaper-pit.{png,json}
"""
import json
import math
import random
import sys
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Gsk", "4.0")
gi.require_version("Graphene", "1.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gdk, Gio, GLib, GLibUnix, Graphene, Gsk, Gtk
from gi.repository import Gtk4LayerShell as LS

STATE = Path.home() / ".local/state"
FPS = 30
GRAVITY = 260.0  # px/s² in the 1920-wide design space
DUST = 140


def rgba(hexcol, alpha):
    c = Gdk.RGBA()
    c.parse(hexcol)
    c.alpha = max(0.0, min(1.0, alpha))
    return c


# Graphene.Rect().init(...) hands back a pointer into the temporary, which Python
# frees at once: GTK then reads garbage bounds and draws nothing. Keep the object.
def rect(x, y, w, h):
    r = Graphene.Rect()
    r.init(x, y, w, h)
    return r


def point(x, y):
    p = Graphene.Point()
    p.init(x, y)
    return p


def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


class Shard:
    def __init__(self, spec, rng):
        self.s = spec
        self.rng = rng
        self.cx = spec["x"] + spec["w"] / 2
        self.cy = spec["y"] + spec["h"] / 2
        self.rest(fresh=True)

    def rest(self, fresh=False):
        self.state = "rest"
        self.dx = self.dy = self.drot = 0.0
        self.alpha = 1.0
        # more decayed pieces hold on for less time
        hold = self.rng.uniform(6, 50) * (1.3 - self.s["d"])
        self.t = hold * (self.rng.random() if fresh else 1)

    def step(self, dt):
        self.t -= dt
        st = self.state
        if st == "rest" and self.t <= 0:
            self.state, self.t = "crack", self.rng.uniform(0.4, 0.9)
        elif st == "crack":
            # a few small jolts before it lets go
            self.drot = math.sin(self.t * 60) * 1.2
            if self.t <= 0:
                ox, oy = self.cx - 960, self.cy - 540
                n = math.hypot(ox, oy) or 1
                kick = self.rng.uniform(8, 40)
                self.vx = ox / n * kick + self.rng.uniform(-12, 12)
                self.vy = oy / n * kick * 0.5 + self.rng.uniform(-20, 5)
                self.vr = self.rng.uniform(-90, 90)
                self.state, self.t = "fall", self.rng.uniform(2.5, 5.0)
                self.life = self.t
        elif st == "fall":
            self.vy += GRAVITY * dt
            self.vx *= 1 - 0.3 * dt
            self.dx += self.vx * dt
            self.dy += self.vy * dt
            self.drot += self.vr * dt
            self.alpha = smooth(self.t / self.life * 1.6)
            if self.t <= 0:
                self.state, self.t = "gone", self.rng.uniform(4, 18)
                self.alpha = 0.0
        elif st == "gone" and self.t <= 0:
            self.dx = self.dy = self.drot = 0.0
            self.state, self.t = "regrow", self.rng.uniform(1.2, 2.5)
            self.life = self.t
        elif st == "regrow":
            self.alpha = smooth(1 - self.t / self.life)
            if self.t <= 0:
                self.rest()

    def draw(self, snap):
        if self.alpha <= 0.003:
            return
        s = self.s
        snap.save()
        snap.translate(point(s["tx"] + self.cx + self.dx, s["ty"] + self.cy + self.dy))
        snap.rotate(s["rot"] + self.drot)
        r = rect(-s["w"] / 2, -s["h"] / 2, s["w"], s["h"])
        if s["fill"]:
            snap.append_color(rgba(s["fill"], s["fop"] * self.alpha), r)
        rr = Gsk.RoundedRect()
        rr.init_from_rect(r, 0)
        c = rgba(s["stroke"], s["sop"] * self.alpha)
        snap.append_border(rr, [s["width"]] * 4, [c] * 4)
        snap.restore()


class Speck:
    def __init__(self, sim):
        self.sim = sim
        self.spawn(initial=True)

    def spawn(self, initial=False):
        rng = self.sim.rng
        self.x, self.y = self.sim.decayed_point()
        self.size = rng.uniform(1.2, 4.0)
        self.vx = rng.uniform(-6, 6)
        self.vy = rng.uniform(14, 55)
        self.rot = rng.uniform(0, 90)
        self.vr = rng.uniform(-40, 40)
        self.col = rng.choice(self.sim.colours)
        self.peak = rng.uniform(0.12, 0.4)
        self.life = rng.uniform(4, 11)
        self.age = rng.uniform(0, self.life) if initial else 0.0

    def step(self, dt):
        self.age += dt
        if self.age >= self.life:
            self.spawn()
            return
        self.x += self.vx * dt
        self.y += self.vy * dt
        self.rot += self.vr * dt

    def draw(self, snap):
        k = self.age / self.life
        a = self.peak * smooth(k * 5) * smooth((1 - k) * 3)
        if a <= 0.003:
            return
        snap.save()
        snap.translate(point(self.x, self.y))
        snap.rotate(self.rot)
        h = self.size / 2
        snap.append_color(rgba(self.col, a), rect(-h, -h, self.size, self.size))
        snap.restore()


class Sim:
    def __init__(self, data):
        self.rng = random.Random()
        self.W, self.H = data["W"], data["H"]
        self.colours = [data["ink"]] + data["accents"]
        grid = data["decay"]
        self.gy, self.gx = len(grid), len(grid[0])
        # dust only comes from cells that are already falling apart
        self.cells = [(i, j) for j, row in enumerate(grid) for i, v in enumerate(row) if v > 0.45]
        self.weights = [grid[j][i] ** 3 for i, j in self.cells]
        self.shards = [Shard(p, self.rng) for p in data["pieces"]]
        self.dust = [Speck(self) for _ in range(DUST if self.cells else 0)]
        self.last = None

    def decayed_point(self):
        i, j = self.rng.choices(self.cells, self.weights)[0]
        cw, ch = self.W / self.gx, self.H / self.gy
        return (i + self.rng.random()) * cw, (j + self.rng.random()) * ch

    def advance(self, now):
        # clamp: after the overview has been closed a while, resume rather than jump
        dt = 0.0 if self.last is None else min(now - self.last, 0.1)
        self.last = now
        for s in self.shards:
            s.step(dt)
        for p in self.dust:
            p.step(dt)


class Pit(Gtk.Widget):
    def __init__(self, app):
        super().__init__()
        self.app = app
        self.last_frame = 0.0
        self.tick_id = 0
        self.animate(app.overview)

    def animate(self, on):
        if on and not self.tick_id:
            self.tick_id = self.add_tick_callback(self.tick)
        elif not on and self.tick_id:
            self.remove_tick_callback(self.tick_id)
            self.tick_id = 0

    def tick(self, widget, clock):
        now = clock.get_frame_time() / 1e6
        if now - self.last_frame >= 1 / FPS - 0.002:
            self.last_frame = now
            self.app.sim_at(now)
            self.queue_draw()
        return GLib.SOURCE_CONTINUE

    def do_snapshot(self, snap):
        w, h = self.get_width(), self.get_height()
        sim = self.app.sim
        k = max(w / sim.W, h / sim.H)
        ox, oy = (w - sim.W * k) / 2, (h - sim.H * k) / 2
        snap.append_texture(self.app.texture, rect(ox, oy, sim.W * k, sim.H * k))
        snap.save()
        snap.translate(point(ox, oy))
        snap.scale(k, k)
        for s in sim.shards:
            s.draw(snap)
        for p in sim.dust:
            p.draw(snap)
        snap.restore()


class App:
    def __init__(self, png, data):
        self.texture = Gdk.Texture.new_from_filename(str(png))
        self.sim = Sim(data)
        self.sim_time = None
        self.windows = {}
        self.overview = False
        self.watch_overview()
        self.display = Gdk.Display.get_default()
        self.monitors = self.display.get_monitors()
        self.monitors.connect("items-changed", lambda *_: self.sync())
        self.sync()

    def watch_overview(self):
        try:
            proc = Gio.Subprocess.new(["niri", "msg", "--json", "event-stream"],
                                      Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE)
        except GLib.Error:
            self.set_overview(True)  # no niri IPC: just animate
            return
        self.events = Gio.DataInputStream.new(proc.get_stdout_pipe())
        self.events.read_line_async(GLib.PRIORITY_DEFAULT, None, self.on_event)

    def on_event(self, stream, res):
        line, _ = stream.read_line_finish_utf8(res)
        if line is None:
            self.set_overview(True)  # stream died (niri restart): fail animated, not frozen
            return
        if '"OverviewOpenedOrClosed"' in line:
            self.set_overview(json.loads(line)["OverviewOpenedOrClosed"]["is_open"])
        stream.read_line_async(GLib.PRIORITY_DEFAULT, None, self.on_event)

    def set_overview(self, is_open):
        self.overview = is_open
        self.sim.last = None
        for win in self.windows.values():
            win.get_child().animate(is_open)

    def sim_at(self, now):
        # several monitors tick off the same clock; step the shared sim once per frame
        if self.sim_time is None or now - self.sim_time > 0.001:
            self.sim_time = now
            self.sim.advance(now)

    def sync(self):
        current = [self.monitors.get_item(i) for i in range(self.monitors.get_n_items())]
        for mon in list(self.windows):
            if mon not in current:
                self.windows.pop(mon).destroy()
        for mon in current:
            if mon not in self.windows:
                self.windows[mon] = self.make_window(mon)

    def make_window(self, mon):
        win = Gtk.Window()
        LS.init_for_window(win)
        LS.set_layer(win, LS.Layer.BACKGROUND)
        LS.set_namespace(win, "wallpaper")
        LS.set_monitor(win, mon)
        for edge in (LS.Edge.TOP, LS.Edge.BOTTOM, LS.Edge.LEFT, LS.Edge.RIGHT):
            LS.set_anchor(win, edge, True)
        LS.set_exclusive_zone(win, -1)
        LS.set_keyboard_mode(win, LS.KeyboardMode.NONE)
        win.set_child(Pit(self))
        win.present()
        return win


def main():
    png = Path(sys.argv[1]) if len(sys.argv) > 1 else STATE / "wallpaper-pit.png"
    meta = Path(sys.argv[2]) if len(sys.argv) > 2 else STATE / "wallpaper-pit.json"
    data = json.loads(meta.read_text())
    if not LS.is_supported():
        sys.exit("pit-fall: compositor lacks wlr-layer-shell")
    Gtk.init()
    _app = App(png, data)  # held for the life of the loop
    loop = GLib.MainLoop()
    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, 15, loop.quit)
    loop.run()


if __name__ == "__main__":
    main()
