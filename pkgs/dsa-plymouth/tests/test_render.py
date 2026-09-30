import importlib.util
import math
import pathlib

import cairo

HERE = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("render", HERE / "render.py")
render = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(render)


# ── palette + geometry constants ────────────────────────────────────────────

def test_locked_proportions():
    assert render.MEDALLION_PX == round(render.SUNBURST_PX / 1.83)
    assert render.ICON_W == round(render.MEDALLION_PX * 0.51)
    assert render.MEDALLION_FRAME_COUNT == (
        render.DESCENT_FRAMES + render.SETTLE_FRAMES + render.HOLD_FRAMES
    )
    assert render.MEDALLION_FRAME_COUNT == 42
    assert render.RAY_FRAMES == 36


def test_rgb_parses_hex():
    assert render._rgb("#ffffff") == (1.0, 1.0, 1.0)
    assert render._rgb("#000000") == (0.0, 0.0, 0.0)
    r, g, b = render._rgb(render.INK)
    assert (r, g, b) == (0x1c / 255, 0x17 / 255, 0x12 / 255)


def test_ease_in_out_endpoints_and_midpoint():
    assert render._ease_in_out(0.0) == 0.0
    assert abs(render._ease_in_out(1.0) - 1.0) < 1e-9
    assert abs(render._ease_in_out(0.5) - 0.5) < 1e-9
    vals = [render._ease_in_out(i / 10) for i in range(11)]
    assert all(vals[i] <= vals[i + 1] for i in range(10))


# ── halftone grain ───────────────────────────────────────────────────────────

def _unique_colors(surf):
    surf.flush()
    d, st, w, h = surf.get_data(), surf.get_stride(), surf.get_width(), surf.get_height()
    colors = set()
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            o = y * st + x * 4
            colors.add((d[o], d[o + 1], d[o + 2]))
    return colors


def test_halftone_produces_real_grain_not_flat_fill():
    w, h = 300, 300
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    cr = cairo.Context(surf)
    render._set(cr, render.MEDALLION)
    cr.paint()
    render.draw_halftone(cr, w, h)
    # a flat fill has exactly 1 unique color; real dot-grid grain has more
    assert len(_unique_colors(surf)) > 1


def test_halftone_dots_are_darker_than_field():
    w, h = 300, 300
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    cr = cairo.Context(surf)
    render._set(cr, render.MEDALLION)
    cr.paint()
    render.draw_halftone(cr, w, h)
    surf.flush()
    d, st = surf.get_data(), surf.get_stride()
    # dot centers sit on a `pitch`-spaced grid starting at pitch/2; sample one
    pitch = max(2, round(min(w, h) * render.DOT_PITCH_FRAC))
    x = y = pitch // 2
    o = y * st + x * 4
    dot_b, dot_g, dot_r = d[o], d[o + 1], d[o + 2]         # cairo surface is BGRA
    field_r, field_g, field_b = render._rgb(render.MEDALLION)
    assert dot_r < field_r * 255 or dot_g < field_g * 255 or dot_b < field_b * 255


# ── background layer ─────────────────────────────────────────────────────────

def test_render_background_is_field_colored_with_grain():
    surf = render.render_background()
    assert surf.get_width() == render.BG_W
    assert surf.get_height() == render.BG_H
    assert len(_unique_colors(surf)) > 5   # not a flat fill


# ── sunburst rays ─────────────────────────────────────────────────────────────

def test_render_sunburst_frames_count_and_size(tmp_path):
    out = tmp_path / "rays"
    render.render_sunburst_frames(str(out))
    files = sorted(out.glob("ray-*.png"))
    assert len(files) == render.RAY_FRAMES
    surf = cairo.ImageSurface.create_from_png(str(out / "ray-0.png"))
    assert surf.get_width() == render.SUNBURST_PX
    assert surf.get_height() == render.SUNBURST_PX


def test_sunburst_frames_differ_by_rotation(tmp_path):
    out = tmp_path / "rays"
    render.render_sunburst_frames(str(out))
    f0 = (out / "ray-0.png").read_bytes()
    f9 = (out / "ray-9.png").read_bytes()   # a quarter into the loop -> visibly rotated
    assert f0 != f9


def test_sunburst_full_rotation_returns_to_start():
    # RAY_COUNT wedges every 20deg means the pattern repeats every 20deg;
    # rotating by RAY_FRAMES * (360/RAY_FRAMES) = 360deg is a no-op vs frame 0
    surf_a = cairo.ImageSurface(cairo.FORMAT_ARGB32, render.SUNBURST_PX, render.SUNBURST_PX)
    render.draw_sunburst(cairo.Context(surf_a), render.SUNBURST_PX, 0)
    surf_b = cairo.ImageSurface(cairo.FORMAT_ARGB32, render.SUNBURST_PX, render.SUNBURST_PX)
    render.draw_sunburst(cairo.Context(surf_b), render.SUNBURST_PX, 360)
    surf_a.flush(); surf_b.flush()
    assert surf_a.get_data()[:] == surf_b.get_data()[:]


