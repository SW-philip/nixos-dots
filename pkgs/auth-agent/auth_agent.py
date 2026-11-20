#!/usr/bin/env python3
"""Polkit authentication agent whose dialog says who is asking.

polkit hands the agent the action's details (unit, verb, the requesting pid) and every stock
agent throws them away, so a 3 a.m. "authentication required" says nothing about its source.
This one labels the dialog with the requesting process chain, the systemd unit it runs in and
what it wants, and logs every prompt and its outcome to the journal (journalctl --user -u
polkit-agent). Only /proc/<pid>/comm is read, never cmdlines: those can carry tokens.
"""
import os
import shlex
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Pango", "1.0")
gi.require_version("Polkit", "1.0")
gi.require_version("PolkitAgent", "1.0")
from gi.repository import Gio, GLib, Gtk, Pango, Polkit, PolkitAgent
from procinfo import chain, log, unit_of

APP_ID = "dev.prepko.auth-agent"
OBJECT_PATH = "/dev/prepko/AuthAgent"


def describe(details):
    get = details.get  # None for a key the mechanism did not send
    pid = get("polkit.subject-pid") or get("polkit.caller-pid")
    info = {"verb": get("verb"), "unit": get("unit"), "command": get("command_line")}
    if pid and pid.isdigit():
        info["pid"] = int(pid)
        info["chain"] = chain(int(pid))
        info["in"] = unit_of(int(pid))
    return info


def pick_identity(identities):
    uid = os.getuid()
    for ident in identities:
        if isinstance(ident, Polkit.UnixUser) and ident.get_uid() == uid:
            return ident
    return identities[0]


def identity_name(ident):
    if isinstance(ident, Polkit.UnixUser):
        return ident.get_name() or str(ident.get_uid())
    return ident.to_string()


class Prompt:
    """One authentication request: the dialog plus its PolkitAgent.Session."""

    def __init__(self, app, reply, action_id, message, details, cookie, identities):
        self.app, self.reply, self.cookie = app, reply, cookie
        self.action_id, self.message = action_id, message
        self.identity = pick_identity(identities)
        self.info = describe(details)
        self.session = None
        self.done = False
        self._build()
        self._log("prompt")
        self._start_session()

    # ── dialog ────────────────────────────────────────────────────────────
    def _build(self):
        self.win = Gtk.Window(application=self.app, title="Authentication required",
                              modal=True, resizable=False)
        self.win.connect("close-request", self._on_close_request)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                      margin_top=20, margin_bottom=20, margin_start=20, margin_end=20)

        head = Gtk.Label(xalign=0, wrap=True, width_chars=40, max_width_chars=56)
        head.set_markup(f"<b>{GLib.markup_escape_text(self.message)}</b>")
        box.append(head)

        grid = Gtk.Grid(column_spacing=12, row_spacing=4)
        rows = []
        i = self.info
        if i.get("chain"):
            rows.append(("Requested by", f"{i['chain']}  (pid {i['pid']})"))
        if i.get("in"):
            rows.append(("Running in", i["in"]))
        if i.get("unit"):
            rows.append(("Wants", f"{i.get('verb') or '?'} {i['unit']}"))
        elif i.get("command"):
            rows.append(("Command", i["command"]))
        rows.append(("Action", self.action_id))
        rows.append(("As user", identity_name(self.identity)))
        for r, (k, v) in enumerate(rows):
            key = Gtk.Label(label=k, xalign=1, yalign=0)
            key.add_css_class("dim-label")
            val = Gtk.Label(label=v, xalign=0, wrap=True, wrap_mode=Pango.WrapMode.WORD_CHAR,
                            selectable=True, width_chars=30, max_width_chars=44)
            grid.attach(key, 0, r, 1, 1)
            grid.attach(val, 1, r, 1, 1)
        box.append(grid)

        self.request = Gtk.Label(label="Password:", xalign=0)
        box.append(self.request)
        self.entry = Gtk.PasswordEntry(show_peek_icon=True, hexpand=True)
        self.entry.connect("activate", self._on_submit)
        box.append(self.entry)
        self.status = Gtk.Label(xalign=0, wrap=True)
        self.status.add_css_class("error")
        box.append(self.status)

        buttons = Gtk.Box(spacing=8, halign=Gtk.Align.END)
        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda *_: self._finish(False, "cancelled"))
        self.ok = Gtk.Button(label="Authenticate")
        self.ok.add_css_class("suggested-action")
        self.ok.connect("clicked", self._on_submit)
        buttons.append(cancel)
        buttons.append(self.ok)
        box.append(buttons)

        self.win.set_child(box)
        self.win.present()
        self.entry.grab_focus()

    # ── polkit session ────────────────────────────────────────────────────
    def _start_session(self):
        s = PolkitAgent.Session.new(self.identity, self.cookie)
        s.connect("request", self._on_request)
        s.connect("show-error", lambda _s, text: self.status.set_text(text))
        s.connect("show-info", lambda _s, text: self.status.set_text(text))
        s.connect("completed", self._on_completed)
        self.session = s
        self.entry.set_sensitive(False)
        self.ok.set_sensitive(False)
        s.initiate()

    def _on_request(self, _s, request, echo_on):
        text = request.strip()
        self.request.set_text("Password:" if text.lower().startswith("password") else text)
        self.entry.set_sensitive(True)
        self.ok.set_sensitive(True)
        self.entry.grab_focus()

    def _on_submit(self, *_):
        if not self.session or not self.entry.get_sensitive():
            return
        self.entry.set_sensitive(False)
        self.ok.set_sensitive(False)
        self.session.response(self.entry.get_text())
        self.entry.set_text("")

    def _on_completed(self, s, gained):
        if self.done:
            return
        if gained:
            self._finish(True, "authorized")
            return
        # wrong password: a session answers once, so start a fresh one and keep the dialog
        self.status.set_text("Authentication failed, try again.")
        self.win.queue_draw()
        self._log("failed attempt")
        GLib.idle_add(self._restart)

    def _restart(self):
        if not self.done:
            self._start_session()
        return False

    # ── ending ────────────────────────────────────────────────────────────
    def _on_close_request(self, *_):
        self._finish(False, "dismissed")
        return False

    def _on_caller_cancel(self, *_):
        # the requester went away (e.g. its job finished): close without an answer
        GLib.idle_add(self._finish, False, "withdrawn by caller")

    def _finish(self, gained, outcome):
        if self.done:
            return False
        self.done = True
        self._log(outcome)
        if self.session and not gained:
            self.session.cancel()
        self.reply(gained)
        self.win.destroy()
        return False

    def _log(self, what):
        i = self.info
        fields = [f"action={self.action_id}"] + [
            f"{k}={shlex.quote(str(i[k]))}" for k in ("verb", "unit", "chain", "in", "pid")
            if i.get(k) is not None]
        log(f"{what}: " + " ".join(fields))


