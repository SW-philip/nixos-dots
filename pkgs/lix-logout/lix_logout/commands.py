"""Pure action -> argv mapping. No subprocess execution, no GTK."""
from __future__ import annotations

ACTIONS: dict[str, list[str]] = {
    "lock":     ["bash", "-c", "pidof hyprlock || hyprlock"],
    "logout":   ["niri", "msg", "action", "quit", "-s"],
    "reboot":   ["systemctl", "reboot"],
    "shutdown": ["systemctl", "poweroff"],
}


def command_for(action: str) -> list[str]:
    try:
        return ACTIONS[action]
    except KeyError:
        raise ValueError(f"unknown action: {action!r}") from None
