"""Contrast-guaranteed ink derivation: SCORE/LYRIC/REST/BAR are always legible
against HALL, tinted with HALL's hue rather than flat black/white.
"""
from theme_lib.colormath import _hex_to_hsl, _hsl_to_hex, _clamp, contrast_ratio

_BLACK, _WHITE = "#000000", "#ffffff"

# Key: (WCAG Floor, Target blending alpha/t toward HALL)
_INK_SPEC = {
    "SCORE": (4.5, 0.10),
    "LYRIC": (4.5, 0.25),
    "REST":  (3.0, 0.45),
    "BAR":   (1.5, 0.65),
}

_BLEND_STEP = 0.05

def _pick_anchor(hall_hex: str) -> str:
    """Choose whether black or white offers the best starting contrast path."""
    return _BLACK if contrast_ratio(_BLACK, hall_hex) >= contrast_ratio(_WHITE, hall_hex) else _WHITE

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

def _ink_color(hall_hex: str, anchor_hex: str, floor: float, start_t: float) -> str:
    """Step back towards the anchor until the contrast floor is satisfied."""
    t = start_t
    color = _blend_toward_hall(anchor_hex, hall_hex, t)
    while contrast_ratio(color, hall_hex) < floor and t > 0:
        t = max(0.0, round(t - _BLEND_STEP, 2))
        color = _blend_toward_hall(anchor_hex, hall_hex, t)
    return color

def derive_ink(hall_hex: str) -> dict[str, str]:
    """Generate contrast-guaranteed text hierarchy slot colors."""
    anchor = _pick_anchor(hall_hex)
    return {key: _ink_color(hall_hex, anchor, floor, start_t)
            for key, (floor, start_t) in _INK_SPEC.items()}
