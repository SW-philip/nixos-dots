from __future__ import annotations
import random
from typing import Callable

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Gio, Pango

from uniremote.status import DeviceStatus, SNARK
from uniremote.widgets import icon_button


class Header(Gtk.WindowHandle):
    def __init__(self, stack, tabs: list[tuple[str, str]],
                 menu: Gio.MenuModel, on_close: Callable[[], None]):
        super().__init__()
        self._was_online = True
        self._snark = ""

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.add_css_class("ur-header")

        title = Gtk.Label(label="UNIREMOTE", xalign=0, hexpand=True)
        title.add_css_class("ur-nameplate")
        menu_button = Gtk.MenuButton(icon_name="view-more-symbolic",
                                     menu_model=menu, tooltip_text="Menu")
        menu_button.add_css_class("ur-chip")
        nameplate = Gtk.Box(spacing=6)
        nameplate.append(title)
        nameplate.append(menu_button)
        nameplate.append(icon_button("window-close-symbolic", on_close,
                                     tooltip="Close", css=["ur-chip"]))
        root.append(nameplate)

        self._led = Gtk.Box(valign=Gtk.Align.CENTER)
        self._led.add_css_class("ur-led")
        self._name = Gtk.Label(xalign=0)
        self._name.add_css_class("ur-name")
        self._line = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END)
        self._line.add_css_class("ur-status")
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True)
        text.append(self._name)
        text.append(self._line)
        self._plate = Gtk.Box(spacing=10)
        self._plate.add_css_class("ur-plate")
        self._plate.append(self._led)
        self._plate.append(text)
        root.append(self._plate)

        tab_row = Gtk.Box(spacing=4, homogeneous=True)
        tab_row.add_css_class("ur-tabs")
        first = None
        for child_name, label in tabs:
            button = Gtk.ToggleButton(label=label)
            button.add_css_class("ur-tab")
            if first is None:
                first = button
            else:
                button.set_group(first)
            button.connect("toggled", self._on_tab, stack, child_name)
            tab_row.append(button)
        first.set_active(True)
        root.append(tab_row)

        self.set_child(root)

    @staticmethod
    def _on_tab(button, stack, child_name):
        if button.get_active():
            stack.set_visible_child_name(child_name)

    def set_device(self, status: DeviceStatus) -> None:
        line = status.line
        if not status.online and not line:
            if self._was_online or not self._snark:
                self._snark = random.choice(SNARK)
            line = self._snark
        self._was_online = status.online
        self._name.set_text(status.name)
        self._line.set_text(line)
        if status.online:
            self._plate.remove_css_class("offline")
        else:
            self._plate.add_css_class("offline")
