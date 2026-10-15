#!/usr/bin/env python3
"""Standalone tests for the portrait window-stacking decision.
Run: python3 scripts/test_niri_portrait_stack.py"""
import importlib.util
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "niri_portrait_stack", Path(__file__).with_name("niri-portrait-stack.py"))
s = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(s)


def win(wid, col, row, ws=1, floating=False):
    return {"id": wid, "workspace_id": ws, "is_floating": floating,
            "layout": {"pos_in_scrolling_layout": None if col is None else [col, row]}}


class StackDecision(unittest.TestCase):
    def test_new_column_beside_a_lone_window_stacks(self):
        self.assertTrue(s.should_stack([win(1, 1, 1), win(2, 2, 1)], 2))

    def test_first_window_has_nothing_to_stack_under(self):
        self.assertFalse(s.should_stack([win(1, 1, 1)], 1))

    def test_full_left_column_starts_a_new_column(self):
        ws = [win(1, 1, 1), win(2, 1, 2), win(3, 2, 1)]
        self.assertFalse(s.should_stack(ws, 3))

    def test_fourth_window_stacks_under_the_third(self):
        ws = [win(1, 1, 1), win(2, 1, 2), win(3, 2, 1), win(4, 3, 1)]
        self.assertTrue(s.should_stack(ws, 4))

    def test_window_already_in_a_stack_is_left_alone(self):
        self.assertFalse(s.should_stack([win(1, 1, 1), win(2, 1, 2)], 2))

    def test_floating_window_is_ignored(self):
        self.assertFalse(s.should_stack([win(1, 1, 1), win(2, None, 1, floating=True)], 2))

    def test_unplaced_window_is_ignored(self):
        self.assertFalse(s.should_stack([win(1, 1, 1), win(2, None, 1)], 2))

    def test_other_workspace_columns_do_not_count(self):
        self.assertFalse(s.should_stack([win(1, 1, 1, ws=2), win(2, 2, 1, ws=1)], 2))

    def test_unknown_window_id(self):
        self.assertFalse(s.should_stack([win(1, 1, 1)], 99))


class Orientation(unittest.TestCase):
    def test_portrait_transforms(self):
        for t in ("90", "270", "Flipped90", "Flipped270"):
            self.assertTrue(s.is_portrait(t), t)

    def test_landscape_transforms(self):
        for t in ("Normal", "180", "Flipped", "Flipped180", ""):
            self.assertFalse(s.is_portrait(t), t)


if __name__ == "__main__":
    unittest.main()
