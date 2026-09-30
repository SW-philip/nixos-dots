"""Load a palette for the greeter. No GTK."""
from __future__ import annotations

import re
from dataclasses import dataclass
from importlib import resources
from pathlib import Path

from . import colors

_EXPORT_RE = re.compile(r'^\s*(?:export\s+)?([A-Z0-9_]+)\s*=\s*"?([^"\n]+)"?\s*$')


def parse_sh(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        m = _EXPORT_RE.match(line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


@dataclass(frozen=True)
class Palette:
    ground: str      # solid bg when the wallpaper is missing
    ink: str         # text over the wallpaper / ground
    field: str       # password / chip fill
    field_ink: str   # text inside the field / chips
    outline: str     # 1px hairline on fields (opaque)
    clock: str       # the big clock glyph
    date: str        # the date line + status text
    ok: str          # entry outline on auth success
    fail: str        # entry outline + fail text on wrong password


def load_theme(path: str | Path) -> Palette:
    text = ""
    try:
        text = Path(path).read_text()
    except OSError:
        pass
    d = parse_sh(text)
    if not d:
        d = parse_sh((resources.files("greeter") / "fallback-palette.sh").read_text())
    hall = d.get("HALL", "#1e1e1e")
    score = d.get("SCORE", "#f0f0f0")
    forte = d.get("FORTE", "#c9a25f")
    return Palette(
        ground=hall,
        ink=score,
        field=d.get("STAGE", colors.mix(hall, score, 0.12)),
        field_ink=score,
        outline=colors.mix(score, hall, 0.45),
        clock=forte,
        date=d.get("REST", colors.mix(score, hall, 0.35)),
        ok=d.get("PIANO", score),
        fail=forte,
    )


_INK = "#211c1c"
_CREAM = "#f0e9d8"
_RUST = "#a8451f"


def load_dsa() -> Palette:
    return Palette(
        ground=_INK,
        ink=_CREAM,
        field=colors.mix(_INK, _CREAM, 0.08),
        field_ink=_CREAM,
        outline=_RUST,
        clock=_RUST,
        date=colors.mix(_CREAM, _INK, 0.35),
        ok="#8fb573",
        fail=_RUST,
    )
