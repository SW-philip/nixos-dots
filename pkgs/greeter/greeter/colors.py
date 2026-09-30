"""Pure color math: hex <-> rgb, HSL lightness, mixing, hue-preserving darken."""
from __future__ import annotations

import colorsys

RGB = tuple[int, int, int]


def hex_to_rgb(h: str) -> RGB:
    """Parse '#rgb' or '#rrggbb' (with or without leading '#') to an (r, g, b) tuple."""
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def css_rgba(h: str, a: float) -> str:
    """GTK/CSS `rgba(r,g,b,a)` from a hex colour and a 0..1 alpha."""
    r, g, b = hex_to_rgb(h)
    return f"rgba({r},{g},{b},{a})"


def rgb_to_hex(rgb: tuple[float, float, float]) -> str:
    r, g, b = (max(0, min(255, round(v))) for v in rgb)
    return f"#{r:02x}{g:02x}{b:02x}"


def lightness(h: str) -> float:
    """HSL lightness in 0..1 (not perceptual luminance)."""
    r, g, b = (v / 255 for v in hex_to_rgb(h))
    return colorsys.rgb_to_hls(r, g, b)[1]


def mix(a: str, b: str, t: float) -> str:
    """Linear blend; t=0 -> a, t=1 -> b."""
    ar, ag, ab = hex_to_rgb(a)
    br, bg, bb = hex_to_rgb(b)
    return rgb_to_hex((ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t))


def set_lightness_keeping_hue(h: str, target_l: float) -> str:
    """Set HSL lightness to target_l, preserving hue and saturation."""
    r, g, b = (v / 255 for v in hex_to_rgb(h))
    hh, _, ss = colorsys.rgb_to_hls(r, g, b)
    r2, g2, b2 = colorsys.hls_to_rgb(hh, target_l, ss)
    return rgb_to_hex((r2 * 255, g2 * 255, b2 * 255))
