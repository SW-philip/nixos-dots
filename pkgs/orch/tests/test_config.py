import tempfile
import unittest
from pathlib import Path

from orch import config


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, text):
        p = self.dir / "config.toml"
        p.write_text(text)
        return p

    def test_missing_file_gives_defaults(self):
        cfg = config.load(self.dir / "absent.toml")
        self.assertEqual(cfg["implementer"], "claude")
        self.assertEqual(cfg["reviewer"], "codex")
        self.assertEqual(cfg["max_rounds"], 3)
        self.assertEqual(cfg["timeout_s"], 1800)

    def test_file_overrides_merge(self):
        p = self.write('max_rounds = 5\n[agents.claude]\nmodel = "m"\n')
        cfg = config.load(p)
        self.assertEqual(cfg["max_rounds"], 5)
        self.assertEqual(cfg["reviewer"], "codex")
        self.assertEqual(config.agent_model(cfg, "claude"), "m")
        self.assertIsNone(config.agent_model(cfg, "codex"))

    def test_dns_default_and_valid(self):
        self.assertIsNone(config.load(self.dir / "absent.toml")["dns"])
        self.assertEqual(config.load(self.write('dns = "10.2.0.1"\n'))["dns"], "10.2.0.1")

    def test_dns_rejects_non_ipv4(self):
        for text in ('dns = "example.com"\n', 'dns = "::1"\n', 'dns = "10.0.0"\n', "dns = 5\n",
                     'dns = ""\n', 'dns = "10.0.0.1 --x"\n', 'dns = "010.0.0.1"\n',
                     'dns = ["10.0.0.1"]\n'):
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, "dns"):
                config.load(self.write(text))

    def test_bad_values_raise(self):
        for text in ("max_rounds = 0\n", 'max_rounds = "x"\n',
                     'implementer = "nope"\n'):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    config.load(self.write(text))

    def test_invalid_toml_raises(self):
        with self.assertRaises(ValueError):
            config.load(self.write("max_rounds = = 3\n"))


if __name__ == "__main__":
    unittest.main()
