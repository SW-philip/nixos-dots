from __future__ import annotations
import os
from pathlib import Path


def cover_path() -> Path:
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(runtime) / "surface-cover"


def cover_detached(path: Path) -> bool:
    """Same signal eww's tablet.sh reads; absent file (desktop) is never tablet."""
    try:
        return path.read_text().strip() == "detached"
    except OSError:
        return False
