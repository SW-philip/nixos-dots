#!/usr/bin/env python3
"""Standalone tests for jbl-speaker-poll.py's parsing/cache logic.
Run: python3 home/waybar/scripts/test_jbl_speaker_poll.py"""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "jbl_speaker_poll", Path(__file__).with_name("jbl-speaker-poll.py"))
jbl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(jbl)

# The real burst captured 2026-08-28 off SWjbl (JBL Go 4), all 12 frames
# concatenated exactly as received over the notify characteristic.
CAPTURE_HEX = (
    "aa120800c10553576a626c"
    "aa121300c2104448303038322d475030353532303935"
    "aa1204004220e4"
    "aa1203004303"
    "aa120300444b"
    "aa1203004600"
    "aa1203004701"
    "aa1208004890f260b3889f"
    "aa1204004aed0a"
    "aa1203004c01"
    "aa1206004d30363430"
    "aa1203004f00"
)


class TestParseBurst(unittest.TestCase):
    def test_parses_full_capture(self):
        got = jbl.parse_burst(bytes.fromhex(CAPTURE_HEX))
        self.assertEqual(got["name"], "SWjbl")
        self.assertEqual(got["model"], "DH0082-GP0552095")
        self.assertEqual(got["battery_pct"], 75)
        self.assertEqual(got["channel"], 0)
        self.assertEqual(got["mac"], "00:00:00:00:00:02")
        self.assertEqual(got["firmware"], "0640")
        self.assertFalse(got["charging"])
        # unrecognised tokens are preserved as hex for later analysis
        self.assertEqual(got["raw"]["42"], "20e4")
        self.assertEqual(got["raw"]["4a"], "ed0a")

    def test_battery_only_frame(self):
        got = jbl.parse_burst(bytes.fromhex("aa120300444b"))
        self.assertEqual(got["battery_pct"], 75)

    def test_truncated_frame_does_not_raise(self):
        # length byte says 8 payload bytes, only 2 present
        got = jbl.parse_burst(bytes.fromhex("aa120800c1"))
        self.assertEqual(got, {"raw": {}})

    def test_empty_input(self):
        self.assertEqual(jbl.parse_burst(b""), {"raw": {}})

    def test_non_aa_prefix_ignored(self):
        self.assertEqual(jbl.parse_burst(bytes.fromhex("ffff00")), {"raw": {}})


class TestFieldsToPayload(unittest.TestCase):
    def test_ok_payload_from_full_capture(self):
        fields = jbl.parse_burst(bytes.fromhex(CAPTURE_HEX))
        p = jbl.fields_to_payload(fields, now=1000.0)
        self.assertTrue(p["ok"])
        self.assertEqual(p["ts"], 1000.0)
        self.assertEqual(p["battery_pct"], 75)
        self.assertEqual(p["name"], "SWjbl")
        self.assertEqual(p["firmware"], "0640")
        self.assertNotIn("raw", p)

    def test_none_fields_is_not_ok(self):
        p = jbl.fields_to_payload(None, now=5.0)
        self.assertEqual(p, {"ok": False, "ts": 5.0})

    def test_burst_without_battery_is_not_ok(self):
        p = jbl.fields_to_payload({"name": "SWjbl", "raw": {}}, now=5.0)
        self.assertFalse(p["ok"])
        self.assertEqual(p["ts"], 5.0)
        self.assertIn("error", p)

    def test_unavailable_marker_carries_reason(self):
        p = jbl.fields_to_payload({"unavailable": "no adapter"}, now=5.0)
        self.assertFalse(p["ok"])
        self.assertEqual(p["error"], "no adapter")


class TestWriteCache(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "nested" / "status.json"

    def tearDown(self):
        self.tmp.cleanup()

    def test_writes_and_creates_parents(self):
        jbl.write_cache(jbl.parse_burst(bytes.fromhex(CAPTURE_HEX)),
                        path=self.path, now=1000.0)
        payload = json.loads(self.path.read_text())
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["battery_pct"], 75)

    def test_no_leftover_tmp(self):
        jbl.write_cache(None, path=self.path, now=1.0)
        self.assertFalse(self.path.with_suffix(".json.tmp").exists())


