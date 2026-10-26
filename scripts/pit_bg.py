"""pit_bg — a natural, endless black shaft for the niri overview backdrop.

The foil to the designed, colourful wallpaper: rough rock walls streaked by
water and weathering, sinking toward a vanishing point at the screen centre
(where the overview's workspace cards shrink to) and swallowed by black well
before it. Wobbly strata converge on the centre, each one darkening the wall
below it, so there is no visible floor. Pure grey: brightness comes from the
theme's SCORE (luminance only), depth from SHADOW. Seeded, so a theme always
renders the same shaft. Imported by make-splotch-bg.py; also runnable on its
own:

  pit_bg.py <theme-dir>
"""
import math
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path

W, H = 1920, 1080
VANISH = (W / 2, H / 2)
STREAKS = 170
STRATA = 16


def _palette(theme_dir):
    out = {}
    for f in Path(theme_dir).glob("palette-*.sh"):
        for m in re.finditer(r'export (\w+)="(#[0-9a-fA-F]{6})"', f.read_text()):
            out[m.group(1)] = m.group(2)
    return out


def _lum(h):
    r, g, b = (int(h[i:i + 2], 16) for i in (1, 3, 5))
    return round(0.2126 * r + 0.7152 * g + 0.0722 * b)


def _grey(level, top, floor):
    v = round(floor + (top - floor) * max(0.0, min(1.0, level)))
    return f"#{v:02x}{v:02x}{v:02x}"


def _wobble(rng, n=5):
    """Smooth closed-curve radius noise: a few random sine harmonics."""
    return [(rng.uniform(0.02, 0.07) / (k + 1), rng.uniform(0, math.tau), k + 2) for k in range(n)]


def _stratum(rng, a, b, harmonics, steps=140):
    pts = []
    for i in range(steps):
        t = math.tau * i / steps
        r = 1 + sum(amp * math.sin(freq * t + ph) for amp, ph, freq in harmonics)
        pts.append((VANISH[0] + a * r * math.cos(t), VANISH[1] + b * r * math.sin(t)))
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)


def build(theme_dir):
    pal = _palette(theme_dir)
    top = _lum(pal.get("SCORE", "#e8e8e8"))  # palette-lint: ok (fallback when the palette lacks the var)
    black = _grey(0, top, _lum(pal.get("SHADOW", "#000000")))  # palette-lint: ok
    rock = _grey(0.42, top, 0)
    edge = _grey(0.70, top, 0)
    vx, vy = VANISH
    big = math.hypot(W, H)
    rng = random.Random(7)

    streaks = []
    for _ in range(STREAKS):
        ang = rng.uniform(0, math.tau)
        half = rng.uniform(0.004, 0.03)
        near = rng.uniform(0.04, 0.35) * big
        far = big
        p = [(vx + near * math.cos(ang - half * 0.3), vy + near * math.sin(ang - half * 0.3)),
             (vx + far * math.cos(ang - half), vy + far * math.sin(ang - half)),
             (vx + far * math.cos(ang + half), vy + far * math.sin(ang + half)),
             (vx + near * math.cos(ang + half * 0.3), vy + near * math.sin(ang + half * 0.3))]
        pts = " ".join(f"{x:.1f},{y:.1f}" for x, y in p)
        streaks.append(f'<polygon points="{pts}" fill="{rock if rng.random() < 0.7 else edge}" '
                       f'fill-opacity="{rng.uniform(0.04, 0.22):.3f}"/>')

    strata = []
    for k in range(STRATA):
        s = 0.9 ** k * 1.18
        harm = _wobble(rng)
        pts = _stratum(rng, W / 2 * s, H / 2 * s, harm)
        fade = (1 - k / STRATA) ** 1.4
        strata.append(f'<polygon points="{pts}" fill="{black}" fill-opacity="0.22" '
                      f'stroke="{edge}" stroke-opacity="{0.34 * fade:.3f}" stroke-width="{max(1.0, 5 * fade):.1f}"/>')

    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}">
<defs>
<filter id="soft" x="-5%" y="-5%" width="110%" height="110%" color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="7"/></filter>
<filter id="strata" x="-5%" y="-5%" width="110%" height="110%" color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="2.4"/></filter>
<filter id="grain" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB">
  <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="3" seed="3"/>
  <feColorMatrix type="matrix" values="0 0 0 0 0.5  0 0 0 0 0.5  0 0 0 0 0.5  0.9 0.9 0.9 0 -0.9"/>
</filter>
<filter id="mottle" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB">
  <feTurbulence type="fractalNoise" baseFrequency="0.006 0.012" numOctaves="5" seed="11"/>
  <feColorMatrix type="matrix" values="0 0 0 0 0.5  0 0 0 0 0.5  0 0 0 0 0.5  1.4 0 0 0 -0.55"/>
</filter>
<radialGradient id="void" cx="{vx}" cy="{vy}" r="{W * 0.58:.0f}" gradientUnits="userSpaceOnUse">
  <stop offset="0" stop-color="{black}" stop-opacity="1"/>
  <stop offset="0.30" stop-color="{black}" stop-opacity="0.97"/>
  <stop offset="0.62" stop-color="{black}" stop-opacity="0.55"/>
  <stop offset="1" stop-color="{black}" stop-opacity="0"/>
</radialGradient>
</defs>
<rect width="{W}" height="{H}" fill="{black}"/>
<rect width="{W}" height="{H}" fill="{rock}" opacity="0.10"/>
<rect width="{W}" height="{H}" filter="url(#mottle)" opacity="0.55"/>
<g filter="url(#soft)">{"".join(streaks)}</g>
<g filter="url(#strata)">{"".join(strata)}</g>
<rect width="{W}" height="{H}" filter="url(#grain)" opacity="0.5"/>
<rect width="{W}" height="{H}" fill="url(#void)"/>
</svg>
'''


def render(theme_dir):
    theme_dir = Path(theme_dir)
    if shutil.which("resvg") is None:
        sys.exit("pit_bg: 'resvg' not found on PATH")
    svg = theme_dir / "wallpaper-pit.svg"
    png = theme_dir / "wallpaper-pit.png"
    svg.write_text(build(theme_dir))
    subprocess.run(["resvg", "--width", str(W), "--height", str(H), str(svg), str(png)], check=True)
    svg.unlink()
    return png


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    print(f"wrote {render(sys.argv[1])}")
