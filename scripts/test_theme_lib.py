import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import MagicMock
import sys

# auto-theme.py imports `theme_lib`; when loaded outside `uv run scripts/auto-theme.py`
# (which puts scripts/ on sys.path[0]), the test must add scripts/ itself.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.modules.setdefault("requests", MagicMock())

from theme_lib.palette import derive_full_palette
from theme_lib.musical import to_musical

_spec = importlib.util.spec_from_file_location("auto_theme", "scripts/auto-theme.py")
auto_theme = importlib.util.module_from_spec(_spec)
sys.modules["auto_theme"] = auto_theme
_spec.loader.exec_module(auto_theme)


class TestColorhuntPort(unittest.TestCase):
    URL = "colorhunt.co/palette/222831393e4600adb5eeeeee"

    def test_parse_url_extracts_four_hex(self):
        self.assertEqual(
            auto_theme.parse_colorhunt_url(self.URL),
            ["#222831", "#393e46", "#00adb5", "#eeeeee"],
        )

    def test_parse_url_rejects_bad_slug(self):
        with self.assertRaises(ValueError):
            auto_theme.parse_colorhunt_url("colorhunt.co/palette/nothex")

    def test_map_fills_five_required_slots(self):
        m = auto_theme.map_colorhunt_to_slots(
            ["#222831", "#393e46", "#00adb5", "#eeeeee"]
        )
        for k in ("HALL", "TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT"):
            self.assertIn(k, m)
            self.assertRegex(m[k], r"^#[0-9a-f]{6}$")
        # darkest is the background
        self.assertEqual(m["HALL"], "#222831")

    def test_map_output_feeds_derive(self):
        m = auto_theme.map_colorhunt_to_slots(["#222831", "#393e46", "#00adb5", "#eeeeee"])
        full = auto_theme.derive_full_palette(m)
        self.assertIn("SUPERTONIC", full)
        self.assertIn("SUBMEDIANT", full)


class TestThemeExists(unittest.TestCase):
    def test_known_theme_exists(self):
        self.assertTrue(auto_theme.theme_exists("onyx-mauve"))

    def test_unknown_theme_absent(self):
        self.assertFalse(auto_theme.theme_exists("definitely-not-a-theme-xyz"))


class TestAccentRanking(unittest.TestCase):
    DUNES = dict(TONIC="#f6b83c", MEDIANT="#d5a66d", DOMINANT="#ffeddb",
                 SUBDOMINANT="#c8723c", SUPERTONIC="#cea736", SUBMEDIANT="#ffffff")

    def test_vividness_orders_vivid_above_grey(self):
        from theme_lib.musical import vividness
        self.assertGreater(vividness("#f6b83c"), vividness("#ffffff"))  # gold > white
        self.assertGreater(vividness("#ca2541"), vividness("#f0a3c0"))  # vivid red > pale pink

    def test_rank_accents_dunes_top_is_love(self):
        from theme_lib.musical import rank_accents
        ranked = rank_accents(self.DUNES)
        self.assertEqual(ranked[0], "#f6b83c")   # ROOT  = TONIC
        self.assertEqual(ranked[3], "#d5a66d")   # SOTTO = MEDIANT
        self.assertEqual(len(ranked), 6)


class TestColorMath(unittest.TestCase):
    def test_lab_landmarks(self):
        from theme_lib.colormath import srgb_to_lab, delta_e_cie76
        L, a, b = srgb_to_lab("#000000")
        self.assertAlmostEqual(L, 0.0, places=1)
        L, a, b = srgb_to_lab("#ffffff")
        self.assertAlmostEqual(L, 100.0, places=1)
        self.assertAlmostEqual(a, 0.0, delta=0.5)
        self.assertAlmostEqual(b, 0.0, delta=0.5)
        # mid grey sits near L*≈53.6 (well-known sRGB #808080 value)
        L, _, _ = srgb_to_lab("#808080")
        self.assertAlmostEqual(L, 53.6, delta=1.0)

    def test_delta_e_cie76(self):
        from theme_lib.colormath import delta_e_cie76
        self.assertEqual(delta_e_cie76("#123456", "#123456"), 0.0)
        self.assertAlmostEqual(delta_e_cie76("#000000", "#ffffff"), 100.0, delta=0.5)
        # accepts bare hex too
        self.assertEqual(delta_e_cie76("112233", "112233"), 0.0)
        # the pair that motivated this work: navy-teal REST vs FIFTH is modest,
        # onyx-mauve REST vs FIFTH is tiny — assert the ordering the review found
        nt = delta_e_cie76("#ac93ad", "#6775b6")   # navy-teal REST, FIFTH
        self.assertGreater(nt, 25)


