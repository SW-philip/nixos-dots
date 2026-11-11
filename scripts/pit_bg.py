"""pit_bg — a decaying recursive pattern for the niri overview backdrop.

The screen is split recursively into nested frames, echoing the workspace
cards that shrink toward the centre in the overview. Near the centre the
structure is whole and orderly; outward it decays: cells subdivide deeper,
lose quadrants Sierpinski-style, crack loose, tilt and drift outward and
down, and finally crumble into fractal dust at the screen edges. Colours
come from the theme (HALL ground, SCORE ink, ROOT/FERMATA accents), so the
pit belongs to the same family as the wallpaper. Seeded, so a theme always
renders the same pattern. Imported by make-splotch-bg.py; also runnable on
its own:

  pit_bg.py <theme-dir>
"""
import json
import math
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path

W, H = 1920, 1080
VANISH = (W / 2, H / 2)
MAX_DEPTH = 13
MIN_SIDE = 5
# share of decayed shards left out of the PNG for the pit-fall animator to own
LOOSE_SHARE = 0.3
DECAY_GRID = (48, 27)


def _palette(theme_dir):
    out = {}
    for f in Path(theme_dir).glob("palette-*.sh"):
        for m in re.finditer(r'export (\w+)="(#[0-9a-fA-F]{6})"', f.read_text()):
            out[m.group(1)] = m.group(2)
    return out


def _smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


class _Field:
    """Decay in [0,1]: 0 at the centre, 1 at the corners, roughened by a few
    random sine waves so the crumbling front is ragged, not a clean ellipse."""

    def __init__(self, rng):
        self.waves = [(rng.uniform(0.002, 0.007), rng.uniform(0, math.tau),
                       rng.uniform(0, math.tau), rng.uniform(0.04, 0.09)) for _ in range(6)]

    def __call__(self, x, y):
        dx, dy = (x - VANISH[0]) / (W / 2), (y - VANISH[1]) / (H / 2)
        r = math.hypot(dx, dy) / math.sqrt(2)
        n = sum(a * math.sin(f * (x * math.cos(d) + y * math.sin(d)) + p)
                for f, d, p, a in self.waves)
        return _smooth(0.22, 0.95, r + n)


