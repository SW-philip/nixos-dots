"""Filesystem paths, API endpoints, and palette-source metadata for the theme engine."""
from pathlib import Path

# ── Paths ─────────────────────────────────────────────────────────────────────
NIXOS_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = NIXOS_ROOT / "scripts"
THEMES_ROOT = NIXOS_ROOT / "themes"
CUSTOM_DIR  = THEMES_ROOT / "Custom"
API_CACHE_FILE = NIXOS_ROOT / "scripts" / "api-palette-cache.json"
MAKE_WALLPAPER = NIXOS_ROOT / "scripts" / "make-splotch-bg.py"
COLOR_MAGIC_API      = "https://colormagic.app/api/palette/search"
ROSE_PINE_PALETTE_URL = "https://raw.githubusercontent.com/rose-pine/palette/main/palette.json"

RP_COLOR_MAP = {
    "base": "HALL", "surface": "STAGE", "overlay": "WING",
    "muted": "BAR", "subtle": "REST", "text": "SCORE",
    "love": "TONIC", "gold": "SUBMEDIANT", "rose": "MEDIANT",
    "pine": "DOMINANT", "foam": "SUBDOMINANT", "iris": "SUPERTONIC",
    "highlightLow": "MUTE", "highlightMed": "MUTE",
    "highlightHigh": "WING",
}

# Keyed by upstream rosepine.com field names so the offline fallback flows through
# RP_COLOR_MAP exactly like the live fetch — single source of truth for name mapping.
RP_FALLBACK: dict[str, dict[str, str]] = {
    "main": {
        "base": "#191724", "surface": "#1f1d2e", "overlay": "#26233a",
        "muted": "#6e6a86", "subtle": "#908caa", "text": "#e0def4",
        "love": "#eb6f92", "gold": "#f6c177", "rose": "#ebbcba",
        "pine": "#31748f", "foam": "#9ccfd8", "iris": "#c4a7e7",
        "highlightLow": "#21202e", "highlightMed": "#403d52", "highlightHigh": "#524f67",
    },
    "moon": {
        "base": "#232136", "surface": "#2a273f", "overlay": "#393552",
        "muted": "#6e6a86", "subtle": "#908caa", "text": "#e0def4",
        "love": "#eb6f92", "gold": "#f6c177", "rose": "#ea9a97",
        "pine": "#3e8fb0", "foam": "#9ccfd8", "iris": "#c4a7e7",
        "highlightLow": "#2a283e", "highlightMed": "#44415a", "highlightHigh": "#56526e",
    },
    "dawn": {
        "base": "#faf4ed", "surface": "#fffaf3", "overlay": "#f2e9e1",
        "muted": "#9893a5", "subtle": "#797593", "text": "#575279",
        "love": "#b4637a", "gold": "#ea9d34", "rose": "#d7827e",
        "pine": "#286983", "foam": "#56949f", "iris": "#907aa9",
        "highlightLow": "#f4ede8", "highlightMed": "#dfdad9", "highlightHigh": "#cecacd",
    },
}

PALETTE_SOURCES: dict[str, str] = {
    "colormagic": "Color Magic — keyword palette generation  (https://colormagic.app)",
    "rosepine":   "Official Rosé Pine — main / moon / dawn   (https://rosepinetheme.com)",
}
