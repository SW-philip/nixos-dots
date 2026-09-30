#!/usr/bin/env python3
"""make-splotch-bg.py — generate a per-theme organic blurred-blob
wallpaper: writes wallpaper-background.svg and rasterises it to
wallpaper-<slug>.png (via resvg).

Two blobs sit over a flat, hue-free dark gray field (FLAT_BG — the same
fixed color on every theme, not derived from the theme's own palette) so
the blobs' own hue never has to compete with a tinted background. Blob
colors are guaranteed hued and visible against FLAT_BG (never white/
black/grey, and never so close in luminance to FLAT_BG that they vanish
into it): one drawn from the theme's own logo ink (LOGO_VARS), one from
the rest of the palette (BLOB_CANDIDATE_VARS), each required to be a
real color and perceptually distinct from the other — with hue/
lightness synthesis as fallback when a theme has no such candidate on
its own. The two blobs sit on a seeded random axis through the canvas
centre, one on each side, at independently-drawn distances; seeded from
the theme's slug so re-running reproduces the same layout. A fine-linen
weave is baked in over the blobs as the wallpaper texture.

Usage:
  make-splotch-bg.py <theme-dir>
  make-splotch-bg.py --all [themes-root]
"""
import colorsys
import math
import os
import re
import random
import shutil
import subprocess
import sys
import zlib
from pathlib import Path

W, H = 1920, 1080
DIFFUSE_STDDEV = 90

# Fixed, hue-free dark slate gray — identical across every theme so the
# base field never competes for attention with the blobs' own theme hue.
FLAT_BG = "#242424"

REPO = Path(__file__).resolve().parent.parent
DEFAULT_THEMES_ROOT = REPO / "themes"

# The two blobs sit on a seeded random axis through the canvas centre, one
# on each side, each at an independently-drawn distance in [D_MIN, D_MAX].
CENTER = (W / 2, H / 2)
D_MIN = 0.0
D_MAX = 0.32 * W   # max blob-centre distance from canvas centre


# Palette vars that historically carried a theme's logo/mark ink — used
# as the primary source for one of the two blob fill colors so the
# wallpaper's blurred accent still echoes the theme's identity colour.
LOGO_VARS = ("HALL", "ROOT", "FIFTH", "SEVENTH", "SOTTO", "FORTE", "PIANO")

# Non-logo palette vars, in priority order, considered as blob fill
# candidates — LEDGER/REST first since they're the most vivid non-logo
# accents (for chromatic themes) or read as plain neutral gray (for
# monochrome ones); LYRIC/SCORE last since they're near-white by
# construction and always fail is_hued()'s saturation floor — they're
# never picked directly here, only ever used as synthesis donors.
BLOB_CANDIDATE_VARS = ("LEDGER", "REST", "BAR", "WING", "STAGE", "MUTE", "DIM", "LYRIC", "SCORE")

DEFAULT_COLORS = {
    "HALL": "#000000", "ROOT": "#8a7070", "FIFTH": "#978d8b",
    "SEVENTH": "#dbd8d7", "SOTTO": "#a8a8a8", "FORTE": "#8a7070", "PIANO": "#978d8b",
    "SCORE": "#e6e6e6", "LYRIC": "#bfbfbf", "REST": "#8c8c8c",
    "LEDGER": "#7c6565", "BAR": "#595959", "STAGE": "#181616", "WING": "#2e292a",
    "MUTE": "#1f1f1f", "DIM": "#0d0c0c",
}


def load_colors(theme_dir):
    colors = dict(DEFAULT_COLORS)
    theme_dir = Path(theme_dir)
    pal = next((theme_dir / f for f in sorted(os.listdir(theme_dir))
                if f.startswith("palette-") and f.endswith(".sh")), None) \
        if theme_dir.is_dir() else None
    if pal:
        txt = pal.read_text()
        for k in list(colors):
            m = re.search(rf'export\s+{k}\s*=\s*"?(#[0-9a-fA-F]{{6}})"?', txt)
            if m:
                colors[k] = m.group(1)
    return colors


