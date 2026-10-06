"""Pure-function tests for quantum_clock.py. Run: python3 -m unittest discover -s home/waybar/scripts/tests"""
import sys
import unittest
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import quantum_clock as qc  # noqa: E402


class HexTime(unittest.TestCase):
    def test_fields(self):
        self.assertEqual(qc.hex_fields(0, 0, 0), (0, 0, 0))
        self.assertEqual(qc.hex_fields(12, 0, 0), (8, 0, 0))
        self.assertEqual(qc.hex_fields(13, 30, 0), (9, 0, 0))
        self.assertEqual(qc.hex_fields(13, 35, 13), (9, 0, 14))
        self.assertEqual(qc.hex_fields(13, 36, 0), (9, 1, 1))

    def test_lerp(self):
        self.assertEqual(qc.lerp_rgb("000000", "ffffff", 0), "000000")
        self.assertEqual(qc.lerp_rgb("000000", "ffffff", 1000), "ffffff")
        self.assertEqual(qc.lerp_rgb("000000", "ffffff", 500), "7f7f7f")

    def test_day_color(self):
        p = {"SCORE": "#ffffff"}
        self.assertEqual(qc.day_color(0, p), "#" + qc.lerp_rgb("0d1b2a", "ffffff", 300))
        self.assertEqual(qc.day_color(86400 * 4 // 16, p), "#" + qc.lerp_rgb("ea580c", "ffffff", 300))
        self.assertEqual(qc.day_color(86399, p)[0], "#")


class Natural(unittest.TestCase):
    def at(self, h, m):
        return qc.natural(datetime(2026, 1, 1, h, m))

    def test_words(self):
        self.assertEqual(self.at(0, 0), "midnight")
        self.assertEqual(self.at(12, 1), "noon")
        self.assertEqual(self.at(9, 0), "nine o'clock")
        self.assertEqual(self.at(10, 25), "twenty-five past ten")
        self.assertEqual(self.at(10, 45), "quarter to eleven")
        self.assertEqual(self.at(23, 58), "midnight")


class Moon(unittest.TestCase):
    def test_reference_new_moon(self):
        ep = (qc.REF_NEW_JD - 2440587.5) * 86400
        glyph, name, illum, _, _ = qc.lunar(ep)
        self.assertEqual((name, illum), ("New Moon", 0))


if __name__ == "__main__":
    unittest.main()
