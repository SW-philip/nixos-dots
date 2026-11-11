#!/usr/bin/env python3
"""Standalone tests for ember-mug-poll.py's parsing/cache-writing logic.
Run: python3 home/waybar/scripts/test_ember_mug_poll.py"""
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_spec = importlib.util.spec_from_file_location(
    "ember_mug_poll", Path(__file__).with_name("ember-mug-poll.py"))
ember_mug_poll = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ember_mug_poll)


class TestParseGetOutput(unittest.TestCase):
    def test_parses_full_sample(self):
        raw = ("35.0%, on charging base\n140.0\n132.5\n#672419\nPerfect\n"
               "Mug ID: 1234, Serial Number: EMBR00231\n"
               "Version: 142, Hardware: 3, Bootloader: 1")
        fields = ember_mug_poll.parse_get_output(raw)
        self.assertEqual(fields, {
            "battery_pct": 35.0,
            "charging": True,
            "current_temp": 140.0,
            "target_temp": 132.5,
            "led_colour": "#672419",
            "name": "Work Mug",
            "liquid_state": "Perfect",
            "serial_number": "EMBR00231",
            "firmware_version": "142",
        })

    def test_parses_partial_sample_without_meta_or_firmware(self):
        """meta/firmware reads intermittently failing server-side (command
        still exits 0, just fewer lines back) must not raise -- the core
        6-field payload the pre-existing widget relied on still parses."""
        raw = "35.0%, on charging base\n140.0\n132.5\n#672419\nPerfect"
        fields = ember_mug_poll.parse_get_output(raw)
        self.assertEqual(fields, {
            "battery_pct": 35.0,
            "charging": True,
            "current_temp": 140.0,
            "target_temp": 132.5,
            "led_colour": "#672419",
            "name": "Work Mug",
            "liquid_state": "Perfect",
            "serial_number": "",
            "firmware_version": "",
        })


class TestFetchFields(unittest.TestCase):
    def test_returns_parsed_fields_on_success(self):
        out = ("35.0%, on charging base\n140.0\n132.5\n#672419\nPerfect\n"
               "Mug ID: 1234, Serial Number: EMBR00231\n"
               "Version: 142, Hardware: 3, Bootloader: 1\n")
        proc = mock.MagicMock(returncode=0)
        proc.communicate.return_value = (out, "")
        with mock.patch.object(ember_mug_poll.subprocess, "Popen", return_value=proc):
            fields = ember_mug_poll.fetch_fields("00:00:00:00:00:01")
        self.assertEqual(fields["name"], "Work Mug")
        self.assertEqual(fields["serial_number"], "EMBR00231")
        self.assertEqual(fields["firmware_version"], "142")

    def test_returns_none_on_timeout(self):
        proc = mock.MagicMock()
        proc.communicate.side_effect = [
            subprocess.TimeoutExpired(cmd="ember-mug", timeout=10), ("", "")]
        with mock.patch.object(ember_mug_poll.subprocess, "Popen", return_value=proc):
            self.assertIsNone(ember_mug_poll.fetch_fields("00:00:00:00:00:01"))


class TestFetchFieldsTermination(unittest.TestCase):
    """A timed-out poll must be asked to exit (SIGTERM) so the CLI can drop its
    GATT link cleanly; subprocess.run's timeout path SIGKILLs it instead."""

    def _proc(self, communicate):
        proc = mock.MagicMock()
        proc.communicate.side_effect = communicate
        return proc

    def test_timeout_terminates_before_killing(self):
        proc = self._proc([subprocess.TimeoutExpired("ember-mug", 20), ("", "")])
        with mock.patch.object(ember_mug_poll.subprocess, "Popen", return_value=proc):
            self.assertIsNone(ember_mug_poll.fetch_fields("00:00:00:00:00:01"))
        proc.terminate.assert_called_once()
        proc.kill.assert_not_called()

    def test_kills_only_if_terminate_is_ignored(self):
        proc = self._proc([
            subprocess.TimeoutExpired("ember-mug", 20),
            subprocess.TimeoutExpired("ember-mug", 5), ("", "")])
        with mock.patch.object(ember_mug_poll.subprocess, "Popen", return_value=proc):
            self.assertIsNone(ember_mug_poll.fetch_fields("00:00:00:00:00:01"))
        proc.terminate.assert_called_once()
        proc.kill.assert_called_once()


class TestWriteCache(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "status.json"

    def tearDown(self):
        self.tmp.cleanup()

    def test_writes_ok_payload_with_fields(self):
        fields = {"battery_pct": 35.0, "charging": True, "current_temp": 60.0,
                  "led_colour": "#672419", "name": "Work Mug", "liquid_state": "Perfect"}
        ember_mug_poll.write_cache(fields, path=self.path, now=1000.0)
        payload = json.loads(self.path.read_text())
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["fetched_at"], 1000.0)
        self.assertEqual(payload["name"], "Work Mug")

    def test_writes_not_ok_payload_when_fields_none(self):
        ember_mug_poll.write_cache(None, path=self.path, now=1000.0)
        payload = json.loads(self.path.read_text())
        self.assertFalse(payload["ok"])
        self.assertNotIn("name", payload)

    def test_creates_parent_directory(self):
        nested = Path(self.tmp.name) / "nested" / "status.json"
        ember_mug_poll.write_cache(None, path=nested, now=1000.0)
        self.assertTrue(nested.exists())

    def test_no_leftover_tmp_file(self):
        ember_mug_poll.write_cache(None, path=self.path, now=1000.0)
        self.assertFalse(self.path.with_suffix(".json.tmp").exists())


if __name__ == "__main__":
    unittest.main()
