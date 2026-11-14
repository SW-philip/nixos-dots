# Fonts (Google Fonts, OFL/Apache): Bungee, Fredoka (wght 700), Bangers, Luckiest Guy,
# Righteous, Audiowide, Monoton, Limelight, in <fontdir> as their upstream .ttf names.
# Run: nix-shell -p "python3.withPackages (ps: [ ps.fonttools ])" librsvg --run "python3 gen.py <fontdir> <outdir> [n...]",
# then rsvg-convert -w 800 each SVG and trim (magick -trim) into ../<n>.png.
#!/usr/bin/env python3
"""ErsatzTV channel logos 1-5, 8, 9, 21: one distinct typeface, palette and
icon each. Text is converted to outlines so the SVGs need no fonts.

    gen.py <fontdir> <outdir> [n...]     # only those channels, else all
"""
import math
import random
import sys
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

FONTS, OUT = Path(sys.argv[1]), Path(sys.argv[2])
_cache = {}


def font(name):
    if name not in _cache:
        f = TTFont(FONTS / name)
        _cache[name] = (f.getGlyphSet(), f.getBestCmap(), f["head"].unitsPerEm)
    return _cache[name]


def text(fname, s, size, x, base, track=0.0, anchor="start"):
    """Return (path d, x0, x1, top, bottom) for s set at baseline `base`."""
    gs, cmap, upm = font(fname)
    k = size / upm
    width = sum(gs[cmap[ord(c)]].width * k + track for c in s) - track
    if anchor == "middle":
        x -= width / 2
    d, cx, top, bot = [], x, base, base
    for c in s:
        g = gs[cmap[ord(c)]]
        pen = SVGPathPen(gs)
        g.draw(TransformPen(pen, (k, 0, 0, -k, cx, base)))
        d.append(pen.getCommands())
        bp = BoundsPen(gs)
        g.draw(bp)
        if bp.bounds:
            top = min(top, base - bp.bounds[3] * k)
            bot = max(bot, base - bp.bounds[1] * k)
        cx += g.width * k + track
    return " ".join(d), x, x + width, top, bot


def layered(d, fills, outline=None, ow=0, shadow=None, dx=0, dy=0):
    """Text path with optional offset shadow and outline under the fill."""
    out = []
    if shadow:
        out.append(f'<path d="{d}" transform="translate({dx} {dy})" fill="{shadow}" '
                   f'stroke="{shadow}" stroke-width="{ow}" stroke-linejoin="round"/>')
    if outline:
        out.append(f'<path d="{d}" fill="{outline}" stroke="{outline}" stroke-width="{ow}" stroke-linejoin="round"/>')
    out.append(f'<path d="{d}" fill="{fills}"/>')
    return "".join(out)


def svg(w, h, body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" '
            f'viewBox="0 0 {w:.0f} {h:.0f}">{f"<defs>{defs}</defs>" if defs else ""}{body}</svg>')


def per_letter(fname, s, size, x, base, colors, track=0.0):
    """Each glyph its own colour; returns (list of (d, colour), x1, top)."""
    out, cx, top = [], x, base
    for i, c in enumerate(s):
        d, _, x1, t, _ = text(fname, c, size, cx, base)
        out.append((d, colors[i % len(colors)]))
        top = min(top, t)
        cx = x1 + track
    return out, cx - track, top


# 1 Kids Movies: theatre marquee with chase lights
def kids_movies():
    F = "Bungee-Regular.ttf"
    l1 = text(F, "KIDS", 120, 0, 0, 4, "middle")
    l2 = text(F, "MOVIES", 120, 0, 0, 4, "middle")
    tw = max(l1[2] - l1[1], l2[2] - l2[1])
    bw, bh = tw + 110, 300
    W, H = bw + 40, bh + 40
    cx = W / 2
    l1 = text(F, "KIDS", 120, cx, 165, 4, "middle")
    l2 = text(F, "MOVIES", 120, cx, 290, 4, "middle")
    body = [f'<rect x="20" y="20" width="{bw}" height="{bh}" rx="28" fill="#b3122e" stroke="#2a0a12" stroke-width="12"/>',
            f'<rect x="58" y="58" width="{bw - 76}" height="{bh - 76}" rx="12" fill="#7a0c20"/>']
    # bulbs along the border
    per = 2 * (bw + bh)
    n = int(per / 40)
    for i in range(n):
        t = i / n * per
        if t < bw:
            x, y = 20 + t, 20
        elif t < bw + bh:
            x, y = 20 + bw, 20 + t - bw
        elif t < 2 * bw + bh:
            x, y = 20 + bw - (t - bw - bh), 20 + bh
        else:
            x, y = 20, 20 + bh - (t - 2 * bw - bh)
        body.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="11" fill="#ffe27a" stroke="#f08a00" stroke-width="4"/>')
    for d, *_ in (l1, l2):
        body.append(layered(d, "#fff6e0", shadow="#2a0a12", ow=6, dx=6, dy=6))
    return svg(W, H, "".join(body))


