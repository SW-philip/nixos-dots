import importlib.util
import os
import pathlib

import cairo

HERE = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("render", HERE / "render.py")
render = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(render)

LOGO = (HERE / "nixos-logo.svg").read_text()


# ── snowflake carving ─────────────────────────────────────────────────────────

def test_extract_snowflake_drops_wordmark_keeps_lambdas():
    flake = render.extract_snowflake(LOGO)
    assert flake.count("<polygon") == 6          # the six gradient lambdas
    assert "<path" not in flake                  # wordmark glyphs gone
    assert "linearGradient" in flake             # gradients survive
    assert flake.strip().endswith("</svg>")


# ── the machine ──────────────────────────────────────────────────────────────

def _alpha(surf, x, y):
    surf.flush()
    return surf.get_data()[y * surf.get_stride() + x * 4 + 3]


def _rgba(surf, x, y):
    surf.flush()
    d = surf.get_data()
    o = y * surf.get_stride() + x * 4
    return d[o + 2], d[o + 1], d[o], d[o + 3]     # cairo is BGRA


def _painted(surf):
    surf.flush()
    d = surf.get_data()
    return sum(1 for i in range(3, len(d), 4) if d[i] != 0)


def _painted_below(surf, y0):
    surf.flush()
    d, st, w, h = surf.get_data(), surf.get_stride(), surf.get_width(), surf.get_height()
    return sum(1 for y in range(y0, h) for x in range(w) if d[y * st + x * 4 + 3])


def _flake_stub():
    s = cairo.ImageSurface(cairo.FORMAT_ARGB32, 60, 60)
    cr = cairo.Context(s)
    cr.set_source_rgba(0.3, 0.5, 0.8, 1.0)
    cr.arc(30, 30, 28, 0, 6.3)
    cr.fill()
    s.flush()
    return s


def test_machine_body_is_steel():
    w, h = 720, 360
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    render.draw_machine(cairo.Context(surf), w, _flake_stub())
    r, g, b, a = _rgba(surf, 200, 150)            # left body face, clear of badge/lever
    assert a > 0
    assert max(r, g, b) - min(r, g, b) < 40 and g > 120   # desaturated, light


def test_machine_lever_is_nix_blue():
    w, h = 720, 360
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    render.draw_machine(cairo.Context(surf), w, _flake_stub())
    lx = int(render.M_BX * w + render.M_BW * w * render.LEV_XF + render.LEV_WF * w / 2)
    ly = int(render.M_BY + render.M_BH * render.LEV_YF + 90)   # below the light cap
    r, g, b, a = _rgba(surf, lx, ly)
    assert a > 0 and b > r + 40 and b > g          # clearly blue


