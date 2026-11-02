import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, HERE)
import quivr_cards as qc
import quivr_view as qv
from test_quivr_view import LINE, palette


class Sparkline(unittest.TestCase):
    def setUp(self):
        self.c = qv.make_colours("/nonexistent")

    def test_bucket_leaves_a_short_series_alone(self):
        self.assertEqual(qc.bucket([1, 2, 3], 16), [1, 2, 3])

    def test_bucket_keeps_a_spike(self):
        values = [0] * 100 + [90] + [0] * 99
        out = qc.bucket(values, 10)
        self.assertEqual(len(out), 10)
        self.assertEqual(max(out), 90)

    def test_bucket_with_mean(self):
        self.assertEqual(qc.bucket([0, 10, 0, 10], 2, agg=qc.mean), [5.0, 5.0])

    def test_sparkline_scale(self):
        self.assertEqual(qc.sparkline([0, 50, 100], 100, self.c, width=3), "▁▅█")

    def test_sparkline_left_pads_a_short_series(self):
        self.assertEqual(qc.sparkline([100], 100, self.c, width=4), "   █")

    def test_sparkline_clamps_above_the_scale(self):
        self.assertEqual(qc.sparkline([500], 100, self.c, width=1), "█")


class HistoryRing(unittest.TestCase):
    def sample(self, cpu, rx, tx):
        return {"cpu": cpu, "rx": rx, "tx": tx}

    def test_keeps_only_the_newest(self):
        h = qc.History(maxlen=3)
        for i in range(5):
            h.push(self.sample(i, i * 10, i))
        snap = h.snapshot()
        self.assertEqual(snap["cpu"], [2, 3, 4])
        self.assertEqual(snap["net"], [22, 33, 44])

    def test_snapshot_is_a_copy(self):
        h = qc.History()
        h.push(self.sample(1, 2, 3))
        snap = h.snapshot()
        h.push(self.sample(4, 5, 6))
        self.assertEqual(snap["cpu"], [1])


HIST = {"cpu": [10, 20, 38], "net": [1000, 20000, 15769]}
EXTREME = {"cpu": 100, "mem_used": 32717824, "mem_total": 32717824, "load": 12.34, "temp": 100,
           "rx": 900 * 1024 * 1024, "tx": 900 * 1024 * 1024, "disk": 100, "up": 9999999, "cpus": 4}


class Card(unittest.TestCase):
    def setUp(self):
        self.c = qv.make_colours("/nonexistent")
        self.s = qv.parse_sample(LINE)

    def card(self, **kw):
        return "\n".join(qc.render_card("desktop", "up", self.s, HIST, self.c, **kw))

    def test_up_card(self):
        text = self.card()
        for part in ("● desktop", "cpu", "38%", "2.4G/7.6G", "0.52", "54°", "↓", "12K", "↑", "3.4K", "51%", "3d"):
            self.assertIn(part, text)

    def test_selected_marker(self):
        self.assertTrue(qc.render_card("pi", "up", self.s, HIST, self.c, selected=True)[0].startswith("▸ "))
        self.assertTrue(qc.render_card("pi", "up", self.s, HIST, self.c)[0].startswith("  "))

    def test_missing_sensor(self):
        s = dict(self.s, temp=None)
        self.assertIn("—", "\n".join(qc.render_card("pi", "up", s, HIST, self.c)))

    def test_wait_card_is_four_lines_without_stats(self):
        lines = qc.render_card("retro", "wait", None, HIST, self.c)
        self.assertEqual(len(lines), 4)
        self.assertIn("reconnecting", "\n".join(lines))
        self.assertNotIn("cpu", "\n".join(lines))

    def test_up_card_is_four_lines(self):
        self.assertEqual(len(qc.render_card("desktop", "up", self.s, HIST, self.c)), 4)

    def test_load_heat_uses_core_count(self):
        c = palette()
        busy = "\n".join(qc.render_card("a", "up", dict(self.s, load=4.0, cpus=4), HIST, c))
        idle = "\n".join(qc.render_card("a", "up", dict(self.s, load=0.4, cpus=4), HIST, c))
        self.assertIn(c.heat(1.0) + " 4.00", busy)
        self.assertNotIn(c.heat(1.0) + " 0.40", idle)

    def test_no_line_outruns_the_card_width(self):
        for c in (self.c, palette()):
            for line in qc.render_card("desktop", "up", EXTREME, HIST, c, selected=True):
                self.assertLessEqual(qc.vlen(line), qc.CARD_WIDTH, line)