class TestToMusical(unittest.TestCase):
    def _derived(self):
        from theme_lib.palette import derive_full_palette
        return derive_full_palette(
            {"HALL": "#1a1a1a", "TONIC": "#f6b83c", "MEDIANT": "#d5a66d",
             "DOMINANT": "#ffeddb", "SUBDOMINANT": "#c8723c"})

    def test_exactly_44_keys_all_musical(self):
        from theme_lib.musical import to_musical
        m = to_musical(self._derived())
        self.assertEqual(len(m), 44)
        for rp in ("BASE", "LOVE", "IRIS", "SURFACE", "HIGHLIGHT_MED", "HOVER_BG", "TINT_PINE_DARK"):
            self.assertNotIn(rp, m)
        for new in ("HALL", "STAGE", "ROOT", "FORTE", "TACET", "BAR", "PIT", "CHG_FF", "STAFF"):
            self.assertIn(new, m)

    def test_signals_preserve_derived_values(self):
        from theme_lib.musical import to_musical
        p = self._derived(); m = to_musical(p)
        self.assertEqual(m["FORTE"], p["FORTE"])
        self.assertEqual(m["PIANO"], p["PIANO"])
        self.assertEqual(m["TACET"], m["SEVENTH"])

    def test_root_is_most_vivid_accent(self):
        from theme_lib.musical import to_musical, rank_accents
        p = self._derived(); m = to_musical(p)
        self.assertEqual(m["ROOT"], rank_accents(p)[0])


class TestCategories(unittest.TestCase):
    def test_animals_category_shape(self):
        from theme_lib.categories import CATEGORIES
        self.assertIn("animals", CATEGORIES)
        self.assertEqual(CATEGORIES["animals"]["family"], "Custom")
        kws = CATEGORIES["animals"]["keywords"]
        self.assertIn("octopus", kws)
        self.assertIn("fox", kws)

    def test_run_category_skips_existing_generates_missing(self):
        from theme_lib import categories
        from unittest.mock import patch
        existing = {"octopus", "squid"}
        with patch.object(categories, "theme_exists", lambda s: s in existing), \
             patch.object(categories, "register_theme") as reg:
            gen, skip, fail = categories.run_category(
                "animals", fetch=lambda kw: {"query": kw, "palette": {"BASE": "#111111"}})
        self.assertEqual(set(skip), {"octopus", "squid"})
        self.assertEqual(len(gen), 10)
        self.assertEqual(fail, [])
        self.assertEqual(reg.call_count, 10)

    def test_run_category_force_regenerates_existing(self):
        from theme_lib import categories
        from unittest.mock import patch
        with patch.object(categories, "theme_exists", lambda s: True), \
             patch.object(categories, "register_theme") as reg:
            gen, skip, fail = categories.run_category(
                "animals", force=True, fetch=lambda kw: {"query": kw, "palette": {"x": 1}})
        self.assertEqual(skip, [])
        self.assertEqual(len(gen), 12)
        self.assertEqual(reg.call_count, 12)

    def test_run_category_records_fetch_failures(self):
        from theme_lib import categories
        from unittest.mock import patch
        with patch.object(categories, "theme_exists", lambda s: False), \
             patch.object(categories, "register_theme") as reg:
            gen, skip, fail = categories.run_category("animals", fetch=lambda kw: None)
        self.assertEqual(len(fail), 12)
        self.assertEqual(gen, [])
        reg.assert_not_called()


class TestSeedRoundTrip(unittest.TestCase):
    SEEDS = {"HALL": "#1a1a1a", "TONIC": "#f6b83c", "MEDIANT": "#d5a66d",
             "DOMINANT": "#ffeddb", "SUBDOMINANT": "#c8723c"}

    def test_write_sh_emits_seed_block(self):
        import tempfile
        from pathlib import Path
        from theme_lib.palette import derive_full_palette
        from theme_lib.musical import to_musical
        from theme_lib.palette_files import write_sh
        from theme_lib.registry import _read_sh_palette
        p = derive_full_palette(dict(self.SEEDS))  # derive_full_palette mutates its arg
        with tempfile.TemporaryDirectory() as d:
            sh = Path(d) / "palette-x.sh"
            write_sh(sh, to_musical(p), "x", seeds=dict(self.SEEDS))
            raw = _read_sh_palette(sh)
            for k in ("HALL", "TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT"):
                self.assertEqual(raw[f"SEED_{k}"], self.SEEDS[k])

    def test_seeds_reproduce_palette(self):
        from theme_lib.palette import derive_full_palette
        from theme_lib.musical import to_musical
        a = to_musical(derive_full_palette(dict(self.SEEDS)))
        b = to_musical(derive_full_palette(dict(self.SEEDS)))
        self.assertEqual(a, b)  # deterministic — re-derive is idempotent

    def test_write_sh_without_seeds_has_no_block(self):
        import tempfile
        from pathlib import Path
        from theme_lib.palette import derive_full_palette
        from theme_lib.musical import to_musical
        from theme_lib.palette_files import write_sh
        p = derive_full_palette(dict(self.SEEDS))
        with tempfile.TemporaryDirectory() as d:
            sh = Path(d) / "palette-x.sh"
            write_sh(sh, to_musical(p), "x")
            self.assertNotIn("SEED_HALL", sh.read_text())