def test_machine_lever_pulls_down():
    w, h = 720, 360
    base = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    render.draw_machine(cairo.Context(base), w, _flake_stub(), 0)
    pulled = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    render.draw_machine(cairo.Context(pulled), w, _flake_stub(), render.LEVER_PULL)
    lx = int(render.M_BX * w + render.M_BW * w * render.LEV_XF + render.LEV_WF * w / 2)
    # just below the lever's resting bottom: blue only once it has pulled down
    y = int(render.M_BY + render.M_BH * render.LEV_YF + render.LEV_H + render.LEVER_PULL // 2)

    def blue(px):
        r, g, b, a = px
        return a > 0 and b > r + 40 and b > g

    assert not blue(_rgba(base, lx, y))
    assert blue(_rgba(pulled, lx, y))


# ── compositing ──────────────────────────────────────────────────────────────

def _solid(path, w, h, box, rgb):
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    cr = cairo.Context(surf)
    cr.set_source_rgba(*rgb, 1.0)
    cr.rectangle(*box)
    cr.fill()
    surf.flush()
    surf.write_to_png(path)


def _layers(tmp_path):
    w, h = 720, 400
    logo, flake = tmp_path / "logo.png", tmp_path / "flake.png"
    _solid(str(logo), w, h, (200, 80, 320, 280), (0.8, 0.0, 0.4))    # cone+swirl artwork
    _solid(str(flake), 80, 80, (10, 10, 60, 60), (0.3, 0.5, 0.8))    # badge mark
    return str(logo), str(flake)


def test_compose_emits_expected_frame_count(tmp_path):
    logo, flake = _layers(tmp_path)
    out = tmp_path / "out"
    render.compose(logo, flake, str(out))
    assert len(os.listdir(out)) == render.FRAME_COUNT


def test_compose_first_frame_is_machine_only(tmp_path):
    logo, flake = _layers(tmp_path)
    out = tmp_path / "out"
    render.compose(logo, flake, str(out))
    f0 = cairo.ImageSurface.create_from_png(str(out / "frame-0.png"))
    assert _alpha(f0, 360, 110) > 0      # machine from the start
    assert _alpha(f0, 360, 450) == 0     # nothing of the logo revealed yet


def test_compose_logo_fully_revealed_in_last_frame(tmp_path):
    logo, flake = _layers(tmp_path)
    out = tmp_path / "out"
    render.compose(logo, flake, str(out))
    fl = cairo.ImageSurface.create_from_png(
        str(out / f"frame-{render.FRAME_COUNT - 1}.png"))
    assert _alpha(fl, 360, 450) > 0      # logo filled in by the end


def test_compose_reveal_is_monotonic_during_descent(tmp_path):
    logo, flake = _layers(tmp_path)
    out = tmp_path / "out"
    render.compose(logo, flake, str(out))
    counts = [
        _painted_below(
            cairo.ImageSurface.create_from_png(str(out / f"frame-{i}.png")), 400)
        for i in range(render.DESCENT_FRAMES)
    ]
    assert all(counts[i] <= counts[i + 1] for i in range(len(counts) - 1))
    assert counts[0] < counts[-1]


def test_compose_lever_pulls_down_during_pour(tmp_path):
    logo, flake = _layers(tmp_path)
    out = tmp_path / "out"
    render.compose(logo, flake, str(out))
    w = 720
    lx = int(render.M_BX * w + render.M_BW * w * render.LEV_XF + render.LEV_WF * w / 2)
    y = int(render.M_BY + render.M_BH * render.LEV_YF + render.LEV_H + render.LEVER_PULL // 2)
    mid = cairo.ImageSurface.create_from_png(
        str(out / f"frame-{render.DESCENT_FRAMES // 2}.png"))
    last = cairo.ImageSurface.create_from_png(
        str(out / f"frame-{render.FRAME_COUNT - 1}.png"))

    def blue(px):
        r, g, b, a = px
        return a > 0 and b > r + 40 and b > g

    assert blue(_rgba(mid, lx, y))
    assert not blue(_rgba(last, lx, y))


def test_compose_final_pose_is_settled_and_held(tmp_path):
    logo, flake = _layers(tmp_path)
    out = tmp_path / "out"
    render.compose(logo, flake, str(out))
    n = render.FRAME_COUNT
    assert (out / f"frame-{n - 1}.png").read_bytes() == (out / f"frame-{n - 2}.png").read_bytes()


def test_compose_corner_is_transparent(tmp_path):
    logo, flake = _layers(tmp_path)
    out = tmp_path / "out"
    render.compose(logo, flake, str(out))
    f0 = cairo.ImageSurface.create_from_png(str(out / "frame-0.png"))
    assert _alpha(f0, 0, 0) == 0


def test_compose_is_deterministic(tmp_path):
    logo, flake = _layers(tmp_path)
    a, b = tmp_path / "a", tmp_path / "b"
    render.compose(logo, flake, str(a))
    render.compose(logo, flake, str(b))
    fn = f"frame-{render.FRAME_COUNT - 1}.png"
    assert (a / fn).read_bytes() == (b / fn).read_bytes()


# ── animation timing ─────────────────────────────────────────────────────────

def test_ease_in_out_endpoints_and_midpoint():
    assert render._ease_in_out(0.0) == 0.0
    assert abs(render._ease_in_out(1.0) - 1.0) < 1e-9
    assert abs(render._ease_in_out(0.5) - 0.5) < 1e-9
    vals = [render._ease_in_out(i / 10) for i in range(11)]
    assert all(vals[i] <= vals[i + 1] for i in range(10))


def test_frame_count_is_sum_of_phases():
    assert render.FRAME_COUNT == (
        render.DESCENT_FRAMES + render.SETTLE_FRAMES + render.HOLD_FRAMES
    )
    assert render.DESCENT_FRAMES >= 2 and render.SETTLE_FRAMES >= 2
    assert render.HOLD_FRAMES >= 2
