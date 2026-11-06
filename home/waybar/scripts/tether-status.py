#!/usr/bin/env python3
"""Waybar status and thread list for tetherd, read from its JSON socket.

Never spawns the daemon: a missing socket just means "offline", so the poll
can't leave a stray tetherd holding the runtime lock.
  tether-status.py            waybar JSON
  tether-status.py threads    one "key<TAB>label" per conversation, unread first
"""
import html
import json
import os
import socket
import sys

SOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "tether", "tetherd.sock")
GLYPH = '<span font_family="Hack Nerd Font Mono"></span>'


def ask(sock, command, replies):
    sock.sendall((json.dumps({"command": command}) + "\n").encode())
    buf = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            raise OSError("daemon closed the socket")
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("command") in replies:
                return msg


def fetch():
    """(connection, threads), or None when tetherd isn't answering."""
    try:
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(2)
            sock.connect(SOCK)
            conn = ask(sock, "bt_connection", {"bt_connection", "bt_connection_changed"})
            threads = ask(sock, "bt_list_threads", {"bt_threads"}).get("threads", [])
        return conn, threads
    except (OSError, TimeoutError):
        return None


def out(text, tooltip, cls):
    print(json.dumps({"text": text, "tooltip": tooltip, "class": cls}), flush=True)


def link(ok, held, label):
    mark = "●" if ok else ("◌" if held else "○")
    return f"{mark} {label}"


def status():
    got = fetch()
    if got is None:
        return out(GLYPH, "tether: daemon not running", "offline")
    conn, threads = got
    if not conn.get("device_present") or not conn.get("device_paired"):
        reason = conn.get("link_reason") or "no iPhone paired over Bluetooth"
        return out(GLYPH, "tether: " + html.escape(reason), "disconnected")

    calls = conn.get("calls") or {}
    unread = sum(t.get("unread", 0) for t in threads)
    on_call = calls.get("calls", 0) > 0
    links = [
        (conn.get("map_open"), conn.get("map_held"), "Messages"),
        (conn.get("pbap_open"), conn.get("pbap_held"), "Contacts"),
        (conn.get("ancs_ready"), conn.get("ancs_held"), "Notifications"),
        (calls.get("available"), False, "Calls"),
    ]
    lines = []
    if conn.get("battery") is not None:
        lines.append(f"battery {conn['battery']}%")
    lines += [link(*entry) for entry in links]
    if unread:
        lines.append(f"{unread} unread")
    for reason in (conn.get("profile_reason"), conn.get("ancs_reason")):
        if reason and reason not in lines:
            lines.append(reason)

    cls = "connected" if all(ok for ok, _, _ in links) else "partial"
    if unread:
        cls += " unread"
    if on_call:
        cls += " call"
    text = GLYPH + (f" {unread}" if unread else "")
    out(text, html.escape("\n".join(lines)), cls)


def threads():
    got = fetch()
    if got is None:
        return
    for t in sorted(got[1], key=lambda t: (-t.get("unread", 0), -t.get("timestamp", 0))):
        name = (t.get("name") or t.get("address") or t["thread"]).replace("\t", " ")
        mark = f" ({t['unread']})" if t.get("unread") else ""
        group = " [group]" if t.get("group") else ""
        preview = (t.get("preview") or "").replace("\t", " ").replace("\n", " ")[:60]
        print(f"{t['thread']}\t{name}{mark}{group}  {preview}")


if __name__ == "__main__":
    threads() if sys.argv[1:] == ["threads"] else status()
