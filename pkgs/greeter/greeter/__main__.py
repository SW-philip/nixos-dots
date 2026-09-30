"""Entry point. Real mode talks to greetd; --dev runs the UI with a mock IPC."""
from __future__ import annotations

import argparse
import sys

from .palette import load_dsa, load_theme
from .sessions import _DEFAULT_DIRS, list_sessions
from .users import list_human_users

_DEFAULT_PALETTE_FILE = "/run/greeter/palette.sh"


class _MockIPC:
    """Dev-only: accepts password 'x', otherwise fails."""
    def create_session(self, username):
        return {"type": "auth_message", "auth_message_type": "secret",
                "auth_message": "Password:"}

    def post_response(self, response):
        return {"type": "success"} if response == "x" else \
            {"type": "error", "description": "try password: x"}

    def start_session(self, cmd, env=None):
        print("would start:", cmd)
        return {"type": "success"}

    def cancel_session(self):
        return {"type": "success"}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="greeter")
    ap.add_argument("--palette", choices=("theme", "dsa"), default="theme",
                    help="'theme' follows the live palette (--palette-file); "
                         "'dsa' is the fixed DSA preset")
    ap.add_argument("--palette-file", default=_DEFAULT_PALETTE_FILE,
                    help="palette.sh to read in --palette theme mode")
    ap.add_argument("--sessions-dir", action="append", dest="sessions_dirs",
                    help="wayland/x session dir to scan first; repeatable. "
                         "Point this at services.displayManager.sessionData.desktops "
                         "so every registered session (niri, mango, …) is offered — "
                         "the /run/current-system default dirs aren't populated under greetd.")
    ap.add_argument("--default-user", default=None,
                    help="username to pre-select in the user pill; falls back to "
                         "the first user (alphabetical) when absent or not found")
    ap.add_argument("--dev", action="store_true", help="run with mock IPC")
    ap.add_argument("--scale", type=float, default=1.0,
                    help="UI size multiplier for HiDPI (cage outputs are scale 1)")
    ap.add_argument("--field-scale", type=float, default=None,
                    help="size multiplier for the field cluster only; defaults to --scale")
    args = ap.parse_args(argv)

    palette = load_dsa() if args.palette == "dsa" else load_theme(args.palette_file)
    users = list_human_users()
    dirs = (args.sessions_dirs + _DEFAULT_DIRS) if args.sessions_dirs else None
    sessions = list_sessions(dirs)

    if args.dev:
        ipc = _MockIPC()
    else:
        from .greetd_ipc import GreetdClient
        ipc = GreetdClient.connect()

    from .app import GreeterApp
    app = GreeterApp(palette, users, sessions, ipc, scale=args.scale,
                     field_scale=args.field_scale, default_user=args.default_user)
    return app.run([])


if __name__ == "__main__":
    sys.exit(main())
