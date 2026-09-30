from __future__ import annotations
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw

from uniremote.api import SmartThingsAPI, discover_roku


class Preferences(Adw.PreferencesDialog):
    def __init__(self, config, run_async, notify):
        super().__init__(title="Preferences")
        self._config = config
        self._run_async = run_async
        self._notify = notify
        self._device_ids: list[str] = []

        page = Adw.PreferencesPage()
        self.add(page)

        samsung = Adw.PreferencesGroup(title="Samsung SmartThings")
        page.add(samsung)

        self._token_row = Adw.PasswordEntryRow(title="API Token")
        self._token_row.set_text(config.samsung_token)
        fetch_btn = Gtk.Button(icon_name="view-refresh-symbolic",
                               valign=Gtk.Align.CENTER,
                               tooltip_text="Fetch devices")
        fetch_btn.add_css_class("flat")
        fetch_btn.connect("clicked", lambda _: self._fetch_devices())
        self._token_row.add_suffix(fetch_btn)
        samsung.add(self._token_row)

        self._device_row = Adw.ComboRow(
            title="Device",
            model=Gtk.StringList.new(["(fetch devices first)"]),
        )
        if config.samsung_device_id:
            self._device_ids = [config.samsung_device_id]
            self._device_row.set_model(
                Gtk.StringList.new([f"Saved: {config.samsung_device_id}"]))
        samsung.add(self._device_row)

        roku = Adw.PreferencesGroup(title="Roku")
        page.add(roku)

        self._ip_row = Adw.EntryRow(title="IP Address")
        self._ip_row.set_text(config.roku_ip)
        discover_btn = Gtk.Button(icon_name="system-search-symbolic",
                                  valign=Gtk.Align.CENTER,
                                  tooltip_text="Discover on network")
        discover_btn.add_css_class("flat")
        discover_btn.connect("clicked", lambda _: self._discover())
        self._ip_row.add_suffix(discover_btn)
        roku.add(self._ip_row)

        actions = Adw.PreferencesGroup()
        page.add(actions)
        save_row = Adw.ButtonRow(title="Save Settings")
        save_row.add_css_class("suggested-action")
        save_row.connect("activated", lambda _: self._save())
        actions.add(save_row)

    def _fetch_devices(self):
        token = self._token_row.get_text().strip()
        if not token:
            self._notify("Enter an API token first.")
            return
        self._notify("Fetching devices…")
        self._run_async(SmartThingsAPI.fetch_devices, token,
                        callback=self._devices_fetched)

    def _devices_fetched(self, result):
        if isinstance(result, Exception):
            self._notify(f"Error: {result}")
            return
        if not result:
            self._notify("No devices found.")
            return
        self._device_ids = [d[0] for d in result]
        self._device_row.set_model(Gtk.StringList.new([d[1] for d in result]))
        self._notify(f"Found {len(result)} device(s).")

    def _discover(self):
        self._notify("Scanning for Roku…")
        self._run_async(discover_roku, callback=self._discovered)

    def _discovered(self, result):
        if isinstance(result, Exception) or not result:
            self._notify("No Roku found on network.")
            return
        self._ip_row.set_text(result)
        self._notify(f"Found Roku at {result}")

    def _save(self):
        self._config.samsung_token = self._token_row.get_text().strip()
        idx = self._device_row.get_selected()
        if self._device_ids and idx < len(self._device_ids):
            self._config.samsung_device_id = self._device_ids[idx]
        self._config.roku_ip = self._ip_row.get_text().strip()
        self._config.save()
        self._notify("Settings saved.")
        self.close()
