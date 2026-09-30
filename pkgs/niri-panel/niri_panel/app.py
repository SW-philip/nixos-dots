import threading

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk, GLib  # noqa: E402

from niri_panel import drmis, niri  # noqa: E402


class PanelWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Display & Theme",
                         default_width=460, default_height=640)
        self._baseline = {}          # name -> dict of applied values at open
        self._outputs = {}

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        revert_btn = Gtk.Button(label="Revert")
        revert_btn.connect("clicked", lambda *_: self._revert())
        header.pack_start(revert_btn)
        toolbar.add_top_bar(header)

        self._page = Adw.PreferencesPage()
        toolbar.set_content(self._page)
        self.set_content(toolbar)

        self._display_group = Adw.PreferencesGroup(title="Displays")
        self._page.add(self._display_group)

        self._build_displays()

        self._theme_group = Adw.PreferencesGroup(title="Theme")
        self._page.add(self._theme_group)

        themes = drmis.list_themes()
        self._theme_slugs = [t["slug"] for t in themes]
        labels = [f"{t['slug']} — {t['family']}" for t in themes]
        cur_idx = next((i for i, t in enumerate(themes) if t["current"]), 0)

        combo = Adw.ComboRow(title="Active theme",
                             model=Gtk.StringList.new(labels))
        combo.set_enable_search(True)
        combo.set_selected(cur_idx)
        self._theme_spinner = Gtk.Spinner()
        combo.add_suffix(self._theme_spinner)

        def on_theme(w, *_):
            slug = self._theme_slugs[w.get_selected()]
            self._theme_spinner.start()
            def work():
                try:
                    drmis.set_theme(slug)
                finally:
                    GLib.idle_add(self._theme_spinner.stop)
            threading.Thread(target=work, daemon=True).start()

        combo.connect("notify::selected", on_theme)
        self._theme_group.add(combo)

    # ---- displays ----
    def _build_displays(self):
        self._outputs = niri.list_outputs()
        self._baseline = {
            name: {
                "enabled": o.enabled,
                "mode": (niri.mode_str(o.modes[o.current_mode_idx])
                         if o.current_mode_idx is not None and o.modes else None),
                "scale": o.scale,
                "transform": o.transform.lower(),
                "vrr": o.vrr_enabled,
                "pos": o.pos,
            }
            for name, o in self._outputs.items()
        }
        primary = self._primary_name()
        for name, o in self._outputs.items():
            self._display_group.add(self._output_row(name, o, primary))

    def _primary_name(self):
        for name, o in self._outputs.items():
            if o.enabled and o.pos == (0, 0):
                return name
        return next(iter(self._outputs), None)

    def _output_row(self, name, o: "niri.Output", primary):
        row = Adw.ExpanderRow(title=o.make or name, subtitle=name)

        enable = Adw.SwitchRow(title="Enabled", active=o.enabled)
        enable.connect("notify::active",
                       lambda w, *_: niri.apply(name, "on" if w.get_active() else "off"))
        row.add_row(enable)

        mode_strs = [niri.mode_str(m) for m in o.modes]
        mode = Adw.ComboRow(title="Mode", model=Gtk.StringList.new(mode_strs))
        if o.current_mode_idx is not None:
            mode.set_selected(o.current_mode_idx)
        mode.connect("notify::selected",
                     lambda w, *_: niri.apply(name, "mode", mode_strs[w.get_selected()]))
        row.add_row(mode)

        scale_strs = [str(s) for s in niri.SCALES]
        scale = Adw.ComboRow(title="Scale", model=Gtk.StringList.new(scale_strs))
        if o.scale in niri.SCALES:
            scale.set_selected(niri.SCALES.index(o.scale))
        scale.connect("notify::selected",
                      lambda w, *_: niri.apply(name, "scale", scale_strs[w.get_selected()]))
        row.add_row(scale)

        tr = Adw.ComboRow(title="Rotation", model=Gtk.StringList.new(niri.TRANSFORMS))
        cur_tr = o.transform.lower()
        if cur_tr in niri.TRANSFORMS:
            tr.set_selected(niri.TRANSFORMS.index(cur_tr))
        tr.connect("notify::selected",
                   lambda w, *_: niri.apply(name, "transform", niri.TRANSFORMS[w.get_selected()]))
        row.add_row(tr)

        vrr = Adw.SwitchRow(title="Adaptive sync (VRR)", active=o.vrr_enabled,
                            sensitive=o.vrr_supported)
        vrr.connect("notify::active",
                    lambda w, *_: niri.apply(name, "vrr", "on" if w.get_active() else "off"))
        row.add_row(vrr)

        if name != primary and primary is not None:
            places = ["right", "left", "above", "below"]
            pos = Adw.ComboRow(title=f"Position (vs {primary})",
                               model=Gtk.StringList.new([f"{p} of primary" for p in places]))
            def on_pos(w, *_):
                p = self._outputs[primary]
                anchor = niri.relative_position(
                    p.pos or (0, 0), p.logical_size or (1920, 1080),
                    o.logical_size or (1920, 1080), places[w.get_selected()])
                niri.apply(name, "position", f"x={anchor[0]}", f"y={anchor[1]}")
            pos.connect("notify::selected", on_pos)
            row.add_row(pos)

        return row

    def _revert(self):
        for name, b in self._baseline.items():
            niri.apply(name, "on" if b["enabled"] else "off")
            if b["enabled"]:
                if b["mode"]:
                    niri.apply(name, "mode", b["mode"])
                niri.apply(name, "scale", str(b["scale"]))
                niri.apply(name, "transform", b["transform"])
                niri.apply(name, "vrr", "on" if b["vrr"] else "off")
                if b["pos"]:
                    niri.apply(name, "position", f"x={b['pos'][0]}", f"y={b['pos'][1]}")


class PanelApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="dev.prepko.niri-panel")

    def do_activate(self):
        win = self.props.active_window or PanelWindow(self)
        win.present()


def main():
    PanelApp().run(None)