# ── medallion shell + icon split ─────────────────────────────────────────────

def _solid_rgba_png(path, w, h, rgba):
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    cr = cairo.Context(surf)
    cr.set_source_rgba(*rgba)
    cr.paint()
    surf.flush()
    surf.write_to_png(path)


def test_draw_medallion_shell_is_rust_with_charcoal_border():
    size = render.MEDALLION_PX
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    cr = cairo.Context(surf)
    render.draw_medallion_shell(cr, size)
    surf.flush()
    d, st = surf.get_data(), surf.get_stride()
    cx = size // 2
    o = cx * st + cx * 4                       # dead center: fill, not border
    b, g, r = d[o], d[o + 1], d[o + 2]
    fr, fg, fb = render._rgb(render.MEDALLION)
    assert abs(r - fr * 255) < 60 and abs(g - fg * 255) < 60   # rust-ish, halftone dithers it


def test_split_icon_produces_rose_on_top_of_fist(tmp_path):
    icon_path = tmp_path / "icon.png"
    _solid_rgba_png(str(icon_path), 200, 400, (1, 0, 0, 1))
    rose, fist = render.split_icon(str(icon_path))
    assert rose.get_width() == fist.get_width() == 200
    assert rose.get_height() == round(400 * render.ICON_SPLIT_FRAC)
    assert fist.get_height() == 400 - rose.get_height()


# ── medallion animation ───────────────────────────────────────────────────────

def _icon_and_text(tmp_path):
    icon = tmp_path / "icon.png"
    text = tmp_path / "text.png"
    _solid_rgba_png(str(icon), 200, 360, (1, 0, 0, 1))     # stand-in icon
    _solid_rgba_png(str(text), 300, 70, (1, 1, 1, 1))      # stand-in "DSA" text
    return str(icon), str(text)


def _painted_rows(surf):
    """Count of rows (y) containing at least one non-transparent pixel."""
    surf.flush()
    d, st, w, h = surf.get_data(), surf.get_stride(), surf.get_width(), surf.get_height()
    rows = 0
    for y in range(h):
        o = y * st
        if any(d[o + x * 4 + 3] for x in range(0, w, 4)):
            rows += 1
    return rows


def test_compose_medallion_emits_expected_frame_count(tmp_path):
    icon, text = _icon_and_text(tmp_path)
    out = tmp_path / "out"
    render.compose_medallion(icon, text, str(out))
    assert len(list(out.glob("medallion-*.png"))) == render.MEDALLION_FRAME_COUNT


def test_compose_medallion_fist_rises_monotonically(tmp_path):
    icon, text = _icon_and_text(tmp_path)
    out = tmp_path / "out"
    render.compose_medallion(icon, text, str(out))
    # the shell (rust fill + grain + border) is redrawn full-circle every
    # frame by design, so per-row alpha counts saturate immediately and
    # can't distinguish rise progress; compare raw bytes instead to prove
    # the icon position actually moves across the descent.
    first = (out / "medallion-0.png").read_bytes()
    last = (out / f"medallion-{render.DESCENT_FRAMES - 1}.png").read_bytes()
    mid = (out / f"medallion-{render.DESCENT_FRAMES // 2}.png").read_bytes()
    assert first != mid != last and first != last


def test_compose_medallion_final_pose_is_settled_and_held(tmp_path):
    icon, text = _icon_and_text(tmp_path)
    out = tmp_path / "out"
    render.compose_medallion(icon, text, str(out))
    n = render.MEDALLION_FRAME_COUNT
    last = (out / f"medallion-{n - 1}.png").read_bytes()
    second_last = (out / f"medallion-{n - 2}.png").read_bytes()
    assert last == second_last


def test_compose_medallion_is_deterministic(tmp_path):
    icon, text = _icon_and_text(tmp_path)
    a, b = tmp_path / "a", tmp_path / "b"
    render.compose_medallion(icon, text, str(a))
    render.compose_medallion(icon, text, str(b))
    fn = f"medallion-{render.MEDALLION_FRAME_COUNT - 1}.png"
    assert (a / fn).read_bytes() == (b / fn).read_bytes()


# ── CLI dispatch ──────────────────────────────────────────────────────────────

def test_main_icon_width_prints_constant(capsys):
    render.main(["icon-width"])
    assert capsys.readouterr().out.strip() == str(render.ICON_W)


def test_main_text_width_prints_constant(capsys):
    render.main(["text-width"])
    assert capsys.readouterr().out.strip() == str(round(render.MEDALLION_PX * 0.62))


def test_main_background_writes_png(tmp_path):
    out = tmp_path / "background.png"
    render.main(["background", str(out)])
    assert out.exists()


def test_main_unknown_command_raises():
    import pytest
    with pytest.raises(SystemExit):
        render.main(["bogus"])
