"""Shared palette.sh reader for the streaming waybar scripts.

palette.sh is rewritten by drmis on every theme change, so callers keep one
Palette around and call get() each tick; it re-parses only when the mtime moves.
"""
import random
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


SPARKLE_ACCENTS = ("ROOT", "FIFTH", "SOTTO", "SEVENTH", "PIANO")
_MARKUP_RE = re.compile(r"(<[^>]*>|&#?\w+;)")


def sparkle(markup: str, p: dict[str, str], n: int | None = None) -> str:
    """Recolor a couple of random letters in Pango `markup` with theme accents.

    Tags and entities are left alone, so existing spans still apply and the new
    one nests inside. Seeded by the visible text: picks hold still while a
    module repeats itself and reshuffle only when its text changes."""
    pool = [p[k] for k in SPARKLE_ACCENTS if k in p]
    parts = _MARKUP_RE.split(markup)
    slots = [(i, j) for i, part in enumerate(parts) if i % 2 == 0
             for j, ch in enumerate(part) if ch.isalpha()]
    if not pool or not slots:
        return markup
    if n is None:
        n = 1 if len(slots) < 6 else 2
    rng = random.Random("".join(parts[::2]))
    lit = {(i, j): f'<span foreground="{rng.choice(pool)}">{parts[i][j]}</span>'
           for i, j in rng.sample(slots, min(n, len(slots)))}
    return "".join("".join(lit.get((i, j), c) for j, c in enumerate(part)) if i % 2 == 0 else part
                   for i, part in enumerate(parts))
