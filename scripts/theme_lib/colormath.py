"""Minimal, dependency-free color math: HSL conversion, adjustment, and readability helpers."""
import math
import re


def _green_sat_ceiling(h: float) -> float:
    """Human vision over-weights green luminance (WCAG: G=0.7152 vs R=0.2126, B=0.0722),
    so saturated colors from grass-green through spring-green read far more vivid
    ("neon") than the same S/L anywhere else on the wheel — and a seed/API color can
    arrive already at S=0.9+, which a smooth falloff doesn't tame near its edges (an
    accent that gets hue-matched to 170 deg instead of dead-on 122 deg would otherwise
    dodge the cap almost entirely). Returns a hard saturation ceiling applied in
    _hsl_to_hex: a flat 0.4 plateau across 85-165 deg, ramping back to 1.0 (no cap) by
    65/185 deg — clear of Rose Pine's teal DOMINANT/SUBDOMINANT anchors at 189/200 deg
    — so anything landing near pure green comes out muted instead of neon, regardless
    of which code path or seed produced it.
    """
    deg = (h * 360) % 360
    center, plateau, margin, min_cap = 125.0, 40.0, 20.0, 0.4
    dist = abs(deg - center)
    if dist <= plateau:
        return min_cap
    if dist >= plateau + margin:
        return 1.0
    t = (dist - plateau) / margin
    return min_cap + (1 - min_cap) * (1 - math.cos(t * math.pi)) / 2


def _hex_to_hsl(h: str) -> tuple[float, float, float]:
    r, g, b = int(h[1:3], 16)/255, int(h[3:5], 16)/255, int(h[5:7], 16)/255
    mx, mn = max(r, g, b), min(r, g, b)
    l = (mx + mn) / 2
    if mx == mn: return 0.0, 0.0, l
    d = mx - mn
    s = d / (2 - mx - mn) if l > 0.5 else d / (mx + mn)
    if mx == r:   hue = (g - b) / d + (6 if g < b else 0)
    elif mx == g: hue = (b - r) / d + 2
    else:         hue = (r - g) / d + 4
    return hue / 6, s, l

def _hsl_to_hex(h: float, s: float, l: float) -> str:
    h = h % 1.0
    s = min(s, _green_sat_ceiling(h))
    if s == 0:
        v = round(l * 255)
        return f"#{v:02x}{v:02x}{v:02x}"
    def _hue(p, q, t):
        t %= 1
        if t < 1/6: return p + (q - p) * 6 * t
        if t < 1/2: return q
        if t < 2/3: return p + (q - p) * (2/3 - t) * 6
        return p
    q = l * (1 + s) if l < 0.5 else l + s - l * s
    p = 2 * l - q
    r, g, b = _hue(p, q, h + 1/3), _hue(p, q, h), _hue(p, q, h - 1/3)
    return f"#{round(r*255):02x}{round(g*255):02x}{round(b*255):02x}".lower()

def _clamp(val, min_v=0.0, max_v=1.0):
    return max(min_v, min(max_v, val))


def relative_luminance(hex_color: str) -> float:
    """WCAG relative luminance of an sRGB hex color (0=black .. 1=white)."""
    h = hex_color.lstrip("#")
    def _lin(c: float) -> float:
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (_lin(int(h[i:i + 2], 16)) for i in (0, 2, 4))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def contrast_ratio(hex_a: str, hex_b: str) -> float:
    """WCAG contrast ratio between two sRGB hex colors (always >= 1.0)."""
    la, lb = relative_luminance(hex_a), relative_luminance(hex_b)
    lighter, darker = max(la, lb), min(la, lb)
    return (lighter + 0.05) / (darker + 0.05)


def _srgb_to_linear(v: float) -> float:
    """8-bit sRGB channel (0..255) -> linear-light 0..1.

    Cutoff 0.04045 is the sRGB-standard value (IEC 61966-2-1), used here for
    CIELAB conversion. `relative_luminance` deliberately uses WCAG 2.x's
    0.03928 instead — don't unify them.
    """
    c = v / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def srgb_to_lab(hex_color: str) -> tuple[float, float, float]:
    """sRGB hex -> CIE L*a*b* (D65 reference white, 2-degree observer)."""
    h = hex_color.lstrip("#")
    r, g, b = (_srgb_to_linear(int(h[i:i + 2], 16)) for i in (0, 2, 4))
    x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
    y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
    z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041
    x, y, z = x / 0.95047, y / 1.0, z / 1.08883

    def _f(t: float) -> float:
        return t ** (1 / 3) if t > 216 / 24389 else (841 / 108) * t + 4 / 29

    fx, fy, fz = _f(x), _f(y), _f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


