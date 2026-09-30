#!/usr/bin/env python3
"""Standalone tests for the three-finger-tap detector.
Run: python3 scripts/test_osk_gesture.py"""
import importlib.util
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "osk_gesture", Path(__file__).with_name("osk-gesture.py"))
g = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(g)


def run(events, fingers=g.FINGERS):
    """Feed [(type, code, value, t)] into a fresh detector; return how many fired."""
    det = g.TapDetector(fingers)
    return sum(1 for e in events if det.feed(*e))


def touch(slots, t0, hold, lift_stagger=0.0, travel=0):
    """Events for `slots` fingers down at t0, up after `hold` seconds."""
    ev = []
    for s in slots:
        ev += [(g.EV_ABS, g.ABS_MT_SLOT, s, t0),
               (g.EV_ABS, g.ABS_MT_TRACKING_ID, 100 + s, t0),
               (g.EV_ABS, g.ABS_MT_X, 3000 + 500 * s, t0),
               (g.EV_ABS, g.ABS_MT_Y, 3000, t0)]
    for i, s in enumerate(slots):
        t = t0 + hold + i * lift_stagger
        if travel:
            ev.append((g.EV_ABS, g.ABS_MT_SLOT, s, t))
            ev.append((g.EV_ABS, g.ABS_MT_X, 3000 + 500 * s + travel, t))
        ev += [(g.EV_ABS, g.ABS_MT_SLOT, s, t),
               (g.EV_ABS, g.ABS_MT_TRACKING_ID, -1, t)]
    return ev


class TestArgs(unittest.TestCase):
    def test_takes_toggle_and_exit_commands(self):
        self.assertEqual(g.parse_args(["x", "/a/toggle", "/b/exit"]), ("/a/toggle", "/b/exit"))

    def test_rejects_wrong_arg_count(self):
        for argv in (["x"], ["x", "/a"], ["x", "/a", "/b", "/c"]):
            with self.assertRaises(SystemExit):
                g.parse_args(argv)


class TestTapDetector(unittest.TestCase):
    def test_three_finger_tap_fires_once(self):
        self.assertEqual(run(touch([0, 1, 2], 1.0, 0.07)), 1)

    def test_staggered_lift_still_fires(self):
        self.assertEqual(run(touch([0, 1, 2], 1.0, 0.06, lift_stagger=0.02)), 1)

    def test_two_fingers_do_not_fire(self):
        self.assertEqual(run(touch([0, 1], 1.0, 0.07)), 0)

    def test_four_fingers_do_not_fire(self):
        self.assertEqual(run(touch([0, 1, 2, 3], 1.0, 0.07)), 0)

    def test_four_finger_tap_fires_the_exit_detector(self):
        self.assertEqual(run(touch([0, 1, 2, 3], 1.0, 0.07), g.EXIT_FINGERS), 1)

    def test_three_finger_tap_does_not_fire_the_exit_detector(self):
        self.assertEqual(run(touch([0, 1, 2], 1.0, 0.07), g.EXIT_FINGERS), 0)

    def test_held_three_fingers_do_not_fire(self):
        self.assertEqual(run(touch([0, 1, 2], 1.0, 0.8)), 0)

    def test_three_finger_swipe_does_not_fire(self):
        self.assertEqual(run(touch([0, 1, 2], 1.0, 0.2, travel=900)), 0)

    def test_three_separate_single_taps_do_not_fire(self):
        ev = (touch([0], 1.00, 0.06) + touch([0], 1.14, 0.06)
              + touch([0], 1.28, 0.06))
        self.assertEqual(run(ev), 0)

    def test_state_resets_after_a_fire(self):
        ev = touch([0, 1, 2], 1.0, 0.07) + touch([0], 2.0, 0.06)
        self.assertEqual(run(ev), 1)

    def test_two_taps_of_three_fingers_fire_twice(self):
        ev = touch([0, 1, 2], 1.0, 0.07) + touch([0, 1, 2], 2.0, 0.07)
        self.assertEqual(run(ev), 2)


if __name__ == "__main__":
    unittest.main()
