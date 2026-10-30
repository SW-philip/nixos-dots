import importlib.util
import os
import unittest

_spec = importlib.util.spec_from_file_location(
    "takeout_photos", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "takeout-photos.py"))
tp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tp)


class SidecarFor(unittest.TestCase):
    # Names taken from a real Takeout export.
    def test_full_suffix(self):
        self.assertEqual(tp.sidecar_for("20191201_164835.jpg", ["20191201_164835.jpg.supplemental-metadata.json"]),
                         "20191201_164835.jpg.supplemental-metadata.json")

    def test_truncated_suffix(self):
        j = "1F808E01-84DD-4B07-B9CB-E2E37DA87EE9.jpg.suppl.json"
        self.assertEqual(tp.sidecar_for("1F808E01-84DD-4B07-B9CB-E2E37DA87EE9.jpg", [j]), j)

    def test_truncated_into_name(self):
        j = "59430378214__CC79D3FB-1271-44F9-9722-3F71C888F.json"
        self.assertEqual(tp.sidecar_for("59430378214__CC79D3FB-1271-44F9-9722-3F71C888F2.JPG", [j]), j)

    def test_dup_counter_moves_after_suffix(self):
        js = ["20191224_175827.mp4.supplemental-metadata.json",
              "20191224_175827.mp4.supplemental-metadata(1).json"]
        self.assertEqual(tp.sidecar_for("20191224_175827(1).mp4", js), js[1])
        self.assertEqual(tp.sidecar_for("20191224_175827.mp4", js), js[0])

    def test_edited_uses_original(self):
        j = "IMG_0648.JPG.supplemental-metadata.json"
        self.assertEqual(tp.sidecar_for("IMG_0648-edited.JPG", [j]), j)

    def test_live_photo_video_borrows_still(self):
        j = "IMG_8251.HEIC.supplemental-metadata.json"
        self.assertEqual(tp.sidecar_for("IMG_8251.MP4", [j]), j)

    def test_short_prefix_is_not_a_match(self):
        self.assertIsNone(tp.sidecar_for("IMG_1.jpg", ["IMG_10.jpg.supplemental-metadata.json"]))

    def test_old_style_sidecar(self):
        self.assertEqual(tp.sidecar_for("IMG_1.jpg", ["IMG_1.jpg.json"]), "IMG_1.jpg.json")


class TrueName(unittest.TestCase):
    def test_reencoded_keeps_case(self):
        self.assertEqual(tp.true_name("IMG_0524.HEIC", "JPG"), "IMG_0524.JPG")
        self.assertEqual(tp.true_name("shot.png", "JPG"), "shot.jpg")

    def test_matching_or_unknown_untouched(self):
        self.assertEqual(tp.true_name("a.jpeg", "JPG"), "a.jpeg")
        self.assertEqual(tp.true_name("a.HEIC", None), "a.HEIC")


class ExifDate(unittest.TestCase):
    def test_zero_and_bogus(self):
        self.assertIsNone(tp.parse_exif_date("0000:00:00 00:00:00"))
        self.assertIsNone(tp.parse_exif_date("1970:01:01 00:00:00"))
        self.assertEqual(tp.parse_exif_date("2019:12:01 16:48:35+05:00").hour, 16)


if __name__ == "__main__":
    unittest.main()
