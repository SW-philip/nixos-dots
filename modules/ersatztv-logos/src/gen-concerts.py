# Channel 10. Font: Poppins Black. Run like gen.py: python3 gen-concerts.py <Poppins-Black.ttf> <out.svg>
#!/usr/bin/env python3
"""Concerts logo: Palladia-style gold wordmark + stained-glass mosaic dragonfly."""
import math
import random
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

FONT, OUT = sys.argv[1], sys.argv[2]
GOLD = "#f6b21b"
INK = "#1b1410"
MOSAIC = ["#e2231a", "#f05a1a", "#f7931e", "#fbc21c", "#c4161c", "#8e1b10", "#fde3a0"]

W, H = 1100, 470
SIZE = 250            # font size in px
BASE = 455            # baseline y
TRACK = -6            # tight, like Palladia

font = TTFont(FONT)
gs = font.getGlyphSet()
cmap = font.getBestCmap()
upm = font["head"].unitsPerEm
s = SIZE / upm

paths, x, boxes = [], 24.0, []
for ch in "concerts":
    g = cmap[ord(ch)]
    pen = SVGPathPen(gs)
    gs[g].draw(TransformPen(pen, (s, 0, 0, -s, x, BASE)))
    paths.append(pen.getCommands())
    adv = gs[g].width * s
    boxes.append((ch, x, adv))
    x += adv + TRACK
text_w = x

# glyph bounds for the last letter, to perch on
from fontTools.pens.boundsPen import BoundsPen
bp = BoundsPen(gs)
gs[cmap[ord("s")]].draw(bp)
xmin, ymin, xmax, ymax = bp.bounds
_, sx, _ = boxes[-1]
s_left, s_right = sx + xmin * s, sx + xmax * s
s_top = BASE - ymax * s

rng = random.Random(7)
CELL, GAP = 12, 2.4
cells = []


def inside_ellipse(px, py, cx, cy, a, b, ang):
    c, sn = math.cos(ang), math.sin(ang)
    dx, dy = px - cx, py - cy
    u, v = dx * c + dy * sn, -dx * sn + dy * c
    return (u / a) ** 2 + (v / b) ** 2


backs = []


def wing(cx, cy, a, b, ang, base_dark):
    """Mosaic wing: ellipse filled with jittered squares, darker edge and root."""
    backs.append(f'<ellipse cx="{cx:.1f}" cy="{cy:.1f}" rx="{a + 4:.1f}" ry="{b + 4:.1f}" fill="{INK}" '
                 f'transform="rotate({math.degrees(ang):.1f} {cx:.1f} {cy:.1f})"/>')
    r = int(max(a, b) / CELL) + 2
    for i in range(-r, r + 1):
        for j in range(-r, r + 1):
            px, py = cx + i * CELL, cy + j * CELL
            d = inside_ellipse(px, py, cx, cy, a, b, ang)
            if d > 1:
                continue
            # position along the wing's long axis: 0 at root, 1 at tip
            c, sn = math.cos(ang), math.sin(ang)
            u = ((px - cx) * c + (py - cy) * sn) / a
            if d > 0.86:
                continue
            elif u < -0.55 and base_dark:
                col = rng.choice([MOSAIC[0], MOSAIC[4], MOSAIC[5], INK])
            elif u > 0.5:
                col = rng.choice([MOSAIC[2], MOSAIC[3], MOSAIC[3], MOSAIC[6], MOSAIC[1]])
            else:
                col = rng.choice(MOSAIC[:5] + [MOSAIC[3]])
            if rng.random() < 0.07:
                col = INK
            cells.append((px, py, CELL - GAP, col, rng.uniform(-4, 4)))


# dragonfly in profile, perched on the "s": thorax over the letter, head to
# the left over the "t", abdomen trailing right past the word
tx, ty = (s_left + s_right) / 2 + 6, s_top - 34      # thorax centre
head = (tx - 40, ty - 6)
# wings raised up and back from the thorax, hind wing behind fore wing
wing(tx + 92, ty - 112, 128, 40, math.radians(-50), True)   # hind
wing(tx + 22, ty - 140, 138, 38, math.radians(-78), True)   # fore

