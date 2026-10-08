"""Derive a dark counterpart's seed colours from an existing theme, and
sanity-check the palette derived from them."""
import re
from itertools import combinations
from pathlib import Path

from theme_lib.colormath import _hex_to_hsl, _hsl_to_hex, contrast_ratio, delta_e_cie76
from theme_lib.palette_files import SEED_KEYS

ACCENT_SEEDS = tuple(k for k in SEED_KEYS if k != "HALL")
_CHECKED_ACCENTS = ("TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT", "SUPERTONIC", "SUBMEDIANT")
MIN_ACCENT_CONTRAST = 3.5
MIN_INK_CONTRAST = 7.0
MIN_ACCENT_DELTA_E = 25.0
_SWATCH_SLOTS = ("HALL", "STAGE", "WING", "TONIC", "MEDIANT", "DOMINANT",
                 "SUBDOMINANT", "SUPERTONIC", "SUBMEDIANT", "SCORE")


def read_seeds(sh_path: Path) -> dict:
    found = {}
    for line in Path(sh_path).read_text().splitlines():
        if line.startswith("export SEED_") and "=" in line:
            key, _, val = line[len("export SEED_"):].partition("=")
            found[key.strip()] = val.strip().strip('"')
    missing = [f"SEED_{k}" for k in SEED_KEYS if k not in found]
    if missing:
        raise ValueError(f"{sh_path}: missing {', '.join(missing)}")
    return {k: found[k] for k in SEED_KEYS}


# Themes generated before seeds were recorded: reuse their final accents, which
# is the closest thing they have to the colours they were built from.
_PALETTE_SEED_SLOTS = {"HALL": "HALL", "TONIC": "ROOT", "MEDIANT": "FIFTH",
                       "DOMINANT": "SOTTO", "SUBDOMINANT": "SEVENTH"}


def palette_seeds(sh_path: Path) -> dict:
    found = {}
    for line in Path(sh_path).read_text().splitlines():
        if line.startswith("export ") and "=" in line:
            key, _, val = line[len("export "):].partition("=")
            found[key.strip()] = val.strip().strip('"')
    missing = [src for src in _PALETTE_SEED_SLOTS.values() if src not in found]
    if missing:
        raise ValueError(f"{sh_path}: missing {', '.join(missing)}")
    return {seed: found[src] for seed, src in _PALETTE_SEED_SLOTS.items()}


def dark_seeds(seeds: dict, ground_l: float = 0.09, ground_sat: float = 0.30,
               accent_sat_max: float = 0.70) -> dict:
    # Accent lightness is left alone on purpose: derive_full_palette raises it
    # until each accent clears MIN_ACCENT_CONTRAST on the real (now dark) HALL.
    h, s, _ = _hex_to_hsl(seeds["HALL"])
    out = {"HALL": _hsl_to_hex(h, min(s, ground_sat), ground_l)}
    for key in ACCENT_SEEDS:
        ah, asat, al = _hex_to_hsl(seeds[key])
        out[key] = seeds[key] if asat <= accent_sat_max else _hsl_to_hex(ah, accent_sat_max, al)
    return out


def light_seeds(seeds: dict, ground_l: float = 0.94, ground_sat: float = 0.30,
                accent_sat_max: float = 0.70) -> dict:
    # Mirror of dark_seeds: accent lightness is left for derive_full_palette,
    # which darkens each accent until it clears the contrast floor on the light HALL.
    return dark_seeds(seeds, ground_l=ground_l, ground_sat=ground_sat,
                      accent_sat_max=accent_sat_max)


def variant_seeds(seeds: dict, mode: str, **knobs) -> dict:
    if mode == "dark":
        return dark_seeds(seeds, **knobs)
    if mode == "light":
        return light_seeds(seeds, **knobs)
    raise ValueError(f"unknown mode {mode!r}: want 'dark' or 'light'")


DERIVED_ACCENTS = ("SUPERTONIC", "SUBMEDIANT")


def apply_overrides(colors: dict, pairs: list[str], allowed: tuple = SEED_KEYS) -> dict:
    out = dict(colors)
    for pair in pairs:
        key, _, val = pair.partition("=")
        if key not in allowed or len(val) != 7 or not val.startswith("#"):
            raise ValueError(f"bad override {pair!r}: want KEY=#rrggbb with KEY in {', '.join(allowed)}")
        out[key] = val.lower()
    return out


def check_palette(p: dict) -> list[str]:
    problems = []
    ink = contrast_ratio(p["SCORE"], p["HALL"])
    if ink < MIN_INK_CONTRAST:
        problems.append(f"SCORE ink contrast {ink:.1f} on HALL (< {MIN_INK_CONTRAST})")
    for key in _CHECKED_ACCENTS:
        c = contrast_ratio(p[key], p["HALL"])
        if c < MIN_ACCENT_CONTRAST:
            problems.append(f"{key} contrast {c:.1f} on HALL (< {MIN_ACCENT_CONTRAST})")
    for a, b in combinations(_CHECKED_ACCENTS, 2):
        de = delta_e_cie76(p[a], p[b])
        if de < MIN_ACCENT_DELTA_E:
            problems.append(f"{a}/{b} ΔE {de:.0f} (< {MIN_ACCENT_DELTA_E:.0f}), too close")
    return problems


def hexline(p: dict) -> str:
    return " ".join(f"{k}={p[k]}" for k in _SWATCH_SLOTS)


def swatch(p: dict) -> str:
    def block(hex_color):
        r, g, b = (int(hex_color[i:i + 2], 16) for i in (1, 3, 5))
        return f"\033[48;2;{r};{g};{b}m    \033[0m"
    return " ".join(block(p[k]) for k in _SWATCH_SLOTS)


_PAIR_RE = re.compile(r'^  PAIR\s*=\s*"[^"]*";\n', re.M)
_TEMPO_RE = re.compile(r'^(  TEMPO\s*=\s*"[^"]*";\n)', re.M)


def set_pair(theme_dir: Path, other_slug: str) -> bool:
    """Write PAIR = "<other>" into the theme's palette .nix (after TEMPO).
    Returns True if the file changed."""
    nix = Path(theme_dir) / f"palette-{Path(theme_dir).name}.nix"
    text = nix.read_text()
    line = f'  PAIR    = "{other_slug}";\n'
    if _PAIR_RE.search(text):
        new = _PAIR_RE.sub(line, text, count=1)
    else:
        new, n = _TEMPO_RE.subn(lambda m: m.group(1) + line, text, count=1)
        if n != 1:
            raise ValueError(f"{nix}: no TEMPO line to anchor PAIR after")
    if new == text:
        return False
    nix.write_text(new)
    return True


def find_pairs(themes_root: Path) -> list[tuple[Path, Path]]:
    """(dark_dir, light_dir) for every slug / slug-light and slug-dark / slug pair."""
    dark, light = Path(themes_root) / "Dark", Path(themes_root) / "Light"
    pairs = []
    for d in sorted(dark.iterdir()) if dark.is_dir() else []:
        twin = light / f"{d.name}-light"
        if twin.is_dir():
            pairs.append((d, twin))
    for l in sorted(light.iterdir()) if light.is_dir() else []:
        twin = dark / f"{l.name}-dark"
        if twin.is_dir():
            pairs.append((twin, l))
    return pairs
