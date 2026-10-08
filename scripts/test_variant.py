#!/usr/bin/env python3
"""Tests for theme_lib.variant. Run: python3 scripts/test_variant.py"""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from theme_lib.colormath import _hex_to_hsl
from theme_lib import variant


def _hue_close(a, b, tol=0.012):
    d = abs(a - b) % 1.0
    return min(d, 1.0 - d) <= tol


class ReadSeeds(unittest.TestCase):
    def test_reads_the_five_seed_exports(self):
        with tempfile.TemporaryDirectory() as d:
            sh = Path(d) / "palette-x.sh"
            sh.write_text(
                '#!/usr/bin/env bash\nexport HALL="#000000"\n'
                'export SEED_HALL="#ff6d1f"\nexport SEED_TONIC="#6f42ff"\n'
                'export SEED_MEDIANT="#ff0586"\nexport SEED_DOMINANT="#24ff8c"\n'
                'export SEED_SUBDOMINANT="#ffb219"\n'
            )
            self.assertEqual(variant.read_seeds(sh), {
                "HALL": "#ff6d1f", "TONIC": "#6f42ff", "MEDIANT": "#ff0586",
                "DOMINANT": "#24ff8c", "SUBDOMINANT": "#ffb219"})

    def test_missing_seed_names_it(self):
        with tempfile.TemporaryDirectory() as d:
            sh = Path(d) / "palette-x.sh"
            sh.write_text('export SEED_HALL="#ff6d1f"\n')
            with self.assertRaisesRegex(ValueError, "SEED_TONIC"):
                variant.read_seeds(sh)


class PaletteSeeds(unittest.TestCase):
    def test_falls_back_to_the_final_accents(self):
        with tempfile.TemporaryDirectory() as d:
            sh = Path(d) / "palette-x.sh"
            sh.write_text('export HALL="#101010"\nexport ROOT="#d8451e"\nexport FIFTH="#8c8c3a"\n'
                          'export SOTTO="#d9a23c"\nexport SEVENTH="#9a6b86"\nexport SCORE="#eeeeee"\n')
            self.assertEqual(variant.palette_seeds(sh), {
                "HALL": "#101010", "TONIC": "#d8451e", "MEDIANT": "#8c8c3a",
                "DOMINANT": "#d9a23c", "SUBDOMINANT": "#9a6b86"})

    def test_missing_export_is_named(self):
        with tempfile.TemporaryDirectory() as d:
            sh = Path(d) / "palette-x.sh"
            sh.write_text('export HALL="#101010"\n')
            with self.assertRaisesRegex(ValueError, "ROOT"):
                variant.palette_seeds(sh)


class DarkSeeds(unittest.TestCase):
    SEEDS = {"HALL": "#ff6d1f", "TONIC": "#6f42ff", "MEDIANT": "#ff0586",
             "DOMINANT": "#24ff8c", "SUBDOMINANT": "#ffb219"}

    def test_ground_goes_dark_and_keeps_its_hue(self):
        out = variant.dark_seeds(self.SEEDS)
        h0, _, _ = _hex_to_hsl(self.SEEDS["HALL"])
        h, s, l = _hex_to_hsl(out["HALL"])
        self.assertAlmostEqual(l, 0.09, delta=0.01)
        self.assertLessEqual(s, 0.30 + 0.02)
        self.assertTrue(_hue_close(h, h0))

    def test_neon_accent_saturation_is_capped_hue_and_lightness_kept(self):
        out = variant.dark_seeds(self.SEEDS)
        h0, _, l0 = _hex_to_hsl(self.SEEDS["DOMINANT"])
        h, s, l = _hex_to_hsl(out["DOMINANT"])
        self.assertLessEqual(s, 0.70 + 0.02)
        self.assertTrue(_hue_close(h, h0))
        self.assertAlmostEqual(l, l0, delta=0.02)

    def test_already_muted_accent_is_unchanged(self):
        seeds = dict(self.SEEDS, TONIC="#7d6bb0")  # sat well under the cap
        self.assertEqual(variant.dark_seeds(seeds)["TONIC"], "#7d6bb0")

    def test_knobs_are_honoured(self):
        out = variant.dark_seeds(self.SEEDS, ground_l=0.14, ground_sat=0.10, accent_sat_max=0.50)
        _, gs, gl = _hex_to_hsl(out["HALL"])
        self.assertAlmostEqual(gl, 0.14, delta=0.01)
        self.assertLessEqual(gs, 0.10 + 0.02)
        self.assertLessEqual(_hex_to_hsl(out["MEDIANT"])[1], 0.50 + 0.02)


