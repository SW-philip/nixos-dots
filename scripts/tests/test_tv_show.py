#!/usr/bin/env python3
"""Standalone tests for tv-show.py: python3 scripts/tests/test_tv_show.py"""
import importlib.util
import io
import os
import stat
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("tv_show", HERE.parent / "tv-show.py")
tv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tv)

LEGO = "LEGO Friends The Next Chapter (2023)"
FSO = "Finding Stuff Out (2014)"


class Numbering(unittest.TestCase):
    def test_title_forms(self):
        cases = {
            "ZAC'S FIRST DAY AT HEARTLAKE 👋🙋 | S1E1 |  #FullEpisode | LEGO Friends The Next Chapter": (1, 1),
            "Fake News Frenzy! 📺 😱 | Season 3 Episode 1 | Full Episode | LEGO Friends: The Next Chapter": (3, 1),
            'Finding Stuff Out - "Insects" Season 1, Episode 2 (FULL EPISODE)': (1, 2),
            "Full Episode FINALE 🎬😂 Movie Ticket Chaos! | Season 3, Episode 20 | LEGO Friends": (3, 20),
        }
        for title, want in cases.items():
            self.assertEqual(tv.episode_number(title), want, title)

    def test_special_is_unnumbered(self):
        self.assertIsNone(tv.episode_number("NEW BEGINNINGS 🥳🎉 | S1 Special | #FullEpisode | LEGO"))


class Topic(unittest.TestCase):
    def test_quoted(self):
        self.assertEqual(tv.topic('Finding Stuff Out –＂Color＂ Season 1, Episode 1 (FULL EPISODE)', FSO), "Color")
        self.assertEqual(tv.topic('Finding Stuff Out – "Animals Big and Small" Season 1, Episode 10', FSO),
                         "Animals Big and Small")

    def test_segments(self):
        self.assertEqual(tv.topic("ZAC'S FIRST DAY AT HEARTLAKE 👋🙋 | S1E1 |  #FullEpisode | LEGO Friends The Next Chapter", LEGO),
                         "Zac's First Day At Heartlake")
        self.assertEqual(tv.topic("SPACE RACE COMPETITION 🚀🧑‍🚀🏅 | S2E2 | #FullEpisode | LEGO® Friends: The Next Chapter", LEGO),
                         "Space Race Competition")
        self.assertEqual(tv.topic("Pranks with Friends 🤪| Season 3 Episode 3 |Full Episode | LEGO Friends: The Next Chapter", LEGO),
                         "Pranks with Friends")

    def test_show_dash_name_dash_ep(self):
        msb = "The Magic School Bus (1994)"
        self.assertEqual(tv.topic("The Magic School Bus - Gets Lost in Space - Ep. 1", msb), "Gets Lost in Space")
        self.assertEqual(tv.topic("The Magic School Bus - Gets Ready, Set, Dough! - Ep. 4", msb), "Gets Ready, Set, Dough!")

    def test_slashes_never_make_dirs(self):
        self.assertNotIn("/", tv.topic('Show - "AC/DC" S1E1', "Show (2000)"))


class Plan(unittest.TestCase):
    def test_position_numbering_only_without_title_numbers(self):
        rows = [("a", 1, "Pilot", 60), ("b", 2, "Second", 60)]
        self.assertEqual([p[1:3] for p in tv.plan(rows, "X (2000)", 2)], [(2, 1), (2, 2)])
        rows = [("a", 1, "Pilot | S1E1", 60), ("b", 2, "Trailer", 60)]
        self.assertEqual([p[1:3] for p in tv.plan(rows, "X (2000)", None)], [(1, 1), (None, None)])


