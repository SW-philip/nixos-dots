from __future__ import annotations
import sys
import threading
from pathlib import Path
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Gio, GLib, Adw, Gdk

import requests
from uniremote import __version__
from uniremote.api import RokuAPI, SmartThingsAPI
from uniremote.config import Config
from uniremote.header import Header
from uniremote.status import NOT_SET_UP, DeviceStatus, roku_status, samsung_status
from uniremote.tablet import cover_detached, cover_path
from uniremote.views.samsung import SamsungView
from uniremote.views.roku import RokuView
from uniremote.preferences import Preferences

APP_ID = "com.prepko.uniremote"
POLL_SECONDS = 5
config = Config()


def run_async(fn, *args, callback=None):
    """Run fn(*args) in a daemon thread; deliver its result (or the raised
    Exception) to callback on the GTK main thread."""
    def worker():
        try:
            result = fn(*args)
        except Exception as e:  # delivered to callback, surfaced as a toast
            result = e
        if callback:
            GLib.idle_add(callback, result)
    threading.Thread(target=worker, daemon=True).start()


class UniremoteApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)
        self._win = None
        self._css = None
        self._css_watch = None
        for name, handler in (("preferences", self._on_preferences),
                              ("about", self._on_about)):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", handler)
            self.add_action(action)

    def do_activate(self):
        self._load_theme()
        if self._win is None:
            self._win = MainWindow(application=self)
        self._win.present()

    def _load_theme(self):
        """Palette sheet deployed by drmis; absent (e.g. no drmis yet) means
        stock libadwaita. drmis replaces the file, so watch moves too and
        reload in place -- no restart after `drmis set`."""
        if self._css is not None:
            return
        path = Path(GLib.get_user_config_dir()) / "uniremote" / "style.css"
        self._css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), self._css,
            Gtk.STYLE_PROVIDER_PRIORITY_USER)
        self._reload_css(path)
        self._css_watch = Gio.File.new_for_path(str(path)).monitor_file(
            Gio.FileMonitorFlags.WATCH_MOVES, None)
        self._css_watch.connect(
            "changed",
            lambda _m, _f, _o, event: event != Gio.FileMonitorEvent.DELETED
            and self._reload_css(path))

    def _reload_css(self, path: Path):
        if path.exists():
            self._css.load_from_path(str(path))

    def notify(self, message: str):
        if self._win is not None:
            self._win.toast(message)

    def _on_preferences(self, *_):
        Preferences(config, run_async, self.notify).present(self._win)

    def _on_about(self, *_):
        Adw.AboutDialog(
            application_name="Uniremote",
            application_icon="tv-symbolic",
            version=__version__,
            developer_name="prepko",
            website="https://github.com/SW-philip/nixos",
            comments="A GTK4 remote for Samsung SmartThings TVs and Roku devices.",
        ).present(self._win)


class MainWindow(Adw.ApplicationWindow):
    def __init__(self, **kwargs):
        super().__init__(title="Uniremote",
                         default_width=320, default_height=680, **kwargs)
        notify = self.get_application().notify
        self._labels: dict[str, str] = {}
        self._poll_seq = 0
        self._applied_seq = 0

        def run_and_poll(fn, *args, callback=None):
            def done(result):
                if callback:
                    callback(result)
                self._poll()
            run_async(fn, *args, callback=done)

        self._stack = Adw.ViewStack()
        self._stack.add_titled(SamsungView(config, run_and_poll, notify), "samsung", "Samsung")
        self._stack.add_titled(RokuView(config, run_and_poll, notify), "roku", "Roku")

        menu = Gio.Menu()
        menu.append("Preferences", "app.preferences")
        menu.append("About Uniremote", "app.about")
        self._header = Header(self._stack,
                              [("samsung", "SAMSUNG"), ("roku", "ROKU")],
                              menu, self.close)

        self._toast_overlay = Adw.ToastOverlay()
        self._toast_overlay.set_child(self._stack)
        self._toast_overlay.add_css_class("ur-body")

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(self._header)
        box.append(self._toast_overlay)
        self._toast_overlay.set_vexpand(True)
        self.set_content(box)

        self._stack.connect("notify::visible-child-name", lambda *_: self._poll())
        self.connect("notify::is-active",
                     lambda *_: self.is_active() and self._poll())
        self._tick_id = GLib.timeout_add_seconds(POLL_SECONDS, self._tick)
        self.connect("close-request", self._on_close_request)
        self._watch_tablet()
        self._poll()

    def _on_close_request(self, *_):
        GLib.source_remove(self._tick_id)
        return False

    def _tick(self):
        if self.is_active():
            self._poll()
        return True

    def _poll(self):
        name = self._stack.get_visible_child_name()
        self._poll_seq += 1
        run_async(self._fetch, name,
                  callback=lambda result, n=name, seq=self._poll_seq: self._on_status(n, result, seq))

    def _fetch(self, name: str) -> DeviceStatus:
        if name == "samsung":
            if not (config.samsung_token and config.samsung_device_id):
                return DeviceStatus("Samsung TV", NOT_SET_UP, False)
            api = SmartThingsAPI(config.samsung_token, config.samsung_device_id)
            if config.samsung_device_id not in self._labels:
                try:
                    self._labels[config.samsung_device_id] = api.label() or ""
                except requests.RequestException:
                    pass
            return samsung_status(api, self._labels.get(config.samsung_device_id, ""))
        if not config.roku_ip:
            return DeviceStatus("Roku", NOT_SET_UP, False)
        return roku_status(RokuAPI(config.roku_ip))

    def _on_status(self, name: str, result, seq: int):
        if name != self._stack.get_visible_child_name():
            return  # stale poll from a tab we've left
        if seq < self._applied_seq:
            return  # an older poll finished after a newer one
        self._applied_seq = seq
        if isinstance(result, Exception):
            result = DeviceStatus(name.title(), "", False)
        self._header.set_device(result)
        self._stack.get_child_by_name(name).set_sensitive(result.online)

    def _watch_tablet(self):
        path = cover_path()

        def apply(*_):
            if cover_detached(path):
                self.add_css_class("tablet")
            else:
                self.remove_css_class("tablet")

        self._cover_watch = Gio.File.new_for_path(str(path)).monitor_file(
            Gio.FileMonitorFlags.NONE, None)
        self._cover_watch.connect("changed", apply)
        apply()

    def toast(self, message: str):
        self._toast_overlay.add_toast(Adw.Toast(title=message, timeout=3))


def main():
    app = UniremoteApp()
    sys.exit(app.run(sys.argv))
