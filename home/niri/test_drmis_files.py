#!/usr/bin/env python3
"""Standalone tests for drmis's table-driven file deploy.
Run: python3 home/niri/test_drmis_files.py"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("drmis", Path(__file__).with_name("drmis.py"))
drmis = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drmis)


class DeployThemeFiles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.src = self.root / "src.css"
        self.src.write_text("new")

    def tearDown(self):
        self.tmp.cleanup()

    def test_copy_creates_parents_and_replaces(self):
        dest = self.home / ".config/a/b.css"
        dest.parent.mkdir(parents=True)
        dest.write_text("old")
        drmis.deploy_theme_files({"k": {"src": str(self.src), "dest": ".config/a/b.css", "mode": "copy"}}, self.home)
        self.assertEqual(dest.read_text(), "new")
        self.assertFalse(dest.is_symlink())

    def test_link_mode_symlinks(self):
        drmis.deploy_theme_files({"k": {"src": str(self.src), "dest": ".local/x/logo.png", "mode": "link"}}, self.home)
        dest = self.home / ".local/x/logo.png"
        self.assertTrue(dest.is_symlink())
        self.assertEqual(dest.resolve(), self.src.resolve())

    def test_unknown_mode_raises(self):
        with self.assertRaises(ValueError):
            drmis.deploy_theme_files({"k": {"src": str(self.src), "dest": "a", "mode": "move"}}, self.home)


class ThemeFile(unittest.TestCase):
    def test_reads_src_from_files_table(self):
        cfgs = {"files": {"waybarSh": {"src": "/s/p.sh", "dest": "d", "mode": "copy"}}}
        self.assertEqual(drmis.theme_file(cfgs, "waybarSh"), "/s/p.sh")

    def test_unknown_key_raises(self):
        with self.assertRaises(KeyError):
            drmis.theme_file({"files": {}}, "nope")


if __name__ == "__main__":
    unittest.main()