svg_body = []
svg_body += backs
for px, py, sz, col, rot in cells:
    svg_body.append(
        f'<rect x="{px - sz / 2:.1f}" y="{py - sz / 2:.1f}" width="{sz:.1f}" height="{sz:.1f}" '
        f'fill="{col}" transform="rotate({rot:.1f} {px:.1f} {py:.1f})"/>')

# abdomen: tapered outlined body with mosaic segment bands
n = 10
spine = []
for k in range(n + 1):
    t = k / n
    spine.append((tx + 24 + t * 230, ty + 2 - math.sin(t * math.pi * 0.85) * 30 + t * 4, 13 - 8 * t))
top, bot = [], []
for i, (px, py, w_) in enumerate(spine):
    j = min(i + 1, n)
    i0 = max(i - 1, 0)
    dx, dy = spine[j][0] - spine[i0][0], spine[j][1] - spine[i0][1]
    ln = math.hypot(dx, dy)
    nx, ny = -dy / ln, dx / ln
    top.append((px + nx * w_, py + ny * w_))
    bot.append((px - nx * w_, py - ny * w_))
poly = top + bot[::-1]
abd = [f'<polygon points="{" ".join(f"{x_:.1f},{y_:.1f}" for x_, y_ in poly)}" fill="{INK}" '
       f'stroke="{INK}" stroke-width="8" stroke-linejoin="round"/>']
for k in range(n):
    (x0, y0, w0), (x1, y1, w1) = spine[k], spine[k + 1]
    col = [MOSAIC[0], MOSAIC[2], MOSAIC[3], MOSAIC[1]][k % 4]
    quad = [top[k], top[k + 1], bot[k + 1], bot[k]]
    # inset each segment so a dark seam shows between them
    cx_, cy_ = sum(q[0] for q in quad) / 4, sum(q[1] for q in quad) / 4
    quad = [(cx_ + (qx - cx_) * 0.72, cy_ + (qy - cy_) * 0.72) for qx, qy in quad]
    abd.append(f'<polygon points="{" ".join(f"{x_:.1f},{y_:.1f}" for x_, y_ in quad)}" fill="{col}"/>')

legs = []
for dx, foot in ((-14, s_left + 30), (0, (s_left + s_right) / 2), (14, s_right - 26)):
    kx, ky = tx + dx * 1.6, ty + 26
    legs.append(f'<polyline points="{tx + dx:.1f},{ty + 8:.1f} {kx:.1f},{ky:.1f} {foot:.1f},{s_top + 6:.1f}" '
                f'fill="none" stroke="{INK}" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>')

thorax = (f'<ellipse cx="{tx:.1f}" cy="{ty:.1f}" rx="27" ry="20" fill="{MOSAIC[4]}" stroke="{INK}" stroke-width="5"/>'
          f'<rect x="{tx - 12:.1f}" y="{ty - 9:.1f}" width="10" height="10" fill="{MOSAIC[3]}"/>'
          f'<rect x="{tx + 3:.1f}" y="{ty - 4:.1f}" width="10" height="10" fill="{MOSAIC[2]}"/>')
headsvg = (f'<circle cx="{head[0]:.1f}" cy="{head[1]:.1f}" r="17" fill="{MOSAIC[5]}" stroke="{INK}" stroke-width="5"/>'
           f'<circle cx="{head[0] - 6:.1f}" cy="{head[1] - 5:.1f}" r="9" fill="{INK}"/>'
           f'<circle cx="{head[0] - 8:.1f}" cy="{head[1] - 8:.1f}" r="3" fill="{MOSAIC[6]}"/>')

width = max(text_w + 10, tx + 270)
svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{H}" viewBox="0 0 {width:.0f} {H}">'
       + "".join(f'<path d="{p}" fill="{GOLD}"/>' for p in paths)
       + "".join(legs) + "".join(svg_body) + "".join(abd) + thorax + headsvg + "</svg>")
open(OUT, "w").write(svg)
print(f"wrote {OUT} {width:.0f}x{H}")
