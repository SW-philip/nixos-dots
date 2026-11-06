#!/usr/bin/env python3
"""Tests for notif_controls.
Run: python3 -I home/eww/scripts/tests/test_notif_controls.py"""
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import notif_controls as nc

CFG = {"widget-config": {
    "title": {"text": "x"},
    "buttons-grid#connectivity": {"actions": [
        {"label": "Wi-Fi", "type": "toggle", "command": "wifi-flip", "update-command": "wifi-state"},
        {"label": "VPN", "command": "vpn-run"}]},
    "buttons-grid#system": {"actions": [
        {"label": "DND", "type": "toggle", "command": "dnd-flip", "update-command": "dnd-state"}]},
}}


def write_cfg():
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(CFG, f)
    return f.name


class GridTests(unittest.TestCase):
    def test_read_state_probes_in_parallel(self):
        grids = {"g": [{"label": str(n), "type": "toggle", "update-command": f"c{n}"} for n in range(4)]}

        def slow(cmd, timeout=0.6):
            time.sleep(0.3)
            return "true"
        t0 = time.monotonic()
        st = nc.read_state(grids, runner=slow)
        self.assertLess(time.monotonic() - t0, 0.8)
        self.assertEqual([r["on"] for r in st["grids"]["g"]], [True] * 4)

    def test_read_state_timeout_keeps_previous_value(self):
        grids = nc.load_grids(write_cfg())
        stuck = lambda cmd, timeout=0.6: None
        st = nc.read_state(grids, runner=stuck, prev={("connectivity", 0): True})
        self.assertEqual(st["grids"]["connectivity"][0]["on"], True)
        st = nc.read_state(grids, runner=stuck)
        self.assertEqual(st["grids"]["connectivity"][0]["on"], False)
        self.assertEqual([r["i"] for r in st["grids"]["connectivity"]], [0, 1])

    def test_load_grids_keys_and_order(self):
        grids = nc.load_grids(write_cfg())
        self.assertEqual(list(grids), ["connectivity", "system"])
        self.assertEqual([a["label"] for a in grids["connectivity"]], ["Wi-Fi", "VPN"])

    def test_missing_file_is_empty(self):
        self.assertEqual(nc.load_grids("/nonexistent/x.json"), {})

    def test_read_state_toggle_on_off_and_plain(self):
        grids = nc.load_grids(write_cfg())
        out = {"wifi-state": "true\n", "dnd-state": "false\n"}
        st = nc.read_state(grids, runner=lambda c, timeout=2.0: out.get(c, ""))
        wifi, vpn = st["grids"]["connectivity"]
        self.assertEqual((wifi["toggle"], wifi["on"]), (True, True))
        self.assertEqual((vpn["toggle"], vpn["on"]), (False, False))
        self.assertEqual(st["grids"]["system"][0]["on"], False)
        self.assertEqual(st["grids"]["connectivity"][1]["i"], 1)

    def test_run_action_runs_command_only(self):
        grids = nc.load_grids(write_cfg())
        seen = []
        nc.run_action(grids, "connectivity", 1, runner=lambda c, timeout=2.0: seen.append(c) or "")
        self.assertEqual(seen, ["vpn-run"])

    def test_run_action_bad_index_ignored(self):
        grids = nc.load_grids(write_cfg())
        nc.run_action(grids, "connectivity", 9, runner=lambda c, timeout=2.0: self.fail("ran"))
        nc.run_action(grids, "nope", 0, runner=lambda c, timeout=2.0: self.fail("ran"))

    def test_run_action_default_does_not_wait(self):
        grids = {"g": [{"command": "sleep 5"}]}
        t0 = time.monotonic()
        nc.run_action(grids, "g", 0)
        self.assertLess(time.monotonic() - t0, 1.0)

    def test_pct_clamps_and_rounds(self):
        self.assertEqual((nc.pct("-5"), nc.pct("37.6"), nc.pct("250")), (0, 38, 100))

    def test_set_level_skips_noop_and_floors_brightness(self):
        ran = []
        run = lambda c, timeout=2.0: ran.append(c) or ""
        cur = lambda: {"vol": 40, "muted": False, "bright": 30}
        nc.set_level("vol", "40.2", runner=run, current=cur)
        nc.set_level("bright", "30", runner=run, current=cur)
        self.assertEqual(ran, [])
        nc.set_level("vol", "55", runner=run, current=cur)
        nc.set_level("bright", "0", runner=run, current=cur)
        self.assertEqual(ran, ["wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 55%", "brightnessctl set 1%"])

    def test_feed_gates_on_flag(self):
        # flag per tick: absent x2, present x8 (ticks 2-9), absent after
        flags = [False, False] + [True] * 8 + [False] * 5
        tick = [0]

        def sleep(_):
            tick[0] += 1
            if tick[0] >= len(flags):
                raise StopIteration

        emitted = []
        try:
            for line in nc.feed(lambda: "S", lambda: flags[tick[0]], lambda: float(tick[0]), sleep):
                emitted.append((tick[0], line))
        except (StopIteration, RuntimeError):
            pass
        self.assertEqual(emitted, [(2, "S"), (7, "S")])

    def test_run_sh_failure_is_empty(self):
        self.assertEqual(nc.run_sh("exit 3"), "")
        self.assertEqual(nc.run_sh("echo hi").strip(), "hi")
        self.assertEqual(nc.run_sh("sleep 5", timeout=0.1), "")


