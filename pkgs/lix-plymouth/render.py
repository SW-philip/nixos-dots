"""Build the Lix soft-serve Plymouth frame sequence.

A compositor, not freehand art. The exact wallpaper artwork (cone.svg, the
orange cup + pink swirl) is the soft-serve; a steel machine is drawn
procedurally above it (`draw_machine`) and badged with the real Nix snowflake
carved out of the official brand logo (`extract_snowflake`).

The build rasterises the wallpaper logo and the snowflake with resvg; `compose`
then emits frames of the logo coming down from the nozzle, revealed peak-first
so it lands exactly on the wallpaper artwork. The lever pulls down while
dispensing, a soft tip sways at the mouth, and the landing is settled with one
damped bob.
"""
from __future__ import annotations

import math
import os
import re
import sys

import cairo

# Machine palette: stainless steel + the official Nix brand blues.
ST_D, ST_M, ST_L, ST_XL = "#5c6672", "#98a3b0", "#d7dee5", "#eef2f6"
NIX_D, NIX_L = "#5277c3", "#7ebae4"
SHADOW = "#241a2b"                            # cel drop, tuned to the pink bg

# Machine geometry. Widths are fractions of the canvas; y values are absolute
# pixels (the canvas width is fixed by the rasterised layers).
M_BX, M_BW, M_BY, M_BH, M_R = 0.178, 0.644, 52, 212, 40
NOZ_THW, NOZ_BHW, NOZ_DROP = 0.117, 0.075, 64
LEV_XF, LEV_WF, LEV_YF, LEV_H = 0.70, 0.061, 0.30, 150
BADGE_RF, BADGE_YF = 0.083, 0.44
NOZ_OVERLAP = 34                             # swirl peak tucks up behind the nozzle
BOTTOM_MARGIN = 30

# The cup + swirl slide down as one rigid unit behind the fixed nozzle (cup
# sinks, peak emerges last), then the landing is settled with one damped bob.
DESCENT_FRAMES = 30          # eased slide of the unit down to its resting place
SETTLE_FRAMES = 8            # damped bob after the pour lands
HOLD_FRAMES = 4              # settled pose, held (also what shutdown/reboot show)
FRAME_COUNT = DESCENT_FRAMES + SETTLE_FRAMES + HOLD_FRAMES

LEVER_PULL = 26              # px the pull lever travels down while dispensing
TIP_RF = 0.05               # deposition-tip radius, fraction of canvas width
TIP_SWAYF = 0.022           # tip sway amplitude, fraction of canvas width
SETTLE_RISE = 9             # px the unit bobs up past rest before settling
ICE_TIP = "d162a4"          # lightest swirl pink, for the dollop at the mouth

NOZ_BOT_Y = M_BY + M_BH - 6 + NOZ_DROP


# ── snowflake carving ─────────────────────────────────────────────────────────

def extract_snowflake(svg: str) -> str:
    """The NixOS logo minus the 'NixOS' wordmark — just the six gradient
    lambdas. The wordmark is a single <g> of <path> glyphs; drop it."""
    return re.sub(r"<g\b.*?</g>", "", svg, flags=re.S)


# ── cairo helpers ────────────────────────────────────────────────────────────

def _rgb(h: str) -> tuple[float, float, float]:
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def _set(cr: cairo.Context, h: str) -> None:
    cr.set_source_rgb(*_rgb(h))


def _ease_in_out(t):
    """Cosine ease, t in [0, 1] -> [0, 1], slow at both ends."""
    return 0.5 - 0.5 * math.cos(math.pi * t)


def _rrect(cr, x, y, w, h, r):
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
    cr.close_path()


def _alpha_bbox(surf: cairo.ImageSurface) -> tuple[int, int, int, int]:
    """(x0, y0, x1, y1) of the surface's opaque region."""
    surf.flush()
    data, stride = surf.get_data(), surf.get_stride()
    w, h = surf.get_width(), surf.get_height()
    x0 = y0 = None
    x1 = y1 = 0
    for y in range(h):
        row = y * stride
        for x in range(0, w, 2):
            if data[row + x * 4 + 3]:
                y0 = y if y0 is None else y0
                y1 = y
                x0 = x if x0 is None else min(x0, x)
                x1 = max(x1, x)
    if y0 is None:
        return (0, 0, w - 1, h - 1)
    return (x0, y0, x1, y1)


