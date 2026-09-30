"""Random wrong-password messages for the greeter's auth-failure path.

Reads a shared, newline-separated pool of lines (baked into the Nix
derivation and pointed to via GREETER_SNARK_FILE by default.nix's
makeWrapper). Never raises: a missing/unset/empty pool falls back to a
single default line so a wrong password can never crash the greeter.
"""
from __future__ import annotations

import os
import random

ENV_VAR = "GREETER_SNARK_FILE"
DEFAULT_LINE = "Nope. Try again."


def load_snark_lines(path: str | None) -> list[str]:
    if not path:
        return [DEFAULT_LINE]
    try:
        with open(path, encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip()]
    except OSError:
        return [DEFAULT_LINE]
    return lines or [DEFAULT_LINE]


def pick_snark_line(path: str | None = None) -> str:
    if path is None:
        path = os.environ.get(ENV_VAR)
    return random.choice(load_snark_lines(path))
