"""Build the DSA rose Plymouth frame sequence: a rotating WPA-style sunburst
behind a rust medallion carrying the real fist+rose mark and "DSA" lettering,
halftone screenprint grain throughout. See
docs/superpowers/specs/2026-07-12-dsa-plymouth-splash-design.md for the full
design rationale (palette/proportion choices, why three independent sprites
instead of one flattened sequence like lix-plymouth's).
"""
from __future__ import annotations

import math
import os
import sys

import cairo

# ── palette ──────────────────────────────────────────────────────────────────
FIELD     = "#233127"   # olive background field
MEDALLION = "#a8451f"   # rust medallion fill
CREAM     = "#f0e9d8"   # ink highlight / lettering
INK       = "#1c1712"   # charcoal ink / grain / borders
RAY       = "#d9a441"   # mustard/gold sunburst

# ── proportions (ratios locked from the approved brainstorming mockup) ───────
SUNBURST_PX     = 900
MEDALLION_PX    = round(SUNBURST_PX / 1.83)
ICON_W          = round(MEDALLION_PX * 0.51)
BORDER_PX       = round(MEDALLION_PX * 0.035)
RAY_COUNT       = 18
RAY_WEDGE_DEG   = 10
DOT_PITCH_FRAC  = 0.026
DOT_RADIUS_FRAC = 0.19
GRAIN_ALPHA     = 0.4
ICON_SPLIT_FRAC = 0.55

RAY_FRAMES     = 36
DESCENT_FRAMES = 30
SETTLE_FRAMES  = 8
HOLD_FRAMES    = 4
MEDALLION_FRAME_COUNT = DESCENT_FRAMES + SETTLE_FRAMES + HOLD_FRAMES

BG_W, BG_H = 1600, 1000

SETTLE_RISE = round(MEDALLION_PX * 0.02)


def _rgb(h: str) -> tuple[float, float, float]:
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def _set(cr: cairo.Context, h: str) -> None:
    cr.set_source_rgb(*_rgb(h))


def _ease_in_out(t):
    return 0.5 - 0.5 * math.cos(math.pi * t)


# ── halftone screenprint grain ────────────────────────────────────────────────

def draw_halftone(cr: cairo.Context, w: int, h: int, tint: str = INK,
                   alpha: float = GRAIN_ALPHA) -> None:
    """Regular screenprint dot-grid grain, multiply-blended over whatever is
    already painted in `cr`. Deliberately a fixed dot grid, not organic
    feTurbulence noise like the desktop wallpaper/greeter fiber grain — this
    is meant to read as a cheap protest-handbill halftone screen, a
    different, more mechanical texture on purpose. Caller should clip `cr`
    first (e.g. to a circle) to bound where dots are drawn; otherwise dots
    cover the full w x h canvas."""
    pitch = max(2, round(min(w, h) * DOT_PITCH_FRAC))
    radius = pitch * DOT_RADIUS_FRAC
    cr.save()
    cr.set_operator(cairo.OPERATOR_MULTIPLY)
    r, g, b = _rgb(tint)
    cr.set_source_rgba(r, g, b, alpha)
    y = pitch / 2
    while y < h:
        x = pitch / 2
        while x < w:
            cr.new_sub_path()
            cr.arc(x, y, radius, 0, 2 * math.pi)
            cr.fill()
            x += pitch
        y += pitch
    cr.restore()


# ── background layer ───────────────────────────────────────────────────────────

def render_background() -> cairo.ImageSurface:
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, BG_W, BG_H)
    cr = cairo.Context(surf)
    _set(cr, FIELD)
    cr.paint()
    draw_halftone(cr, BG_W, BG_H)
    surf.flush()
    return surf


# ── sunburst rays ──────────────────────────────────────────────────────────────

def draw_sunburst(cr: cairo.Context, size: int, angle_deg: float) -> None:
    """One frame of the rotating ray ring, centered in a size x size canvas.
    Rays start just clear of the medallion's edge (RAY_COUNT wedges of
    RAY_WEDGE_DEG degrees, repeating every 360/RAY_COUNT degrees)."""
    cx = cy = size / 2
    outer_r = size / 2
    inner_r = MEDALLION_PX / 2 + BORDER_PX
    cr.save()
    cr.translate(cx, cy)
    cr.rotate(math.radians(angle_deg))
    _set(cr, RAY)
    step = 360 / RAY_COUNT
    for i in range(RAY_COUNT):
        a0 = math.radians(i * step)
        a1 = a0 + math.radians(RAY_WEDGE_DEG)
        cr.new_sub_path()
        cr.move_to(inner_r * math.cos(a0), inner_r * math.sin(a0))
        cr.line_to(outer_r * math.cos(a0), outer_r * math.sin(a0))
        cr.arc(0, 0, outer_r, a0, a1)
        cr.line_to(inner_r * math.cos(a1), inner_r * math.sin(a1))
        cr.arc_negative(0, 0, inner_r, a1, a0)
        cr.close_path()
        cr.fill()
    cr.restore()


def render_sunburst_frames(out_dir: str) -> int:
    os.makedirs(out_dir, exist_ok=True)
    for i in range(RAY_FRAMES):
        angle = i * (360 / RAY_FRAMES)
        surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, SUNBURST_PX, SUNBURST_PX)
        draw_sunburst(cairo.Context(surf), SUNBURST_PX, angle)
        surf.flush()
        surf.write_to_png(f"{out_dir}/ray-{i}.png")
    return RAY_FRAMES


# ── medallion shell ────────────────────────────────────────────────────────────