# 2 Little Kids: pastel blocks, lowercase rounded type
def little_kids():
    F = "Fredoka-Bold.ttf"
    pastel = ["#ff9aa2", "#ffc46b", "#86d9a5", "#7ec8f2", "#b9a3f5", "#ff9ed1"]
    plum = "#5b4a6b"
    body = []
    blocks = [(40, 150, "#ff9aa2", "a"), (150, 150, "#7ec8f2", "b"), (95, 45, "#86d9a5", "c")]
    for x, y, col, ch in blocks:
        body.append(f'<rect x="{x}" y="{y}" width="100" height="100" rx="22" fill="{col}" stroke="{plum}" stroke-width="8"/>')
        body.append(f'<rect x="{x + 12}" y="{y + 12}" width="76" height="76" rx="14" fill="#ffffff" fill-opacity="0.35"/>')
        d, *_ = text(F, ch, 78, x + 50, y + 76, 0, "middle")
        body.append(f'<path d="{d}" fill="#ffffff" stroke="{plum}" stroke-width="5" paint-order="stroke"/>')
    g1, x1, _ = per_letter(F, "little", 132, 290, 128, pastel, -2)
    g2, x2, _ = per_letter(F, "kids", 132, 290, 250, pastel[3:] + pastel[:3], -2)
    for d, c in g1 + g2:
        body.append(f'<path d="{d}" fill="{plum}" stroke="{plum}" stroke-width="18" stroke-linejoin="round"/>')
    for d, c in g1 + g2:
        body.append(f'<path d="{d}" fill="{c}" stroke="#ffffff" stroke-width="5" paint-order="stroke"/>')
    return svg(max(x1, x2) + 30, 275, "".join(body))


# 3 Big Kids: comic starburst, Bangers, rocket
def big_kids():
    F = "Bangers-Regular.ttf"
    l1 = text(F, "BIG", 150, 0, 0, 6)
    l2 = text(F, "KIDS!", 150, 0, 0, 6)
    cx, cy, R = 150, 150, 135
    pts = []
    for i in range(32):
        r = R if i % 2 == 0 else R * 0.68
        a = i / 32 * 2 * math.pi
        pts.append(f"{cx + r * math.cos(a):.1f},{cy + r * math.sin(a):.1f}")
    body = [f'<polygon points="{" ".join(pts)}" fill="#ffd400" stroke="#111" stroke-width="10" stroke-linejoin="round"/>']
    # halftone dots inside the burst
    for i in range(-6, 7):
        for j in range(-6, 7):
            x, y = cx + i * 18 + (j % 2) * 9, cy + j * 18
            dist = math.hypot(x - cx, y - cy)
            if dist < R * 0.6:
                body.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{3.5 + dist / R * 3:.1f}" fill="#ff9f1c"/>')
    # rocket, tilted up-right
    body.append(f'<g transform="translate({cx} {cy}) rotate(40)">'
                '<path d="M0 -95 C38 -60 38 20 26 50 L-26 50 C-38 20 -38 -60 0 -95 Z" fill="#f4f4f4" stroke="#111" stroke-width="9" stroke-linejoin="round"/>'
                '<path d="M-26 20 L-56 62 L-24 52 Z M26 20 L56 62 L24 52 Z" fill="#e63946" stroke="#111" stroke-width="8" stroke-linejoin="round"/>'
                '<circle cx="0" cy="-22" r="17" fill="#3a86ff" stroke="#111" stroke-width="8"/>'
                '<path d="M-16 52 Q0 105 16 52 Z" fill="#ff7b00" stroke="#111" stroke-width="7" stroke-linejoin="round"/></g>')
    x0 = 310
    d1, *_ = text(F, "BIG", 150, x0, 140, 6)
    d2, _, x2, *_ = text(F, "KIDS!", 150, x0 + 20, 285, 6)
    for d in (d1, d2):
        body.append(f'<g transform="skewX(-8)">{layered(d, "#e63946", outline="#111", ow=14, shadow="#1d4ed8", dx=9, dy=9)}</g>')
    return svg(x2 + 30, 310, "".join(body))


