from __future__ import annotations
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk

from uniremote.widgets import icon_button, dpad, button_row


class SamsungView(Gtk.Box):
    def __init__(self, config, samsung_api, run_async, notify):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=4,
                         margin_top=8, margin_bottom=8,
                         margin_start=10, margin_end=10)
        self._config = config
        self._api = samsung_api
        self._run_async = run_async
        self._notify = notify

        # stays live while the TV is off the network, so Wake-on-LAN can reach it
        self._power_row = button_row(
            icon_button("system-shutdown-symbolic",
                        lambda: self._power("on"),
                        tooltip="Power on", css=["circular"]),
            icon_button("system-shutdown-symbolic",
                        lambda: self._power("off"),
                        tooltip="Power off", css=["circular", "destructive-action"]),
        )
        self.append(self._power_row)

        self.append(dpad(
            on_up=lambda: self._key("KEY_UP"),
            on_down=lambda: self._key("KEY_DOWN"),
            on_left=lambda: self._key("KEY_LEFT"),
            on_right=lambda: self._key("KEY_RIGHT"),
            on_ok=lambda: self._key("KEY_ENTER"),
        ))

        self.append(button_row(
            icon_button("go-previous-symbolic",
                        lambda: self._key("KEY_RETURN"),
                        tooltip="Back"),
            icon_button("go-home-symbolic",
                        lambda: self._key("KEY_HOME"),
                        tooltip="Home"),
            icon_button("video-display-symbolic",
                        lambda: self._key("KEY_SOURCE"),
                        tooltip="Source"),
        ))

        self.append(button_row(
            icon_button("media-skip-backward-symbolic",
                        lambda: self._key("KEY_REWIND"),
                        tooltip="Rewind"),
            icon_button("media-playback-start-symbolic",
                        lambda: self._key("KEY_PLAY"),
                        tooltip="Play / Pause"),
            icon_button("media-skip-forward-symbolic",
                        lambda: self._key("KEY_FF"),
                        tooltip="Fast-forward"),
        ))

        grid = Gtk.Grid(row_spacing=0, column_spacing=18, halign=Gtk.Align.CENTER)
        grid.attach(Gtk.Label(label="Volume"), 0, 0, 1, 1)
        grid.attach(icon_button("audio-volume-high-symbolic",
                                lambda: self._key("KEY_VOLUP"),
                                tooltip="Volume up"), 0, 1, 1, 1)
        grid.attach(icon_button("audio-volume-low-symbolic",
                                lambda: self._key("KEY_VOLDOWN"),
                                tooltip="Volume down"), 0, 2, 1, 1)
        grid.attach(Gtk.Label(label="Channel"), 1, 0, 1, 1)
        grid.attach(icon_button("pan-up-symbolic",
                                lambda: self._key("KEY_CHUP"),
                                tooltip="Channel up"), 1, 1, 1, 1)
        grid.attach(icon_button("pan-down-symbolic",
                                lambda: self._key("KEY_CHDOWN"),
                                tooltip="Channel down"), 1, 2, 1, 1)
        self.append(grid)

    def set_online(self, online: bool):
        child = self.get_first_child()
        while child is not None:
            child.set_sensitive(online or child is self._power_row)
            child = child.get_next_sibling()

    def _key(self, key: str):
        self._send(lambda api: api.send_key(key))

    def _power(self, state: str):
        self._send(lambda api: api.power(state, self._config.samsung_mac))

    def _send(self, fn):
        api = self._api()
        if api is None:
            self._notify("Set the TV's IP in ⋯ → Preferences")
            return

        def done(result):
            if isinstance(result, Exception):
                self._notify(f"Samsung: {result}")
        self._run_async(fn, api, callback=done)
