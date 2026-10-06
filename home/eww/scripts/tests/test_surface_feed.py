#!/usr/bin/env python3
"""Tests for the eww tablet/osk feeds.
Run: uv run --with inotify-simple --with dbus-fast python3 home/eww/scripts/tests/test_surface_feed.py"""
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import surface_feed as sf


def wait_for(pred, timeout=2.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.02)
    return pred()


class ReadCoverTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "surface-cover"

    def tearDown(self):
        self.dir.cleanup()

    def test_detached_is_true(self):
        self.path.write_text("detached\n")
        self.assertTrue(sf.read_cover(self.path))

    def test_everything_else_is_false(self):
        self.assertFalse(sf.read_cover(self.path))  # missing
        for content in ("attached\n", "garbage\n", ""):
            self.path.write_text(content)
            self.assertFalse(sf.read_cover(self.path), content)


class ChangesTests(unittest.TestCase):
    def test_only_changes_are_forwarded(self):
        seen = []
        c = sf.Changes(seen.append)
        for v in (False, False, True, True, False):
            c.push(v)
        self.assertEqual(seen, [False, True, False])


class OskStateTests(unittest.TestCase):
    def test_true_only_when_present_and_visible(self):
        s = sf.OskState()
        self.assertFalse(s.value)
        s.visible = True
        self.assertFalse(s.value)  # visible flag alone, service gone
        s.present = True
        self.assertTrue(s.value)
        s.visible = False
        self.assertFalse(s.value)


class WatchCoverTests(unittest.TestCase):
    def test_emits_initial_value_then_each_change_once(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "surface-cover"
            seen, stop = [], threading.Event()
            t = threading.Thread(target=sf.watch_cover, args=(path, seen.append, stop))
            t.start()
            try:
                self.assertTrue(wait_for(lambda: seen == [False]), "initial value")

                path.write_text("detached\n")
                self.assertTrue(wait_for(lambda: seen == [False, True]), "detached")

                path.write_text("detached\n")  # same value again: no new line
                time.sleep(0.4)
                self.assertEqual(seen, [False, True])

                path.write_text("attached\n")
                self.assertTrue(wait_for(lambda: seen == [False, True, False]), "attached")

                tmp = Path(d) / "tmp"
                tmp.write_text("detached\n")
                os.replace(tmp, path)  # atomic replace is also picked up
                self.assertTrue(wait_for(lambda: seen == [False, True, False, True]), "replace")

                path.unlink()
                self.assertTrue(wait_for(lambda: seen == [False, True, False, True, False]), "delete")
            finally:
                stop.set()
                t.join(3)
            self.assertFalse(t.is_alive())

    def test_unrelated_files_in_the_directory_are_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "surface-cover"
            seen, stop = [], threading.Event()
            t = threading.Thread(target=sf.watch_cover, args=(path, seen.append, stop))
            t.start()
            try:
                self.assertTrue(wait_for(lambda: seen == [False]))
                (Path(d) / "eww-vitals.json").write_text("{}")
                time.sleep(0.4)
                self.assertEqual(seen, [False])
            finally:
                stop.set()
                t.join(3)


if __name__ == "__main__":
    unittest.main()