class TestAdvertMatches(unittest.TestCase):
    NAMES = ["JBL", "SWjbl"]

    def test_harman_mfr_id_and_name(self):
        self.assertTrue(jbl.advert_matches(
            "SWjbl", {0x0057: b"\xe4 \x03"}, [], self.NAMES))

    def test_service_uuid_and_name(self):
        self.assertTrue(jbl.advert_matches(
            "JBL Go 4", {}, [jbl.SVC], self.NAMES))

    def test_harman_id_no_name_still_matches(self):
        self.assertTrue(jbl.advert_matches(
            None, {0x0057: b""}, [], self.NAMES))

    def test_name_mismatch_rejected(self):
        self.assertFalse(jbl.advert_matches(
            "Sony WH-1000", {0x0057: b""}, [], self.NAMES))

    def test_no_harman_no_uuid_rejected(self):
        self.assertFalse(jbl.advert_matches(
            "SWjbl", {0x004C: b""}, [], self.NAMES))


class TestCharging(unittest.TestCase):
    def test_charging_bit_set(self):
        got = jbl.parse_burst(bytes.fromhex("aa12030044bc"))
        self.assertEqual(got["battery_pct"], 60)
        self.assertTrue(got["charging"])

    def test_charging_bit_clear(self):
        got = jbl.parse_burst(bytes.fromhex("aa120300443c"))
        self.assertEqual(got["battery_pct"], 60)
        self.assertFalse(got["charging"])

    def test_full_on_charger_capture(self):
        # real ON-charger burst, reconstructed: identical to CAPTURE_HEX
        # except the battery byte is 0xbc (0x80 | 60) instead of 0x4b.
        on_hex = (
            "aa120800c10553576a626c"
            "aa121300c2104448303038322d475030353532303935"
            "aa1204004220e4"
            "aa1203004303"
            "aa12030044bc"
            "aa1203004600"
            "aa1203004701"
            "aa1208004890f260b3889f"
            "aa1204004aed0a"
            "aa1203004c01"
            "aa1206004d30363430"
            "aa1203004f00"
        )
        got = jbl.parse_burst(bytes.fromhex(on_hex))
        self.assertEqual(got["battery_pct"], 60)
        self.assertTrue(got["charging"])
        self.assertEqual(got["firmware"], "0640")
        self.assertEqual(got["mac"], "00:00:00:00:00:02")

    def test_payload_carries_charging(self):
        p = jbl.fields_to_payload(jbl.parse_burst(bytes.fromhex("aa12030044bc")), now=1.0)
        self.assertTrue(p["ok"])
        self.assertTrue(p["charging"])


class TestMainReadStatusRaises(unittest.TestCase):
    def test_raise_yields_not_ok_cache_and_nonzero_rc(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as d:
            cache = Path(d) / "sub" / "status.json"
            with mock.patch.object(jbl, "CACHE", cache), \
                 mock.patch.object(jbl, "read_status",
                                   new=mock.AsyncMock(side_effect=RuntimeError("boom"))):
                rc = jbl.main([])
            self.assertEqual(rc, 1)
            payload = json.loads(cache.read_text())
            self.assertFalse(payload["ok"])


class TestHexdumpFrames(unittest.TestCase):
    def test_splits_capture_into_frames(self):
        out = jbl.hexdump_frames(bytes.fromhex(CAPTURE_HEX))
        lines = out.splitlines()
        self.assertEqual(len(lines), 12)
        self.assertTrue(lines[0].startswith("aa 12 08 00 c1"))

    def test_truncated_tail_flagged(self):
        out = jbl.hexdump_frames(bytes.fromhex("aa120800c1"))
        self.assertIn("truncated", out)


class TestMainArgparse(unittest.TestCase):
    def test_dump_flag_parses(self):
        # --dump with no reachable speaker: read_status returns None fast,
        # main prints and returns 1, writes nothing.
        import io
        from unittest import mock
        with mock.patch.object(jbl, "read_status",
                               new=mock.AsyncMock(return_value=None)), \
             mock.patch("sys.stdout", new=io.StringIO()):
            rc = jbl.main(["--dump"])
        self.assertEqual(rc, 1)

    def test_bluetooth_unavailable_exits_zero_and_caches_reason(self):
        # No adapter (rfkill / unplugged / HCI init fail) is a resting state,
        # not a unit failure: exit 0, cache a not-ok payload with the reason.
        from unittest import mock
        with mock.patch.object(
                jbl, "read_status",
                new=mock.AsyncMock(side_effect=jbl.BluetoothUnavailable(
                    "No Bluetooth adapters found."))), \
             mock.patch.object(jbl, "write_cache") as wc:
            rc = jbl.main([])
        self.assertEqual(rc, 0)
        cached = wc.call_args.args[0]
        p = jbl.fields_to_payload(cached, now=1.0)
        self.assertFalse(p["ok"])
        self.assertIn("No Bluetooth adapters found.", p["error"])


if __name__ == "__main__":
    unittest.main()