import notif_search as ns


STATE = {"grids": {"connectivity": [{"i": 0, "label": "WiFi", "toggle": True, "on": True},
                                    {"i": 1, "label": "Bluetooth", "toggle": True, "on": False}],
                   "system": [{"i": 0, "label": "Night Light", "toggle": True, "on": False}]}}
GRIDS = {"connectivity": [{"label": "WiFi", "command": "wifi-cmd"}, {"label": "Bluetooth", "command": "bt-cmd"}],
         "system": [{"label": "Night Light", "command": "nl-cmd"}]}


class QueryTests(unittest.TestCase):
    def test_apply_query_flags_rows_and_lists_matches(self):
        out = nc.apply_query(STATE, ns.parse_query("blue"))
        flags = {r["label"]: r["match"] for rows in out["grids"].values() for r in rows}
        self.assertEqual(flags, {"WiFi": False, "Bluetooth": True, "Night Light": False})
        self.assertEqual(out["matches"], [{"grid": "connectivity", "i": 1, "label": "Bluetooth", "on": False}])
        self.assertEqual(out["focus"], "")

    def test_empty_query_everything_matches_but_matches_list_empty(self):
        out = nc.apply_query(STATE, ns.parse_query(""))
        self.assertTrue(all(r["match"] for rows in out["grids"].values() for r in rows))
        self.assertEqual(out["matches"], [])

    def test_focus_is_passed_through(self):
        self.assertEqual(nc.apply_query(STATE, ns.parse_query("vol"))["focus"], "vol")

    def test_apply_query_does_not_mutate_input(self):
        nc.apply_query(STATE, ns.parse_query("wifi"))
        self.assertNotIn("match", STATE["grids"]["connectivity"][0])

    def test_run_first_match_runs_first_in_grid_order(self):
        ran = []
        nc.run_first_match(GRIDS, ns.parse_query("t"), runner=lambda cmd, timeout=None: ran.append(cmd))
        self.assertEqual(ran, ["bt-cmd"])  # "Bluetooth" precedes "Night Light"

    def test_run_first_match_noop_without_terms_or_match(self):
        ran = []
        run = lambda cmd, timeout=None: ran.append(cmd)
        nc.run_first_match(GRIDS, ns.parse_query(""), runner=run)
        nc.run_first_match(GRIDS, ns.parse_query("zzz"), runner=run)
        nc.run_first_match(GRIDS, ns.parse_query("!"), runner=run)
        self.assertEqual(ran, [])

    def test_feed_reemits_when_query_changes(self):
        class Done(Exception):
            pass

        tick = [0]
        qs = ["", "", "wifi", "wifi", "wifi", "wifi"]

        def sleep(_):
            tick[0] += 1
            if tick[0] >= len(qs):
                raise Done

        emitted = []
        try:
            for _line in nc.feed(lambda: "S", lambda: True, lambda: float(tick[0]), sleep,
                                 query=lambda: qs[tick[0]], interval=100.0):
                emitted.append(tick[0])
        except Done:
            pass
        self.assertEqual(emitted, [0, 2])


