"""Greeter clock — gi-free so it unit-tests without a display."""
from __future__ import annotations

import time
from pathlib import Path

# The 12/24h toggle written by quantum-clock (waybar) and read by hyprlock.
# The greeter runs as the `greeter` user, which usually has no such file —
# is_24h() then falls back to 12h, matching hyprlock's own fallback.
try:
    H24_FILE = Path.home() / ".cache" / "quantum_clock" / "24h"
except RuntimeError:  # $HOME unresolvable — is_24h() recomputes it lazily anyway
    H24_FILE = Path("/nonexistent/quantum_clock/24h")


def is_24h(state_file: Path | None = None) -> bool:
    try:
        sf = state_file or (Path.home() / ".cache" / "quantum_clock" / "24h")
        return sf.read_text().strip() == "1"
    except (OSError, ValueError):
        return False


def clock_text(*, now: time.struct_time | None = None,
               twenty_four: bool | None = None) -> str:
    tf = is_24h() if twenty_four is None else twenty_four
    t = now if now is not None else time.localtime()
    return time.strftime("%H:%M" if tf else "%-I:%M %p", t)


def date_text(*, now: time.struct_time | None = None) -> str:
    return time.strftime("%A, %d %B", now or time.localtime())