class LightSeeds(unittest.TestCase):
    DARK = {"HALL": "#1d1415", "TONIC": "#d8451e", "MEDIANT": "#8c8c3a",
            "DOMINANT": "#d9a23c", "SUBDOMINANT": "#9a6b86"}

    def test_ground_goes_light_and_keeps_its_hue(self):
        out = variant.light_seeds(self.DARK)
        h0, _, _ = _hex_to_hsl(self.DARK["HALL"])
        h, s, l = _hex_to_hsl(out["HALL"])
        self.assertAlmostEqual(l, 0.94, delta=0.01)
        self.assertLessEqual(s, 0.30 + 0.02)
        self.assertTrue(_hue_close(h, h0))

    def test_accent_saturation_is_capped_hue_kept(self):
        seeds = dict(self.DARK, TONIC="#ff0586")
        out = variant.light_seeds(seeds)
        h0, _, _ = _hex_to_hsl(seeds["TONIC"])
        h, s, _ = _hex_to_hsl(out["TONIC"])
        self.assertLessEqual(s, 0.70 + 0.02)
        self.assertTrue(_hue_close(h, h0))

    def test_variant_seeds_dispatches_on_mode(self):
        self.assertEqual(variant.variant_seeds(self.DARK, "light"), variant.light_seeds(self.DARK))
        self.assertEqual(variant.variant_seeds(self.DARK, "dark"), variant.dark_seeds(self.DARK))
        with self.assertRaises(ValueError):
            variant.variant_seeds(self.DARK, "dim")


class WriteNixIsLight(unittest.TestCase):
    def _palette(self, hall):
        from theme_lib.palette import derive_full_palette
        from theme_lib.musical import to_musical
        seeds = {"HALL": hall, "TONIC": "#d8451e", "MEDIANT": "#6a7a2a",
                 "DOMINANT": "#c28a1c", "SUBDOMINANT": "#8a5a78"}
        return to_musical(derive_full_palette(seeds, harmonize=False))

    def _written(self, hall):
        from theme_lib.palette_files import write_nix
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "palette-x.nix"
            write_nix(out, self._palette(hall), "x")
            return out.read_text()

    def test_light_ground_marks_the_palette_light(self):
        self.assertIn("isLight = true;", self._written("#f1ece4"))

    def test_dark_ground_writes_no_isLight(self):
        self.assertNotIn("isLight", self._written("#1d1415"))


