#!/usr/bin/env python3
"""Notification history for the eww notif-center: watches the session bus for
Notify calls (swaync stays the daemon) and keeps the list swaync won't expose."""

import asyncio
import json
import os
import signal
import subprocess
import sys
import time

import notif_search

SWAYNC = ("org.erikreider.swaync.cc", "/org/erikreider/swaync/cc", "org.erikreider.swaync.cc")
RULES = ["type='method_call',interface='org.freedesktop.Notifications',member='Notify'",
         "type='method_return',sender='org.freedesktop.Notifications'",
         "type='signal',interface='org.freedesktop.Notifications',member='NotificationClosed'"]
URGENCY_RANK = {"critical": 0, "normal": 1, "low": 2}
GROUP_WINDOW = 600  # seconds, measured from a group's newest item


class History:
    def __init__(self, cap=100):
        self.cap = cap
        self.items = []      # newest first
        self.pending = {}    # (sender, serial) -> (args, now)
        self.query = ""

    def on_notify(self, sender, serial, args, now):
        self.pending = {k: v for k, v in self.pending.items() if now - v[1] <= 30}
        self.pending[(sender, serial)] = (args, now)

    def on_return(self, dest, reply_serial, body):
        hit = self.pending.pop((dest, reply_serial), None)
        if hit is None or not body:
            return False
        args, now = hit
        nid = int(body[0])
        app, _replaces, icon, summary, text, _actions, hints, _timeout = args[:8]
        entry = {"id": nid, "app": app, "summary": summary, "body": text,
                 "icon": icon, "urgency": _urgency(hints), "time": now}
        self.items = [i for i in self.items if i["id"] != nid]
        self.items.insert(0, entry)
        del self.items[self.cap:]
        return True

    def on_closed(self, nid):
        kept = [i for i in self.items if i["id"] != nid]
        changed = len(kept) != len(self.items)
        self.items = kept
        return changed

    def clear(self):
        self.items = []

    def set_query(self, text):
        self.query = text

    def snapshot(self):
        q = notif_search.parse_query(self.query)
        groups = notif_search.annotate_groups(group_items(self.items), q)
        return {"count": len(self.items), "items": list(self.items), "groups": groups,
                "query": self.query,
                "matches": sum(notif_search.item_matches(i, q) for i in self.items)}


def _urgency(hints):
    raw = hints.get("urgency")
    level = getattr(raw, "value", raw)
    return {0: "low", 2: "critical"}.get(level, "normal")


def group_items(items, window=GROUP_WINDOW):
    """Stack same-app items (newest first in) and sort critical first, low last."""
    groups = []
    for it in items:
        for g in groups:
            if g["app"] == it["app"] and g["items"][0]["time"] - it["time"] <= window:
                g["items"].append(it)
                break
        else:
            groups.append({"app": it["app"], "items": [it]})
    for g in groups:
        g["count"] = len(g["items"])
        g["ids"] = " ".join(str(i["id"]) for i in g["items"])
        g["urgency"] = min((i["urgency"] for i in g["items"]), key=URGENCY_RANK.get)
        g["time"] = g["items"][0]["time"]
        # Oldest id: stable while newer items join the stack. Shell-safe for EWW.
        g["key"] = f"g{g['items'][-1]['id']}"
    groups.sort(key=lambda g: (URGENCY_RANK[g["urgency"]], -g["time"]))
    return groups


def state_path():
    return os.path.join(os.environ["XDG_RUNTIME_DIR"], "notif-history.json")


def write_state(hist):
    tmp = state_path() + ".tmp"
    with open(tmp, "w") as f:
        json.dump(hist.snapshot(), f)
    os.replace(tmp, state_path())


async def monitor():
    from dbus_fast import Message, MessageType
    from dbus_fast.aio import MessageBus

    hist = History()
    notif_search.write_query("")
    write_state(hist)
    bus = await MessageBus().connect()

    def handle(m):
        changed = False
        try:
            if m.message_type == MessageType.METHOD_CALL and m.member == "Notify":
                hist.on_notify(m.sender, m.serial, m.body, time.time())
            elif m.message_type == MessageType.METHOD_RETURN:
                changed = hist.on_return(m.destination, m.reply_serial, m.body)
            elif m.message_type == MessageType.SIGNAL and m.member == "NotificationClosed":
                changed = hist.on_closed(m.body[0])
        except Exception as e:  # noqa: BLE001
            print(f"notif-history: {e!r}", file=sys.stderr)
            return True  # malformed message: keep the monitor alive
        if changed:
            write_state(hist)
        # handled: otherwise dbus-fast replies UNKNOWN_METHOD to a Notify call,
        # and the broker drops a monitor connection that sends
        return True

    def clear():
        hist.clear()
        write_state(hist)

    def requery():
        hist.set_query(notif_search.read_query())
        write_state(hist)

    asyncio.get_running_loop().add_signal_handler(signal.SIGUSR1, clear)
    asyncio.get_running_loop().add_signal_handler(signal.SIGUSR2, requery)

    bus.add_message_handler(handle)
    await bus.call(Message(destination="org.freedesktop.DBus", path="/org/freedesktop/DBus",
                           interface="org.freedesktop.DBus.Monitoring", member="BecomeMonitor",
                           signature="asu", body=[RULES, 0]))
    await bus.wait_for_disconnect()


def swaync_call(member, signature="", body=()):
    dest, path, iface = SWAYNC
    args = ["busctl", "--user", "call", dest, path, iface, member]
    if signature:
        args += [signature, *map(str, body)]
    subprocess.run(args, check=False, stdout=subprocess.DEVNULL)


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "run"
    if cmd == "run":
        asyncio.run(monitor())
    elif cmd == "dismiss" and len(argv) >= 3:
        for nid in argv[2:]:
            swaync_call("CloseNotification", "u", [int(nid)])
    elif cmd == "clear":
        swaync_call("CloseAllNotifications")
        # swaync may not emit NotificationClosed per item for close-all, so the
        # daemon (which owns the in-memory list) clears itself on SIGUSR1
        subprocess.run(["systemctl", "--user", "kill", "-s", "USR1", "notif-history.service"],
                       check=False)
    elif cmd == "query":
        notif_search.write_query(" ".join(argv[2:]))
        subprocess.run(["systemctl", "--user", "kill", "-s", "USR2", "notif-history.service"],
                       check=False)
    else:
        sys.exit("usage: notif_history.py run | dismiss ID [ID...] | clear | query [TEXT...]")


if __name__ == "__main__":
    main(sys.argv)
