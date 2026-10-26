"""GTK4 session menu: header + four keyboard-driven rows.

Not a layer-shell surface — a plain floating GTK window sized/centered by a
niri window-rule (match app-id="dev.prepko.lix-logout") instead, same
mechanism this repo already uses for weather-radar/drmis-pick.
"""
from __future__ import annotations

import getpass
import socket
import subprocess
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

from .armgate import ARM_WINDOW_SECONDS, ArmGate
from .commands import command_for
from .menu import ARMED_LABELS, ROWS, action_for_key, header_text

CSS_PATH = Path.home() / ".config" / "lix-logout" / "style.css"
MARK_PATH = Path.home() / ".local" / "state" / "nix-mark-img"
MARK_PX = 22


def _load_css() -> None:
    provider = Gtk.CssProvider()
    try:
        provider.load_from_path(str(CSS_PATH))
    except GLib.Error:
        pass
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(), provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


class LogoutWindow(Gtk.ApplicationWindow):
    def __init__(self, app: Gtk.Application):
        super().__init__(application=app)
        # No titlebar/CSD, so don't reserve GTK's default decoration shadow
        # margin — otherwise the popup floats with an invisible gap between
        # its visible border and the actual window edge.
        self.set_decorated(False)
        self.set_resizable(False)
        self.gate = ArmGate()
        self._rows: dict[str, tuple[Gtk.Button, Gtk.Label, str]] = {}

        _load_css()
        self.set_child(self._build())
        self._first.grab_focus()

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._on_key)
        self.add_controller(keys)

    def _build(self) -> Gtk.Widget:
        panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        panel.add_css_class("lix-logout-panel")
        panel.set_size_request(260, -1)

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        header.add_css_class("lix-logout-header")
        if MARK_PATH.exists():
            mark = Gtk.Image.new_from_file(str(MARK_PATH))
            mark.set_pixel_size(MARK_PX)
            mark.add_css_class("lix-logout-mark")
            header.append(mark)
        host = Gtk.Label(label=header_text(socket.gethostname(), getpass.getuser()))
        host.add_css_class("lix-logout-host")
        host.set_xalign(0)
        header.append(host)
        panel.append(header)
        panel.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))

        self._first: Gtk.Button | None = None
        for row in ROWS:
            btn = Gtk.Button()
            btn.set_has_frame(False)
            btn.add_css_class("lix-logout-row")

            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            icon = Gtk.Label(label=row.icon)
            icon.add_css_class("lix-logout-icon")
            label = Gtk.Label(label=row.label)
            label.add_css_class("lix-logout-label")
            label.set_xalign(0)
            label.set_hexpand(True)
            hint = Gtk.Label(label=row.key.upper())
            hint.add_css_class("lix-logout-hint")
            box.append(icon)
            box.append(label)
            box.append(hint)
            btn.set_child(box)
            btn.connect("clicked", lambda _b, a=row.action: self._activate(a))

            self._rows[row.action] = (btn, label, row.label)
            panel.append(btn)
            self._first = self._first or btn

        return panel

    def _on_key(self, _ctrl, keyval, _keycode, state):
        if keyval == Gdk.KEY_Escape:
            self.get_application().quit()
            return True
        if state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK):
            return False
        action = action_for_key(Gdk.keyval_name(keyval) or "")
        if action is None:
            return False
        self._activate(action)
        return True

    def _activate(self, action: str) -> None:
        if action not in ARMED_LABELS:
            self._fire(action)
            return

        if self.gate.click(action, time.monotonic()):
            self._fire(action)
            return

        for other in ARMED_LABELS:
            if other != action:
                self._disarm(other)
        btn, label, _ = self._rows[action]
        btn.add_css_class("armed")
        label.set_label(ARMED_LABELS[action])
        GLib.timeout_add(int(ARM_WINDOW_SECONDS * 1000), self._maybe_disarm, action)

    def _fire(self, action: str) -> None:
        subprocess.Popen(command_for(action))
        self.get_application().quit()

    def _disarm(self, action: str) -> None:
        btn, label, base = self._rows[action]
        btn.remove_css_class("armed")
        label.set_label(base)

    def _maybe_disarm(self, action: str):
        if not self.gate.is_armed(action, time.monotonic()):
            self._disarm(action)
        return GLib.SOURCE_REMOVE


class LogoutApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="dev.prepko.lix-logout")

    def do_activate(self):
        LogoutWindow(self).present()
