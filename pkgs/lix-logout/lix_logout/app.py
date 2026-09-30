"""GTK4 logout popup window.

Not a layer-shell surface — a plain floating GTK window sized/centered by a
niri window-rule (match app-id="dev.prepko.lix-logout") instead, same
mechanism this repo already uses for weather-radar/drmis-pick. Simpler and
more reliable than fighting gtk4-layer-shell's GI-binding compatibility.
"""
from __future__ import annotations

import random
import subprocess
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

from .armgate import ARM_WINDOW_SECONDS, ArmGate
from .commands import command_for

CSS_PATH = Path.home() / ".config" / "lix-logout" / "style.css"
MARK_PATH = Path.home() / ".local" / "state" / "nix-mark-img"
MARK_PX = 40

# Core buttons, in display order: (action id, label, icon glyph). Nerd Font
# glyphs (nf-md-lock, nf-md-logout, nf-md-restart, nf-fa-power_off), matching
# the "JetBrainsMono Nerd Font" family style.nix already sets — flag any
# that render as tofu and they can be swapped for a different codepoint.
CORE_BUTTONS = [
    ("lock", "Lock", "\U000f033e"),
    ("logout", "Logout", "\U000f0343"),
    ("reboot", "Reboot", "\U000f0709"),
    ("shutdown", "Shutdown", ""),
]

ARMED_LABELS = {
    "reboot": "Confirm reboot?",
    "shutdown": "Confirm shutdown?",
}

REVEAL_STAGGER_MS = 70

# The dodge button serves no purpose — it exists purely because a small,
# tidy popup needed one ridiculous feature for no reason. Spots are
# (halign, valign, region as x0,x1,y0,y1 fractions of the overlay) so
# pointer-proximity can be tested without needing widget allocation APIs.
DODGE_SPOTS = [
    (Gtk.Align.START, Gtk.Align.START, 0.0, 0.45, 0.0, 0.45),
    (Gtk.Align.END, Gtk.Align.START, 0.55, 1.0, 0.0, 0.45),
    (Gtk.Align.START, Gtk.Align.END, 0.0, 0.45, 0.55, 1.0),
    (Gtk.Align.END, Gtk.Align.END, 0.55, 1.0, 0.55, 1.0),
    (Gtk.Align.CENTER, Gtk.Align.START, 0.35, 0.65, 0.0, 0.3),
    (Gtk.Align.CENTER, Gtk.Align.END, 0.35, 0.65, 0.7, 1.0),
]

