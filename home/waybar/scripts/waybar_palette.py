"""Shared palette.sh reader for the streaming waybar scripts.

palette.sh is rewritten by drmis on every theme change, so callers keep one
Palette around and call get() each tick; it re-parses only when the mtime moves.
"""
import re
from pathlib import Path

PALETTE_FILE = Path.home() / ".config/waybar/palette.sh"
_EXPORT_RE = re.compile(r'^export\s+([A-Z0-9_]+)="([^"]*)"')


class Palette:
    def __init__(self, path: Path = PALETTE_FILE) -> None:
        self.path = path
        self._mtime = None
        self._colors: dict[str, str] = {}

    def changed(self) -> bool:
        try:
            return self.path.stat().st_mtime != self._mtime
        except OSError:
            return False

    def get(self) -> dict[str, str]:
        mtime = self.path.stat().st_mtime
        if mtime != self._mtime:
            colors = {}
            for line in self.path.read_text().splitlines():
                m = _EXPORT_RE.match(line)
                if m:
                    colors[m.group(1)] = m.group(2)
            self._colors, self._mtime = colors, mtime
        return self._colors