HUED_MIN_SAT = 0.25
HUED_LIGHT_HI = 0.90
MIN_CONTRAST_VS_BG = 1.6
BOOST_TARGET_SAT = 0.50
BOOST_LIGHT_LO = 0.35
BOOST_LIGHT_HI = 0.65
MIN_DELTA_E = 25.0


def _hls(hexcolor):
    hexcolor = hexcolor.lstrip("#")
    r, g, b = (int(hexcolor[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return colorsys.rgb_to_hls(r, g, b)


def _from_hls(h, l, s):
    h = h % 1.0
    r, g, b = colorsys.hls_to_rgb(h, l, s)
    return "#{:02x}{:02x}{:02x}".format(round(r * 255), round(g * 255), round(b * 255))


def _srgb_to_linear(v):
    v = v / 255
    return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4


def _luminance(hexcolor):
    hexcolor = hexcolor.lstrip("#")
    r, g, b = (int(hexcolor[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * _srgb_to_linear(r) + 0.7152 * _srgb_to_linear(g) + 0.0722 * _srgb_to_linear(b)


_FLAT_BG_LUMINANCE = _luminance(FLAT_BG)


def _contrast_vs_bg(hexcolor):
    """WCAG contrast ratio against FLAT_BG. A color can clear the
    saturation floor and still be indistinguishable from FLAT_BG's own
    lightness (14%) if it's merely 'not literally black' — this is the
    actual visibility guarantee is_hued() needs, not an absolute
    lightness cutoff."""
    lum = _luminance(hexcolor)
    lighter, darker = max(lum, _FLAT_BG_LUMINANCE), min(lum, _FLAT_BG_LUMINANCE)
    return (lighter + 0.05) / (darker + 0.05)


_LAB_WHITE = (95.047, 100.0, 108.883)  # CIE D65


def _rgb_to_xyz(hexcolor):
    hexcolor = hexcolor.lstrip("#")
    r, g, b = (int(hexcolor[i:i + 2], 16) / 255 for i in (0, 2, 4))
    def lin(v):
        return ((v + 0.055) / 1.055) ** 2.4 if v > 0.04045 else v / 12.92
    r, g, b = lin(r), lin(g), lin(b)
    return (
        r * 41.24 + g * 35.76 + b * 18.05,
        r * 21.26 + g * 71.52 + b * 7.22,
        r * 1.93 + g * 11.92 + b * 95.05,
    )


def _xyz_to_lab(xyz):
    x, y, z = (v / w for v, w in zip(xyz, _LAB_WHITE))
    def f(t):
        return t ** (1 / 3) if t > 0.008856 else (7.787 * t) + (16 / 116)
    fx, fy, fz = f(x), f(y), f(z)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def _delta_e(hex1, hex2):
    """CIE76 perceptual color distance. Two colors can be hex-inequal yet
    look identical once blurred (e.g. a theme's ROOT and its LEDGER
    accent are often near-twin shades) — exact-hex exclusion doesn't
    catch that; ΔE does."""
    lab1, lab2 = _xyz_to_lab(_rgb_to_xyz(hex1)), _xyz_to_lab(_rgb_to_xyz(hex2))
    return sum((a - b) ** 2 for a, b in zip(lab1, lab2)) ** 0.5


def is_hued(hexcolor):
    """True for anything that reads as an actual color, visible against
    FLAT_BG — false for black, white, the low-saturation structural
    grays used for UI chrome (REST/BAR/MUTE/DIM/...), and anything too
    close in luminance to FLAT_BG itself to register as a distinct blob."""
    _h, l, s = _hls(hexcolor)
    if s < HUED_MIN_SAT or l > HUED_LIGHT_HI:
        return False
    return _contrast_vs_bg(hexcolor) >= MIN_CONTRAST_VS_BG


def is_distinct(hexcolor, others):
    return all(_delta_e(hexcolor, o) >= MIN_DELTA_E for o in others)


def pick_hued(colors, var_list, distinct_from=frozenset()):
    for v in var_list:
        c = colors.get(v)
        if c and is_hued(c) and is_distinct(c, distinct_from):
            return c
    return None


def synthesize_hued(colors, var_list, distinct_from=frozenset()):
    """Fallback for themes with no hued-and-distinct color in var_list
    (e.g. the intentionally near-monochrome onyx-mauve/slate-lavender):
    take the highest-saturation existing color as a hue donor, then walk
    a small deterministic grid of hue offsets and lightness values until
    the result clears both is_hued() and, if given, is_distinct() —
    guaranteeing the fallback always meets the same bar a direct pick
    would have to. Widens the donor search to the full palette if every
    var in var_list has zero saturation."""
    donors = [colors[v] for v in var_list if colors.get(v) and colors[v] not in distinct_from]
    if not donors or all(_hls(c)[2] == 0 for c in donors):
        donors = [c for c in colors.values() if c not in distinct_from]
    best_hex, best_key = None, None
    for c in donors:
        _h, l, s = _hls(c)
        key = (s, l)
        if best_key is None or key > best_key:
            best_key, best_hex = key, c
    h0, l0, s0 = _hls(best_hex)
    new_s = max(s0, BOOST_TARGET_SAT)
    candidate = None
    for hue_offset_deg in (0, 30, 60, 90, 120, 150, 180):
        h = h0 + hue_offset_deg / 360
        l = min(max(l0, BOOST_LIGHT_LO), BOOST_LIGHT_HI)
        while l <= 0.85:
            candidate = _from_hls(h, l, new_s)
            if is_hued(candidate) and is_distinct(candidate, distinct_from):
                return candidate
            l += 0.02
    return candidate


def pick_blob_colors(colors):
    """Two blob fill colors: one drawn from the theme's own logo ink
    (LOGO_VARS), one from the rest of the palette (BLOB_CANDIDATE_VARS).
    Both are guaranteed hued and visible against FLAT_BG, and guaranteed
    perceptually distinct from each other — via synthesis when the theme
    has no naturally-hued-and-distinct candidate in the relevant list."""
    logo = pick_hued(colors, LOGO_VARS) or synthesize_hued(colors, LOGO_VARS)
    palette = pick_hued(colors, BLOB_CANDIDATE_VARS, distinct_from={logo}) or \
        synthesize_hued(colors, BLOB_CANDIDATE_VARS, distinct_from={logo})
    return [logo, palette]


def seed_for(slug):
    return zlib.crc32(slug.encode())


def blob_path(cx, cy, r, wobbles, n=64):
    """Closed rounded blob: radius perturbed by a few overlaid sine waves,
    walked with cubic-bezier segments so the boundary stays smooth."""
    def radius(theta):
        rr = r
        for amp, freq, phase in wobbles:
            rr += amp * math.sin(freq * theta + phase)
        return rr

    pts = []
    for i in range(n):
        theta = 2 * math.pi * i / n
        rr = radius(theta)
        pts.append((cx + rr * math.cos(theta), cy + rr * math.sin(theta)))

    d = f"M {pts[0][0]:.1f},{pts[0][1]:.1f} "
    k = 0.55
    for i in range(n):
        p0 = pts[i]
        p1 = pts[(i + 1) % n]
        pm1 = pts[(i - 1) % n]
        p2 = pts[(i + 2) % n]
        c1 = (p0[0] + (p1[0] - pm1[0]) * k / 6, p0[1] + (p1[1] - pm1[1]) * k / 6)
        c2 = (p1[0] - (p2[0] - p0[0]) * k / 6, p1[1] - (p2[1] - p0[1]) * k / 6)
        d += f"C {c1[0]:.1f},{c1[1]:.1f} {c2[0]:.1f},{c2[1]:.1f} {p1[0]:.1f},{p1[1]:.1f} "
    return d + "Z"


def make_wobbles(rng, r):
    return [
        (rng.uniform(0.08, 0.12) * r, rng.choice([3, 4]), rng.uniform(0, 2 * math.pi)),
        (rng.uniform(0.04, 0.06) * r, rng.choice([5, 6]), rng.uniform(0, 2 * math.pi)),
        (rng.uniform(0.02, 0.03) * r, rng.choice([7, 8, 9]), rng.uniform(0, 2 * math.pi)),
    ]


def plan_blobs(theme_dir):
    theme_dir = Path(theme_dir)
    rng = random.Random(seed_for(theme_dir.name))
    colors = load_colors(theme_dir)

    blob_colors = pick_blob_colors(colors)
    rng.shuffle(blob_colors)

    theta = rng.uniform(0, 2 * math.pi)
    ux, uy = math.cos(theta), math.sin(theta)
    cx0, cy0 = CENTER

    third_r = math.sqrt((W * H / 3) / math.pi)
    blobs = []
    for sign, color in ((+1, blob_colors[0]), (-1, blob_colors[1])):
        d = rng.uniform(D_MIN, D_MAX)
        cx = cx0 + sign * d * ux
        cy = cy0 + sign * d * uy
        r = third_r * rng.uniform(0.85, 1.15)
        blobs.append((color, cx, cy, r, make_wobbles(rng, r)))
    return colors, blobs


def build(theme_dir):
    colors, blobs = plan_blobs(theme_dir)
    body = "".join(
        f'<path d="{blob_path(cx, cy, r, wobbles)}" fill="{color}" filter="url(#sp-diffuse)"/>'
        for color, cx, cy, r, wobbles in blobs
    )
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}">
<defs>
<filter id="sp-diffuse" x="-50%" y="-50%" width="200%" height="200%" color-interpolation-filters="sRGB">
<feGaussianBlur stdDeviation="{DIFFUSE_STDDEV}"/>
</filter>
<pattern id="lin-h" width="4" height="4" patternUnits="userSpaceOnUse">
<rect width="4" height="1" fill="#000" opacity="0.10"/>
</pattern>
<pattern id="lin-d" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(63)">
<rect width="8" height="1.5" fill="#000" opacity="0.06"/>
</pattern>
</defs>
<rect width="{W}" height="{H}" fill="{FLAT_BG}"/>
{body}
<rect width="{W}" height="{H}" fill="url(#lin-h)"/>
<rect width="{W}" height="{H}" fill="url(#lin-d)"/>
</svg>
'''
    return svg


def iter_theme_dirs(themes_root):
    themes_root = Path(themes_root)
    for fam_dir in sorted(themes_root.iterdir()):
        if not fam_dir.is_dir():
            continue
        for theme_dir in sorted(fam_dir.iterdir()):
            if not theme_dir.is_dir():
                continue
            if not list(theme_dir.glob("palette-*.sh")):
                continue
            yield theme_dir


def _require_resvg():
    if shutil.which("resvg") is None:
        sys.exit("make-splotch-bg: 'resvg' not found on PATH — cannot rasterise wallpapers")


def render(theme_dir):
    """Write wallpaper-background.svg + wallpaper-<slug>.png into theme_dir.
    Returns the PNG path."""
    theme_dir = Path(theme_dir)
    slug = theme_dir.name
    svg_path = theme_dir / "wallpaper-background.svg"
    png_path = theme_dir / f"wallpaper-{slug}.png"
    svg_path.write_text(build(theme_dir))
    subprocess.run(
        ["resvg", "--width", str(W), "--height", str(H), str(svg_path), str(png_path)],
        check=True,
    )
    return png_path


def generate_all(themes_root):
    _require_resvg()
    written = []
    for theme_dir in iter_theme_dirs(themes_root):
        written.append(render(theme_dir))
    return written


def main():
    if "--all" in sys.argv:
        rest = [a for a in sys.argv[1:] if a != "--all"]
        themes_root = rest[0] if rest else DEFAULT_THEMES_ROOT
        for out in generate_all(themes_root):
            print(f"🎨 wrote {out}")
        return

    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    _require_resvg()
    out = render(sys.argv[1])
    print(f"🎨 wrote {out}")


if __name__ == "__main__":
    main()