def _crop_to_alpha(surf: cairo.ImageSurface, pad: int = 8) -> cairo.ImageSurface:
    x0, y0, x1, y1 = _alpha_bbox(surf)
    w, h = (x1 - x0) + 2 * pad, (y1 - y0) + 2 * pad
    out = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    cr = cairo.Context(out)
    cr.set_source_surface(surf, -(x0 - pad), -(y0 - pad))
    cr.paint()
    return out


def _blit_centered(cr, surf, cx, cy, target_w):
    sw, sh = surf.get_width(), surf.get_height()
    sc = target_w / sw
    cr.save()
    cr.translate(cx - target_w / 2, cy - sh * sc / 2)
    cr.scale(sc, sc)
    cr.set_source_surface(surf, 0, 0)
    cr.paint()
    cr.restore()


# ── the machine ──────────────────────────────────────────────────────────────

def draw_machine(cr: cairo.Context, w: int, flake: cairo.ImageSurface, lever_dy: float = 0) -> None:
    """Steel soft-serve machine with a Nix-blue lever and snowflake badge,
    lit upper-left to match the swirl. `flake` is the cropped snowflake mark."""
    cx = w / 2
    bx, bw = M_BX * w, M_BW * w
    by, bh, r = M_BY, M_BH, M_R

    # body: cel shadow → mid fill → left sheen / right-under shadow faces
    cr.save(); cr.translate(9, 10); _set(cr, SHADOW); _rrect(cr, bx, by, bw, bh, r); cr.fill(); cr.restore()
    _set(cr, ST_M); _rrect(cr, bx, by, bw, bh, r); cr.fill()
    cr.save(); _rrect(cr, bx, by, bw, bh, r); cr.clip()
    _set(cr, ST_L); cr.rectangle(bx, by, bw * 0.32, bh); cr.fill()
    _set(cr, ST_XL); cr.rectangle(bx, by, bw * 0.13, bh); cr.fill()
    _set(cr, ST_D); cr.rectangle(bx + bw * 0.81, by, bw * 0.19, bh); cr.fill()
    cr.rectangle(bx, by + bh * 0.85, bw, bh * 0.15); cr.fill()
    cr.restore()

    # lid cap
    _set(cr, ST_L); _rrect(cr, bx + 26, by - 22, bw - 52, 42, 21); cr.fill()
    cr.save(); _rrect(cr, bx + 26, by - 22, bw - 52, 42, 21); cr.clip()
    _set(cr, ST_XL); cr.rectangle(bx + 26, by - 22, (bw - 52) * 0.5, 42); cr.fill(); cr.restore()

    # nozzle: narrowing spout the swirl pours from
    nt, nb = NOZ_THW * w, NOZ_BHW * w
    ntop, nbot = by + bh - 6, by + bh - 6 + NOZ_DROP
    cr.save(); cr.translate(9, 10); _set(cr, SHADOW)
    cr.move_to(cx - nt, ntop); cr.line_to(cx + nt, ntop); cr.line_to(cx + nb, nbot); cr.line_to(cx - nb, nbot); cr.close_path(); cr.fill(); cr.restore()
    _set(cr, ST_M)
    cr.move_to(cx - nt, ntop); cr.line_to(cx + nt, ntop); cr.line_to(cx + nb, nbot); cr.line_to(cx - nb, nbot); cr.close_path(); cr.fill()
    _set(cr, ST_D); cr.move_to(cx + nt * 0.5, ntop); cr.line_to(cx + nt, ntop); cr.line_to(cx + nb, nbot); cr.line_to(cx + nb * 0.5, nbot); cr.close_path(); cr.fill()
    _set(cr, ST_XL); cr.move_to(cx - nt, ntop); cr.line_to(cx - nt * 0.62, ntop); cr.line_to(cx - nb * 0.62, nbot); cr.line_to(cx - nb, nbot); cr.close_path(); cr.fill()

    # Nix-blue pull lever
    lx, lw = bx + bw * LEV_XF, LEV_WF * w
    ly, lh = by + bh * LEV_YF + lever_dy, LEV_H
    cr.save(); cr.translate(9, 10); _set(cr, SHADOW); _rrect(cr, lx, ly, lw, lh, 20); cr.fill(); cr.restore()
    _set(cr, NIX_D); _rrect(cr, lx, ly, lw, lh, 20); cr.fill()
    _set(cr, NIX_L); _rrect(cr, lx, ly, lw, 42, 20); cr.fill()

    # badge plate + real Nix snowflake
    pr = BADGE_RF * w
    pcx, pcy = cx, by + bh * BADGE_YF
    _set(cr, SHADOW); cr.arc(pcx + 7, pcy + 8, pr, 0, 2 * math.pi); cr.fill()
    _set(cr, ST_XL); cr.arc(pcx, pcy, pr, 0, 2 * math.pi); cr.fill()
    _set(cr, NIX_D); cr.set_line_width(8); cr.arc(pcx, pcy, pr, 0, 2 * math.pi); cr.stroke()
    _blit_centered(cr, flake, pcx, pcy, pr * 1.55)


