"""Palette readability scoring and source comparison.

Seeded with the comparison printer; the composite scorer (WCAG contrast +
vibrancy + accent distinctness) and pick_best land here in Part 2.
"""

# The seeds plus their harmonic accents — the smallest set that shows a
# palette's character without dragging in derived depth/ink keys (STAGE,
# WING, MUTE, SCORE, LYRIC, REST, BAR) that don't vary meaningfully between
# candidate sources.
_COMPARE_KEYS = ("HALL", "TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT", "SUPERTONIC", "SUBMEDIANT")

_KEY_COL = 13
_COL_WIDTH = 14


def _swatch(hex_color: str, col_width: int) -> str:
    """A truecolor block + hex code, right-padded to `col_width` visible columns."""
    h = hex_color.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    block = f"\033[48;2;{r};{g};{b}m  \033[0m"
    text = f" {hex_color}"
    return block + text + " " * max(2, col_width - (2 + len(text)))


def print_source_comparison(query: str, results: dict[str, dict]) -> None:
    """Print ANSI color swatches for a set of palette results, one source per column."""
    sources = list(results)

    print(f"\n'{query}' — {len(sources)} source(s):\n")
    print(" " * _KEY_COL + "".join(name.ljust(_COL_WIDTH) for name in sources))

    for key in _COMPARE_KEYS:
        row = "".join(
            _swatch(results[name][key], _COL_WIDTH) if key in results[name] else " " * _COL_WIDTH
            for name in sources
        )
        print(f"{key:<{_KEY_COL}}{row}")
    print()
