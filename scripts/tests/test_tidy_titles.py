import importlib.util
import unittest
from pathlib import Path

_PATH = Path(__file__).resolve().parents[1] / "tidy-titles.py"
_spec = importlib.util.spec_from_file_location("tidy_titles", _PATH)
tidy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tidy)


class TestClean(unittest.TestCase):
    def check(self, raw, want):
        self.assertEqual(tidy.clean(raw), want)

    def test_drops_trailing_boilerplate(self):
        self.check("Spork! | Read Aloud Kids Book | Vooks Narrated Storybooks", "Spork!")

    def test_cuts_boilerplate_lead_in(self):
        self.check("Bedtime Story for Kids: It's Time to Say Goodnight | Vooks Narrated Storybooks",
                   "It's Time to Say Goodnight")

    def test_keeps_real_colon(self):
        self.check("Animal Classification: The Vertebrates Song", "Animal Classification: The Vertebrates Song")

    def test_keeps_meaningful_second_segment(self):
        self.check("Kooki's Crafty Show | Hippo Bookmark", "Kooki's Crafty Show - Hippo Bookmark")

    def test_first_segment_never_dropped(self):
        self.check("Goldilocks Fairy Tale for Kids | Read Aloud | Vooks Narrated Storybooks",
                   "Goldilocks Fairy Tale for Kids")

    def test_dash_separator_quotes_and_emoji(self):
        self.check('"Twist and Shake Dance!" \U0001F483\U0001F3FC --- Danny Go! Brain Break Songs for Kids',
                   "Twist and Shake Dance!")

    def test_trailing_empty_segment(self):
        self.check("There Are MORE Than 5 Senses?! \U0001F440 | Senses Song for Kids |",
                   "There Are MORE Than 5 Senses?!")


class TestRename(unittest.TestCase):
    def test_skips_collisions(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "Spork!.mkv").write_text("a")
            (d / "Spork! | Vooks Narrated Storybooks.mkv").write_text("b")
            self.assertEqual(tidy.tidy_dir(d, apply=True), 1)
            self.assertEqual((d / "Spork!.mkv").read_text(), "a")


if __name__ == "__main__":
    unittest.main()
