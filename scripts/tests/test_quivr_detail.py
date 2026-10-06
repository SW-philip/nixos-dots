import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import quivr_detail as qd  # noqa: E402
import quivr_view as qv  # noqa: E402

FRAME = """@frame 1000
core 0 20
core 1 91
net eth0 2000 1000
net tailscale0 10 10
mount 50 500000 1000000 /
mount 10 20000 200000 /mnt/my disk
io nvme0n1 1048576 2097152
pcpu 1234 alice 100.0 2000 my prog
pcpu 77 root 10.0 40 kworker/0:1
pmem 9 4242 0.0 200000 idle (thing)
future 1 2 3
@end
"""


def read(text):
    r = qd.FrameReader()
    out = None
    for line in text.splitlines():
        out = r.feed(line) or out
    return out


def palette():
    f = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
    f.write('export REST="#0a141e"\nexport ROOT="#646e78"\nexport FERMATA="#c8d2dc"\nexport FORTE="#fa0000"\n')
    f.close()
    c = qv.make_colours(f.name)
    os.unlink(f.name)
    return c


class Frames(unittest.TestCase):
    def test_parse_frame(self):
        fr = read(FRAME)
        self.assertEqual(fr["at"], 1000)
        self.assertEqual(fr["cores"], [(0, 20), (1, 91)])
        self.assertEqual(fr["net"][0], ("eth0", 2000, 1000))
        self.assertEqual(fr["mounts"][1], ("/mnt/my disk", 10, 20000, 200000))
        self.assertEqual(fr["io"], [("nvme0n1", 1048576, 2097152)])
        self.assertEqual(fr["pcpu"][0], (1234, "alice", 100.0, 2000, "my prog"))
        self.assertEqual(fr["pmem"][0], (9, "4242", 0.0, 200000, "idle (thing)"))

    def test_unknown_and_malformed_lines_are_ignored(self):
        fr = read("@frame 5\ncore x y\nnet eth0 1\nbogus\ncore 0 5\n@end\n")
        self.assertEqual(fr["cores"], [(0, 5)])
        self.assertEqual(fr["net"], [])

    def test_truncated_frame_is_discarded(self):
        r = qd.FrameReader()
        for line in ("@frame 1", "core 0 50", "@frame 2", "core 0 9", "@end"):
            out = r.feed(line)
        self.assertEqual(out["at"], 2)
        self.assertEqual(out["cores"], [(0, 9)])

    def test_lines_before_a_frame_are_ignored(self):
        r = qd.FrameReader()
        self.assertIsNone(r.feed("core 0 5"))
        self.assertIsNone(r.feed("@end"))


class Rendering(unittest.TestCase):
    def setUp(self):
        self.c = qv.make_colours("/nonexistent")
        self.fr = read(FRAME)

    def test_sections_and_content(self):
        out = qd.render_detail("desktop", self.fr, 1, 8000000, self.c, 120, 40)
        for part in ("quivr", "desktop", "CPU", " 0 ", "20%", "91%", "NETWORK", "eth0", "DISKS",
                     "/mnt/my disk", "nvme0n1", "PROCESSES by CPU", "PROCESSES by MEMORY",
                     "alice", "my prog", "idle (thing)", "esc back"):
            self.assertIn(part, out)

    def test_header_has_no_overview_row_repeat(self):
        out = qd.render_detail("desktop", self.fr, 1, 8000000, self.c, 120, 40)
        self.assertNotIn("load", out)
        self.assertNotIn("up ", out.split("\n")[0])

    def test_connecting(self):
        out = qd.render_detail("retro", None, 0, 0, self.c, 120, 40)
        self.assertIn("retro", out)
        self.assertIn("connecting", out)

    def test_height_is_respected(self):
        for h in (10, 14, 20, 30, 60):
            lines = qd.render_detail("desktop", self.fr, 1, 8000000, self.c, 120, h).split("\n")
            self.assertLessEqual(len(lines), h, h)

    def test_short_terminal_drops_the_memory_table_first(self):
        out = qd.render_detail("desktop", self.fr, 1, 8000000, self.c, 120, 22)
        self.assertIn("PROCESSES by CPU", out)
        self.assertNotIn("PROCESSES by MEMORY", out)

    def test_core_columns_follow_width(self):
        many = dict(self.fr, cores=[(i, 10) for i in range(8)])
        wide = qd.render_detail("d", many, 0, 1, self.c, 140, 50).split("\n")
        narrow = qd.render_detail("d", many, 0, 1, self.c, 40, 50).split("\n")
        self.assertLess(len(wide), len(narrow))

    def test_heat_colours_hot_values(self):
        c = palette()
        out = qd.render_detail("desktop", self.fr, 1, 8000000, c, 120, 40)
        self.assertIn(c.heat(0.91) + " 91%", out)

    def test_age_text(self):
        self.assertIn("2s old", qd.render_detail("d", self.fr, 2, 1, self.c, 120, 40))