DODGE_CAUGHT_MESSAGES = [
    "You weren't supposed to catch that.",
    "Fine. You win. It does nothing.",
    "Congratulations, this achieves nothing.",
    "Impressive reflexes. Still pointless.",
]


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
        # margin — without this the popup floats with an invisible gap
        # between its visible border and the actual window edge.
        self.set_decorated(False)
        self.set_resizable(False)
        self.gate = ArmGate()
        self._revealers: list[Gtk.Revealer] = []
        self._dodge_spot_idx = 0

        _load_css()

        self.set_child(self._build())

        escape = Gtk.EventControllerKey()
        escape.connect("key-pressed", self._on_key)
        self.add_controller(escape)

    def _on_key(self, _ctrl, keyval, _keycode, _state):
        if keyval == Gdk.KEY_Escape:
            self.get_application().quit()
            return True
        return False

    def _build(self) -> Gtk.Widget:
        card = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        card.set_halign(Gtk.Align.CENTER)
        card.set_valign(Gtk.Align.CENTER)
        card.add_css_class("lix-logout-card")

        for action, label, icon in CORE_BUTTONS:
            btn = Gtk.Button()
            btn.add_css_class("lix-logout-btn")
            btn.add_css_class(f"lix-logout-btn-{action}")

            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            box.set_halign(Gtk.Align.CENTER)
            icon_label = Gtk.Label(label=icon)
            icon_label.add_css_class("lix-logout-icon")
            text_label = Gtk.Label(label=label)
            text_label.add_css_class("lix-logout-label")
            box.append(icon_label)
            box.append(text_label)
            btn.set_child(box)
            btn.connect("clicked", self._on_click, action, text_label, label)

            revealer = Gtk.Revealer()
            revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP)
            revealer.set_transition_duration(220)
            revealer.set_child(btn)
            revealer.set_reveal_child(False)
            self._revealers.append(revealer)
            card.append(revealer)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        root.set_halign(Gtk.Align.CENTER)
        root.set_valign(Gtk.Align.CENTER)

        if MARK_PATH.exists():
            mark = Gtk.Image.new_from_file(str(MARK_PATH))
            mark.set_pixel_size(MARK_PX)
            mark.add_css_class("lix-logout-mark")
            mark.set_halign(Gtk.Align.CENTER)
            root.append(mark)

        root.append(card)

        overlay = Gtk.Overlay()
        self._overlay = overlay
        overlay.set_child(root)

        self._dodge_btn = Gtk.Button(label="???")
        self._dodge_btn.add_css_class("lix-logout-dodge")
        self._dodge_btn.set_can_target(True)
        self._place_dodge_btn()
        self._dodge_btn.connect("clicked", self._on_dodge_clicked)
        overlay.add_overlay(self._dodge_btn)

        motion = Gtk.EventControllerMotion()
        motion.connect("motion", self._on_pointer_motion)
        overlay.add_controller(motion)

        return overlay

    def _place_dodge_btn(self) -> None:
        halign, valign, *_ = DODGE_SPOTS[self._dodge_spot_idx]
        self._dodge_btn.set_halign(halign)
        self._dodge_btn.set_valign(valign)
        self._dodge_btn.set_margin_start(10)
        self._dodge_btn.set_margin_end(10)
        self._dodge_btn.set_margin_top(10)
        self._dodge_btn.set_margin_bottom(10)

    def _on_pointer_motion(self, _ctrl, x: float, y: float) -> None:
        w = self._overlay.get_width() or 1
        h = self._overlay.get_height() or 1
        _, _, x0, x1, y0, y1 = DODGE_SPOTS[self._dodge_spot_idx]
        if x0 * w <= x <= x1 * w and y0 * h <= y <= y1 * h:
            choices = [i for i in range(len(DODGE_SPOTS)) if i != self._dodge_spot_idx]
            self._dodge_spot_idx = random.choice(choices)
            self._place_dodge_btn()

    def _on_dodge_clicked(self, _btn: Gtk.Button) -> None:
        msg = random.choice(DODGE_CAUGHT_MESSAGES)
        subprocess.Popen(["notify-send", "lix-logout", msg])

    def present(self) -> None:  # noqa: D102 - overriding Gtk.Window.present
        super().present()
        for i, revealer in enumerate(self._revealers):
            GLib.timeout_add(i * REVEAL_STAGGER_MS, self._reveal, revealer)

    @staticmethod
    def _reveal(revealer: Gtk.Revealer):
        revealer.set_reveal_child(True)
        return GLib.SOURCE_REMOVE

    def _on_click(self, btn: Gtk.Button, action: str, text_label: Gtk.Label, base_label: str):
        if action not in ARMED_LABELS:
            subprocess.Popen(command_for(action))
            self.get_application().quit()
            return

        now = time.monotonic()
        if self.gate.click(action, now):
            btn.remove_css_class("armed")
            text_label.set_label(base_label)
            subprocess.Popen(command_for(action))
            self.get_application().quit()
            return

        btn.add_css_class("armed")
        text_label.set_label(ARMED_LABELS[action])
        GLib.timeout_add(int(ARM_WINDOW_SECONDS * 1000), self._maybe_disarm,
                          action, btn, text_label, base_label)

    def _maybe_disarm(self, action: str, btn: Gtk.Button, text_label: Gtk.Label, base_label: str):
        if not self.gate.is_armed(action, time.monotonic()):
            btn.remove_css_class("armed")
            text_label.set_label(base_label)
        return GLib.SOURCE_REMOVE


class LogoutApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="dev.prepko.lix-logout")

    def do_activate(self):
        win = LogoutWindow(self)
        win.present()
