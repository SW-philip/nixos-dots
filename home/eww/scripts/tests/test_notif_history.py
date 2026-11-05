#!/usr/bin/env python3
"""Tests for the notification history state machine.
Run: python3 home/eww/scripts/tests/test_notif_history.py"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import notif_history as nh


class V:
    """Stands in for dbus_fast.Variant."""
    def __init__(self, value):
        self.value = value


def notify(h, app="a", summary="s", body="b", replaces=0, hints=None, serial=1, sender=":1.9", now=100.0):
    h.on_notify(sender, serial, [app, replaces, "", summary, body, [], hints or {}, -1], now)


class HistoryTests(unittest.TestCase):
    def test_notify_waits_for_reply_then_appears(self):
        h = nh.History()
        notify(h)
        self.assertEqual(h.snapshot()["count"], 0)
        self.assertTrue(h.on_return(":1.9", 1, [7]))
        snap = h.snapshot()
        self.assertEqual(snap["count"], 1)
        self.assertEqual(snap["items"][0]["id"], 7)
        self.assertEqual(snap["items"][0]["summary"], "s")

    def test_stale_pending_pruned(self):
        h = nh.History()
        notify(h, serial=1, now=100.0)
        notify(h, serial=2, now=131.5)
        self.assertNotIn((":1.9", 1), h.pending)
        self.assertFalse(h.on_return(":1.9", 1, [7]))

    def test_unrelated_return_ignored(self):
        h = nh.History()
        notify(h, serial=1)
        self.assertFalse(h.on_return(":1.9", 2, [7]))
        self.assertFalse(h.on_return(":1.8", 1, [7]))

    def test_newest_first(self):
        h = nh.History()
        notify(h, summary="one", serial=1); h.on_return(":1.9", 1, [1])
        notify(h, summary="two", serial=2); h.on_return(":1.9", 2, [2])
        self.assertEqual([i["summary"] for i in h.snapshot()["items"]], ["two", "one"])

    def test_replace_updates_in_place(self):
        h = nh.History()
        notify(h, summary="old", serial=1); h.on_return(":1.9", 1, [5])
        notify(h, summary="new", serial=2, replaces=5); h.on_return(":1.9", 2, [5])
        items = h.snapshot()["items"]
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["summary"], "new")

    def test_closed_removes(self):
        h = nh.History()
        notify(h); h.on_return(":1.9", 1, [3])
        self.assertTrue(h.on_closed(3))
        self.assertFalse(h.on_closed(3))
        self.assertEqual(h.snapshot()["count"], 0)

    def test_urgency_from_variant_and_default(self):
        h = nh.History()
        notify(h, hints={"urgency": V(2)}, serial=1); h.on_return(":1.9", 1, [1])
        notify(h, serial=2); h.on_return(":1.9", 2, [2])
        got = {i["id"]: i["urgency"] for i in h.snapshot()["items"]}
        self.assertEqual(got, {1: "critical", 2: "normal"})

    def test_cap_drops_oldest(self):
        h = nh.History(cap=2)
        for n in (1, 2, 3):
            notify(h, serial=n); h.on_return(":1.9", n, [n])
        self.assertEqual([i["id"] for i in h.snapshot()["items"]], [3, 2])

    def test_clear(self):
        h = nh.History()
        notify(h); h.on_return(":1.9", 1, [1])
        h.clear()
        self.assertEqual(h.snapshot()["count"], 0)


def item(id, app="a", urgency="normal", time=100.0):
    return {"id": id, "app": app, "summary": f"s{id}", "body": "", "icon": "",
            "urgency": urgency, "time": time}


class GroupTests(unittest.TestCase):
    def test_same_app_within_window_groups(self):
        groups = nh.group_items([item(2, time=100.0), item(1, time=90.0)])
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["count"], 2)
        self.assertEqual(groups[0]["ids"], "2 1")
        self.assertEqual([i["id"] for i in groups[0]["items"]], [2, 1])

    def test_outside_window_splits(self):
        groups = nh.group_items([item(2, time=1000.0), item(1, time=100.0)])
        self.assertEqual([g["count"] for g in groups], [1, 1])

    def test_different_apps_separate(self):
        groups = nh.group_items([item(2, app="x"), item(1, app="y")])
        self.assertEqual(sorted(g["app"] for g in groups), ["x", "y"])

    def test_group_urgency_is_most_severe(self):
        groups = nh.group_items([item(2, urgency="low"), item(1, urgency="critical")])
        self.assertEqual(groups[0]["urgency"], "critical")

    def test_sorted_critical_first_low_last_then_newest(self):
        groups = nh.group_items([
            item(4, app="n1", urgency="normal", time=400.0),
            item(3, app="low", urgency="low", time=300.0),
            item(2, app="n2", urgency="normal", time=200.0),
            item(1, app="crit", urgency="critical", time=100.0),
        ])
        self.assertEqual([g["app"] for g in groups], ["crit", "n1", "n2", "low"])

    def test_snapshot_has_groups_and_unchanged_count(self):
        h = nh.History()
        notify(h, app="a", serial=1); h.on_return(":1.9", 1, [1])
        notify(h, app="a", serial=2); h.on_return(":1.9", 2, [2])
        snap = h.snapshot()
        self.assertEqual(snap["count"], 2)
        self.assertEqual(len(snap["groups"]), 1)
        self.assertEqual(snap["groups"][0]["count"], 2)

    def test_key_is_shell_safe_and_stable_when_items_join(self):
        a = nh.group_items([item(1, app="Google Chrome")])[0]["key"]
        b = nh.group_items([item(2, app="Google Chrome", time=110.0), item(1, app="Google Chrome")])[0]["key"]
        self.assertEqual(a, "g1")
        self.assertEqual(a, b)

    def test_keys_unique_per_group(self):
        groups = nh.group_items([item(2, app="x"), item(1, app="y")])
        self.assertEqual(len({g["key"] for g in groups}), 2)


class DismissTests(unittest.TestCase):
    def test_dismiss_accepts_several_ids(self):
        calls = []
        orig = nh.swaync_call
        nh.swaync_call = lambda member, signature="", body=(): calls.append((member, signature, list(body)))
        try:
            nh.main(["notif_history.py", "dismiss", "4", "5", "6"])
        finally:
            nh.swaync_call = orig
        self.assertEqual(calls, [("CloseNotification", "u", [4]),
                                 ("CloseNotification", "u", [5]),
                                 ("CloseNotification", "u", [6])])


class QueryTests(unittest.TestCase):
    def _hist(self):
        h = nh.History()
        notify(h, app="Signal", summary="wifi back", serial=1); h.on_return(":1.9", 1, [1])
        notify(h, app="Signal", summary="hello", serial=2); h.on_return(":1.9", 2, [2])
        notify(h, app="Meraki", summary="portal", serial=3); h.on_return(":1.9", 3, [3])
        return h

    def test_empty_query_everything_matches(self):
        snap = self._hist().snapshot()
        self.assertEqual(snap["query"], "")
        self.assertEqual(snap["matches"], snap["count"])
        self.assertTrue(all(g["match"] for g in snap["groups"]))

    def test_query_flags_matches_and_counts(self):
        h = self._hist()
        h.set_query("wifi")
        snap = h.snapshot()
        self.assertEqual(snap["query"], "wifi")
        self.assertEqual(snap["matches"], 1)
        by_app = {g["app"]: g for g in snap["groups"]}
        self.assertTrue(by_app["Signal"]["match"])
        self.assertFalse(by_app["Meraki"]["match"])
        self.assertEqual([i["match"] for i in by_app["Signal"]["items"]], [False, True])

    def test_query_does_not_reorder_or_drop(self):
        h = self._hist()
        before = [g["key"] for g in h.snapshot()["groups"]]
        h.set_query("portal")
        self.assertEqual([g["key"] for g in h.snapshot()["groups"]], before)
        self.assertEqual(h.snapshot()["count"], 3)


if __name__ == "__main__":
    unittest.main()
