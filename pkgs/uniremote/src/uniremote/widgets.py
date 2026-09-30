from __future__ import annotations
from typing import Callable
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk


def icon_button(icon_name: str, on_click: Callable[[], None], *,
                tooltip: str | None = None,
                css: list[str] | None = None) -> Gtk.Button:
    button = Gtk.Button(icon_name=icon_name)
    if tooltip:
        button.set_tooltip_text(tooltip)
    for cls in css or []:
        button.add_css_class(cls)
    button.connect("clicked", lambda _: on_click())
    return button


def dpad(*, on_up: Callable[[], None], on_down: Callable[[], None],
         on_left: Callable[[], None], on_right: Callable[[], None],
         on_ok: Callable[[], None]) -> Gtk.Grid:
    grid = Gtk.Grid(row_spacing=0, column_spacing=0, halign=Gtk.Align.CENTER)
    grid.attach(icon_button("pan-up-symbolic", on_up, tooltip="Up"), 1, 0, 1, 1)
    grid.attach(icon_button("pan-start-symbolic", on_left, tooltip="Left"), 0, 1, 1, 1)
    grid.attach(icon_button("object-select-symbolic", on_ok, tooltip="OK",
                            css=["circular", "suggested-action"]), 1, 1, 1, 1)
    grid.attach(icon_button("pan-end-symbolic", on_right, tooltip="Right"), 2, 1, 1, 1)
    grid.attach(icon_button("pan-down-symbolic", on_down, tooltip="Down"), 1, 2, 1, 1)
    return grid


def button_row(*buttons: Gtk.Widget) -> Gtk.Box:
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0,
                  halign=Gtk.Align.CENTER)
    for button in buttons:
        box.append(button)
    return box
