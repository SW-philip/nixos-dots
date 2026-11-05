"""Text legibility floors, checked against every surface text actually sits on.

Works on both a derive_full_palette dict and a musical dict: each check uses
whichever of its keys the palette carries.
"""
from itertools import combinations

from theme_lib.colormath import contrast_ratio, delta_e_cie76

# WING is waybar's bar fill and .module and swaync/nemo/firefox/tmux chrome; MUTE
# backs firefox/zed rows; DIM (GRAD_STAGE_LO before to_musical) is swaync's and
# lix-logout's trough. The GRAD_* stops are never behind text.
TEXT_SURFACES = ("HALL", "STAGE", "WING", "MUTE", "DIM", "GRAD_STAGE_LO",
                 "PIT", "PIT_SURFACE", "PIT_OVERLAY")

MIN_SCORE_CONTRAST = 7.0
MIN_TEXT_CONTRAST = 4.5
MIN_REST_CONTRAST = 3.0
MIN_ACCENT_DELTA_E = 25.0

DERIVED_ACCENTS = ("TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT", "SUPERTONIC", "SUBMEDIANT")
MUSICAL_ACCENTS = ("ROOT", "FIFTH", "SEVENTH", "SOTTO")
# FORTE/PIANO are TONIC/SUBMEDIANT under another name, but in a musical dict
# they may not be among the four ranked accents.
_MUSICAL_DISTINCT = MUSICAL_ACCENTS + ("FORTE", "PIANO")
SIGNALS = ("FORTE", "FERMATA", "PIANO", "TACET", "LEDGER")

TEXT_FLOORS = {
    "SCORE": MIN_SCORE_CONTRAST,
    "LYRIC": MIN_TEXT_CONTRAST,
    "REST": MIN_REST_CONTRAST,
    **{k: MIN_TEXT_CONTRAST for k in DERIVED_ACCENTS + MUSICAL_ACCENTS + SIGNALS},
}


def surfaces(p: dict) -> list[str]:
    return [p[k] for k in TEXT_SURFACES if k in p]


def worst_contrast(color: str, grounds: list[str]) -> float:
    return min(contrast_ratio(color, g) for g in grounds)


def contrast_problems(p: dict) -> list[str]:
    """Every text slot under its floor on its worst surface."""
    problems = []
    named = [k for k in TEXT_SURFACES if k in p]
    for key, floor in TEXT_FLOORS.items():
        if key not in p:
            continue
        c, on = min((contrast_ratio(p[key], p[s]), s) for s in named)
        if c < floor:
            problems.append(f"{key} contrast {c:.1f} on {on} (< {floor})")
    return problems


def distinctness_problems(p: dict) -> list[str]:
    """Every accent pair closer than the ΔE distinctness bar."""
    problems = []
    keys = [k for k in DERIVED_ACCENTS if k in p] or [k for k in _MUSICAL_DISTINCT if k in p]
    seen = {}
    for k in keys:
        seen.setdefault(p[k].lower(), k)
    accents = list(seen.values())
    for a, b in combinations(accents, 2):
        de = delta_e_cie76(p[a], p[b])
        if de < MIN_ACCENT_DELTA_E:
            problems.append(f"{a}/{b} ΔE {de:.0f} (< {MIN_ACCENT_DELTA_E:.0f}), too close")
    return problems


def legibility_problems(p: dict) -> list[str]:
    return contrast_problems(p) + distinctness_problems(p)
