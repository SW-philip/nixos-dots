#!/usr/bin/env python3
"""Standalone tests for waybar-sqlch's resolve_cover_path() cover-art
caching logic.
Run: python3 home/waybar/scripts/test_waybar_sqlch.py"""
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_loader = importlib.machinery.SourceFileLoader(
    "waybar_sqlch", str(Path(__file__).with_name("waybar-sqlch")))
_spec = importlib.util.spec_from_loader("waybar_sqlch", _loader)
waybar_sqlch = importlib.util.module_from_spec(_spec)
_loader.exec_module(waybar_sqlch)


class TestResolveCoverPath(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        orig = waybar_sqlch.CACHE_DIR
        waybar_sqlch.CACHE_DIR = Path(self.tmp.name)
        self.addCleanup(setattr, waybar_sqlch, "CACHE_DIR", orig)

    def test_none_url_returns_none(self):
        self.assertIsNone(waybar_sqlch.resolve_cover_path(None))

    def test_empty_url_returns_none(self):
        self.assertIsNone(waybar_sqlch.resolve_cover_path(""))

    def test_downloads_when_not_cached(self):
        url = "https://example.com/covers/track.jpg"

        def _fake_fetch(_url, dest):
            Path(dest).write_bytes(b"fake-jpeg-bytes")

        with mock.patch("urllib.request.urlretrieve", side_effect=_fake_fetch) as m_fetch:
            result = waybar_sqlch.resolve_cover_path(url)
        m_fetch.assert_called_once()
        self.assertIsNotNone(result)
        self.assertTrue(Path(result).exists())
        self.assertTrue(result.endswith(".jpg"))

    def test_skips_download_when_already_cached(self):
        url = "https://example.com/covers/track.png"
        fname = hashlib.md5(url.encode()).hexdigest() + ".png"
        cached = waybar_sqlch.CACHE_DIR / "covers" / fname
        cached.parent.mkdir(parents=True, exist_ok=True)
        cached.write_bytes(b"already-here")
        with mock.patch("urllib.request.urlretrieve") as m_fetch:
            result = waybar_sqlch.resolve_cover_path(url)
        m_fetch.assert_not_called()
        self.assertEqual(result, str(cached))

    def test_download_failure_returns_none(self):
        url = "https://example.com/covers/track.jpg"
        with mock.patch("urllib.request.urlretrieve", side_effect=OSError("network down")):
            result = waybar_sqlch.resolve_cover_path(url)
        self.assertIsNone(result)


class TestBlurCoverPath(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        orig = waybar_sqlch.CACHE_DIR
        waybar_sqlch.CACHE_DIR = Path(self.tmp.name)
        self.addCleanup(setattr, waybar_sqlch, "CACHE_DIR", orig)

    def test_none_path_returns_none(self):
        self.assertIsNone(waybar_sqlch.blur_cover_path(None))

    def test_empty_path_returns_none(self):
        self.assertIsNone(waybar_sqlch.blur_cover_path(""))

    def test_generates_blurred_copy_via_magick(self):
        src = waybar_sqlch.CACHE_DIR / "covers" / "abc123.jpg"
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_bytes(b"fake-jpeg-bytes")

        def _fake_magick(cmd, check, capture_output):
            Path(cmd[-1]).write_bytes(b"fake-blurred-bytes")
            return mock.Mock(returncode=0)

        with mock.patch("subprocess.run", side_effect=_fake_magick) as m_run:
            result = waybar_sqlch.blur_cover_path(str(src))
        m_run.assert_called_once()
        args = m_run.call_args[0][0]
        self.assertEqual(args[0], "magick")
        self.assertEqual(args[1], str(src))
        self.assertIsNotNone(result)
        self.assertTrue(Path(result).exists())
        self.assertEqual(Path(result).name, src.name)
        self.assertIn("covers-blurred", result)

    def test_skips_regenerating_when_already_cached(self):
        src = waybar_sqlch.CACHE_DIR / "covers" / "abc123.jpg"
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_bytes(b"fake-jpeg-bytes")
        blurred = waybar_sqlch.CACHE_DIR / "covers-blurred" / "abc123.jpg"
        blurred.parent.mkdir(parents=True, exist_ok=True)
        blurred.write_bytes(b"already-blurred")
        with mock.patch("subprocess.run") as m_run:
            result = waybar_sqlch.blur_cover_path(str(src))
        m_run.assert_not_called()
        self.assertEqual(result, str(blurred))

    def test_magick_failure_returns_none(self):
        src = waybar_sqlch.CACHE_DIR / "covers" / "abc123.jpg"
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_bytes(b"fake-jpeg-bytes")
        with mock.patch("subprocess.run", side_effect=OSError("magick not found")):
            result = waybar_sqlch.blur_cover_path(str(src))
        self.assertIsNone(result)


class TestCmdWingStatusCoverPath(unittest.TestCase):
    """cmd_wing_status() prints JSON to stdout; capture and parse it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        orig = waybar_sqlch.CACHE_DIR
        waybar_sqlch.CACHE_DIR = Path(self.tmp.name)
        self.addCleanup(setattr, waybar_sqlch, "CACHE_DIR", orig)

    def _run_wing_status(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            waybar_sqlch.cmd_wing_status()
        return json.loads(buf.getvalue())

    def test_cover_path_null_when_no_track(self):
        with mock.patch.object(waybar_sqlch, "daemon_send", return_value={"ok": True, "current": None}), \
             mock.patch.object(waybar_sqlch, "mpv_get", return_value=None), \
             mock.patch.object(waybar_sqlch, "current_track", return_value=(None, None)):
            payload = self._run_wing_status()
        self.assertIsNone(payload["cover_path"])
        self.assertIsNone(payload["cover_path_blurred"])

    def test_cover_path_null_when_no_enrichment_match(self):
        current = {"item": {"name": "KEXP", "id": "kexp"}}
        with mock.patch.object(waybar_sqlch, "daemon_send", return_value={"ok": True, "current": current}), \
             mock.patch.object(waybar_sqlch, "mpv_get", return_value=False), \
             mock.patch.object(waybar_sqlch, "current_track", return_value=("Artist", "Track")), \
             mock.patch.object(waybar_sqlch, "enrich_lookup", return_value=None):
            payload = self._run_wing_status()
        self.assertIsNone(payload["cover_path"])
        self.assertIsNone(payload["cover_path_blurred"])

    def test_cover_path_populated_on_enrichment_match(self):
        current = {"item": {"name": "KEXP", "id": "kexp"}}
        enrich = {"cover": "https://example.com/a.jpg", "genres": []}
        with mock.patch.object(waybar_sqlch, "daemon_send", return_value={"ok": True, "current": current}), \
             mock.patch.object(waybar_sqlch, "mpv_get", return_value=False), \
             mock.patch.object(waybar_sqlch, "current_track", return_value=("Artist", "Track")), \
             mock.patch.object(waybar_sqlch, "enrich_lookup", return_value=enrich), \
             mock.patch.object(waybar_sqlch, "resolve_cover_path", return_value="/tmp/fake/a.jpg") as m_resolve, \
             mock.patch.object(waybar_sqlch, "blur_cover_path", return_value="/tmp/fake/a.blur.jpg") as m_blur:
            payload = self._run_wing_status()
        m_resolve.assert_called_once_with("https://example.com/a.jpg")
        m_blur.assert_called_once_with("/tmp/fake/a.jpg")
        self.assertEqual(payload["cover_path"], "/tmp/fake/a.jpg")
        self.assertEqual(payload["cover_path_blurred"], "/tmp/fake/a.blur.jpg")

    def test_no_enrich_lookup_call_without_artist_and_track(self):
        """artist/track both empty must short-circuit before enrich_lookup,
        matching the existing station-only (no track metadata) idle state."""
        current = {"item": {"name": "KEXP", "id": "kexp"}}
        with mock.patch.object(waybar_sqlch, "daemon_send", return_value={"ok": True, "current": current}), \
             mock.patch.object(waybar_sqlch, "mpv_get", return_value=False), \
             mock.patch.object(waybar_sqlch, "current_track", return_value=(None, None)), \
             mock.patch.object(waybar_sqlch, "enrich_lookup") as m_enrich:
            payload = self._run_wing_status()
        m_enrich.assert_not_called()
        self.assertIsNone(payload["cover_path"])
        self.assertIsNone(payload["cover_path_blurred"])


if __name__ == "__main__":
    unittest.main()
