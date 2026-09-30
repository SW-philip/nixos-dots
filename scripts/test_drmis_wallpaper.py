import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_DRMIS = Path(__file__).resolve().parents[1] / "home" / "niri" / "drmis.py"
_spec = importlib.util.spec_from_file_location("drmis", _DRMIS)
drmis = importlib.util.module_from_spec(_spec)
sys.modules["drmis"] = drmis
_spec.loader.exec_module(drmis)


class TestResolveWallpaper(unittest.TestCase):
    def test_returns_slug_png_when_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            live = Path(tmp)
            (live / "wallpaper-dunes.png").write_text("x")
            self.assertEqual(
                drmis.resolve_wallpaper("dunes", live, "/fallback.png"),
                str(live / "wallpaper-dunes.png"),
            )

    def test_falls_back_when_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(
                drmis.resolve_wallpaper("dunes", Path(tmp), "/fallback.png"),
                "/fallback.png",
            )

    def test_ignores_other_pngs_in_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            live = Path(tmp)
            (live / "wallpaper-dunes-old-sticker.png").write_text("x")
            self.assertEqual(
                drmis.resolve_wallpaper("dunes", live, "/fallback.png"),
                "/fallback.png",
            )


class TestRegenWallpapers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.root = self.home / "nixos" / "themes"
        scripts = self.home / "nixos" / "scripts"
        scripts.mkdir(parents=True)
        (scripts / "make-splotch-bg.py").write_text("# stub\n")
        for fam, slug in [("Lix", "teal-indigo"), ("Lix", "navy-teal"), ("Animals", "octopus")]:
            d = self.root / fam / slug
            d.mkdir(parents=True)
            (d / f"palette-{slug}.sh").write_text("x")
        drmis.THEMES_ROOT = self.root

    def tearDown(self):
        self.tmp.cleanup()

    def test_no_family_runs_all_once(self):
        with mock.patch.object(drmis.Path, "home", return_value=self.home), \
             mock.patch.object(drmis.subprocess, "run",
                               return_value=mock.Mock(returncode=0)) as run:
            drmis.regen_wallpapers(family=None, force=False)
        self.assertEqual(run.call_count, 1)
        self.assertIn("--all", run.call_args_list[0].args[0])

    def test_family_filter_iterates_that_family(self):
        with mock.patch.object(drmis.Path, "home", return_value=self.home), \
             mock.patch.object(drmis.subprocess, "run",
                               return_value=mock.Mock(returncode=0)) as run:
            drmis.regen_wallpapers(family="Animals", force=True)
        called = [c.args[0][-1] for c in run.call_args_list]
        self.assertEqual(len(called), 1)
        self.assertTrue(called[0].endswith("/Animals/octopus"))

    def test_missing_script_is_noop(self):
        (self.home / "nixos" / "scripts" / "make-splotch-bg.py").unlink()
        with mock.patch.object(drmis.Path, "home", return_value=self.home), \
             mock.patch.object(drmis.subprocess, "run") as run:
            drmis.regen_wallpapers(family=None, force=False)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
