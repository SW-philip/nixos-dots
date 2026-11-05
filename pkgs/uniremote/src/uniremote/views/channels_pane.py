from __future__ import annotations
from pathlib import Path
from typing import Callable

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GLib, Gtk, Pango

from uniremote.channels import sections

PANE_WIDTH = 340
ICON_PX = 36
PLACEHOLDER_ICON = "applications-multimedia-symbolic"
HEADINGS = (("favorites", "Favorites"), ("recent", "Recent"), ("all", "All channels"))


class ChannelsPane(Gtk.Box):
    """Favorites, Recent and All channels with a search filter, attached to the remote's right edge."""

    def __init__(self, config, on_launch: Callable[[str], None],
                 icon_for: Callable[[str], Path | None],
                 request_icon: Callable[[str], None]):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=6,
                         margin_top=8, margin_bottom=8, margin_start=6, margin_end=10)
        self.add_css_class("ur-pane")
        self.set_size_request(PANE_WIDTH, -1)
        self._config = config
        self._on_launch = on_launch
        self._icon_for = icon_for
        self._request_icon = request_icon
        self._apps: list[tuple[str, str]] = []
        self._pictures: dict[str, list[Gtk.Image]] = {}
        self._requested: set[str] = set()

        self._search = Gtk.SearchEntry(placeholder_text="Search channels")
        self._search.add_css_class("ur-pane-search")
        self._search.connect("search-changed", lambda _e: self.refresh())
        self.append(self._search)

        self._list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        scroll = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        scroll.set_child(self._list)
        self.append(scroll)

    def set_apps(self, apps) -> None:
        self._apps = list(apps)
        self.refresh()

    def refresh(self) -> None:
        """Rebuild the rows from the config and the current search text."""
        self._pictures.clear()
        child = self._list.get_first_child()
        while child is not None:
            following = child.get_next_sibling()
            self._list.remove(child)
            child = following
        parts = sections(self._apps, self._config.favorite_roku_apps,
                         self._config.recent_roku_apps, self._search.get_text())
        for key, title in HEADINGS:
            rows = parts[key]
            if not rows:
                continue
            heading = Gtk.Label(label=title.upper(), xalign=0)
            heading.add_css_class("ur-pane-heading")
            self._list.append(heading)
            for app_id, name in rows:
                self._list.append(self._row(app_id, name))

    def icon_ready(self, app_id: str) -> None:
        for image in self._pictures.get(app_id, []):
            self._load_icon(image, app_id)

    def _row(self, app_id: str, name: str) -> Gtk.Box:
        icon = Gtk.Image(icon_name=PLACEHOLDER_ICON, pixel_size=ICON_PX)
        self._pictures.setdefault(app_id, []).append(icon)
        self._load_icon(icon, app_id)
        if app_id not in self._requested:
            self._requested.add(app_id)
            self._request_icon(app_id)

        label = Gtk.Label(label=name, xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END)
        inner = Gtk.Box(spacing=10)
        inner.append(icon)
        inner.append(label)
        launch = Gtk.Button(child=inner, hexpand=True)
        launch.add_css_class("ur-chan")
        launch.connect("clicked", lambda _b, i=app_id: self._on_launch(i))

        favorite = app_id in self._config.favorite_roku_apps
        star = Gtk.Button(icon_name="starred-symbolic" if favorite else "non-starred-symbolic",
                          tooltip_text="Remove favorite" if favorite else "Add favorite")
        star.add_css_class("ur-chan-star")
        star.connect("clicked", lambda _b, i=app_id: self._toggle_favorite(i))

        row = Gtk.Box(spacing=4)
        row.append(launch)
        row.append(star)
        return row

    def _load_icon(self, image: Gtk.Image, app_id: str) -> None:
        path = self._icon_for(app_id)
        if path is None:
            return
        try:
            image.set_from_paintable(Gdk.Texture.new_from_filename(str(path)))
        except GLib.Error:
            pass  # unreadable file: keep the placeholder

    def _toggle_favorite(self, app_id: str) -> None:
        self._config.toggle_favorite(app_id)
        self._config.save()
        self.refresh()