# ── compositing ──────────────────────────────────────────────────────────────

def compose(logo_png: str, flake_png: str, out_dir: str) -> int:
    """Emit FRAME_COUNT frames: the full wallpaper logo (cone + swirl) comes
    down from the nozzle, revealed peak-first, top-down (the mouth always shows
    the narrow tip, never a wide cross-section), so the settled frame is exactly
    the wallpaper logo. The lever pulls down while dispensing, a soft tip sways
    at the mouth, the landing settles with one damped bob."""
    os.makedirs(out_dir, exist_ok=True)
    logo = cairo.ImageSurface.create_from_png(logo_png)
    flake = _crop_to_alpha(cairo.ImageSurface.create_from_png(flake_png))

    w = logo.get_width()
    _, logo_top, _, logo_bot = _alpha_bbox(logo)
    art_off = int(NOZ_BOT_Y - NOZ_OVERLAP - logo_top)
    h = art_off + logo.get_height() + BOTTOM_MARGIN

    swirl_top = art_off + logo_top                # peak, tucked up behind the nozzle
    swirl_bot = art_off + logo_bot                # base, where the logo settles
    span = swirl_bot - swirl_top                   # reveal height
    cx = w / 2
    tip_r, sway_amp = TIP_RF * w, TIP_SWAYF * w

    def emit(n, p, lever_dy, tip, bob=0):
        # p: fill progress 0..1 — fraction of the logo revealed from the peak down.
        frame = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
        cr = cairo.Context(frame)
        reveal_bot = swirl_top + p * span + bob
        cr.save()                                  # reveal the logo peak-first, top-down
        cr.rectangle(0, NOZ_BOT_Y, w, max(0.0, reveal_bot - NOZ_BOT_Y)); cr.clip()
        cr.set_source_surface(logo, 0, art_off + bob); cr.paint()
        cr.restore()
        if tip is not None:                        # pink dollop swaying at the mouth, fading out
            dx, alpha = tip
            cr.set_source_rgba(*_rgb(ICE_TIP), alpha)
            cr.save(); cr.translate(cx + dx, NOZ_BOT_Y); cr.scale(1.0, 0.6)
            cr.arc(0, 0, tip_r, 0, 2 * math.pi); cr.fill(); cr.restore()
        draw_machine(cr, w, flake, lever_dy)       # machine on top, occludes the peak
        frame.flush()
        frame.write_to_png(f"{out_dir}/frame-{n}.png")

    n = 0
    for i in range(DESCENT_FRAMES):                # pour: swirl grows down, cup sinks, lever pulls
        t = i / (DESCENT_FRAMES - 1)
        p = _ease_in_out(t)
        lever_dy = LEVER_PULL * _ease_in_out(min(t * 1.5, 1.0))
        fade = min(1.0, (1 - t) / 0.15)            # ease the dollop out over the last 15%
        tip = (sway_amp * math.sin(t * math.pi * 5), fade) if fade > 0 else None
        emit(n, p, lever_dy, tip); n += 1
    for i in range(SETTLE_FRAMES):                 # land: one damped bob up, lever springs back
        t = i / (SETTLE_FRAMES - 1)
        bob = -SETTLE_RISE * math.sin(math.pi * t) * (1 - t)
        lever_dy = LEVER_PULL * (1 - _ease_in_out(t))
        emit(n, 1.0, lever_dy, None, bob); n += 1
    for _ in range(HOLD_FRAMES):                   # settled pose, also shown on shutdown/reboot
        emit(n, 1.0, 0, None); n += 1
    return 0


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    cmd = argv[0]
    if cmd == "snowflake":
        _, src, out = argv
        open(out, "w").write(extract_snowflake(open(src).read()))
        return 0
    if cmd == "compose":
        _, out_dir, logo_png, flake_png = argv
        return compose(logo_png, flake_png, out_dir)
    raise SystemExit(f"unknown command: {cmd!r}")


if __name__ == "__main__":
    raise SystemExit(main())