AGENT_XML = """<node><interface name='org.freedesktop.PolicyKit1.AuthenticationAgent'>
  <method name='BeginAuthentication'>
    <arg type='s' name='action_id' direction='in'/>
    <arg type='s' name='message' direction='in'/>
    <arg type='s' name='icon_name' direction='in'/>
    <arg type='a{ss}' name='details' direction='in'/>
    <arg type='s' name='cookie' direction='in'/>
    <arg type='a(sa{sv})' name='identities' direction='in'/>
  </method>
  <method name='CancelAuthentication'><arg type='s' name='cookie' direction='in'/></method>
</interface></node>"""


class Agent:
    """The org.freedesktop.PolicyKit1.AuthenticationAgent object, exported by hand.

    PolkitAgent.Listener can't be subclassed from PyGObject: its vfunc passes polkit's
    completion callback with user_data=None, so finishing any request calls auth_cb(NULL)
    and the agent segfaults after its first dialog.
    """

    def __init__(self, app):
        self.app = app
        self.prompts = {}
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    def register(self, subject, path):
        node = Gio.DBusNodeInfo.new_for_xml(AGENT_XML)
        self.bus.register_object(path, node.interfaces[0], self._on_call, None, None)
        locale = next((os.environ[k] for k in ("LC_ALL", "LC_MESSAGES", "LANG")
                       if os.environ.get(k)), "en_US.UTF-8")
        Polkit.Authority.get_sync(None).register_authentication_agent_sync(
            subject, locale, path, None)

    def _polkitd(self):
        try:
            r = self.bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                   "org.freedesktop.DBus", "GetNameOwner",
                                   GLib.Variant("(s)", ("org.freedesktop.PolicyKit1",)),
                                   None, Gio.DBusCallFlags.NONE, -1, None)
            return r.unpack()[0]
        except GLib.Error:
            return None

    def _on_call(self, _conn, sender, _path, _iface, method, params, invocation):
        # any process can reach this bus name; only polkitd may raise a password dialog
        if sender != self._polkitd():
            invocation.return_dbus_error("org.freedesktop.DBus.Error.AccessDenied",
                                         "only polkitd may call the authentication agent")
        elif method == "BeginAuthentication":
            self._begin(invocation, *params.unpack())
        elif method == "CancelAuthentication":
            prompt = self.prompts.get(params.unpack()[0])
            if prompt:
                prompt._on_caller_cancel()
                invocation.return_value(None)
            else:
                invocation.return_error_literal(Polkit.error_quark(), int(Polkit.Error.FAILED),
                                                "No pending authentication request for that cookie")

    def _begin(self, invocation, action_id, message, _icon, details, cookie, identities):
        def reply(gained):
            self.prompts.pop(cookie, None)
            if gained:
                invocation.return_value(None)
            else:
                invocation.return_error_literal(Polkit.error_quark(), int(Polkit.Error.CANCELLED),
                                                "Authentication dialog was dismissed")

        if os.environ.get("AUTH_AGENT_HEADLESS"):  # testing: log what polkit sent, decline
            log(f"headless: action={action_id} details={details}")
            reply(False)
            return
        idents = [Polkit.Identity.from_string(f"{kind}:{next(iter(d.values()))}")
                  for kind, d in identities]
        try:
            self.prompts[cookie] = Prompt(self.app, reply, action_id, message, details, cookie, idents)
        except Exception as e:  # never leave polkitd's call unanswered
            log(f"prompt failed: {e!r}")
            reply(False)


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.agent = None

    def do_startup(self):
        Gtk.Application.do_startup(self)
        self.hold()  # stay up with no window open
        self.agent = Agent(self)
        pid = int(os.environ.get("AUTH_AGENT_PROCESS", "0"))
        if pid:  # testing: answer only for one process (pkttyagent --process style)
            subject = Polkit.UnixProcess.new_for_owner(pid, 0, os.getuid())
        else:
            subject = Polkit.UnixSession.new_for_process_sync(os.getpid(), None)
        try:
            self.agent.register(subject, OBJECT_PATH)
        except GLib.Error as e:
            log(f"could not register as the polkit agent: {e.message}")
            sys.exit(1)
        log(f"registered for {subject.to_string()}")

    def do_activate(self):
        pass


if __name__ == "__main__":
    sys.exit(App().run([sys.argv[0]]))
