import os
import re
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import quivr_view as qv  # noqa: E402

LINE = "cpu=38 mem_used=2516582 mem_total=7969177 load=0.52 temp=54 rx=12288 tx=3481 disk=51 up=270000 cpus=4"
PALETTE = ('export REST="#0a141e"\nexport ROOT="#646e78"\nexport FERMATA="#c8d2dc"\nexport FORTE="#fa0000"\n')


def palette(text=PALETTE):
    f = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
    f.write(text)
    f.close()
    c = qv.make_colours(f.name)
    os.unlink(f.name)
    return c


class Formatting(unittest.TestCase):
    def test_parse_sample(self):
        s = qv.parse_sample(LINE)
        self.assertEqual((s["cpu"], s["load"], s["temp"], s["up"], s["cpus"]), (38, 0.52, 54, 270000, 4))

    def test_parse_sample_without_cpus_or_sensor(self):
        s = qv.parse_sample(LINE.replace(" cpus=4", "").replace("temp=54", "temp=-"))
        self.assertEqual(s["cpus"], 1)
        self.assertIsNone(s["temp"])

    def test_parse_sample_rejects_garbage(self):
        for bad in ("hello world", "cpu=abc mem_used=1", ""):
            self.assertIsNone(qv.parse_sample(bad))

    def test_norm(self):
        self.assertEqual(qv.norm(30, 30, 90), 0.0)
        self.assertEqual(qv.norm(60, 30, 90), 0.5)
        self.assertEqual(qv.norm(200, 30, 90), 1.0)
        self.assertEqual(qv.norm(-5, 0, 100), 0.0)

    def test_plain_bar(self):
        self.assertEqual(qv.bar(0), "░" * 10)
        self.assertEqual(qv.bar(50), "█" * 5 + "░" * 5)
        self.assertEqual(qv.bar(100), "█" * 10)
        self.assertEqual(qv.bar(250), "█" * 10)
        self.assertEqual(qv.bar(-5), "░" * 10)

    def test_fmt_rate_mem_uptime(self):
        self.assertEqual(qv.fmt_rate(0), "0B")
        self.assertEqual(qv.fmt_rate(1023), "1023B")
        self.assertEqual(qv.fmt_rate(1024), "1.0K")
        self.assertEqual(qv.fmt_rate(10240), "10K")
        self.assertEqual(qv.fmt_rate(1572864), "1.5M")
        self.assertEqual(qv.fmt_mem(2516582, 7969177), "2.4G/7.6G")
        self.assertEqual(qv.fmt_uptime(59), "0m")
        self.assertEqual(qv.fmt_uptime(18000), "5h")
        self.assertEqual(qv.fmt_uptime(270000), "3d")


class Heat(unittest.TestCase):
    def test_missing_palette_is_plain(self):
        c = qv.make_colours("/nonexistent/palette.sh")
        self.assertEqual((c.rs, c.bold, c.dim, c.accent, c.heat(0.5)), ("",) * 5)

    def test_partial_palette_is_plain(self):
        c = palette('export REST="#0a141e"\n')
        self.assertEqual(c.heat(0.5), "")

    def test_anchors(self):
        c = palette()
        self.assertEqual(c.heat(0.0), "\x1b[2m\x1b[38;2;10;20;30m")        # REST, faint
        self.assertEqual(c.heat(0.35), "\x1b[38;2;100;110;120m")           # ROOT
        self.assertEqual(c.heat(1.0), "\x1b[1;4m\x1b[38;2;250;0;0m")       # FORTE, bold+underline

    def test_blend_midpoint(self):
        self.assertEqual(palette().heat(0.525), "\x1b[38;2;150;160;170m")

    def test_clamps(self):
        c = palette()
        self.assertEqual(c.heat(-1), c.heat(0.0))
        self.assertEqual(c.heat(2), c.heat(1.0))

    def test_attribute_bands(self):
        c = palette()
        self.assertTrue(c.heat(0.1).startswith("\x1b[2m"))
        self.assertFalse(c.heat(0.5).startswith("\x1b["+"1") or c.heat(0.5).startswith("\x1b[2m"))
        self.assertTrue(c.heat(0.8).startswith("\x1b[1m"))
        self.assertTrue(c.heat(0.95).startswith("\x1b[1;4m"))

    def test_heat_without_attrs(self):
        self.assertEqual(palette().heat(1.0, attrs=False), "\x1b[38;2;250;0;0m")

    def test_bar_cells_follow_their_position(self):
        c = palette()
        b = qv.bar(100, 10, c)
        self.assertTrue(b.startswith(c.heat(0.05, attrs=False) + "█"))
        self.assertIn(c.heat(0.95, attrs=False) + "█", b)
        low = qv.bar(10, 10, c)
        self.assertNotIn(c.heat(0.95, attrs=False), low)
        self.assertIn("░", low)

    def test_no_hex_literals_in_the_viewer_code(self):
        for name in ("quivr.py", "quivr_view.py"):
            with open(os.path.join(HERE, "..", name)) as f:
                self.assertIsNone(re.search(r"#[0-9a-fA-F]{6}", f.read()), name)


class Rendering(unittest.TestCase):
    def setUp(self):
        self.c = qv.make_colours("/nonexistent")
        self.s = qv.parse_sample(LINE)

    def test_up_row(self):
        row = qv.render_row("desktop", "up", self.s, self.c)
        for part in ("● desktop", "cpu", "38%", "2.4G/7.6G", "0.52", "54°", "↓", "12K", "↑", "3.4K", "51%", "3d"):
            self.assertIn(part, row)

    def test_selected_marker(self):
        self.assertTrue(qv.render_row("pi", "up", self.s, self.c, selected=True).startswith("▸ "))
        self.assertTrue(qv.render_row("pi", "up", self.s, self.c).startswith("  "))

    def test_missing_sensor_row(self):
        self.assertIn("—", qv.render_row("pi", "up", dict(self.s, temp=None), self.c))

    def test_wait_row(self):
        row = qv.render_row("retro", "wait", None, self.c)
        self.assertIn("reconnecting", row)
        self.assertNotIn("cpu", row)

    def test_compact_drops_net_and_disk(self):
        row = qv.render_row("desktop", "up", self.s, self.c, compact=True)
        self.assertNotIn("↓", row)
        self.assertNotIn("disk", row)

    def test_load_heat_uses_core_count(self):
        c = palette()
        busy = qv.render_row("a", "up", dict(self.s, load=4.0, cpus=4), c)
        idle = qv.render_row("a", "up", dict(self.s, load=0.4, cpus=4), c)
        self.assertIn(c.heat(1.0) + " 4.00", busy)
        self.assertNotIn(c.heat(1.0) + " 0.40", idle)

    def test_frame(self):
        rows = [("desktop", "up", self.s), ("retro", "wait", None)]
        lines = qv.render_frame(rows, 0, self.c, 140, selected=0).split("\n")
        self.assertIn("quivr", lines[0])
        self.assertTrue(any(ln.startswith("▸ ● desktop") for ln in lines))
        self.assertTrue(any("reconnecting" in ln for ln in lines))
        self.assertIn("q quit", lines[-1])


if __name__ == "__main__":
    unittest.main()
