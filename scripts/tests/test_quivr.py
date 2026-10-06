import os
import subprocess
import sys
import tempfile
import unittest

LINE = "cpu=38 mem_used=2516582 mem_total=7969177 load=0.52 temp=54 rx=12288 tx=3481 disk=51 up=270000 cpus=4"


class Once(unittest.TestCase):
    def run_once(self, hosts, stub_body):
        d = tempfile.mkdtemp()
        stub = os.path.join(d, "fakessh")
        with open(stub, "w") as f:
            f.write("#!/bin/sh\n" + stub_body)
        os.chmod(stub, 0o755)
        env = dict(os.environ, QUIVR_HOSTS=hosts, QUIVR_SSH=stub, QUIVR_PALETTE="/nonexistent", COLUMNS="140")
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "quivr.py")
        return subprocess.run([sys.executable, script, "--once"], env=env, capture_output=True, text=True, timeout=30)

    def test_once_renders_streamed_hosts(self):
        r = self.run_once("alpha beta", f'echo "{LINE}"\nexec sleep 30\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("● alpha", r.stdout)
        self.assertIn("● beta", r.stdout)
        self.assertIn("38%", r.stdout)

    def test_once_marks_a_dead_host(self):
        r = self.run_once("alpha", "exit 255\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("alpha", r.stdout)
        self.assertIn("reconnecting", r.stdout)


DETAIL = """@frame 1000
core 0 20
net eth0 2000 1000
mount 50 500000 1000000 /
pcpu 1234 alice 100.0 2000 my prog
pmem 9 4242 0.0 200000 idle
@end
"""


def load_quivr():
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "quivr.py")
    spec = importlib.util.spec_from_file_location("quivr_main", path)
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, os.path.dirname(path))
    spec.loader.exec_module(mod)
    return mod


class OnceDetail(Once):
    def run_detail(self, host, stub_body):
        d = tempfile.mkdtemp()
        stub = os.path.join(d, "fakessh")
        with open(stub, "w") as f:
            f.write("#!/bin/sh\n" + stub_body)
        os.chmod(stub, 0o755)
        env = dict(os.environ, QUIVR_HOSTS="alpha beta", QUIVR_SSH=stub, QUIVR_PALETTE="/nonexistent",
                   COLUMNS="120", LINES="40")
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "quivr.py")
        return subprocess.run([sys.executable, script, "--once", "--detail", host],
                              env=env, capture_output=True, text=True, timeout=30)

    def test_detail_once_renders_a_frame(self):
        r = self.run_detail("alpha", f"cat <<'EOF'\n{DETAIL}EOF\nexec sleep 30\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        for part in ("alpha", "CPU", "eth0", "my prog", "idle"):
            self.assertIn(part, r.stdout)

    def test_detail_once_dead_host_shows_connecting(self):
        r = self.run_detail("alpha", "exit 255\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("connecting", r.stdout)

    def test_detail_unknown_host_is_an_error(self):
        r = self.run_detail("nope", "exit 255\n")
        self.assertEqual(r.returncode, 2)


class TopCommand(unittest.TestCase):
    def test_remote_top_command(self):
        q = load_quivr()
        cmd = q.top_command("retro")
        self.assertEqual(cmd[0], "ssh")
        self.assertIn("-t", cmd)
        self.assertIn("retro", cmd)
        self.assertIn("btop", cmd[-1])
        self.assertLess(cmd[-1].index("btop"), cmd[-1].index("htop"))
        self.assertLess(cmd[-1].index("htop"), cmd[-1].index("top;"))

    def test_local_top_command(self):
        q = load_quivr()
        q.LOCAL_NAMES = {os.uname().nodename.lower(): "alpha"}
        cmd = q.top_command("alpha")
        self.assertEqual(cmd[:2], ["sh", "-c"])


if __name__ == "__main__":
    unittest.main()
