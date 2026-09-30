from __future__ import annotations
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw

from uniremote.api import RokuAPI
from uniremote.widgets import icon_button, dpad, button_row

RECENT_CAP = 5


class RokuView(Gtk.Box):
    def __init__(self, config, run_async, notify):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=4,
                         margin_top=8, margin_bottom=8,
                         margin_start=10, margin_end=10)
        self._config = config
        self._run_async = run_async
        self._notify = notify
        self._app_names: dict[str, str] = {}

        self.append(button_row(
            icon_button("system-shutdown-symbolic",
                        lambda: self._key("PowerOff"),
                        tooltip="Power", css=["circular"]),
        ))

        self.append(dpad(
            on_up=lambda: self._key("Up"),
            on_down=lambda: self._key("Down"),
            on_left=lambda: self._key("Left"),
            on_right=lambda: self._key("Right"),
            on_ok=lambda: self._key("Select"),
        ))

        self.append(button_row(
            icon_button("go-previous-symbolic",
                        lambda: self._key("Back"), tooltip="Back"),
            icon_button("go-home-symbolic",
                        lambda: self._key("Home"), tooltip="Home"),
            icon_button("system-search-symbolic",
                        self._open_search, tooltip="Search"),
        ))

        self.append(button_row(
            icon_button("media-skip-backward-symbolic",
                        lambda: self._key("Rev"), tooltip="Rewind"),
            icon_button("media-playback-start-symbolic",
                        lambda: self._key("Play"), tooltip="Play / Pause"),
            icon_button("media-skip-forward-symbolic",
                        lambda: self._key("Fwd"), tooltip="Fast-forward"),
        ))

        self.append(button_row(
            icon_button("audio-volume-low-symbolic",
                        lambda: self._key("VolumeDown"), tooltip="Volume down"),
            icon_button("audio-volume-muted-symbolic",
                        lambda: self._key("VolumeMute"), tooltip="Mute"),
            icon_button("audio-volume-high-symbolic",
                        lambda: self._key("VolumeUp"), tooltip="Volume up"),
        ))

        self._recent_label = Gtk.Label(label="Recent", halign=Gtk.Align.START)
        self._recent_label.add_css_class("heading")
        self._recent_label.set_visible(False)
        self._recent_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self._recent_box.set_visible(False)
        self.append(self._recent_label)
        self.append(self._recent_box)

        self._apps_box = Gtk.FlowBox(max_children_per_line=3,
                                     selection_mode=Gtk.SelectionMode.NONE,
                                     row_spacing=6, column_spacing=6,
                                     homogeneous=True)
        scroll = Gtk.ScrolledWindow(vexpand=True)
        scroll.set_child(self._apps_box)
        self.append(scroll)

        self._run_async(self._load_apps, callback=self._on_apps_loaded)

    def _roku(self) -> RokuAPI:
        return RokuAPI(self._config.roku_ip)

    def _key(self, key: str):
        def done(result):
            if isinstance(result, Exception):
                self._notify(f"Roku: {result}")
        self._run_async(self._roku().keypress, key, callback=done)

    def _load_apps(self):
        if not self._config.roku_ip:
            return []
        return self._roku().list_apps()

    def _on_apps_loaded(self, apps):
        if isinstance(apps, Exception):
            self._notify(f"Roku: {apps}")
            return
        if not apps:
            return
        self._app_names = {app_id: name for app_id, name in apps}
        for child in list(self._apps_box):
            self._apps_box.remove(child)
        for app_id, name in apps:
            self._apps_box.append(self._app_button(app_id, name))
        self._rebuild_recent()

    def _app_button(self, app_id: str, name: str) -> Gtk.Button:
        button = Gtk.Button(label=name, hexpand=True)
        button.connect("clicked", lambda _: self._launch(app_id))
        return button

    def _launch(self, app_id: str):
        def done(result):
            if isinstance(result, Exception):
                self._notify(f"Roku: {result}")
                return
            self._record_recent(app_id)
        self._run_async(self._roku().launch_app, app_id, callback=done)

    def _record_recent(self, app_id: str):
        recent = [a for a in self._config.recent_roku_apps if a != app_id]
        recent.insert(0, app_id)
        self._config.recent_roku_apps = recent[:RECENT_CAP]
        self._config.save()
        self._rebuild_recent()

    def _rebuild_recent(self):
        for child in list(self._recent_box):
            self._recent_box.remove(child)
        ids = [a for a in self._config.recent_roku_apps if a in self._app_names]
        self._recent_label.set_visible(bool(ids))
        self._recent_box.set_visible(bool(ids))
        for app_id in ids:
            self._recent_box.append(self._app_button(app_id, self._app_names[app_id]))

    def _open_search(self):
        dialog = Adw.AlertDialog(heading="Search Roku",
                                 body="Launch a search on the Roku.")
        entry = Gtk.Entry(placeholder_text="Search…", activates_default=True)
        dialog.set_extra_child(entry)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("search", "Search")
        dialog.set_response_appearance("search", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("search")
        dialog.set_close_response("cancel")

        def on_response(_dialog, response):
            query = entry.get_text().strip()
            if response == "search" and query:
                self._run_async(self._roku().search, query, callback=self._search_done)

        dialog.connect("response", on_response)
        dialog.present(self.get_root())

    def _search_done(self, result):
        if isinstance(result, Exception):
            self._notify(f"Roku: {result}")
