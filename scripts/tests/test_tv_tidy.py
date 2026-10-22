#!/usr/bin/env python3
"""Standalone tests for tv-tidy.
Run: python3 scripts/tests/test_tv_tidy.py"""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_spec = importlib.util.spec_from_file_location(
    "tv_tidy", Path(__file__).resolve().parents[1] / "tv-tidy.py")
t = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(t)


class TestEpisode(unittest.TestCase):
    def test_forms(self):
        cases = {
            "Community S01E04 Social Psychology  [1080p x265 10bit Joy].mkv": "S01E04",
            "Better.Off.Ted.1x02.Mr.Risolve.Problemi (Heroes).mkv": "S01E02",
            "The.IT.Crowd.Season.4.Episode.5.Bad.Boys.H265.mkv": "S04E05",
            "show.s1e2e3.mkv": "S01E02-E03",
            "Euphoria US S03E06 2160p HDR H 265-Kitsune.mkv": "S03E06",
        }
        for name, want in cases.items():
            self.assertEqual(t.episode(name), want, name)

    def test_codec_is_not_an_episode(self):
        self.assertIsNone(t.episode("Gag Reel (1080p x265 10bit).mkv"))
        self.assertIsNone(t.episode("Community S01 - Outtakes 1.mkv"))


def build(root, files):
    for rel in files:
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(rel)


class TestTarget(unittest.TestCase):
    def check(self, files, want):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for rel, body in files.items():
                p = root / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(body)
            moves, problems = t.plan(root)
            got = {str(s.relative_to(root)): str(d.relative_to(root)) for s, d in moves}
            got.update({str(s.relative_to(root)): why for s, why in problems})
            self.assertEqual(got, want)

    def test_metadata_is_kept(self):
        xml = '<?xml version="1.0"?><episodedetails/>'
        self.check({
            "Bluey (2020)/tvshow.nfo": xml,
            "Bluey (2020)/poster.jpg": "",
            "Bluey (2020)/rel/Bluey.S01E01.mkv": "",
            "Bluey (2020)/rel/Bluey.S01E01.nfo": xml,
            "Bluey (2020)/rel/scene.nfo": "Title : Bluey",
            "Bluey (2020)/rel/theme.flac": "",
        }, {
            "Bluey (2020)/rel/Bluey.S01E01.mkv": "Bluey (2020)/Season 01/Bluey (2020) S01E01.mkv",
            "Bluey (2020)/rel/Bluey.S01E01.nfo": "Bluey (2020)/Season 01/Bluey (2020) S01E01.nfo",
            "Bluey (2020)/rel/scene.nfo": ".tv-tidy-junk/Bluey (2020)/rel/scene.nfo",
            "Bluey (2020)/rel/theme.flac": "unrecognised file type, left alone",
        })

    def test_absolute_number_in_season_folder(self):
        self.check({
            "Pokemon (1997)/Season 01 - Indigo League/[AT] Pokemon - 024 - Haunter.mkv": "",
            "Toca (2020)/01 - ZEKE GOES VIRAL.mp4": "",
            "Toca Life Stories (2020)/02 - HELPFUL RITA.mp4": "",
            "MBAM (1994)/Season 1/My Brother and Me - Ep. 02 - The War (480p).mp4": "",
            "Sago (2022)/rel/Subs/Sago.S01E03.1080p/2_English.srt": "",
        }, {
            "MBAM (1994)/Season 1/My Brother and Me - Ep. 02 - The War (480p).mp4":
                "MBAM (1994)/Season 01/MBAM (1994) S01E02.mp4",
            "Sago (2022)/rel/Subs/Sago.S01E03.1080p/2_English.srt":
                "Sago (2022)/Season 01/Sago (2022) S01E03.2_English.srt",
            "Pokemon (1997)/Season 01 - Indigo League/[AT] Pokemon - 024 - Haunter.mkv":
                "Pokemon (1997)/Season 01/Pokemon (1997) S01E24.mkv",
            "Toca (2020)/01 - ZEKE GOES VIRAL.mp4": "video with no episode number, left alone",
            "Toca Life Stories (2020)/02 - HELPFUL RITA.mp4":
                "Toca Life Stories (2020)/Season 01/Toca Life Stories (2020) S01E02.mp4",
        })