def build(theme_dir, loose=None):
    """SVG for the pit. With a `loose` list, a share of the decayed shards is
    collected there (rest pose and style, in W×H space) instead of drawn, and a
    coarse decay grid plus the colours are added, for pit-fall to animate."""
    pal = _palette(theme_dir)
    ground = pal.get("HALL", "#080808")  # palette-lint: ok (fallback when the palette lacks the var)
    ink = pal.get("SCORE", "#e8e8e8")  # palette-lint: ok
    accents = [pal.get(k) for k in ("ROOT", "FERMATA", "SOTTO") if pal.get(k)] or [ink]
    rng = random.Random(7)
    pick = random.Random(11)  # separate stream so the static layout never shifts
    decay = _Field(rng)
    vx, vy = VANISH

    frames, shards = [], []

    def leaf(x, y, w, h, depth, d):
        cx, cy = x + w / 2, y + h / 2
        gap = 1.5 + 2.5 * d
        x, y, w, h = x + gap, y + gap, w - 2 * gap, h - 2 * gap
        if w < 1.5 or h < 1.5:
            return
        # loose pieces: drift away from the centre and sag downward
        drift = d ** 2.2
        ox, oy = cx - vx, cy - vy
        norm = math.hypot(ox, oy) or 1
        push = drift * rng.uniform(10, 70)
        tx = ox / norm * push + rng.uniform(-1, 1) * 18 * drift
        ty = oy / norm * push + drift * rng.uniform(15, 110)
        rot = rng.uniform(-1, 1) * 38 * drift
        colour = rng.choice(accents) if rng.random() < 0.25 + 0.5 * d else ink
        op = (0.45 - 0.12 * depth / MAX_DEPTH) * (1 - 0.55 * d)
        width = max(0.6, 2.4 - depth * 0.2 - d)
        tf = f' transform="translate({tx:.1f} {ty:.1f}) rotate({rot:.1f} {cx:.1f} {cy:.1f})"' if drift > 0.01 else ""
        fill_col, fop = None, 0.0
        if rng.random() < 0.08 + 0.3 * d:
            fill_col, fop = rng.choice(accents), round(op * rng.uniform(0.08, 0.3), 3)
        fill = f' fill="{fill_col}" fill-opacity="{fop:.3f}"' if fill_col else ' fill="none"'
        if loose is not None and d > 0.5 and w * h > 30 and pick.random() < LOOSE_SHARE:
            loose.append({"x": round(x, 1), "y": round(y, 1), "w": round(w, 1), "h": round(h, 1),
                          "tx": round(tx, 1), "ty": round(ty, 1), "rot": round(rot, 1), "d": round(d, 3),
                          "stroke": colour, "sop": round(op, 3), "width": round(width, 2),
                          "fill": fill_col, "fop": fop})
            return
        target = shards if d > 0.35 else frames
        target.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}"{fill} '
                      f'stroke="{colour}" stroke-opacity="{op:.3f}" stroke-width="{width:.2f}"{tf}/>')

    def split(x, y, w, h, depth):
        d = decay(x + w / 2, y + h / 2)
        # cell size shrinks with decay: whole slabs near the centre, grit at the edges
        target = 300 * (1 - d) ** 1.6 + 7
        want = depth < 3 or max(w, h) > target * rng.uniform(0.7, 1.4)
        if depth >= MAX_DEPTH or min(w, h) < MIN_SIDE * 2 or not want:
            leaf(x, y, w, h, depth, d)
            return
        if depth >= 3 and d > 0.5 and rng.random() < 0.75:
            # Sierpinski decay: quarter the cell and lose one or more quarters
            hw, hh = w / 2, h / 2
            quads = [(x, y), (x + hw, y), (x, y + hh), (x + hw, y + hh)]
            lost = rng.sample(range(4), 1 if d < 0.85 else rng.randint(1, 3))
            for i, (qx, qy) in enumerate(quads):
                if i not in lost:
                    split(qx, qy, hw, hh, depth + 1)
            return
        if depth >= 4 and d < 0.45 and rng.random() < 0.4 and min(w, h) > 40:
            # intact core: a frame with a smaller copy of itself inside
            leaf(x, y, w, h, depth, d)
            m = rng.uniform(0.06, 0.14)
            split(x + w * m, y + h * m, w * (1 - 2 * m), h * (1 - 2 * m), depth + 1)
            return
        t = rng.uniform(0.38, 0.62)
        if w / h >= (W / H) * rng.uniform(0.7, 1.3):
            split(x, y, w * t, h, depth + 1)
            split(x + w * t, y, w * (1 - t), h, depth + 1)
        else:
            split(x, y, w, h * t, depth + 1)
            split(x, y + h * t, w, h * (1 - t), depth + 1)

    split(0, 0, W, H, 0)

    # fractal dust shed past the crumbling front
    dust = []
    for _ in range(900):
        x, y = rng.uniform(0, W), rng.uniform(0, H)
        d = decay(x, y)
        if rng.random() > d ** 1.5:
            continue
        s = rng.uniform(1, 4.5) * (0.5 + d)
        y += d * rng.uniform(0, 60)
        c = rng.choice(accents) if rng.random() < 0.5 else ink
        dust.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{s:.1f}" height="{s:.1f}" fill="{c}" '
                    f'fill-opacity="{rng.uniform(0.08, 0.35) * d:.3f}" '
                    f'transform="rotate({rng.uniform(0, 90):.0f} {x:.1f} {y:.1f})"/>')

    if loose is not None:
        gx, gy = DECAY_GRID
        loose.append({"meta": {"W": W, "H": H, "ink": ink, "accents": accents,
                               "decay": [[round(decay((i + 0.5) * W / gx, (j + 0.5) * H / gy), 3)
                                          for i in range(gx)] for j in range(gy)]}})
    glow = accents[0]
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}">
<defs>
<filter id="bloom" x="-5%" y="-5%" width="110%" height="110%" color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="6"/></filter>
<filter id="grain" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB">
  <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="3" seed="3"/>
  <feColorMatrix type="matrix" values="0 0 0 0 0.5  0 0 0 0 0.5  0 0 0 0 0.5  0.9 0.9 0.9 0 -0.9"/>
</filter>
<radialGradient id="core" cx="{vx}" cy="{vy}" r="{W * 0.55:.0f}" gradientUnits="userSpaceOnUse">
  <stop offset="0" stop-color="{glow}" stop-opacity="0.10"/>
  <stop offset="0.5" stop-color="{glow}" stop-opacity="0.03"/>
  <stop offset="1" stop-color="{glow}" stop-opacity="0"/>
</radialGradient>
<radialGradient id="vignette" cx="{vx}" cy="{vy}" r="{W * 0.62:.0f}" gradientUnits="userSpaceOnUse">
  <stop offset="0.55" stop-color="{ground}" stop-opacity="0"/>
  <stop offset="1" stop-color="{ground}" stop-opacity="0.55"/>
</radialGradient>
</defs>
<rect width="{W}" height="{H}" fill="{ground}"/>
<rect width="{W}" height="{H}" fill="url(#core)"/>
<g filter="url(#bloom)" opacity="0.6">{"".join(shards)}</g>
<g>{"".join(frames)}</g>
<g>{"".join(shards)}</g>
<g>{"".join(dust)}</g>
<rect width="{W}" height="{H}" filter="url(#grain)" opacity="0.35"/>
<rect width="{W}" height="{H}" fill="url(#vignette)"/>
</svg>
'''


def render(theme_dir):
    theme_dir = Path(theme_dir)
    if shutil.which("resvg") is None:
        sys.exit("pit_bg: 'resvg' not found on PATH")
    svg = theme_dir / "wallpaper-pit.svg"
    png = theme_dir / "wallpaper-pit.png"
    loose = []
    svg.write_text(build(theme_dir, loose))
    meta = loose.pop()["meta"]
    (theme_dir / "wallpaper-pit.json").write_text(json.dumps(dict(meta, pieces=loose)))
    subprocess.run(["resvg", "--width", str(W), "--height", str(H), str(svg), str(png)], check=True)
    svg.unlink()
    return png


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    print(f"wrote {render(sys.argv[1])}")
