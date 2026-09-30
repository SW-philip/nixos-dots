#!/usr/bin/env python3
"""Standalone tests for drmis's ember-mug HALL-sync argv builder.
Run: python3 home/niri/test_drmis_mug_sync.py"""
import importlib.util
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("drmis", Path(__file__).with_name("drmis.py"))
drmis = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drmis)


class TestEmberMugLedArgv(unittest.TestCase):
    def test_builds_argv_for_valid_hex(self):
        argv = drmis.ember_mug_led_argv("/nix/store/xyz/bin/ember-mug", "#672419")
        self.assertEqual(
            argv,
            ["/nix/store/xyz/bin/ember-mug", "set", "-m", drmis.EMBER_MUG_MAC,
             "--led-colour", "672419"],
        )

    def test_none_when_mug_not_installed(self):
        self.assertIsNone(drmis.ember_mug_led_argv(None, "#672419"))

    def test_none_when_theme_has_no_hall(self):
        self.assertIsNone(drmis.ember_mug_led_argv("/bin/ember-mug", None))

    def test_none_when_hex_malformed(self):
        self.assertIsNone(drmis.ember_mug_led_argv("/bin/ember-mug", "not-a-hex"))


if __name__ == "__main__":
    unittest.main()
