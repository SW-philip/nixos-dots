"""Pure-function tests for bluetooth_status.py. Run: python3 -m unittest discover -s home/waybar/scripts/tests"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bluetooth_status as bs  # noqa: E402

P = {"REST": "#111111", "ROOT": "#222222"}
snark = lambda bucket: f"snark-{bucket}"  # noqa: E731


def objs(powered, devices):
    o = {bs.ADAPTER: {"org.bluez.Adapter1": {"Powered": {"type": "b", "data": powered}}}}
    for i, (mac, alias, conn) in enumerate(devices):
        o[f"{bs.ADAPTER}/dev_{i}"] = {"org.bluez.Device1": {
            "Address": {"data": mac}, "Alias": {"data": alias}, "Connected": {"data": conn}}}
    return o


class Snapshot(unittest.TestCase):
    def test_off(self):
        self.assertEqual(bs.snapshot(objs(False, [("A", "x", True)])), (False, None))

    def test_idle(self):
        self.assertEqual(bs.snapshot(objs(True, [("A", "x", False)])), (True, None))

    def test_first_connected(self):
        self.assertEqual(bs.snapshot(objs(True, [("A", "x", False), ("B", "y", True)])), (True, ("B", "y")))

    def test_empty(self):
        self.assertEqual(bs.snapshot({}), (False, None))


class Render(unittest.TestCase):
    def test_off_and_idle(self):
        self.assertEqual(bs.render(False, None, {}, P, snark)["class"], "off")
        self.assertEqual(bs.render(False, None, {}, P, snark)["text"], bs.ICON_OFF)
        idle = bs.render(True, None, {}, P, snark)
        self.assertEqual((idle["class"], idle["text"]), ("idle", bs.ICON_ON))

    def test_connected_speaker(self):
        f = bs.render(True, ("M", "SW<jbl>"), {"type": "speaker", "battery": "80", "charging": True,
                                              "model": "X", "channel": 0}, P, snark)
        self.assertEqual((f["class"], f["text"]), ("on", bs.GLYPHS["speaker"]))
        self.assertIn("<b>SW&lt;jbl&gt;</b>", f["tooltip"])
        self.assertIn("Battery: 80% (charging)", f["tooltip"])
        self.assertNotIn("Channel", f["tooltip"])

    def test_unknown_type_falls_back(self):
        self.assertEqual(bs.render(True, ("M", "n"), {}, P, snark)["text"], bs.ICON_CONNECTED)


if __name__ == "__main__":
    unittest.main()