class TestGoldenInvariant(unittest.TestCase):
    """The rename must not change any generated palette. Fixed seed hexes ->
    byte-identical 44-key musical output. Update SEED_INPUTS keys alongside the
    rename; never regenerate golden_palettes.json."""

    # Keyed by the seed names CURRENTLY in force. Hexes are frozen.
    SEED_INPUTS = {
        "rose_pine_main": {"HALL": "#191724", "TONIC": "#eb6f92", "MEDIANT": "#ebbcba", "DOMINANT": "#31748f", "SUBDOMINANT": "#9ccfd8"},
        "light_set":      {"HALL": "#faf4ed", "TONIC": "#b4637a", "MEDIANT": "#d7827e", "DOMINANT": "#286983", "SUBDOMINANT": "#56949f"},
        "vivid_set":      {"HALL": "#1a1b26", "TONIC": "#f7768e", "MEDIANT": "#ff9e64", "DOMINANT": "#9ece6a", "SUBDOMINANT": "#7dcfff"},
    }

    def test_musical_output_matches_golden(self):
        golden = json.loads((Path(__file__).resolve().parent / "golden_palettes.json").read_text())
        for name, seeds in self.SEED_INPUTS.items():
            got = to_musical(derive_full_palette(dict(seeds)))
            self.assertEqual(got, golden[name], f"musical output drifted for {name}")


class TestApiCacheResilience(unittest.TestCase):
    """The persisted API cache must survive palette-schema changes. It stores raw
    seed colors and derives on read; entries that predate the rename (a derived
    palette, no raw colors) must NOT be trusted — they crash the renamed
    to_musical path — and are refetched instead."""

    def test_cache_hit_with_colors_rederives_to_current_schema(self):
        from theme_lib import sources
        cache = {"x": {"query": "x", "palette_name": "X", "tags": [],
                       "colors": ["#1a1a1a", "#f6b83c", "#d5a66d", "#ffeddb", "#c8723c"]}}
        res = sources.fetch_api_palette("x", cache)
        self.assertIsNotNone(res)
        self.assertIn("TONIC", res["palette"])
        self.assertEqual(len(to_musical(res["palette"])), 44)  # the regression: no KeyError

    def test_old_schema_entry_without_colors_is_refetched(self):
        from theme_lib import sources
        from unittest.mock import patch, MagicMock
        # Stale pre-rename entry: a derived palette keyed by old RP names, no raw colors.
        cache = {"y": {"palette_name": "Y", "tags": [],
                       "palette": {"BASE": "#1a1a1a", "LOVE": "#f6b83c", "ROSE": "#d5a66d",
                                   "PINE": "#ffeddb", "FOAM": "#c8723c"}}}
        fake = MagicMock()
        fake.json.return_value = [{"text": "Y", "likesCount": 3,
                                   "colors": ["#1a1a1a", "#f6b83c", "#d5a66d", "#ffeddb", "#c8723c"]}]
        with patch.object(sources, "requests") as rq, patch.object(sources, "save_cache"):
            rq.get.return_value = fake
            res = sources.fetch_api_palette("y", cache)
        self.assertIsNotNone(res)
        self.assertIn("TONIC", res["palette"])  # fresh fetch, not the stale entry


