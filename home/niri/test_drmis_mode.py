#!/usr/bin/env python3
"""Standalone tests for drmis mode (light/dark pairing) and mode-scoped cycling.
Run: python3 home/niri/test_drmis_mode.py"""
import importlib.util
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("drmis", Path(__file__).with_name("drmis.py"))
drmis = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drmis)

MAP = {"themes": {
    "a":       {"isLight": False, "pair": "a-light"},
    "a-light": {"isLight": True,  "pair": "a"},
    "b":       {"isLight": False, "pair": None},
    "c":       {"isLight": False, "pair": "c-light"},
    "c-light": {"isLight": True,  "pair": "c"},
}}


class ModeOf(unittest.TestCase):
    def test_reads_isLight(self):
        self.assertEqual(drmis.mode_of({"isLight": True}), "light")
        self.assertEqual(drmis.mode_of({"isLight": False}), "dark")
        self.assertEqual(drmis.mode_of({}), "dark")


# a three-member group: two dark, one light, PAIR = next member, closing the cycle
CYCLE = {"themes": {
    "m": {"isLight": False, "pair": "i"},
    "i": {"isLight": False, "pair": "d"},
    "d": {"isLight": True,  "pair": "m"},
}}
# two same-mode themes that just swap (Rose Pine today)
SWAP = {"themes": {
    "m": {"isLight": False, "pair": "i"},
    "i": {"isLight": False, "pair": "m"},
}}


class GroupCycle(unittest.TestCase):
    def test_toggle_steps_to_the_next_member(self):
        self.assertEqual(drmis.mode_target("m", "toggle", CYCLE)[0], "i")
        self.assertEqual(drmis.mode_target("i", "toggle", CYCLE)[0], "d")
        self.assertEqual(drmis.mode_target("d", "toggle", CYCLE)[0], "m")

    def test_light_and_dark_walk_the_group_to_the_first_match(self):
        self.assertEqual(drmis.mode_target("m", "light", CYCLE)[0], "d")   # skips i
        self.assertEqual(drmis.mode_target("d", "dark", CYCLE)[0], "m")
        self.assertEqual(drmis.mode_target("i", "light", CYCLE)[0], "d")

    def test_same_mode_group_toggles_but_has_no_other_mode(self):
        self.assertEqual(drmis.mode_target("m", "toggle", SWAP)[0], "i")
        self.assertEqual(drmis.mode_target("i", "toggle", SWAP)[0], "m")
        target, msg = drmis.mode_target("m", "light", SWAP)
        self.assertIsNone(target)
        self.assertIn("no light theme", msg)
        target, msg = drmis.mode_target("m", "dark", SWAP)
        self.assertIsNone(target)
        self.assertIn("already dark", msg)

    def test_a_broken_cycle_does_not_loop_forever(self):
        loop = {"themes": {"a": {"isLight": False, "pair": "b"},
                           "b": {"isLight": False, "pair": "b"}}}
        target, msg = drmis.mode_target("a", "light", loop)
        self.assertIsNone(target)


class ModeSlugs(unittest.TestCase):
    def test_filters_to_the_mode_and_keeps_order(self):
        self.assertEqual(drmis.mode_slugs(["a", "a-light", "b", "c", "ghost"], MAP, "dark"),
                         ["a", "b", "c"])
        self.assertEqual(drmis.mode_slugs(["a", "a-light", "c-light"], MAP, "light"),
                         ["a-light", "c-light"])


class ModeTarget(unittest.TestCase):
    def test_toggle_goes_to_the_pair_both_ways(self):
        self.assertEqual(drmis.mode_target("a", "toggle", MAP)[0], "a-light")
        self.assertEqual(drmis.mode_target("a-light", "toggle", MAP)[0], "a")

    def test_light_from_dark_goes_and_light_from_light_is_a_noop(self):
        self.assertEqual(drmis.mode_target("a", "light", MAP)[0], "a-light")
        target, msg = drmis.mode_target("a-light", "light", MAP)
        self.assertIsNone(target)
        self.assertIn("already light", msg)

    def test_no_pair_is_reported(self):
        target, msg = drmis.mode_target("b", "toggle", MAP)
        self.assertIsNone(target)
        self.assertIn("no light/dark pair", msg)

    def test_pair_missing_from_the_map_is_reported(self):
        broken = {"themes": {"x": {"isLight": False, "pair": "gone"}}}
        target, msg = drmis.mode_target("x", "toggle", broken)
        self.assertIsNone(target)
        self.assertIn("gone", msg)

    def test_unknown_current_theme(self):
        target, msg = drmis.mode_target("nope", "toggle", MAP)
        self.assertIsNone(target)
        self.assertIn("unknown theme", msg)


class DoModeExitCodes(unittest.TestCase):
    def setUp(self):
        self.sets = []
        self._set, self._cur = drmis.do_set, drmis.current_theme
        drmis.do_set = lambda slug, m: self.sets.append(slug)

    def tearDown(self):
        drmis.do_set, drmis.current_theme = self._set, self._cur

    def test_toggle_applies_the_pair(self):
        drmis.current_theme = lambda: "a"
        self.assertEqual(drmis.do_mode("toggle", MAP), 0)
        self.assertEqual(self.sets, ["a-light"])

    def test_already_in_mode_is_success_and_changes_nothing(self):
        drmis.current_theme = lambda: "a"
        self.assertEqual(drmis.do_mode("dark", MAP), 0)
        self.assertEqual(self.sets, [])

    def test_no_pair_fails_and_changes_nothing(self):
        drmis.current_theme = lambda: "b"
        self.assertEqual(drmis.do_mode("toggle", MAP), 1)
        self.assertEqual(self.sets, [])

    def test_bad_argument_is_a_usage_error(self):
        self.assertEqual(drmis.do_mode("dim", MAP), 2)
        self.assertEqual(self.sets, [])


class StepStaysInMode(unittest.TestCase):
    def setUp(self):
        self.sets = []
        self._set, self._cur, self._ord = drmis.do_set, drmis.current_theme, drmis.ordered_slugs
        drmis.do_set = lambda slug, m: self.sets.append(slug)
        drmis.ordered_slugs = lambda: ["a", "a-light", "b", "c", "c-light"]

    def tearDown(self):
        drmis.do_set, drmis.current_theme, drmis.ordered_slugs = self._set, self._cur, self._ord

    def test_next_from_dark_skips_the_light_themes(self):
        import subprocess
        real = subprocess.run
        subprocess.run = lambda *a, **k: None  # the notify-send call
        try:
            drmis.current_theme = lambda: "a"
            drmis.do_step(1, MAP)
            drmis.current_theme = lambda: "c"
            drmis.do_step(1, MAP)  # wraps to a, never lands on c-light
        finally:
            subprocess.run = real
        self.assertEqual(self.sets, ["b", "a"])

    def test_prev_from_light_stays_light(self):
        import subprocess
        real = subprocess.run
        subprocess.run = lambda *a, **k: None
        try:
            drmis.current_theme = lambda: "c-light"
            drmis.do_step(-1, MAP)
        finally:
            subprocess.run = real
        self.assertEqual(self.sets, ["a-light"])


if __name__ == "__main__":
    unittest.main()