class ActsTests(unittest.TestCase):
    def test_split_label(self):
        self.assertEqual(nc.split_label("\U000f0582  VPN"), ("\U000f0582", "VPN"))
        self.assertEqual(nc.split_label("Free Palestine"), ("F", "Free Palestine"))

    def test_acts_are_the_non_toggle_rows(self):
        state = {"grids": {"g": [
            {"i": 0, "label": "A", "toggle": True, "on": True, "glyph": "A", "name": "A"},
            {"i": 1, "label": "x  VPN", "toggle": False, "on": False, "glyph": "x", "name": "VPN"}]}}
        acts = nc.apply_query(state, ns.parse_query(""))["acts"]
        self.assertEqual(acts, {"g": [{"i": 1, "glyph": "x", "name": "VPN", "match": True}]})

    def test_mute_runs_wpctl_toggle(self):
        seen = []
        nc.toggle_mute(runner=seen.append)
        self.assertEqual(seen, ["wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"])


class SummaryTests(unittest.TestCase):
    STATE = {"grids": {
        "connectivity": [
            {"i": 0, "label": "Wi-Fi", "toggle": True, "on": True},
            {"i": 1, "label": "Bluetooth", "toggle": True, "on": True},
            {"i": 2, "label": "VPN", "toggle": False, "on": False}],
        "system": [{"i": 0, "label": "Quiet", "toggle": True, "on": False}]}}

    def test_counts_and_tags(self):
        s = nc.apply_query(self.STATE, ns.parse_query(""))["summary"]
        self.assertEqual(s["connectivity"], {"on": 2, "total": 2, "tags": "W B", "hit": False})
        self.assertEqual(s["system"], {"on": 0, "total": 1, "tags": "", "hit": False})

    def test_hit_marks_only_the_matching_grid(self):
        s = nc.apply_query(self.STATE, ns.parse_query("quiet"))["summary"]
        self.assertTrue(s["system"]["hit"])
        self.assertFalse(s["connectivity"]["hit"])