class TestHarmonizeAccentsByRank(unittest.TestCase):
    # scarab's real derived accents (pre-harmonization) — all six clustered
    # in a ~30deg warm/green band. This is the actual muddy case from the design doc.
    CLUSTERED = {
        "TONIC": "#7e9e6b", "MEDIANT": "#c2d6c2", "DOMINANT": "#d4b6a1",
        "SUBDOMINANT": "#b4574b", "SUPERTONIC": "#ba7c45", "SUBMEDIANT": "#decdbf",
    }
    KEYS = ("TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT", "SUPERTONIC", "SUBMEDIANT")
    ANCHORS = [0/360, 40/360, 130/360, 185/360, 230/360, 300/360]

    @staticmethod
    def _min_gap(colors, keys):
        from theme_lib.colormath import _hex_to_hsl
        hues = sorted(_hex_to_hsl(colors[k])[0] for k in keys)
        n = len(hues)
        gaps = [min(abs(hues[i] - hues[(i + 1) % n]) % 1.0,
                     1.0 - abs(hues[i] - hues[(i + 1) % n]) % 1.0) * 360
                for i in range(n)]
        return min(gaps)

    def test_clustered_fixture_is_actually_clustered(self):
        # Sanity check on the fixture itself: confirms this reproduces the muddy case.
        self.assertLess(self._min_gap(self.CLUSTERED, self.KEYS), 10)

    def test_harmonize_separates_clustered_accents(self):
        from theme_lib.palette import harmonize_accents_by_rank
        out = harmonize_accents_by_rank(dict(self.CLUSTERED), self.KEYS, self.ANCHORS,
                                         strength=0.6, min_sat=0.35)
        self.assertGreaterEqual(self._min_gap(out, self.KEYS), 20)

    def test_zero_strength_is_identity(self):
        from theme_lib.palette import harmonize_accents_by_rank
        out = harmonize_accents_by_rank(dict(self.CLUSTERED), self.KEYS, self.ANCHORS, strength=0.0)
        self.assertEqual(out, self.CLUSTERED)

    def test_missing_keys_are_ignored(self):
        from theme_lib.palette import harmonize_accents_by_rank
        partial = {"TONIC": "#7e9e6b", "MEDIANT": "#c2d6c2"}
        out = harmonize_accents_by_rank(dict(partial), self.KEYS, self.ANCHORS, strength=0.6, min_sat=0.35)
        self.assertEqual(set(out.keys()), {"TONIC", "MEDIANT"})


class TestDeriveFullPaletteFamilyGate(unittest.TestCase):
    SEEDS = {"HALL": "#4c7b5e", "TONIC": "#7e9e6b", "MEDIANT": "#c2d6c2",
             "DOMINANT": "#d4b6a1", "SUBDOMINANT": "#b4574b"}

    def test_default_family_none_calls_universal_harmonize(self):
        from theme_lib import palette
        from unittest.mock import patch
        with patch.object(palette, "harmonize_accents_by_rank",
                          wraps=palette.harmonize_accents_by_rank) as spy:
            palette.derive_full_palette(dict(self.SEEDS))
        spy.assert_called_once()

    def test_non_rose_pine_family_calls_universal_harmonize(self):
        from theme_lib import palette
        from unittest.mock import patch
        with patch.object(palette, "harmonize_accents_by_rank",
                          wraps=palette.harmonize_accents_by_rank) as spy:
            palette.derive_full_palette(dict(self.SEEDS), family="Lix")
        spy.assert_called_once()

    def test_rose_pine_family_skips_universal_harmonize(self):
        from theme_lib import palette
        from unittest.mock import patch
        with patch.object(palette, "harmonize_accents_by_rank") as spy:
            palette.derive_full_palette(dict(self.SEEDS), family="Rose-Pine")
        spy.assert_not_called()

    def test_universal_harmonize_actually_separates_scarab_seeds(self):
        from theme_lib.palette import derive_full_palette
        from theme_lib.colormath import _hex_to_hsl
        keys = ("TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT", "SUPERTONIC", "SUBMEDIANT")
        out = derive_full_palette(dict(self.SEEDS))
        hues = sorted(_hex_to_hsl(out[k])[0] for k in keys)
        n = len(hues)
        gaps = [min(abs(hues[i] - hues[(i + 1) % n]) % 1.0,
                     1.0 - abs(hues[i] - hues[(i + 1) % n]) % 1.0) * 360
                for i in range(n)]
        self.assertGreaterEqual(min(gaps), 20)


class TestThemeLocking(unittest.TestCase):
    def test_unlocked_dir_is_not_locked(self):
        import tempfile
        from pathlib import Path
        from theme_lib.locking import is_locked
        with tempfile.TemporaryDirectory() as d:
            self.assertFalse(is_locked(Path(d)))

    def test_dir_with_locked_marker_is_locked(self):
        import tempfile
        from pathlib import Path
        from theme_lib.locking import is_locked
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "LOCKED").touch()
            self.assertTrue(is_locked(Path(d)))


if __name__ == "__main__":
    unittest.main()
