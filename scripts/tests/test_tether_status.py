import importlib.util
import os
import stat
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "home", "waybar", "scripts", "tether-status.py")


def load():
    spec = importlib.util.spec_from_file_location("tether_status", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ParslyUnreadTests(unittest.TestCase):
    def fake(self, body):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        path = os.path.join(d.name, "parsly")
        with open(path, "w") as f:
            f.write("#!/bin/sh\n" + body + "\n")
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        module = load()
        module.PARSLY = path
        return module

    def test_reads_the_counts(self):
        module = self.fake("""echo '{"unread": 3, "filtered": 9}'""")
        self.assertEqual(module.parsly_unread(), (3, 9))

    def test_failure_is_none(self):
        self.assertIsNone(self.fake("exit 1").parsly_unread())

    def test_garbage_is_none(self):
        self.assertIsNone(self.fake("echo nope").parsly_unread())

    def test_missing_binary_is_none(self):
        module = load()
        module.PARSLY = "/nonexistent/parsly"
        self.assertIsNone(module.parsly_unread())


if __name__ == "__main__":
    unittest.main()