class WarmCacheTests(unittest.TestCase):
    def test_feed_primes_once_at_start_even_with_pane_closed(self):
        class Done(Exception):
            pass

        tick = [0]

        def sleep(_):
            tick[0] += 1
            if tick[0] >= 4:
                raise Done

        emitted = []
        try:
            for line in nc.feed(lambda: "FULL", lambda: False, lambda: float(tick[0]), sleep, prime=True):
                emitted.append((tick[0], line))
        except Done:
            pass
        self.assertEqual(emitted, [(0, "FULL")])

    def test_prime_with_pane_open_does_not_refresh_again_on_first_tick(self):
        class Done(Exception):
            pass

        tick = [0]

        def sleep(_):
            tick[0] += 1
            if tick[0] >= 4:
                raise Done

        emitted = []
        try:
            for line in nc.feed(lambda: "FULL", lambda: True, lambda: float(tick[0]), sleep,
                                prime=True, interval=5.0):
                emitted.append((tick[0], line))
        except Done:
            pass
        self.assertEqual(emitted, [(0, "FULL")])

    def test_snapshot_warm_loads_last_refresh_without_probes(self):
        old = os.environ.get("XDG_RUNTIME_DIR")
        orig_rs, orig_lv = nc.read_state, nc.levels
        with tempfile.TemporaryDirectory() as d:
            os.environ["XDG_RUNTIME_DIR"] = d
            try:
                nc.read_state = lambda grids, runner=None, prev=None: {"grids": {"g": [{"i": 0, "label": "WiFi", "toggle": True, "on": True}]}}
                nc.levels = lambda: {"vol": 5, "muted": False, "bright": 7}
                nc.Snapshot("").full()
                nc.read_state = nc.levels = lambda *a, **k: self.fail("probed")
                fresh = nc.Snapshot("")
                self.assertTrue(fresh.warm())
                line = json.loads(fresh.line())
            finally:
                nc.read_state, nc.levels = orig_rs, orig_lv
                if old is None:
                    del os.environ["XDG_RUNTIME_DIR"]
                else:
                    os.environ["XDG_RUNTIME_DIR"] = old
        self.assertTrue(line["grids"]["g"][0]["on"])
        self.assertEqual(line["vol"], 5)

    def test_snapshot_warm_is_false_without_a_cache(self):
        old = os.environ.get("XDG_RUNTIME_DIR")
        with tempfile.TemporaryDirectory() as d:
            os.environ["XDG_RUNTIME_DIR"] = d
            try:
                self.assertFalse(nc.Snapshot("").warm())
            finally:
                if old is None:
                    del os.environ["XDG_RUNTIME_DIR"]
                else:
                    os.environ["XDG_RUNTIME_DIR"] = old

    def test_query_only_change_uses_rerender_not_full_state(self):
        class Done(Exception):
            pass

        tick = [0]
        qs = ["", "", "wifi", "wifi", "wifi", "wifi"]

        def sleep(_):
            tick[0] += 1
            if tick[0] >= len(qs):
                raise Done

        emitted = []
        try:
            for line in nc.feed(lambda: "FULL", lambda: True, lambda: float(tick[0]), sleep,
                                query=lambda: qs[tick[0]], rerender=lambda: "CACHED", interval=100.0):
                emitted.append((tick[0], line))
        except Done:
            pass
        self.assertEqual(emitted, [(0, "FULL"), (2, "CACHED")])

    def test_snapshot_reuses_cached_state_across_queries(self):
        calls = {"state": 0, "levels": 0}
        orig_rs, orig_lv = nc.read_state, nc.levels
        nc.read_state = lambda grids, runner=None, prev=None: (calls.__setitem__("state", calls["state"] + 1) or
                                                    {"grids": {"g": [{"i": 0, "label": "WiFi", "toggle": True, "on": False}]}})
        nc.levels = lambda: (calls.__setitem__("levels", calls["levels"] + 1) or {"vol": 5, "muted": False, "bright": 7})
        old = os.environ.get("XDG_RUNTIME_DIR")
        with tempfile.TemporaryDirectory() as d:
            os.environ["XDG_RUNTIME_DIR"] = d
            try:
                snap = nc.Snapshot("")
                ns.write_query("wifi")
                first = json.loads(snap.full())
                ns.write_query("zzz")
                second = json.loads(snap.line())
            finally:
                nc.read_state, nc.levels = orig_rs, orig_lv
                if old is None:
                    del os.environ["XDG_RUNTIME_DIR"]
                else:
                    os.environ["XDG_RUNTIME_DIR"] = old
        self.assertEqual(calls, {"state": 1, "levels": 1})
        self.assertTrue(first["grids"]["g"][0]["match"])
        self.assertFalse(second["grids"]["g"][0]["match"])
        self.assertEqual((second["vol"], second["bright"]), (5, 7))


    def test_cached_reemit_does_not_postpone_the_full_refresh(self):
        class Done(Exception):
            pass

        tick = [0]
        qs = ["", "", "wifi"] + ["wifi"] * 6

        def sleep(_):
            tick[0] += 1
            if tick[0] >= 8:
                raise Done

        emitted = []
        try:
            for line in nc.feed(lambda: "FULL", lambda: True, lambda: float(tick[0]), sleep,
                                query=lambda: qs[tick[0]], rerender=lambda: "CACHED", interval=5.0):
                emitted.append((tick[0], line))
        except Done:
            pass
        self.assertEqual(emitted, [(0, "FULL"), (2, "CACHED"), (5, "FULL")])


if __name__ == "__main__":
    unittest.main()
