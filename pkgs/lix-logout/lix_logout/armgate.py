"""Two-click arm/confirm gate for destructive actions.

Caller supplies the clock (time.monotonic()) so this stays free of GTK/timer
dependencies and is trivially testable with fake timestamps.
"""
from __future__ import annotations

ARM_WINDOW_SECONDS = 2.5


class ArmGate:
    def __init__(self) -> None:
        self._armed_action: str | None = None
        self._armed_at: float = 0.0

    def click(self, action: str, now: float) -> bool:
        """Register a click. Returns True if this click should fire the
        action (it was already armed within the window), False if it just
        armed the action and needs a confirming second click."""
        if self._armed_action == action and (now - self._armed_at) <= ARM_WINDOW_SECONDS:
            self._armed_action = None
            return True
        self._armed_action = action
        self._armed_at = now
        return False

    def is_armed(self, action: str, now: float) -> bool:
        return self._armed_action == action and (now - self._armed_at) <= ARM_WINDOW_SECONDS
