#!/usr/bin/env python3
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "yt-dlp-wait.py"


def run(output: str, code: int = 0, env: dict | None = None,
        args: tuple = ("-J", "x")) -> tuple[subprocess.CompletedProcess, float]:
    with tempfile.TemporaryDirectory() as tmp:
        fake = Path(tmp) / "yt-dlp"
        out = Path(tmp) / "out"
        out.write_text(output)
        fake.write_text(f'#!/bin/sh\ncat "{out}"\nexit {code}\n')
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        start = time.monotonic()
        proc = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True,
                              text=True, check=False,
                              env={**os.environ, "YT_DLP": str(fake), **(env or {})})
        return proc, time.monotonic() - start


class WaitTest(unittest.TestCase):
    def test_holds_until_selected_formats_open(self):
        at = time.time() + 2
        body = json.dumps({"format_id": "401+251", "formats": [
            {"format_id": "401", "available_at": at - 1},
            {"format_id": "251", "available_at": at}]})
        proc, took = run(body)
        self.assertEqual(proc.stdout, body)
        self.assertGreaterEqual(took, 2)

    def test_ignores_unselected_formats(self):
        body = json.dumps({"format_id": "251", "formats": [
            {"format_id": "251", "available_at": 0},
            {"format_id": "18", "available_at": time.time() + 60}]})
        self.assertLess(run(body)[1], 3)

    def test_flat_listing_passes_straight_through(self):
        body = json.dumps({"entries": [{"id": "a"}]})
        proc, took = run(body)
        self.assertEqual(proc.stdout, body)
        self.assertLess(took, 2)

    def test_failure_keeps_exit_code(self):
        proc, _ = run("not json", code=1)
        self.assertEqual((proc.stdout, proc.returncode), ("not json", 1))


class PopupTest(unittest.TestCase):
    WATCH = "https://www.youtube.com/watch?v=DZM95jNHWXU"

    def popped(self, *args: str, cached: bool = True) -> bool:
        with tempfile.TemporaryDirectory() as tmp:
            covers = Path(tmp) / "sqlch" / "youtube"
            covers.mkdir(parents=True)
            if cached:
                (covers / "DZM95jNHWXU.jpg").touch()
            mark = Path(tmp) / "popped"
            mpv = Path(tmp) / "mpv"
            mpv.write_text(f'#!/bin/sh\ntouch "{mark}"\n')
            mpv.chmod(0o755)
            at = time.time()  # gives the fake mpv the margin's second to run
            run(json.dumps({"format_id": "1", "formats": [{"format_id": "1", "available_at": at}]}),
                env={"XDG_CACHE_HOME": tmp, "POPUP_MPV": str(mpv)}, args=args)
            return mark.exists()

    def test_video_load_shows_cached_thumbnail(self):
        self.assertTrue(self.popped("-J", self.WATCH))

    def test_no_cached_thumbnail_no_window(self):
        self.assertFalse(self.popped("-J", self.WATCH, cached=False))

    def test_audio_load_no_window(self):
        self.assertFalse(self.popped("--format", "bestaudio/best", "-J", self.WATCH))

    def test_listing_no_window(self):
        self.assertFalse(self.popped("-J", "ytsearch25:golf"))


if __name__ == "__main__":
    unittest.main()