# 4 Retro Toons: slime splat
def retro_toons():
    F = "LuckiestGuy-Regular.ttf"
    rng = random.Random(4)
    l1 = text(F, "RETRO", 118, 0, 0, 2)
    l2 = text(F, "TOONS", 118, 0, 0, 2)
    tw = max(l1[2] - l1[1], l2[2] - l2[1])
    W, H = tw + 160, 330
    cx, cy = W / 2, 160
    pts = []
    n = 26
    for i in range(n):
        a = i / n * 2 * math.pi
        rx, ry = (tw / 2 + 60), 135
        jit = rng.uniform(0.86, 1.08) if i % 2 else rng.uniform(0.95, 1.12)
        pts.append((cx + rx * jit * math.cos(a), cy + ry * jit * math.sin(a)))
    # smooth closed curve through the points
    dpath = f"M{(pts[0][0] + pts[-1][0]) / 2:.1f},{(pts[0][1] + pts[-1][1]) / 2:.1f} "
    for i in range(n):
        p, q = pts[i], pts[(i + 1) % n]
        dpath += f"Q{p[0]:.1f},{p[1]:.1f} {(p[0] + q[0]) / 2:.1f},{(p[1] + q[1]) / 2:.1f} "
    body = [f'<path d="{dpath}Z" fill="#7ac943" stroke="#244d12" stroke-width="10" stroke-linejoin="round"/>']
    for dx_, ln in ((-0.25, 55), (0.1, 75), (0.32, 40)):
        x = cx + dx_ * (tw + 120)
        body.append(f'<path d="M{x - 14:.1f},{cy + 120} L{x - 14:.1f},{cy + 120 + ln} a14,14 0 0 0 28,0 L{x + 14:.1f},{cy + 120} Z" '
                    f'fill="#7ac943" stroke="#244d12" stroke-width="8" stroke-linejoin="round"/>')
    body.append(f'<path d="{dpath}Z" fill="#7ac943" transform="translate(0 -4)"/>')
    for i, (sx, sy, r) in enumerate([(cx - tw / 2 - 40, 50, 14), (cx + tw / 2 + 50, 60, 10), (cx + tw / 2 + 30, 285, 12)]):
        body.append(f'<circle cx="{sx:.1f}" cy="{sy}" r="{r}" fill="#7ac943" stroke="#244d12" stroke-width="6"/>')
    for s_, base in (("RETRO", 150), ("TOONS", 262)):
        d, *_ = text(F, s_, 118, cx, base, 2, "middle")
        body.append(layered(d, "#7b2cbf", outline="#ffffff", ow=16, shadow="#240046", dx=0, dy=7))
    return svg(W, H + 40, "".join(body))


# 5 Music Videos: neon equalizer on a dark screen, Righteous
def music_videos():
    F = "Righteous-Regular.ttf"
    ink, pink, violet, cyan, sun = "#160b2e", "#ff2e88", "#8b3dff", "#22d3ff", "#ffe14d"
    rng = random.Random(5)
    d1, _, a1, *_ = text(F, "MUSIC", 150, 300, 160, 6)
    d2, _, a2, *_ = text(F, "VIDEOS", 92, 304, 262, 10)
    W, H = max(a1, a2) + 40, 300
    defs = ('<linearGradient id="eq" x1="0" y1="1" x2="0" y2="0">'
            f'<stop offset="0" stop-color="{violet}"/><stop offset="0.55" stop-color="{pink}"/>'
            f'<stop offset="1" stop-color="{sun}"/></linearGradient>'
            '<linearGradient id="word" x1="0" y1="0" x2="1" y2="0">'
            f'<stop offset="0" stop-color="{cyan}"/><stop offset="1" stop-color="{pink}"/></linearGradient>')
    # TV screen with an equalizer and two notes
    body = [f'<rect x="12" y="22" width="262" height="256" rx="40" fill="{ink}" stroke="{cyan}" stroke-width="10"/>']
    for i in range(7):
        h = 40 + rng.random() * 130 if i not in (2, 4) else 170 - i * 8
        x = 40 + i * 31
        body.append(f'<rect x="{x}" y="{250 - h:.0f}" width="22" height="{h:.0f}" rx="6" fill="url(#eq)"/>')
    for nx, ny, sc in ((198, 92, 1.0), (88, 74, 0.8)):
        body.append(f'<g transform="translate({nx} {ny}) scale({sc})" fill="{sun}" stroke="{ink}" stroke-width="5">'
                    '<ellipse cx="0" cy="44" rx="20" ry="15" transform="rotate(-20 0 44)"/>'
                    '<rect x="13" y="-26" width="9" height="70" rx="3"/>'
                    '<path d="M18 -26 Q50 -14 40 22 Q36 2 18 -6 Z"/></g>')
    body.append(layered(d1, "url(#word)", outline=ink, ow=16, shadow=violet, dx=7, dy=7))
    body.append(layered(d2, "#ffffff", outline=ink, ow=12, shadow=pink, dx=5, dy=5))
    return svg(W, H, "".join(body), defs)