class SetPair(unittest.TestCase):
    NIX = '{\n  TEMPO   = "12px";\n  MEASURE = "x";\n}\n'

    def _theme(self, root, family, slug, extra=""):
        d = root / family / slug
        d.mkdir(parents=True)
        (d / f"palette-{slug}.nix").write_text(self.NIX.replace('TEMPO   = "12px";\n', 'TEMPO   = "12px";\n' + extra))
        return d

    def test_inserts_after_tempo_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as t:
            d = self._theme(Path(t), "Dark", "a")
            self.assertTrue(variant.set_pair(d, "a-light"))
            txt = (d / "palette-a.nix").read_text()
            self.assertIn('TEMPO   = "12px";\n  PAIR    = "a-light";\n', txt)
            self.assertFalse(variant.set_pair(d, "a-light"))
            self.assertEqual(txt, (d / "palette-a.nix").read_text())

    def test_replaces_an_existing_pair(self):
        with tempfile.TemporaryDirectory() as t:
            d = self._theme(Path(t), "Dark", "a", extra='  PAIR    = "old";\n')
            self.assertTrue(variant.set_pair(d, "new"))
            txt = (d / "palette-a.nix").read_text()
            self.assertIn('PAIR    = "new";', txt)
            self.assertNotIn("old", txt)

    def test_find_pairs_matches_suffixed_variants_in_both_families(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            self._theme(root, "Dark", "a"); self._theme(root, "Light", "a-light")
            self._theme(root, "Light", "c"); self._theme(root, "Dark", "c-dark")
            self._theme(root, "Dark", "lonely")
            pairs = {(x.name, y.name) for x, y in variant.find_pairs(root)}
            self.assertEqual(pairs, {("a", "a-light"), ("c-dark", "c")})


class ApplyOverrides(unittest.TestCase):
    SEEDS = DarkSeeds.SEEDS

    def test_replaces_only_the_named_seed(self):
        out = variant.apply_overrides(self.SEEDS, ["DOMINANT=#C9806A"])
        self.assertEqual(out["DOMINANT"], "#c9806a")
        self.assertEqual(out["TONIC"], self.SEEDS["TONIC"])

    def test_derived_slots_only_when_allowed(self):
        out = variant.apply_overrides({"SUPERTONIC": "#000000"}, ["SUPERTONIC=#B4B98A"],
                                      allowed=variant.DERIVED_ACCENTS)
        self.assertEqual(out["SUPERTONIC"], "#b4b98a")
        with self.assertRaises(ValueError):
            variant.apply_overrides(self.SEEDS, ["SUPERTONIC=#b4b98a"])

    def test_rejects_unknown_key_and_bad_hex(self):
        for bad in ("NOPE=#112233", "TONIC=112233", "TONIC=#12"):
            with self.assertRaises(ValueError):
                variant.apply_overrides(self.SEEDS, [bad])


class Harmonize(unittest.TestCase):
    SEEDS = {"HALL": "#1d1415", "TONIC": "#d8451e", "MEDIANT": "#8c8c3a",
             "DOMINANT": "#d9a23c", "SUBDOMINANT": "#9a6b86"}

    def test_off_keeps_seed_hues(self):
        from theme_lib.palette import derive_full_palette
        out = derive_full_palette(dict(self.SEEDS), harmonize=False)
        for key in ("TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT"):
            self.assertTrue(_hue_close(_hex_to_hsl(out[key])[0], _hex_to_hsl(self.SEEDS[key])[0], 0.02), key)

    def test_default_is_unchanged(self):
        from theme_lib.palette import derive_full_palette
        self.assertEqual(derive_full_palette(dict(self.SEEDS)),
                         derive_full_palette(dict(self.SEEDS), harmonize=True))


class CheckPalette(unittest.TestCase):
    CLEAN = {"HALL": "#14100c", "SCORE": "#f2e8dc", "TONIC": "#e08a3c",
             "MEDIANT": "#7ab6e0", "DOMINANT": "#8fd48f", "SUBDOMINANT": "#d46a9a",
             "SUPERTONIC": "#b79be0", "SUBMEDIANT": "#e0c24a"}

    def test_clean_palette_reports_nothing(self):
        self.assertEqual(variant.check_palette(self.CLEAN), [])

    def test_low_contrast_accent_is_named(self):
        p = dict(self.CLEAN, DOMINANT="#1d1812")
        msgs = variant.check_palette(p)
        self.assertTrue(any("DOMINANT" in m and "contrast" in m for m in msgs), msgs)

    def test_indistinct_accent_pair_is_named(self):
        p = dict(self.CLEAN, MEDIANT="#e08c3e")  # near-identical to TONIC
        msgs = variant.check_palette(p)
        self.assertTrue(any("TONIC" in m and "MEDIANT" in m and "ΔE" in m for m in msgs), msgs)

    def test_weak_ink_is_named(self):
        msgs = variant.check_palette(dict(self.CLEAN, SCORE="#4a4036"))
        self.assertTrue(any("SCORE" in m for m in msgs), msgs)


class Swatch(unittest.TestCase):
    def test_one_truecolor_block_per_slot(self):
        s = variant.swatch(CheckPalette.CLEAN | {"STAGE": "#1d1812", "WING": "#2b231b"})
        self.assertEqual(s.count("\033[48;2;"), 10)
        self.assertNotIn("\n", s)


if __name__ == "__main__":
    unittest.main()
