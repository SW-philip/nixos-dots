#!/usr/bin/env python3
"""Standalone tests for drmis's squeekboard stylesheet deploy.
Run: python3 home/niri/test_drmis_squeekboard.py"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("drmis", Path(__file__).with_name("drmis.py"))
drmis = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drmis)


class TestDeploySqueekboardCss(unittest.TestCase):
    def test_copies_css_into_private_gtk_dir(self):
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "src.css"
            src.write_text("sq_view { color: red; }")
            home = Path(d) / "home"
            drmis.deploy_squeekboard_css({"squeekboardCss": str(src)}, home)
            self.assertEqual(
                (home / ".config/squeekboard-gtk/gtk-3.0/gtk.css").read_text(),
                "sq_view { color: red; }",
            )

    def test_leaves_global_gtk_css_alone(self):
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "src.css"
            src.write_text("x")
            home = Path(d) / "home"
            drmis.deploy_squeekboard_css({"squeekboardCss": str(src)}, home)
            self.assertFalse((home / ".config/gtk-3.0/gtk.css").exists())

    def test_redeploy_replaces_existing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "home"
            for body in ("one", "two"):
                src = Path(d) / "src.css"
                src.write_text(body)
                drmis.deploy_squeekboard_css({"squeekboardCss": str(src)}, home)
            self.assertEqual(
                (home / drmis.SQUEEKBOARD_CSS_REL).read_text(), "two")


if __name__ == "__main__":
    unittest.main()
