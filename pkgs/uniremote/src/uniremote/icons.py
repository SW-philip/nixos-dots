"""On-disk cache for Roku channel icons."""
from __future__ import annotations
from pathlib import Path

CACHE_DIR = Path.home() / ".cache" / "uniremote" / "icons"


class IconCache:
    def __init__(self, root: Path = CACHE_DIR):
        self.root = Path(root)

    def _path(self, app_id: str) -> Path | None:
        # Roku channel ids are digits; anything else must never reach the filesystem.
        return self.root / f"{app_id}.png" if app_id.isdigit() else None

    def get(self, app_id: str) -> Path | None:
        path = self._path(app_id)
        return path if path is not None and path.is_file() else None

    def store(self, app_id: str, data: bytes) -> Path | None:
        path = self._path(app_id)
        if path is None:
            return None
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path