FAKE = """#!/usr/bin/env python3
import sys
args = sys.argv[1:]
if "--flat-playlist" in args:
    print("v1\\t1\\tShow - \\"Color\\" Season 1, Episode 1\\t1260")
    print("v2\\t2\\tShow - \\"Insects\\" Season 1, Episode 2\\t1260")
    print("v3\\t3\\tBehind the scenes\\t60")
    sys.exit(0)
out = args[args.index("-o") + 1].replace("%(ext)s", "mkv")
open(out, "w").close()
arch = args[args.index("--download-archive") + 1]
open(arch, "a").write("youtube " + args[-1].split("=")[-1] + "\\n")
"""


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        fake = self.tmp / "yt-dlp"
        fake.write_text(FAKE)
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        tv.YT_DLP = str(fake)
        tv.TV_ROOT = self.tmp / "tv"
        tv.LIST_DIR = self.tmp / "lists"
        tv.LIST_DIR.mkdir()
        tv.minutes = lambda p: 21.0

    def run_tv(self, *argv):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = tv.main(list(argv))
        return rc, buf.getvalue()

    def test_fetch_then_rerun_skips(self):
        season = tv.TV_ROOT / "Show (2014)" / "Season 01"
        season.mkdir(parents=True)
        (season / "Show - S01E01 - Color.mkv").touch()   # filed by hand earlier

        rc, out = self.run_tv("Show (2014)", "https://youtube.com/playlist?list=P&si=xyz")
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(p.name for p in season.iterdir()),
                         ["Show - S01E01 - Color.mkv", "Show - S01E02 - Insects.mkv"])
        self.assertIn("S01E01 already on disk", out)
        self.assertIn("skipped: Behind the scenes", out)
        self.assertIn('"Show" = { eps = 2; mins = 21.0; };', out)
        self.assertIn("https://youtube.com/playlist?list=P\n",
                      (tv.LIST_DIR / "show-show.txt").read_text())

        rc, out = self.run_tv("Show (2014)")             # bare rerun reads the list
        self.assertEqual(rc, 0)
        self.assertNotIn("S01E02 already on disk", out)  # archived, so not even checked
        self.assertNotIn("would fetch", out)

    def test_leftover_stream_piece_is_not_an_episode(self):
        season = tv.TV_ROOT / "Show (2014)" / "Season 01"
        season.mkdir(parents=True)
        (season / "Show - S01E01 - Color.f399.mp4").touch()
        _, out = self.run_tv("Show (2014)", "https://youtube.com/playlist?list=P")
        self.assertNotIn("already on disk", out)
        self.assertTrue((season / "Show - S01E01 - Color.mkv").exists())

    def test_taken_slot_does_not_archive_the_other_video(self):
        season = tv.TV_ROOT / "Show (2014)" / "Season 01"
        season.mkdir(parents=True)
        (season / "Other Show - S01E01 - Something Else.mkv").touch()
        self.run_tv("Show (2014)", "https://youtube.com/playlist?list=P")
        archive = (tv.TV_ROOT / "Show (2014)" / ".archive").read_text()
        self.assertNotIn("youtube v1", archive)
        self.assertIn("youtube v2", archive)

    def test_two_playlists_cannot_share_a_slot(self):
        tv.LIST_DIR.joinpath("show-show.txt").write_text("u1 1\nu2 1\n")   # same season by mistake
        rc, out = self.run_tv("Show (2014)", "--dry-run")
        self.assertEqual(rc, 1)
        self.assertEqual(out.count("would fetch: Season 01/Show - S01E01"), 1)

    def test_dry_run_writes_nothing(self):
        rc, out = self.run_tv("Show (2014)", "https://youtube.com/playlist?list=P", "--dry-run")
        self.assertEqual(rc, 0)
        self.assertIn("would fetch: Season 01/Show - S01E01 - Color.mkv", out)
        self.assertFalse((tv.TV_ROOT / "Show (2014)").exists())
        self.assertFalse((tv.LIST_DIR / "show-show.txt").exists())

    def test_year_required(self):
        with self.assertRaises(SystemExit), redirect_stdout(io.StringIO()), \
                open(os.devnull, "w") as null, __import__("contextlib").redirect_stderr(null):
            tv.main(["Show", "u"])


if __name__ == "__main__":
    unittest.main()
