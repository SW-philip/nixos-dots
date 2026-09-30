"""Theme lock convention: an empty LOCKED marker file protects a theme
directory from ever being re-derived, even by `--batch --force`."""
from pathlib import Path

LOCK_FILENAME = "LOCKED"


def is_locked(theme_dir: Path) -> bool:
    return (theme_dir / LOCK_FILENAME).exists()