class Keys(unittest.TestCase):
    def test_arrows_and_enter(self):
        self.assertEqual(qd.parse_key("\x1b[A"), ("up", ""))
        self.assertEqual(qd.parse_key("\x1b[B"), ("down", ""))
        self.assertEqual(qd.parse_key("\x1b[C"), ("right", ""))
        self.assertEqual(qd.parse_key("\x1b[D"), ("left", ""))
        self.assertEqual(qd.parse_key("\x1bOA"), ("up", ""))
        self.assertEqual(qd.parse_key("\r"), ("enter", ""))
        self.assertEqual(qd.parse_key("\n"), ("enter", ""))

    def test_bare_escape_and_chars(self):
        self.assertEqual(qd.parse_key("\x1b"), ("esc", ""))
        self.assertEqual(qd.parse_key("]"), ("]", ""))
        self.assertEqual(qd.parse_key("tq"), ("t", "q"))
        self.assertEqual(qd.parse_key("\x1b[Aj"), ("up", "j"))

    def test_unknown_escape_sequence_is_swallowed(self):
        self.assertEqual(qd.parse_key("\x1b[3~x"), ("?", "x"))


class Navigation(unittest.TestCase):
    def new(self, **kw):
        return dict({"mode": "overview", "sel": 0, "quit": False, "top": False}, **kw)

    def test_overview_selection_wraps(self):
        s = qd.handle_key(self.new(), "up", 4)
        self.assertEqual(s["sel"], 3)
        s = qd.handle_key(s, "down", 4)
        self.assertEqual(s["sel"], 0)
        self.assertEqual(qd.handle_key(self.new(), "j", 4)["sel"], 1)
        self.assertEqual(qd.handle_key(self.new(), "k", 4)["sel"], 3)

    def test_open_and_back(self):
        s = qd.handle_key(self.new(sel=2), "enter", 4)
        self.assertEqual((s["mode"], s["sel"]), ("detail", 2))
        for back in ("esc", "left", "h"):
            self.assertEqual(qd.handle_key(s, back, 4)["mode"], "overview")

    def test_detail_steps_hosts(self):
        s = self.new(mode="detail", sel=3)
        self.assertEqual(qd.handle_key(s, "]", 4)["sel"], 0)
        self.assertEqual(qd.handle_key(s, "[", 4)["sel"], 2)

    def test_top_and_quit(self):
        self.assertTrue(qd.handle_key(self.new(mode="detail"), "t", 4)["top"])
        self.assertFalse(qd.handle_key(self.new(), "t", 4)["top"])
        self.assertTrue(qd.handle_key(self.new(), "q", 4)["quit"])
        self.assertTrue(qd.handle_key(self.new(mode="detail"), "q", 4)["quit"])

    def test_input_state_is_not_mutated(self):
        s = self.new()
        qd.handle_key(s, "down", 4)
        self.assertEqual(s["sel"], 0)


if __name__ == "__main__":
    unittest.main()
