import importlib.util
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "make-splotch-bg.py"
_spec = importlib.util.spec_from_file_location("make_splotch_bg", _SCRIPT)
splotch = importlib.util.module_from_spec(_spec)
sys.modules["make_splotch_bg"] = splotch
_spec.loader.exec_module(splotch)

_HAS_RESVG = shutil.which("resvg") is not None


def _make_theme_dir(tmp, slug, mute="#112233", dim="#445566"):
    theme_dir = Path(tmp) / slug
    theme_dir.mkdir()
    (theme_dir / f"palette-{slug}.sh").write_text(
        f'export MUTE="{mute}"\n'
        f'export DIM="{dim}"\n'
    )
    return theme_dir


class TestLoadColors(unittest.TestCase):
    def test_reads_palette_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            theme_dir = _make_theme_dir(tmp, "test-theme")
            colors = splotch.load_colors(theme_dir)
        self.assertEqual(colors["MUTE"], "#112233")
        self.assertEqual(colors["DIM"], "#445566")

    def test_falls_back_when_no_palette_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            theme_dir = Path(tmp) / "empty-theme"
            theme_dir.mkdir()
            colors = splotch.load_colors(theme_dir)
        self.assertIn("MUTE", colors)
        self.assertIn("DIM", colors)


class TestIsHued(unittest.TestCase):
    def test_rejects_black_white_grey(self):
        for c in ("#000000", "#ffffff", "#8c8c8c", "#bfbfbf"):
            self.assertFalse(splotch.is_hued(c), c)

    def test_rejects_low_saturation_near_neutral(self):
        # onyx-mauve's ROOT: real color, but only ~10% saturation
        self.assertFalse(splotch.is_hued("#8a7070"))

    def test_accepts_saturated_midtone(self):
        # wu-tang's ROOT: clearly gold
        self.assertTrue(splotch.is_hued("#f0c02d"))

    def test_rejects_low_contrast_against_flat_bg(self):
        # navy-teal's HALL: 33.3% saturation clears HUED_MIN_SAT, but at
        # 17.1% lightness it's only contrast 1.01 against FLAT_BG (#242424,
        # itself 14% lightness) — reads as black against the background
        # even though it isn't literally #000000.
        self.assertFalse(splotch.is_hued("#1d243a"))


class TestPickBlobColors(unittest.TestCase):
    def test_logo_blob_is_hued_when_logo_has_a_hued_color(self):
        colors = dict(splotch.DEFAULT_COLORS)
        colors["ROOT"] = "#f0c02d"
        colors["FORTE"] = "#f0c02d"
        picks = splotch.pick_blob_colors(colors)
        self.assertEqual(len(picks), 2)
        self.assertEqual(picks[0], "#f0c02d")
        self.assertTrue(splotch.is_hued(picks[0]))

    def test_palette_blob_excludes_the_chosen_logo_color(self):
        colors = dict(splotch.DEFAULT_COLORS)
        colors["ROOT"] = "#f0c02d"
        colors["FORTE"] = "#f0c02d"
        picks = splotch.pick_blob_colors(colors)
        self.assertNotEqual(picks[0], picks[1])

    def test_palette_blob_is_perceptually_distinct_from_logo_not_just_hex_unequal(self):
        colors = dict(splotch.DEFAULT_COLORS)
        colors["ROOT"] = "#f0c02d"
        colors["FORTE"] = "#f0c02d"
        colors["LEDGER"] = "#f2c230"  # hex-different but near-identical to ROOT
        picks = splotch.pick_blob_colors(colors)
        self.assertNotEqual(picks, ["#f0c02d", "#f2c230"])
        self.assertGreaterEqual(splotch._delta_e(picks[0], picks[1]), splotch.MIN_DELTA_E)

    def test_both_blobs_hued_even_for_all_neutral_default_colors(self):
        # DEFAULT_COLORS has zero vars above the hue threshold — every
        # pick must go through synthesize_hued, and both results must
        # still clear is_hued.
        colors = dict(splotch.DEFAULT_COLORS)
        picks = splotch.pick_blob_colors(colors)
        self.assertEqual(picks, ["#bb3f3f", "#d47d7d"])
        for c in picks:
            self.assertTrue(splotch.is_hued(c), c)

    def test_synthesis_is_deterministic(self):
        colors = dict(splotch.DEFAULT_COLORS)
        first = splotch.pick_blob_colors(colors)
        second = splotch.pick_blob_colors(colors)
        self.assertEqual(first, second)

    def test_widens_to_full_palette_when_logo_vars_all_neutral(self):
        # All LOGO_VARS are pure grays (saturation == 0); synthesize_hued
        # should widen search to the full palette and pick the highest
        # saturation color available (which is in BLOB_CANDIDATE_VARS).
        colors = dict(splotch.DEFAULT_COLORS)
        # Set all LOGO_VARS to different gray levels (zero saturation)
        for v in splotch.LOGO_VARS:
            colors[v] = "#444444"
        picks = splotch.pick_blob_colors(colors)
        self.assertEqual(len(picks), 2)
        for c in picks:
            self.assertTrue(splotch.is_hued(c), c)