def delta_e_cie76(hex_a: str, hex_b: str) -> float:
    """CIE76 colour difference: Euclidean distance in L*a*b*.

    ~2.3 is a just-noticeable difference; >= 25 reads as "clearly different"
    (this repo's distinctness bar).
    """
    la = srgb_to_lab(hex_a)
    lb = srgb_to_lab(hex_b)
    return math.sqrt(sum((p - q) ** 2 for p, q in zip(la, lb)))

def parse_colorhunt_url(url: str) -> list[str]:
    """Extract 4 hex colors from a colorhunt.co palette URL (slug = 4×6 hex, no HTTP)."""
    slug = url.rstrip("/").split("/")[-1]
    if not re.fullmatch(r"[0-9a-fA-F]{24}", slug):
        raise ValueError(f"Not a valid ColorHunt palette slug: {slug!r} (expected 24 hex chars)")
    return [f"#{slug[i:i + 6].lower()}" for i in range(0, 24, 6)]


def map_colorhunt_to_slots(colors: list[str]) -> dict:
    """Map 4 ColorHunt colors onto the 5 slots derive_full_palette needs.

    Luminance-detect HALL; the remaining 3 fill TONIC/DOMINANT/SUBDOMINANT in palette order.
    MEDIANT mirrors TONIC (4 colors can't fill 5 accent slots); derive_full_palette
    then computes MEDIANT-adjacent depth, SUPERTONIC, and SUBMEDIANT.
    """
    by_lum = sorted(colors, key=relative_luminance)
    base = by_lum[0] if relative_luminance(by_lum[0]) < 0.2 else by_lum[-1]
    accents = [c for c in colors if c != base]
    return {
        "HALL": base,
        "TONIC": accents[0],
        "MEDIANT": accents[0],
        "DOMINANT": accents[1],
        "SUBDOMINANT": accents[2],
    }


def _adjust_color(hex_color: str, l_offset: float = 0, s_offset: float = 0, h_offset: float = 0) -> str:
    """Adjusts HSL with clamping and automatic hue compensation for depth."""
    h, s, l = _hex_to_hsl(hex_color)

    # Auto hue-shift based on direction of lightness change for perceptual depth
    if l_offset < 0:
        h -= 0.02  # cool shift when darkening
        s += 0.05  # prevent muddiness
    elif l_offset > 0:
        h += 0.02  # warm shift when lightening
        s -= 0.02  # prevent neon-glow

    return _hsl_to_hex(
        (h + h_offset) % 1.0,
        _clamp(s + s_offset),
        _clamp(l + l_offset),
    )

def _get_farthest_hue(hex_color: str) -> str:
    """Returns a high-contrast accent hue using the Golden Ratio."""
    h, s, l = _hex_to_hsl(hex_color)
    # Use the Golden Ratio (approx 0.618) to find a harmonious but distinct hue
    return _hsl_to_hex((h + 0.618033988749895) % 1.0, s, l)

def _get_text_color(hex_color: str) -> str:
    r, g, b = int(hex_color[1:3], 16), int(hex_color[3:5], 16), int(hex_color[5:7], 16)
    brightness = (r * 299 + g * 587 + b * 114) // 1000
    return "#1a1a1a" if brightness > 155 else "#ffffff"

def _theme_mode(hex_color: str) -> str:
    r, g, b = int(hex_color[1:3], 16), int(hex_color[3:5], 16), int(hex_color[5:7], 16)
    brightness = (r * 299 + g * 587 + b * 114) // 1000
    return "dark" if brightness < 128 else "light"


def _adjust(hex_col: str, l: float = 0, s: float = 0, h: float = 0) -> str:
    """Adjusts HSL values with clamping and returns a hex string."""
    hue, sat, light = _hex_to_hsl(hex_col)
    return _hsl_to_hex((hue + h) % 1.0, max(0, min(1, sat + s)), max(0, min(1, light + l)))
