#!/usr/bin/env python3
"""gnome-keyring's password prompter, with a label saying who is asking.

gnome-keyring and gcr-ssh-agent show their dialogs through whoever owns
org.gnome.keyring.SystemPrompter, normally a D-Bus-activated gcr-prompter. This owns the name
first and serves gcr's own C dialog (GcrPromptDialog) with rows added on top. The password
path stays in C: a Python Gcr.Prompt returns its password as a borrowed string, which PyGObject
frees before gcr reads it.

The prompt always arrives from the keyring daemon or the ssh agent, so the real requester is
inferred: for a key unlock, the process waiting on the gcr ssh-agent socket; otherwise the last
app to call the Secret Service's Unlock or Prompt (watched with a D-Bus monitor connection).
"""
import os
import time

import gi

gi.require_version("Gcr", "3")
gi.require_version("Gdk", "3.0")
gi.require_version("GcrUi", "3")
gi.require_version("Gtk", "3.0")
from gi.repository import Gcr, GcrUi, Gdk, Gio, GLib, Gtk
from procinfo import chain, log, ssh_agent_clients, unit_of

PROMPTER_NAME = os.environ.get("KEYRING_PROMPTER_NAME", "org.gnome.keyring.SystemPrompter")  # override: tests
APP_ID = "dev.prepko.keyring-prompter"
SECRET_WINDOW = 10  # seconds a Secret Service call stays the likely requester

recent_secret_caller = {}  # {"pid": int, "at": monotonic}


def watch_secret_service(bus):
    """Remember the last process that asked the Secret Service to unlock or prompt."""
    addr = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None)
    mon = Gio.DBusConnection.new_for_address_sync(
        addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT
        | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    rules = ["type='method_call',interface='org.freedesktop.Secret.Prompt',member='Prompt'",
             "type='method_call',interface='org.freedesktop.Secret.Service',member='Unlock'"]
    mon.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                  "org.freedesktop.DBus.Monitoring", "BecomeMonitor",
                  GLib.Variant("(asu)", (rules, 0)), None, Gio.DBusCallFlags.NONE, -1, None)

    def resolve(sender):
        try:
            pid = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                "org.freedesktop.DBus", "GetConnectionUnixProcessID",
                                GLib.Variant("(s)", (sender,)), GLib.VariantType("(u)"),
                                Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
            recent_secret_caller.update(pid=pid, at=time.monotonic())
        except GLib.Error:
            pass
        return False

    def on_message(_conn, msg, _incoming):
        sender = msg.get_sender()
        if sender:  # runs on GDBus's worker thread: resolve on the main loop
            GLib.idle_add(resolve, sender)
        # returning nothing drops the message: a monitor only reads

    mon.add_filter(on_message)
    return mon  # keep the connection alive


def requester(title):
    """(pid, how) for the most likely process behind this prompt, or (None, reason)."""
    about_key = "key" in (title or "").lower()
    clients = ssh_agent_clients()
    if clients and about_key:
        return clients[0], "ssh-agent client"
    fresh = recent_secret_caller and time.monotonic() - recent_secret_caller["at"] < SECRET_WINDOW
    if fresh:
        return recent_secret_caller["pid"], "Secret Service caller"
    if clients:
        return clients[0], "ssh-agent client"
    return None, "not found (gnome-keyring itself?)"


class LabelledPrompt(GcrUi.PromptDialog):
    def do_constructed(self):
        GcrUi.PromptDialog.do_constructed(self)
        self.rows = Gtk.Grid(column_spacing=12, row_spacing=4, margin_bottom=6)
        area = self.get_content_area()
        area.pack_start(self.rows, False, False, 0)
        area.reorder_child(self.rows, 0)
        self.labelled = False
        self.connect("map", self._on_map)
        self.connect("response", self._on_response)
        self.connect("prompt-close", self._on_close)

    def _on_map(self, *_):
        # by the time the dialog shows, gcr has set the title and message
        if self.labelled:
            return
        self.labelled = True
        pid, how = requester(self.props.title)
        self.info = {"title": self.props.title, "pid": pid, "how": how,
                     "chain": chain(pid) if pid else None, "in": unit_of(pid) if pid else None}
        rows = [("Requested by", f"{self.info['chain']}  (pid {pid})" if pid else how)]
        if self.info["in"]:
            rows.append(("Running in", self.info["in"]))
        if pid:
            rows.append(("Found as", how))
        for r, (k, v) in enumerate(rows):
            key = Gtk.Label(label=k, xalign=1, yalign=0)
            key.get_style_context().add_class("dim-label")
            val = Gtk.Label(label=v, xalign=0, wrap=True, selectable=True, max_width_chars=44)
            self.rows.attach(key, 0, r, 1, 1)
            self.rows.attach(val, 1, r, 1, 1)
        self.rows.show_all()
        self._log("prompt")

    def _on_response(self, _dialog, response):
        self._log("answered" if response == Gtk.ResponseType.OK else "dismissed")

    def _on_close(self, *_):
        if self.labelled:  # gcr emits prompt-close more than once
            self.labelled = None
            self._log("closed")

    def _log(self, what):
        i = getattr(self, "info", {})
        log(f"{what}: " + " ".join(f"{k}={v!r}" for k, v in i.items() if v is not None))


def main():
    # GTK3 takes the Wayland app-id from the program class, which defaults to a capitalised prgname
    GLib.set_prgname(APP_ID)
    Gdk.set_program_class(APP_ID)
    Gtk.init([])
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    try:
        monitor = watch_secret_service(bus)  # noqa: F841 (held for the process lifetime)
    except GLib.Error as e:
        log(f"no Secret Service watch, keyring prompts will lack a requester: {e.message}")
    prompter = Gcr.SystemPrompter.new(Gcr.SystemPrompterMode.SINGLE, LabelledPrompt.__gtype__)
    prompter.register(bus)

    def lost(*_):
        # someone else holds the name (a gcr-prompter that started first): retry is not worth
        # it, the next session start wins; exit so systemd shows the failure
        log(f"could not own {PROMPTER_NAME}")
        Gtk.main_quit()

    Gio.bus_own_name_on_connection(bus, PROMPTER_NAME, Gio.BusNameOwnerFlags.NONE,
                                   lambda *_: log(f"owns {PROMPTER_NAME}"), lost)
    Gtk.main()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
