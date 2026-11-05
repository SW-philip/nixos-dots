"""Contrast-guaranteed ink derivation: SCORE/LYRIC/REST are legible on every
text surface (BAR, an edge, only against HALL), tinted with HALL's hue rather
than flat black/white.
"""
from theme_lib.colormath import _clamp, _hex_to_hsl, _hsl_to_hex
from theme_lib.legibility import (
    MIN_REST_CONTRAST,
    MIN_SCORE_CONTRAST,
    MIN_TEXT_CONTRAST,
    worst_contrast,
)

_BLACK, _WHITE = "#000000", "#ffffff"

# Key: (WCAG Floor, Target blending alpha/t toward HALL, checked on every surface)
_INK_SPEC = {
    "SCORE": (MIN_SCORE_CONTRAST, 0.10, True),
    "LYRIC": (MIN_TEXT_CONTRAST, 0.25, True),
    "REST":  (MIN_REST_CONTRAST, 0.45, True),
    "BAR":   (1.5, 0.65, False),
}

_BLEND_STEP = 0.05

def _pick_anchor(grounds: list[str]) -> str:
    """Choose whether black or white offers the best starting contrast path."""
    return _BLACK if worst_contrast(_BLACK, grounds) >= worst_contrast(_WHITE, grounds) else _WHITE

def _blend_toward_hall(anchor_hex: str, hall_hex: str, t: float) -> str:
    """Interpolate an anchor color toward HALL in HSL space, capping max saturation."""
    ah, a_s, a_l = _hex_to_hsl(anchor_hex)
    hh, hs, hl = _hex_to_hsl(hall_hex)

    # Shortest circular arc for hue
    diff = (hh - ah + 0.5) % 1.0 - 0.5
    new_h = (ah + diff * t) % 1.0

    # Keep saturation restrained to prevent fluorescent text
    new_s = _clamp(a_s + (min(hs, 0.30) - a_s) * t)
    new_l = _clamp(a_l + (hl - a_l) * t)
    return _hsl_to_hex(new_h, new_s, new_l)

def _ink_color(hall_hex: str, grounds: list[str], anchor_hex: str, floor: float,
               start_t: float) -> str:
    """Step back towards the anchor until the contrast floor is satisfied."""
    t = start_t
    color = _blend_toward_hall(anchor_hex, hall_hex, t)
    while worst_contrast(color, grounds) < floor and t > 0:
        t = max(0.0, round(t - _BLEND_STEP, 2))
        color = _blend_toward_hall(anchor_hex, hall_hex, t)
    return color

def derive_ink(hall_hex: str, grounds: list[str] | None = None) -> dict[str, str]:
    """Generate contrast-guaranteed text hierarchy slot colors. `grounds` are the
    surfaces the ink must read on (default: HALL alone)."""
    grounds = grounds or [hall_hex]
    anchor = _pick_anchor(grounds)
    return {key: _ink_color(hall_hex, grounds if every else [hall_hex], anchor, floor, start_t)
            for key, (floor, start_t, every) in _INK_SPEC.items()}
