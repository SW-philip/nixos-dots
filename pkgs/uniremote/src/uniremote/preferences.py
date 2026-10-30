from __future__ import annotations
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw

from samsungtvws.exceptions import UnauthorizedError

from uniremote.api import SamsungAPI, discover_roku, discover_samsung


class Preferences(Adw.PreferencesDialog):
    def __init__(self, config, run_async, notify):
        super().__init__(title="Preferences")
        self._config = config
        self._run_async = run_async
        self._notify = notify

        page = Adw.PreferencesPage()
        self.add(page)

        samsung = Adw.PreferencesGroup(
            title="Samsung TV",
            description="Pair once and accept the prompt on the TV.")
        page.add(samsung)

        self._samsung_ip_row = Adw.EntryRow(title="IP Address")
        self._samsung_ip_row.set_text(config.samsung_ip)
        samsung_discover = Gtk.Button(icon_name="system-search-symbolic",
                                      valign=Gtk.Align.CENTER,
                                      tooltip_text="Discover on network")
        samsung_discover.add_css_class("flat")
        samsung_discover.connect("clicked", lambda _: self._discover_samsung())
        self._samsung_ip_row.add_suffix(samsung_discover)
        samsung.add(self._samsung_ip_row)

        # filled in from the TV the first time it answers
        self._mac_row = Adw.EntryRow(title="MAC Address (Wake-on-LAN)")
        self._mac_row.set_text(config.samsung_mac)
        samsung.add(self._mac_row)

        pair_row = Adw.ButtonRow(title="Pair with TV")
        pair_row.connect("activated", lambda _: self._pair())
        samsung.add(pair_row)

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

    def _discover_samsung(self):
        self._notify("Scanning for Samsung TV…")
        self._run_async(discover_samsung, callback=self._samsung_discovered)

    def _samsung_discovered(self, result):
        if isinstance(result, Exception) or not result:
            self._notify("No Samsung TV found on network.")
            return
        self._samsung_ip_row.set_text(result)
        self._notify(f"Found Samsung TV at {result}")

    def _pair(self):
        ip = self._samsung_ip_row.get_text().strip()
        if not ip:
            self._notify("Enter the TV's IP first.")
            return
        self._notify("Accept the prompt on the TV…")
        api = SamsungAPI(ip, self._config.samsung_token_file)
        self._run_async(api.pair, callback=self._paired)

    def _paired(self, result):
        if isinstance(result, UnauthorizedError):
            self._notify("TV refused. Allow it under External Device Manager → Device Connection Manager.")
        elif isinstance(result, Exception):
            self._notify(f"Pairing failed: {result}")
        else:
            self._notify("Paired with TV.")

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
        self._config.samsung_ip = self._samsung_ip_row.get_text().strip()
        self._config.samsung_mac = self._mac_row.get_text().strip()
        self._config.roku_ip = self._ip_row.get_text().strip()
        self._config.save()
        self._notify("Settings saved.")
        self.close()