def draw_medallion_shell(cr: cairo.Context, size: int) -> None:
    """Static parts of the medallion: rust fill, halftone grain clipped to the
    circle, charcoal border. Icon + text are composited on top per-frame by
    the caller (compose_medallion)."""
    cx = cy = size / 2
    r = size / 2 - BORDER_PX / 2
    cr.save()
    cr.arc(cx, cy, r, 0, 2 * math.pi)
    cr.clip_preserve()
    _set(cr, MEDALLION)
    cr.fill()
    draw_halftone(cr, size, size)
    cr.restore()
    cr.save()
    cr.arc(cx, cy, r, 0, 2 * math.pi)
    _set(cr, INK)
    cr.set_line_width(BORDER_PX)
    cr.stroke()
    cr.restore()


# ── icon split (rose+leaves vs fist, for the rise/bloom reveal) ──────────────

def _crop(surf: cairo.ImageSurface, x: int, y: int, w: int, h: int) -> cairo.ImageSurface:
    out = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    cr = cairo.Context(out)
    cr.set_source_surface(surf, -x, -y)
    cr.paint()
    out.flush()
    return out


def split_icon(icon_png: str) -> tuple[cairo.ImageSurface, cairo.ImageSurface]:
    """Split the rasterised dsa.svg into (rose_and_leaves, fist) crops at
    ICON_SPLIT_FRAC of its height, so the two can animate independently
    (fist rises via translation, rose fades in via alpha)."""
    icon = cairo.ImageSurface.create_from_png(icon_png)
    w, h = icon.get_width(), icon.get_height()
    split_y = round(h * ICON_SPLIT_FRAC)
    rose = _crop(icon, 0, 0, w, split_y)
    fist = _crop(icon, 0, split_y, w, h - split_y)
    return rose, fist


# ── medallion animation: fist rises, rose blooms, settles, holds ────────────

def compose_medallion(icon_png: str, text_png: str, out_dir: str) -> int:
    """Emit MEDALLION_FRAME_COUNT frames of the medallion: the fist rises up
    from below into its resting spot (eased), the rose fades in over the
    back half of the rise so it "blooms" as the fist lands, one damped
    settle bob, then a held pose. The static shell (rust fill, grain,
    border) and "DSA" text are redrawn every frame (cheap, deterministic) —
    only the icon crops move/fade."""
    os.makedirs(out_dir, exist_ok=True)
    size = MEDALLION_PX
    rose, fist = split_icon(icon_png)
    text = cairo.ImageSurface.create_from_png(text_png)

    scale = ICON_W / rose.get_width()
    rose_h, fist_h = rose.get_height() * scale, fist.get_height() * scale
    text_scale = (size * 0.5) / text.get_width()
    text_w, text_h = text.get_width() * text_scale, text.get_height() * text_scale

    cx = size / 2
    icon_cy = size * 0.40
    icon_top = icon_cy - (rose_h + fist_h) / 2
    fist_rest_y = icon_top + rose_h
    text_y = icon_top + rose_h + fist_h + size * 0.03
    rise_drop = fist_h * 1.3

    n = 0

    def emit(p, bob, rose_alpha):
        nonlocal n
        surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
        cr = cairo.Context(surf)
        draw_medallion_shell(cr, size)

        # Clip icon/text painting to the medallion's own border-inset circle
        # (same geometry as draw_medallion_shell's border) so the fist rises
        # from behind the bottom edge instead of spilling past it as a
        # disconnected shape while still low in the descent.
        cr.save()
        cr.arc(cx, cx, size / 2 - BORDER_PX / 2, 0, 2 * math.pi)
        cr.clip()

        fist_y = fist_rest_y + rise_drop * (1 - p) + bob
        cr.save()
        cr.translate(cx - ICON_W / 2, fist_y)
        cr.scale(scale, scale)
        cr.set_source_surface(fist, 0, 0)
        cr.paint()
        cr.restore()

        if rose_alpha > 0:
            cr.save()
            cr.translate(cx - ICON_W / 2, fist_y - rose_h)
            cr.scale(scale, scale)
            cr.set_source_surface(rose, 0, 0)
            cr.paint_with_alpha(rose_alpha)
            cr.restore()

        cr.save()
        cr.translate(cx - text_w / 2, text_y)
        cr.scale(text_scale, text_scale)
        cr.set_source_surface(text, 0, 0)
        cr.paint()
        cr.restore()

        cr.restore()

        surf.flush()
        surf.write_to_png(f"{out_dir}/medallion-{n}.png")
        n += 1

    for i in range(DESCENT_FRAMES):
        t = i / (DESCENT_FRAMES - 1)
        p = _ease_in_out(t)
        rose_alpha = min(1.0, max(0.0, (t - 0.5) / 0.5))   # blooms over the back half
        emit(p, 0, rose_alpha)
    for i in range(SETTLE_FRAMES):
        t = i / (SETTLE_FRAMES - 1)
        bob = -SETTLE_RISE * math.sin(math.pi * t) * (1 - t)
        emit(1.0, bob, 1.0)
    for _ in range(HOLD_FRAMES):
        emit(1.0, 0, 1.0)

    return n


# ── CLI dispatch ───────────────────────────────────────────────────────────────

TEXT_TARGET_W = round(MEDALLION_PX * 0.62)


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    cmd = argv[0]
    if cmd == "icon-width":
        print(ICON_W)
        return 0
    if cmd == "text-width":
        print(TEXT_TARGET_W)
        return 0
    if cmd == "background":
        _, out = argv
        render_background().write_to_png(out)
        return 0
    if cmd == "sunburst":
        _, out_dir = argv
        render_sunburst_frames(out_dir)
        return 0
    if cmd == "medallion":
        _, icon_png, text_png, out_dir = argv
        compose_medallion(icon_png, text_png, out_dir)
        return 0
    raise SystemExit(f"unknown command: {cmd!r}")


if __name__ == "__main__":
    raise SystemExit(main())