class Frame(unittest.TestCase):
    def setUp(self):
        self.c = qv.make_colours("/nonexistent")
        self.s = qv.parse_sample(LINE)
        self.rows = [(n, "up", self.s, HIST) for n in ("desktop", "surface", "retro", "pi")]

    def frame(self, width, selected=0):
        return qc.render_frame(self.rows, 0, self.c, width, selected=selected).split("\n")

    def test_header_and_footer(self):
        lines = self.frame(140)
        self.assertIn("quivr", lines[0])
        self.assertIn("q quit", lines[-2])
        self.assertIn("1 ship", lines[-1])
        self.assertLess(lines[-1].index("ship"), lines[-1].index("deploy"))
        self.assertLess(lines[-1].index("deploy"), lines[-1].index("release"))

    def test_selected_card_starts_a_line(self):
        self.assertTrue(any(ln.startswith("▸ ● desktop") for ln in self.frame(140)))

    def test_wide_terminal_is_a_two_column_grid(self):
        lines = self.frame(140)
        self.assertTrue(any("desktop" in ln and "surface" in ln for ln in lines))
        self.assertTrue(any("retro" in ln and "pi" in ln for ln in lines))

    def test_grid_threshold(self):
        self.assertTrue(any("desktop" in ln and "surface" in ln for ln in self.frame(qc.GRID_MIN_WIDTH)))
        self.assertFalse(any("desktop" in ln and "surface" in ln for ln in self.frame(qc.GRID_MIN_WIDTH - 1)))

    def test_narrow_terminal_is_one_column(self):
        lines = self.frame(80)
        self.assertFalse(any("desktop" in ln and "surface" in ln for ln in lines))
        self.assertTrue(any("surface" in ln for ln in lines))

    def test_a_waiting_host_keeps_the_grid_aligned(self):
        rows = [("desktop", "up", self.s, HIST), ("retro", "wait", None, HIST)]
        lines = qc.render_frame(rows, 0, self.c, 140).split("\n")
        self.assertTrue(any("reconnecting" in ln for ln in lines))
        self.assertTrue(any("desktop" in ln and "retro" in ln for ln in lines))


class Gaps(unittest.TestCase):
    def setUp(self):
        self.c = qv.make_colours("/nonexistent")

    def test_bucket_ignores_gaps_and_keeps_an_all_gap_slice(self):
        self.assertEqual(qc.bucket([1, None, None, None], 2), [1, None])

    def test_sparkline_draws_a_gap_as_a_dot(self):
        self.assertEqual(qc.sparkline([100, None, 100], 100, self.c, width=3), "█·█")

    def test_history_gap_marker(self):
        h = qc.History()
        h.mark_gap()
        self.assertEqual(h.snapshot()["cpu"], [])
        h.push({"cpu": 1, "rx": 2, "tx": 3})
        h.mark_gap()
        h.mark_gap()
        h.push({"cpu": 4, "rx": 5, "tx": 6})
        snap = h.snapshot()
        self.assertEqual(snap["cpu"], [1, None, 4])
        self.assertEqual(snap["net"], [5, None, 11])

    def test_card_survives_a_gap_in_the_history(self):
        hist = {"cpu": [10, None, 20], "net": [None, 5, 5]}
        s = qv.parse_sample(LINE)
        self.assertEqual(len(qc.render_card("a", "up", s, hist, self.c)), 4)


class Overflow(unittest.TestCase):
    def setUp(self):
        self.c = qv.make_colours("/nonexistent")
        self.s = qv.parse_sample(LINE)

    def test_long_hostname_is_clipped_to_the_card(self):
        name = "a-very-long-hostname-that-would-overflow-the-card-header"
        for state, s in (("up", self.s), ("wait", None)):
            head = qc.render_card(name, state, s, HIST, self.c)[0]
            self.assertLessEqual(qc.vlen(head), qc.CARD_WIDTH, head)
            self.assertIn("…", head)

    def test_temp_and_load_keep_a_separator(self):
        hot = dict(self.s, load=12.34, temp=100)
        self.assertIn("12.34 100°", qc.render_card("a", "up", hot, HIST, self.c)[1])

    def test_missing_sensor_is_as_wide_as_a_reading(self):
        with_temp = qc.render_card("a", "up", self.s, HIST, self.c)[1]
        without = qc.render_card("a", "up", dict(self.s, temp=None), HIST, self.c)[1]
        self.assertEqual(qc.vlen(with_temp), qc.vlen(without))


if __name__ == "__main__":
    unittest.main()
