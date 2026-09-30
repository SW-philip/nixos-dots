from __future__ import annotations
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk

from uniremote.api import SmartThingsAPI
from uniremote.widgets import icon_button, dpad, button_row


class SamsungView(Gtk.Box):
    def __init__(self, config, run_async, notify):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=4,
                         margin_top=8, margin_bottom=8,
                         margin_start=10, margin_end=10)
        self._config = config
        self._run_async = run_async
        self._notify = notify

        self.append(button_row(
            icon_button("system-shutdown-symbolic",
                        lambda: self._send(self._st().power, "on"),
                        tooltip="Power on", css=["circular"]),
            icon_button("system-shutdown-symbolic",
                        lambda: self._send(self._st().power, "off"),
                        tooltip="Power off", css=["circular", "destructive-action"]),
        ))

        self.append(dpad(
            on_up=lambda: self._send(self._st().send_key, "KEY_UP"),
            on_down=lambda: self._send(self._st().send_key, "KEY_DOWN"),
            on_left=lambda: self._send(self._st().send_key, "KEY_LEFT"),
            on_right=lambda: self._send(self._st().send_key, "KEY_RIGHT"),
            on_ok=lambda: self._send(self._st().send_key, "KEY_ENTER"),
        ))

        self.append(button_row(
            icon_button("go-previous-symbolic",
                        lambda: self._send(self._st().send_key, "KEY_RETURN"),
                        tooltip="Back"),
            icon_button("go-home-symbolic",
                        lambda: self._send(self._st().send_key, "KEY_HOME"),
                        tooltip="Home"),
            icon_button("video-display-symbolic",
                        lambda: self._send(self._st().send_key, "KEY_SOURCE"),
                        tooltip="Source"),
        ))

        self.append(button_row(
            icon_button("media-skip-backward-symbolic",
                        lambda: self._send(self._st().send_key, "KEY_REWIND"),
                        tooltip="Rewind"),
            icon_button("media-playback-start-symbolic",
                        lambda: self._send(self._st().send_key, "KEY_PLAY"),
                        tooltip="Play / Pause"),
            icon_button("media-skip-forward-symbolic",
                        lambda: self._send(self._st().send_key, "KEY_FF"),
                        tooltip="Fast-forward"),
        ))

        grid = Gtk.Grid(row_spacing=0, column_spacing=18, halign=Gtk.Align.CENTER)
        grid.attach(Gtk.Label(label="Volume"), 0, 0, 1, 1)
        grid.attach(icon_button("audio-volume-high-symbolic",
                                lambda: self._send(self._st().volume_up),
                                tooltip="Volume up"), 0, 1, 1, 1)
        grid.attach(icon_button("audio-volume-low-symbolic",
                                lambda: self._send(self._st().volume_down),
                                tooltip="Volume down"), 0, 2, 1, 1)
        grid.attach(Gtk.Label(label="Channel"), 1, 0, 1, 1)
        grid.attach(icon_button("pan-up-symbolic",
                                lambda: self._send(self._st().channel_up),
                                tooltip="Channel up"), 1, 1, 1, 1)
        grid.attach(icon_button("pan-down-symbolic",
                                lambda: self._send(self._st().channel_down),
                                tooltip="Channel down"), 1, 2, 1, 1)
        self.append(grid)

    def _st(self) -> SmartThingsAPI:
        return SmartThingsAPI(self._config.samsung_token,
                              self._config.samsung_device_id)

    def _send(self, fn, *args):
        def done(result):
            if isinstance(result, Exception):
                self._notify(f"Samsung: {result}")
        self._run_async(fn, *args, callback=done)