class TestTitles(unittest.TestCase):
    EPS = (("S01E02", "Up All Night"), ("S01E12", "Fish and Dips"),
           ("S01E15", "Mission to the Big Hot Thingy"), ("S02E05", "Muscular Beaver II"),
           ("S03E06", "Up All Night II: Up All Day: The Reckoning"),
           ("S03E09", "In Search of Big Byoo-Tox"), ("S03E14", "A Little Dad'll Do You"))

    def test_match(self):
        eps = [(tag, t._norm(name), name) for tag, name in self.EPS]
        show = "The Angry Beavers (1997)"
        cases = {
            "Angry Beavers - Up All Night.mp4": "S01E02",
            "Angry Beavers - Up All Night 2- Up A.mp4": "S03E06",
            "Angry Beavers - Mission to the Big H.mp4": "S01E15",
            "Angry Beavers - Muscular Beaver 2.mp4": "S02E05",
            "Angry Beavers - Big Byoo-tox.mp4": "S03E09",
            "Angry Beavers - A Little Dad-ll Do Y.mp4": "S03E14",
            "The Angry Beavers - Fish Dips.mp4": "S01E12",
            "Angry Beavers - Christmas Special.mp4": None,
        }
        with mock.patch.object(t, "tvmaze_episodes", lambda _: eps):
            for name, want in cases.items():
                self.assertEqual(t.title_episode(show, Path(name))[0], want, name)

    def test_only_with_flag(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            build(root, ["Angry Beavers/Angry Beavers - Up All Night.mp4"])
            with mock.patch.object(t, "tvmaze_episodes", lambda _: [("S01E02", "upallnight", "")]):
                self.assertEqual(t.plan(root)[0], [])
                (_, dst), = t.plan(root, titles=True)[0]
            self.assertEqual(dst.name, "The Angry Beavers (1997) S01E02.mp4")


class TestRoundTrip(unittest.TestCase):
    FILES = (
        "community/Community Season 1  [Joy]/Community S01E01 Pilot  [Joy].mkv",
        "community/Community Season 1  [Joy]/Featurettes/Community S01 - Outtakes 1.mkv",
        "community/Community Season 1  [Joy]/info.txt",
        "Firefly (2002)/Season 1/Firefly (2002) - S01E03 - Bushwhacked.mkv",
        "game_of_thrones/GoT S03/Game.Of.Thrones.S03E02.1080p.srt",
        "game_of_thrones/GoT S03/Game.Of.Thrones.S03E02.1080p.mkv",
        "Mystery Show/ep1.mkv",
        "Sago (2022)/rel/Subs/Sago.S01E03.1080p/2_English.srt",
        "Sago (2022)/rel/Subs/Sago.S01E03.1080p/3_English.srt",
    )

    def test_apply_then_undo(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "tv"
            build(root, self.FILES)
            moves, problems = t.plan(root)
            dsts = {str(dst.relative_to(root)) for _, dst in moves}
            self.assertEqual(dsts, {
                "Community (2009)/Season 01/Community (2009) S01E01.mkv",
                "Community (2009)/extras/Community S01 - Outtakes 1.mkv",
                ".tv-tidy-junk/community/Community Season 1  [Joy]/info.txt",
                "Firefly (2002)/Season 01/Firefly (2002) S01E03.mkv",
                "Game of Thrones (2011)/Season 03/Game of Thrones (2011) S03E02.srt",
                "Game of Thrones (2011)/Season 03/Game of Thrones (2011) S03E02.mkv",
                "Sago (2022)/Season 01/Sago (2022) S01E03.2_English.srt",
                "Sago (2022)/Season 01/Sago (2022) S01E03.3_English.srt",
            })
            self.assertEqual([p.name for p, _ in problems], ["Mystery Show"])

            with mock.patch.object(t, "STATE", Path(d) / "state"):
                t.apply(root, moves)
                self.assertFalse((root / "community").exists())
                self.assertFalse((root / "Firefly (2002)" / "Season 1").exists())
                self.assertEqual(t.plan(root)[0], [])
                self.assertEqual([p.name for p, _ in t.plan(root)[1]], ["Mystery Show"])
                t.undo(next((Path(d) / "state").iterdir()))
            for rel in self.FILES:
                self.assertEqual((root / rel).read_text(), rel)
            self.assertFalse((root / "Community (2009)").exists())

    def test_collision_moves_neither(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            build(root, ["community/a/Community S01E01.mkv",
                         "community/b/Community S01E01 REPACK.mkv"])
            moves, problems = t.plan(root)
            self.assertEqual(moves, [])
            self.assertEqual(len(problems), 2)


if __name__ == "__main__":
    unittest.main()