# 8 Science!: flask + Audiowide
def science():
    F = "Audiowide-Regular.ttf"
    navy, teal, lime = "#0b2545", "#13c4a3", "#b5e61d"
    body = [
        # flask
        '<path d="M80 40 L140 40 L140 115 L205 240 Q215 265 190 270 L30 270 Q5 265 15 240 L80 115 Z" fill="#e8fbff" stroke="#0b2545" stroke-width="12" stroke-linejoin="round"/>',
        '<path d="M52 180 L168 180 L198 242 Q204 256 188 258 L32 258 Q16 256 22 242 Z" fill="#13c4a3"/>',
        '<rect x="66" y="26" width="88" height="22" rx="8" fill="#0b2545"/>',
    ]
    for x, y, r in ((95, 215, 12), (130, 232, 8), (115, 160, 9), (100, 120, 6), (128, 95, 11), (108, 62, 7)):
        body.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{lime if y < 180 else "#e8fbff"}" stroke="{navy}" stroke-width="4"/>')
    d, _, x1, *_ = text(F, "SCIENCE!", 128, 250, 205, 4)
    body.append(layered(d, teal, outline=navy, ow=16, shadow=lime, dx=7, dy=7))
    return svg(x1 + 30, 290, "".join(body))


# 9 Retro: VHS-label stripes, Monoton
def retro():
    F = "Monoton-Regular.ttf"
    d, x0, x1, top, bot = text(F, "RETRO", 170, 70, 215, 4)
    W = x1 + 260
    stripes = ["#ff3c6f", "#ff8a3d", "#ffd23f", "#3ddc97", "#3aa7ff"]
    body = [f'<rect x="10" y="10" width="{W - 20:.0f}" height="270" rx="26" fill="#1a1033"/>']
    for i, c in enumerate(stripes):
        x = W - 250 + i * 34
        body.append(f'<polygon points="{x:.0f},10 {x + 26:.0f},10 {x + 126:.0f},280 {x + 100:.0f},280" fill="{c}" clip-path="url(#label)"/>')
    body.append(f'<rect x="10" y="10" width="{W - 20:.0f}" height="270" rx="26" fill="none" stroke="#ff5fa2" stroke-width="8"/>')
    defs = (f'<clipPath id="label"><rect x="10" y="10" width="{W - 20:.0f}" height="270" rx="26"/></clipPath>'
            '<linearGradient id="sun" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#ffd23f"/><stop offset="0.5" stop-color="#ff5fa2"/>'
            '<stop offset="1" stop-color="#9b5de5"/></linearGradient>')
    body.append(f'<path d="{d}" fill="url(#sun)"/>')
    return svg(W, 290, "".join(body), defs)


# 21 Movie Night: art deco gold + film reel
def movie_night():
    F = "Limelight-Regular.ttf"
    gold, wine, char = "#e9b949", "#6b1420", "#222226"
    body = []
    cx, cy, R = 140, 150, 118
    strip = f'M{cx} {cy + R - 10} C{cx + 60} {cy + R + 10} {cx + 150} {cy + R - 30} {cx + 230} {cy + R + 20}'
    body.append(f'<path d="{strip}" fill="none" stroke="{gold}" stroke-width="54"/>')
    body.append(f'<path d="{strip}" fill="none" stroke="{char}" stroke-width="42"/>')
    for i in range(6):
        x = cx + 30 + i * 36
        y = cy + R - 10 + (i * 8) - 6
        body.append(f'<rect x="{x}" y="{y - 26}" width="16" height="10" rx="2" fill="{gold}" transform="rotate(8 {x} {y})"/>')
    body.append(f'<circle cx="{cx}" cy="{cy}" r="{R}" fill="{char}" stroke="{gold}" stroke-width="10"/>')
    for i in range(5):
        a = i / 5 * 2 * math.pi - math.pi / 2
        body.append(f'<circle cx="{cx + 62 * math.cos(a):.1f}" cy="{cy + 62 * math.sin(a):.1f}" r="30" fill="{gold}" fill-opacity="0.18" stroke="{gold}" stroke-width="5"/>')
    body.append(f'<circle cx="{cx}" cy="{cy}" r="20" fill="{gold}"/>')
    x0 = cx + R + 50
    d1, _, a1, *_ = text(F, "MOVIE", 128, x0, 140, 8)
    d2, _, a2, *_ = text(F, "NIGHT", 128, x0, 272, 8)
    for d in (d1, d2):
        body.append(layered(d, gold, outline=wine, ow=10))
    body.append(f'<rect x="{x0}" y="160" width="{max(a1, a2) - x0:.0f}" height="6" fill="{gold}"/>')
    return svg(max(a1, a2) + 30, 300, "".join(body))


OUT.mkdir(parents=True, exist_ok=True)
LOGOS = {"1": kids_movies, "2": little_kids, "3": big_kids, "4": retro_toons,
         "5": music_videos, "8": science, "9": retro, "21": movie_night}
for n, fn in LOGOS.items():
    if sys.argv[3:] and n not in sys.argv[3:]:
        continue
    (OUT / f"{n}.svg").write_text(fn())
    print("wrote", n)