class TestPlanBlobs(unittest.TestCase):
    def test_deterministic_for_same_theme(self):
        with tempfile.TemporaryDirectory() as tmp:
            theme_dir = _make_theme_dir(tmp, "repeatable")
            first = splotch.plan_blobs(theme_dir)
            second = splotch.plan_blobs(theme_dir)
        self.assertEqual(first, second)

    def test_two_distinct_hued_colors(self):
        with tempfile.TemporaryDirectory() as tmp:
            theme_dir = _make_theme_dir(tmp, "colorcheck")
            _, blobs = splotch.plan_blobs(theme_dir)
        colors_used = {b[0] for b in blobs}
        self.assertEqual(len(colors_used), 2)
        for c in colors_used:
            self.assertTrue(splotch.is_hued(c), c)

    def test_blobs_are_diametrically_opposed_through_center(self):
        cx, cy = splotch.CENTER
        for slug in ("alpha", "beta", "gamma", "delta", "epsilon"):
            with tempfile.TemporaryDirectory() as tmp:
                theme_dir = _make_theme_dir(tmp, slug)
                _, blobs = splotch.plan_blobs(theme_dir)
            self.assertEqual(len(blobs), 2)
            (_, ax, ay, _, _), (_, bx, by, _, _) = blobs
            va = (ax - cx, ay - cy)
            vb = (bx - cx, by - cy)
            # opposite sides: dot product of the two centre-vectors <= 0
            self.assertLessEqual(va[0] * vb[0] + va[1] * vb[1], 1e-6, slug)
            # colinear with centre: cross product ~ 0
            self.assertAlmostEqual(va[0] * vb[1] - va[1] * vb[0], 0.0, places=3, msg=slug)

    def test_blob_centers_within_distance_bound(self):
        cx, cy = splotch.CENTER
        with tempfile.TemporaryDirectory() as tmp:
            theme_dir = _make_theme_dir(tmp, "boundcheck")
            _, blobs = splotch.plan_blobs(theme_dir)
        for _, x, y, _, _ in blobs:
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            self.assertLessEqual(d, splotch.D_MAX + 1e-6)


class TestBuild(unittest.TestCase):
    def test_includes_flat_neutral_fill(self):
        with tempfile.TemporaryDirectory() as tmp:
            theme_dir = _make_theme_dir(tmp, "flatbgcheck")
            svg = splotch.build(theme_dir)
        self.assertIn(f'fill="{splotch.FLAT_BG}"', svg)
        self.assertNotIn("radialGradient", svg)

    def test_flat_fill_is_hue_free(self):
        r, g, b = (int(splotch.FLAT_BG.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
        self.assertEqual(r, g)
        self.assertEqual(g, b)

    def test_includes_blob_fill_colors(self):
        with tempfile.TemporaryDirectory() as tmp:
            theme_dir = _make_theme_dir(tmp, "fillcheck")
            colors, blobs = splotch.plan_blobs(theme_dir)
            svg = splotch.build(theme_dir)
        for color, *_rest in blobs:
            self.assertIn(f'fill="{color}"', svg)

    def test_valid_svg_root_and_viewbox(self):
        with tempfile.TemporaryDirectory() as tmp:
            theme_dir = _make_theme_dir(tmp, "svgcheck")
            svg = splotch.build(theme_dir)
        self.assertIn('viewBox="0 0 1920 1080"', svg)
        self.assertTrue(svg.strip().endswith("</svg>"))

    def test_has_linen_texture_patterns(self):
        with tempfile.TemporaryDirectory() as tmp:
            theme_dir = _make_theme_dir(tmp, "lincheck")
            svg = splotch.build(theme_dir)
        self.assertIn('<pattern id="lin-h"', svg)
        self.assertIn('<pattern id="lin-d"', svg)
        self.assertIn('fill="url(#lin-h)"', svg)
        self.assertIn('fill="url(#lin-d)"', svg)

    def test_no_turbulence_grain(self):
        with tempfile.TemporaryDirectory() as tmp:
            theme_dir = _make_theme_dir(tmp, "noturb")
            svg = splotch.build(theme_dir)
        self.assertNotIn("feTurbulence", svg)


class TestIterThemeDirs(unittest.TestCase):
    def _make_root(self, tmp):
        root = Path(tmp) / "themes"
        root.mkdir()
        fam = root / "Family"
        fam.mkdir()
        _make_theme_dir(fam, "theme-a")
        _make_theme_dir(fam, "free-palestine")
        no_palette = fam / "no-palette-dir"
        no_palette.mkdir()
        return root

    def test_includes_free_palestine(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self._make_root(tmp)
            names = {d.name for d in splotch.iter_theme_dirs(root)}
        self.assertIn("theme-a", names)
        self.assertIn("free-palestine", names)

    def test_skips_dirs_without_palette(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self._make_root(tmp)
            names = {d.name for d in splotch.iter_theme_dirs(root)}
        self.assertNotIn("no-palette-dir", names)


class TestGenerateAll(unittest.TestCase):
    def _root(self, tmp):
        root = Path(tmp) / "themes"; root.mkdir()
        fam = root / "Family"; fam.mkdir()
        _make_theme_dir(fam, "theme-a")
        _make_theme_dir(fam, "free-palestine")
        return root, fam

    @unittest.skipUnless(_HAS_RESVG, "resvg not on PATH")
    def test_writes_svg_and_png_for_every_theme(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, fam = self._root(tmp)
            written = splotch.generate_all(root)
            for slug in ("theme-a", "free-palestine"):
                self.assertTrue((fam / slug / "wallpaper-background.svg").exists(), slug)
                self.assertTrue((fam / slug / f"wallpaper-{slug}.png").exists(), slug)
            self.assertEqual({p.name for p in written},
                             {"wallpaper-theme-a.png", "wallpaper-free-palestine.png"})

    @unittest.skipUnless(_HAS_RESVG, "resvg not on PATH")
    def test_svg_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, fam = self._root(tmp)
            splotch.generate_all(root)
            first = (fam / "theme-a" / "wallpaper-background.svg").read_text()
            splotch.generate_all(root)
            second = (fam / "theme-a" / "wallpaper-background.svg").read_text()
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
