"""GTK4 greeter window — flat, matches the hyprlock lock screen."""
from __future__ import annotations

import os
import subprocess
import sys
from importlib import resources
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

try:
    gi.require_version("Gtk4LayerShell", "1.0")
    from gi.repository import Gtk4LayerShell as LayerShell  # noqa: E402
    _HAVE_LAYER_SHELL = True
except (ValueError, ImportError):
    _HAVE_LAYER_SHELL = False

from .clock import clock_text, date_text
from .colors import css_rgba, hex_to_rgb
from .mark import tint_svg
from .palette import Palette
from .snark import pick_snark_line

WALLPAPER = "/run/greeter/wallpaper-img"
NIX_MARK_PX = 48.0
_SCRIM_PAD = 32       # px (× field_scale) of band around the mark/clock/date
_AUTH_BLOCK_PX = 180  # rough height of the user+password+session+status stack;
                      # only used to bias the band onto the screen centre — tune
                      # if the band reads high or low
_CLOCK_TICK_S = 10


def _css_rgb(hex_color: str) -> str:
    r, g, b = hex_to_rgb(hex_color)
    return f"rgb({r},{g},{b})"


class GreeterWindow(Gtk.ApplicationWindow):
    def __init__(self, app, palette: Palette, users, sessions, ipc, on_success,
                 scale=1.0, field_scale=None, default_user=None):
        super().__init__(application=app)
        self.palette = palette
        self.users = users or ["user"]
        self.sessions = sessions or [{"id": "niri", "name": "Niri", "exec": "niri-session"}]
        self.ipc = ipc
        self.on_success = on_success
        self.scale = scale if scale and scale > 0 else 1.0
        self.field_scale = field_scale if field_scale and field_scale > 0 else self.scale
        self.user_idx = self.users.index(default_user) if default_user in self.users else 0
        self.session_idx = 0

        self._apply_css()
        # cage (our greetd compositor) has no wlr-layer-shell — plain fullscreen there;
        # layer-shell only when a compositor advertises it.
        if _HAVE_LAYER_SHELL and LayerShell.is_supported():
            LayerShell.init_for_window(self)
            LayerShell.set_layer(self, LayerShell.Layer.OVERLAY)
            for edge in ("LEFT", "RIGHT", "TOP", "BOTTOM"):
                LayerShell.set_anchor(self, getattr(LayerShell.Edge, edge), True)
            LayerShell.set_keyboard_mode(self, LayerShell.KeyboardMode.EXCLUSIVE)
        else:
            self.fullscreen()

        self.set_child(self._build())

    def _apply_css(self):
        p = self.palette
        # cage has no wp_cursor_shape_v1 and GTK ignores XCURSOR_* env, so name + size
        # the cursor theme explicitly (resolved via the launcher's XCURSOR_PATH).
        settings = Gtk.Settings.get_default()
        if settings is not None:
            settings.set_property("gtk-cursor-aspect-ratio", 0.08)
            settings.set_property("gtk-cursor-theme-name", "posys_cursor_scalable")
            settings.set_property("gtk-cursor-theme-size", round(32 * self.scale))
        s = self.field_scale

        def px(n):
            return round(n * s)

        css = f"""
        .root  {{ background-color: {_css_rgb(p.ground)}; }}
        label  {{ color: {_css_rgb(p.ink)}; }}
        .clock {{ color: {_css_rgb(p.clock)}; font-size: {px(96)}px; font-weight: 600; }}
        .date  {{ color: {_css_rgb(p.date)}; font-size: {px(32)}px; }}
        .scrim {{ background-color: {css_rgba(p.ground, 0.55)}; padding: {px(_SCRIM_PAD)}px 0; }}
        .field, .chip, .pbtn {{
            background-image: none;
            background-color: {_css_rgb(p.field)};
            color: {_css_rgb(p.field_ink)};
            border: 1px solid {_css_rgb(p.outline)};
            border-radius: {px(8)}px;
        }}
        .field, .chip, .pbtn, .field label, .chip label, .pbtn label {{
            color: {_css_rgb(p.field_ink)};
        }}
        .field {{ min-width: {px(300)}px; caret-color: {_css_rgb(p.field_ink)};
                  padding: {px(10)}px {px(16)}px; font-size: {px(20)}px; }}
        .field text, .field text > placeholder {{ color: {_css_rgb(p.field_ink)}; }}
        .field:focus-within {{ outline: none; }}
        .field.fail {{ border-color: {_css_rgb(p.fail)}; }}
        .chip  {{ padding: {px(6)}px {px(14)}px; font-size: {px(16)}px; }}
        .pbtn  {{ min-width: {px(40)}px; min-height: {px(40)}px; font-size: {px(18)}px; }}
        .msg   {{ color: {_css_rgb(p.date)}; font-size: {px(15)}px; }}
        .field:disabled {{ opacity: 0.6; }}
        * {{ font-family: "Josefin Sans"; }}
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css.encode())
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def _nix_mark_path(self) -> str:
        """The shared nix-flake SVG recoloured to the palette's muted ink
        (REST role, self.palette.date), written to the runtime dir. Falls
        back to the untinted asset on any read/write error."""
        src = resources.files("greeter") / "assets" / "nix-flake.svg"
        try:
            svg = tint_svg(src.read_text(), self.palette.date)
            out = Path(GLib.get_user_runtime_dir()) / "greeter-nix-mark.svg"
            out.write_text(svg)
            return str(out)
        except OSError as e:
            print(f"greeter: nix-mark tint failed ({e}); using untinted asset",
                  file=sys.stderr)
            return str(src)

    def _build(self):
        s = self.field_scale

        # ── band layer: mark + clock + date, full-bleed scrim, screen-centred ──
        band = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=round(14 * s))
        band.add_css_class("scrim")
        band.set_halign(Gtk.Align.FILL)      # full-bleed width
        band.set_valign(Gtk.Align.CENTER)    # centred on the screen

        mark = Gtk.Image.new_from_file(self._nix_mark_path())
        mark.set_pixel_size(round(NIX_MARK_PX * self.scale))
        mark.set_halign(Gtk.Align.CENTER)
        band.append(mark)

        self.clock_lbl = Gtk.Label(label=clock_text())
        self.clock_lbl.add_css_class("clock")
        self.clock_lbl.set_halign(Gtk.Align.CENTER)
        band.append(self.clock_lbl)

        self.date_lbl = Gtk.Label(label=date_text())
        self.date_lbl.add_css_class("date")
        self.date_lbl.set_halign(Gtk.Align.CENTER)
        band.append(self.date_lbl)

        # ── auth layer: chips + password + status, just below the band ──
        # valign=center only shifts a widget down by margin_top/2, so clearing
        # the band (half of it below centre) plus the auth block's own height
        # needs the full sum, not half.
        band_h = round(NIX_MARK_PX * self.scale
                       + (14 + 96 + 14 + 32) * s
                       + 2 * _SCRIM_PAD * s)
        auth = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=round(14 * s))
        auth.set_halign(Gtk.Align.CENTER)
        auth.set_valign(Gtk.Align.CENTER)
        # +24*s == 2× the ~12px band→auth gap (valign=CENTER applies half of margin_top)
        auth.set_margin_top(band_h + round(_AUTH_BLOCK_PX * s) + round(24 * s))

        self.user_btn = Gtk.Button(label=f"{self.users[self.user_idx]}  ▾")
        self.user_btn.add_css_class("chip")
        self.user_btn.set_halign(Gtk.Align.CENTER)
        self.user_btn.connect("clicked", self._cycle_user)
        auth.append(self.user_btn)

        self.pw = Gtk.PasswordEntry()
        self.pw.set_show_peek_icon(False)
        self.pw.set_alignment(0.5)
        self.pw.add_css_class("field")
        self.pw.set_halign(Gtk.Align.CENTER)
        self.pw.connect("activate", self._submit)
        auth.append(self.pw)

        self.session_btn = Gtk.Button(label=f"{self.sessions[self.session_idx]['name']}  ▾")
        self.session_btn.add_css_class("chip")
        self.session_btn.set_halign(Gtk.Align.CENTER)
        self.session_btn.connect("clicked", self._cycle_session)
        auth.append(self.session_btn)

        self.status = Gtk.Label(label="")
        self.status.add_css_class("msg")
        self.status.set_halign(Gtk.Align.CENTER)
        auth.append(self.status)

        # ── overlay: wallpaper (or .root ground) · band · auth · power ──
        overlay = Gtk.Overlay()
        overlay.add_css_class("root")
        if os.path.exists(WALLPAPER):
            paper = Gtk.Picture.new_for_filename(WALLPAPER)
            paper.set_can_shrink(True)
            paper.set_content_fit(Gtk.ContentFit.COVER)
            overlay.set_child(paper)
        else:
            overlay.set_child(Gtk.Box(hexpand=True, vexpand=True))
        overlay.add_overlay(band)
        overlay.add_overlay(auth)

        power = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=round(10 * s))
        power.set_halign(Gtk.Align.END)
        power.set_valign(Gtk.Align.END)
        power.set_margin_end(round(18 * s))
        power.set_margin_bottom(round(16 * s))
        for label, cmd in (("⏻", ["systemctl", "poweroff"]),
                           ("⟳", ["systemctl", "reboot"])):
            b = Gtk.Button(label=label)
            b.add_css_class("pbtn")
            b.connect("clicked", lambda _w, c=cmd: subprocess.Popen(c))
            power.append(b)
        overlay.add_overlay(power)
        return overlay

    def tick_clock(self):
        self.clock_lbl.set_label(clock_text())
        self.date_lbl.set_label(date_text())
        return GLib.SOURCE_CONTINUE

    def _cycle_user(self, _btn):
        self.user_idx = (self.user_idx + 1) % len(self.users)
        self.user_btn.set_label(f"{self.users[self.user_idx]}  ▾")
        self.pw.remove_css_class("fail")
        try:
            self.ipc.cancel_session()
        except Exception:  # noqa: BLE001
            pass

    def _cycle_session(self, _btn):
        self.session_idx = (self.session_idx + 1) % len(self.sessions)
        self.session_btn.set_label(f"{self.sessions[self.session_idx]['name']}  ▾")
        self.pw.remove_css_class("fail")

    def _fail(self, msg):
        self.status.set_label(msg)
        self.pw.set_text("")
        self.pw.add_css_class("fail")
        self.pw.grab_focus()

    def _submit(self, _entry):
        self.pw.remove_css_class("fail")
        username = self.users[self.user_idx]
        password = self.pw.get_text()
        try:
            resp = self.ipc.create_session(username)
            while resp.get("type") == "auth_message":
                amt = resp.get("auth_message_type")
                answer = password if amt == "secret" else (
                    None if amt in ("info", "error") else password)
                resp = self.ipc.post_response(answer)
            if resp.get("type") == "success":
                session = self.sessions[self.session_idx]
                cmd = session["exec"].split() or ["niri-session"]
                start = self.ipc.start_session(cmd)
                if start.get("type") == "error":
                    self._fail(start.get("description", "Session failed to start"))
                    return
                self.on_success()
                return
            self.ipc.cancel_session()
            self._fail(pick_snark_line())
        except Exception as e:  # noqa: BLE001
            self._fail(str(e))


class GreeterApp(Gtk.Application):
    def __init__(self, palette, users, sessions, ipc, scale=1.0, field_scale=None,
                 default_user=None):
        super().__init__(application_id="dev.prepko.greeter")
        self._args = (palette, users, sessions, ipc)
        self._scale = scale
        self._field_scale = field_scale
        self._default_user = default_user

    def do_activate(self):
        win = GreeterWindow(self, *self._args, on_success=self.quit,
                            scale=self._scale, field_scale=self._field_scale,
                            default_user=self._default_user)
        win.present()
        GLib.timeout_add_seconds(_CLOCK_TICK_S, win.tick_clock)

        def _focus_once():
            win.pw.grab_focus()
            # run once; returning True would re-select the entry every idle tick,
            # clobbering all but the last typed char.
            return GLib.SOURCE_REMOVE

        GLib.idle_add(_focus_once)
