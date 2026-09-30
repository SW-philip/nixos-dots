#!/usr/bin/env python3
"""Standalone tests for drmis's ordered theme-cycling logic. Run: python3 home/niri/test_drmis_cycle.py"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("drmis", Path(__file__).with_name("drmis.py"))
drmis = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drmis)


class TestStepSlug(unittest.TestCase):
    def test_steps_forward(self):
        self.assertEqual(drmis.step_slug("b", ["a", "b", "c"], 1), "c")

    def test_steps_backward(self):
        self.assertEqual(drmis.step_slug("b", ["a", "b", "c"], -1), "a")

    def test_wraps_forward_at_end(self):
        self.assertEqual(drmis.step_slug("c", ["a", "b", "c"], 1), "a")

    def test_wraps_backward_at_start(self):
        self.assertEqual(drmis.step_slug("a", ["a", "b", "c"], -1), "c")

    def test_unknown_current_lands_on_first(self):
        self.assertEqual(drmis.step_slug("zzz", ["a", "b", "c"], 1), "a")
        self.assertEqual(drmis.step_slug("zzz", ["a", "b", "c"], -1), "a")

    def test_empty_slugs_returns_none(self):
        self.assertIsNone(drmis.step_slug("a", [], 1))


class TestOrderedSlugs(unittest.TestCase):
    def setUp(self):
        self.orig_themes_root = drmis.THEMES_ROOT
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for family, slug in [("Lix", "b-theme"), ("Animals", "z-theme"), ("Animals", "a-theme")]:
            d = self.root / family / slug
            d.mkdir(parents=True)
            (d / f"palette-{slug}.nix").write_text("{}")
            (d / f"palette-{slug}.sh").write_text("")
        drmis.THEMES_ROOT = self.root

    def tearDown(self):
        drmis.THEMES_ROOT = self.orig_themes_root
        self.tmp.cleanup()

    def test_orders_by_family_then_slug(self):
        self.assertEqual(
            drmis.ordered_slugs(),
            ["a-theme", "z-theme", "b-theme"],
        )


if __name__ == "__main__":
    unittest.main()
