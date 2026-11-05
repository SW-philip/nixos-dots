"""Menu rows, key bindings and header text. No GTK, so it is unit-testable."""
from __future__ import annotations

from dataclasses import dataclass
from html import escape


@dataclass(frozen=True)
class Row:
    action: str
    label: str
    icon: str
    key: str


# Nerd Font glyphs: nf-md-lock, nf-md-logout, nf-md-restart, nf-fa-power_off.
ROWS = [
    Row("lock", "Lock", "\U000f033e", "l"),
    Row("logout", "Log out", "\U000f0343", "o"),
    Row("reboot", "Reboot", "\U000f0709", "r"),
    Row("shutdown", "Shut down", "", "s"),
]

ARMED_LABELS = {
    "reboot": "Confirm reboot?",
    "shutdown": "Confirm shutdown?",
}

_BY_KEY = {r.key: r.action for r in ROWS}


def action_for_key(name: str) -> str | None:
    return _BY_KEY.get(name.lower())


def header_text(host: str, user: str) -> str:
    return f"{host} · {user}"


def header_markup(host: str, user: str) -> str:
    """Pango markup for the header: the hostname bold, the rest regular."""
    return f"<b>{escape(host)}</b> · {escape(user)}"
