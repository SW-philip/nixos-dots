#!/usr/bin/env python3
"""Tests for notif-center query parsing and matching.
Run: python3 home/eww/scripts/tests/test_notif_search.py"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import notif_search as ns


def item(app="a", summary="s", body="", urgency="normal"):
    return {"id": 1, "app": app, "summary": summary, "body": body, "urgency": urgency}


class ParseTests(unittest.TestCase):
    def test_plain_terms_lowercased(self):
        self.assertEqual(ns.parse_query("WiFi Meraki")["terms"], ["wifi", "meraki"])

    def test_empty(self):
        q = ns.parse_query("   ")
        self.assertEqual((q["terms"], q["urgent"], q["app"], q["focus"]), ([], False, "", ""))

    def test_bang_marks_urgent_and_keeps_rest_as_term(self):
        q = ns.parse_query("!disk")
        self.assertTrue(q["urgent"])
        self.assertEqual(q["terms"], ["disk"])
        q = ns.parse_query("! disk")
        self.assertTrue(q["urgent"])
        self.assertEqual(q["terms"], ["disk"])

    def test_at_token_sets_app(self):
        q = ns.parse_query("@Firefox download")
        self.assertEqual((q["app"], q["terms"]), ("firefox", ["download"]))

    def test_lone_at_is_a_term(self):
        self.assertEqual(ns.parse_query("@")["terms"], ["@"])

    def test_focus_only_when_sole_term(self):
        self.assertEqual(ns.parse_query("vol")["focus"], "vol")
        self.assertEqual(ns.parse_query("Brightness")["focus"], "bright")
        self.assertEqual(ns.parse_query("vol up")["focus"], "")


class MatchTests(unittest.TestCase):
    def test_empty_query_matches_everything(self):
        self.assertTrue(ns.item_matches(item(), ns.parse_query("")))
        self.assertTrue(ns.row_matches("WiFi", ns.parse_query("")))

    def test_terms_are_anded_across_app_summary_body(self):
        it = item(app="Signal", summary="New message", body="from Alex")
        self.assertTrue(ns.item_matches(it, ns.parse_query("signal alex")))
        self.assertFalse(ns.item_matches(it, ns.parse_query("signal bob")))

    def test_urgent_filter(self):
        q = ns.parse_query("!")
        self.assertTrue(ns.item_matches(item(urgency="critical"), q))
        self.assertFalse(ns.item_matches(item(urgency="normal"), q))

    def test_app_filter(self):
        q = ns.parse_query("@fire")
        self.assertTrue(ns.item_matches(item(app="Firefox"), q))
        self.assertFalse(ns.item_matches(item(app="Signal"), q))

    def test_rows_ignore_urgent_and_app_filters(self):
        self.assertFalse(ns.row_matches("WiFi", ns.parse_query("!")))
        self.assertFalse(ns.row_matches("WiFi", ns.parse_query("@x")))
        self.assertTrue(ns.row_matches("Night Light", ns.parse_query("night")))
        self.assertFalse(ns.row_matches("Night Light", ns.parse_query("wifi")))


class AnnotateTests(unittest.TestCase):
    def test_group_matches_if_any_item_does_and_inputs_are_not_mutated(self):
        groups = [{"app": "a", "items": [item(summary="wifi up"), item(summary="other")]},
                  {"app": "b", "items": [item(app="b", summary="nope")]}]
        out = ns.annotate_groups(groups, ns.parse_query("wifi"))
        self.assertEqual([g["match"] for g in out], [True, False])
        self.assertEqual([i["match"] for i in out[0]["items"]], [True, False])
        self.assertNotIn("match", groups[0])
        self.assertNotIn("match", groups[0]["items"][0])


class QueryFileTests(unittest.TestCase):
    def test_roundtrip_and_missing_file(self):
        with tempfile.TemporaryDirectory() as d:
            old = os.environ.get("XDG_RUNTIME_DIR")
            os.environ["XDG_RUNTIME_DIR"] = d
            try:
                self.assertEqual(ns.read_query(), "")
                ns.write_query("wifi now")
                self.assertEqual(ns.read_query(), "wifi now")
                ns.write_query("")
                self.assertEqual(ns.read_query(), "")
            finally:
                if old is None:
                    del os.environ["XDG_RUNTIME_DIR"]
                else:
                    os.environ["XDG_RUNTIME_DIR"] = old


if __name__ == "__main__":
    unittest.main()
