"""Enumerate wayland/x sessions from .desktop files. niri is the default."""
from __future__ import annotations

import configparser
from pathlib import Path

_DEFAULT_DIRS = [
    "/run/current-system/sw/share/wayland-sessions",
    "/usr/share/wayland-sessions",
    "/usr/local/share/wayland-sessions",
    "/run/current-system/sw/share/xsessions",
    "/usr/share/xsessions",
]


def list_sessions(dirs: list[str] | None = None, default: str = "niri") -> list[dict]:
    dirs = dirs if dirs is not None else _DEFAULT_DIRS
    found: dict[str, dict] = {}
    for d in dirs:
        p = Path(d)
        if not p.is_dir():
            continue
        for f in sorted(p.glob("*.desktop")):
            cp = configparser.ConfigParser(interpolation=None, strict=False)
            try:
                cp.read(f, encoding="utf-8")
            except (OSError, configparser.Error, UnicodeDecodeError):
                continue
            if not cp.has_section("Desktop Entry"):
                continue
            entry = cp["Desktop Entry"]
            found.setdefault(f.stem, {
                "id": f.stem,
                "name": entry.get("Name", f.stem),
                "exec": entry.get("Exec", ""),
            })
    sessions = list(found.values())
    sessions.sort(key=lambda s: (s["id"] != default, s["name"].lower()))
    return sessions
