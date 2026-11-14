"""On-disk cache for Roku channel icons."""
from __future__ import annotations
import io
from pathlib import Path

from PIL import Image, UnidentifiedImageError

CACHE_DIR = Path.home() / ".cache" / "uniremote" / "icons-png"


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
        path.write_bytes(_as_png(data))
        return path


def _as_png(data: bytes) -> bytes:
    """Roku serves WebP, which gdk-pixbuf here can't decode; re-encode as PNG."""
    try:
        with Image.open(io.BytesIO(data)) as img:
            out = io.BytesIO()
            img.convert("RGBA").save(out, "PNG")
            return out.getvalue()
    except (UnidentifiedImageError, OSError):
        return data
