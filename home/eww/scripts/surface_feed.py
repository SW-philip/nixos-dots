#!/usr/bin/env python3
"""Event-driven eww deflisten feeds. Each prints its current value at start,
then one line per change.

  tablet  true while the Type Cover is detached (surface-kbd-monitor's state file)
  osk     true while squeekboard is running with its keyboard visible
"""
import asyncio
import os
import sys
from pathlib import Path

COVER_FILE = "surface-cover"
OSK_NAME = "sm.puri.OSK0"
OSK_PATH = "/sm/puri/OSK0"
PROPS = "org.freedesktop.DBus.Properties"
BUS = "org.freedesktop.DBus"


def cover_path():
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(runtime) / COVER_FILE


def read_cover(path):
    try:
        return path.read_text().strip() == "detached"
    except OSError:
        return False


class Changes:
    """Forwards a value to emit() only when it differs from the last one."""

    def __init__(self, emit):
        self._emit = emit
        self._last = None

    def push(self, value):
        if value != self._last:
            self._last = value
            self._emit(value)


class OskState:
    def __init__(self):
        self.present = False
        self.visible = False

    @property
    def value(self):
        return self.present and self.visible


def watch_cover(path, emit, stop=None):
    from inotify_simple import INotify, flags

    out = Changes(emit)
    ino = INotify()
    # The directory is watched, not the file: the file is rewritten in place
    # and may not exist yet. Truncation (MODIFY) is skipped on purpose so an
    # empty half-written file is never read.
    ino.add_watch(str(path.parent),
                  flags.CLOSE_WRITE | flags.MOVED_TO | flags.MOVED_FROM | flags.DELETE)
    try:
        out.push(read_cover(path))
        while not (stop and stop.is_set()):
            for ev in ino.read(timeout=200):
                if ev.name == path.name:
                    out.push(read_cover(path))
    finally:
        ino.close()


async def osk_feed(emit):
    from dbus_fast import BusType, Message, MessageType
    from dbus_fast.aio import MessageBus

    out = Changes(emit)
    state = OskState()
    bus = await MessageBus(bus_type=BusType.SESSION).connect()

    def call(destination, path, interface, member, signature="", body=()):
        return bus.call(Message(destination=destination, path=path, interface=interface,
                                member=member, signature=signature, body=list(body)))

    async def read_visible():
        reply = await call(OSK_NAME, OSK_PATH, PROPS, "Get", "ss", [OSK_NAME, "Visible"])
        return reply.message_type == MessageType.METHOD_RETURN and bool(reply.body[0].value)

    async def set_present(present):
        state.present = present
        state.visible = await read_visible() if present else False
        out.push(state.value)

    def on_message(msg):
        if msg.message_type != MessageType.SIGNAL:
            return
        if msg.member == "NameOwnerChanged" and msg.body[0] == OSK_NAME:
            asyncio.ensure_future(set_present(bool(msg.body[2])))
        elif msg.member == "PropertiesChanged" and msg.path == OSK_PATH \
                and msg.body[0] == OSK_NAME and "Visible" in msg.body[1]:
            state.visible = bool(msg.body[1]["Visible"].value)
            out.push(state.value)

    bus.add_message_handler(on_message)
    for rule in (
        f"type='signal',sender='{BUS}',interface='{BUS}',member='NameOwnerChanged',arg0='{OSK_NAME}'",
        f"type='signal',interface='{PROPS}',member='PropertiesChanged',path='{OSK_PATH}'",
    ):
        await call(BUS, "/org/freedesktop/DBus", BUS, "AddMatch", "s", [rule])

    # Subscribe first, then look up the current owner, so no transition is missed.
    reply = await call(BUS, "/org/freedesktop/DBus", BUS, "NameHasOwner", "s", [OSK_NAME])
    await set_present(bool(reply.body[0]))

    await bus.wait_for_disconnect()
    print("surface_feed: session bus went away", file=sys.stderr)
    return 1


def main(argv):
    if len(argv) != 2 or argv[1] not in ("tablet", "osk"):
        print(__doc__, file=sys.stderr)
        return 2

    def emit(value):
        print("true" if value else "false", flush=True)

    try:
        if argv[1] == "tablet":
            watch_cover(cover_path(), emit)
            return 0
        return asyncio.run(osk_feed(emit))
    except (BrokenPipeError, KeyboardInterrupt):
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
