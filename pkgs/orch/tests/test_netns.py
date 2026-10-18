"""Real-sandbox probes through the default wrapper (pasta + bwrap). Skipped unless
both tools exist and a trivial probe runs; no outside network is used."""

import json
import os
import shutil
import socket
import sys
import tempfile
import unittest
from pathlib import Path

from orch import agents

PROBE = r"""
import json, os, socket
out = {"uid": os.getuid()}
def tcp(host, port):
    s = socket.socket(); s.settimeout(2)
    try:
        s.connect((host, port)); return "connected"
    except OSError as e:
        return type(e).__name__
    finally:
        s.close()
def abstract(name):
    s = socket.socket(socket.AF_UNIX); s.settimeout(2)
    try:
        s.connect("\0" + name); return "connected"
    except OSError as e:
        return type(e).__name__
    finally:
        s.close()
t = os.environ.get("PROBE_TCP")
out["tcp"] = tcp("127.0.0.1", int(t)) if t else None
out["abstract"] = abstract(os.environ["PROBE_ABSTRACT"]) if "PROBE_ABSTRACT" in os.environ else None
print(json.dumps(out))
"""


class ProbeAdapter(agents.Adapter):
    name = "probe"
    binary = "python3"

    def __init__(self, code):
        self.code = code

    def home_env(self, home):
        return {"HOME": str(home)}

    def command(self, role, workdir, schema_path, out_path, model):
        return [self.binary, "-c", self.code]

    def parse(self, role, stdout, out_path):
        return stdout, None


def local_addrs():
    """IPv4 addresses assigned to this host, from /proc/net/fib_trie."""
    addrs, last = [], None
    try:
        lines = Path("/proc/net/fib_trie").read_text().splitlines()
    except OSError:
        return addrs
    for ln in lines:
        ln = ln.strip()
        if ln.startswith("|--"):
            last = ln[3:].strip()
        elif ln.startswith("/32 host LOCAL") and last and last not in addrs:
            addrs.append(last)
    return addrs


def primary_addr():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def is_cgnat(a):
    import ipaddress
    return ipaddress.ip_address(a) in ipaddress.ip_network("100.64.0.0/10")


def real_python():
    py = os.path.realpath(sys.executable)
    return py if py.startswith("/nix/store/") else None


class NetnsProbes(unittest.TestCase):
    def setUp(self):
        self.py = real_python()
        if not (self.py and shutil.which("pasta") and shutil.which("bwrap")):
            self.skipTest("needs pasta, bwrap and a store python")
        self.td = tempfile.TemporaryDirectory()
        self.addCleanup(self.td.cleanup)
        root = Path(self.td.name).resolve()
        self.work = root / "work"
        self.work.mkdir()
        self.root = root
        from orch import sandbox
        try:
            sandbox.network_plan(agents._find_ip())
        except (sandbox.NoRoute, sandbox.NoDns) as e:
            self.skipTest(f"no usable route: {e}")
        if self.probe("print(1)").exit_code != 0:
            self.skipTest("pasta/bwrap cannot run here")

    def probe(self, code):
        return agents.run_agent(
            ProbeAdapter(code), "implement", workdir=self.work, prompt="", writable=True,
            home=self.root / "agent-home" / "implement", schema_path=None,
            log_path=self.root / "log.txt", timeout=60, binary=self.py)

    def test_real_uid_not_root_and_isolated_from_host_sockets(self):
        # abstract unix socket, the way Xwayland's @/tmp/.X11-unix/X0 is exposed
        abstract = f"orch-probe-{os.getpid()}"
        unix = socket.socket(socket.AF_UNIX)
        unix.bind("\0" + abstract)
        unix.listen(1)
        self.addCleanup(unix.close)
        tcp = socket.socket()
        tcp.bind(("127.0.0.1", 0))
        tcp.listen(1)
        self.addCleanup(tcp.close)
        port = tcp.getsockname()[1]
        code = ("import os\n"
                f"os.environ['PROBE_TCP'] = '{port}'\n"
                f"os.environ['PROBE_ABSTRACT'] = '{abstract}'\n" + PROBE)
        r = self.probe(code)
        self.assertEqual(r.exit_code, 0, r.text)
        out = json.loads(r.text.strip().splitlines()[-1])
        self.assertNotEqual(out["uid"], 0)
        self.assertEqual(out["uid"], os.getuid())
        self.assertNotEqual(out["tcp"], "connected")
        self.assertNotEqual(out["abstract"], "connected")

    def _host_address_reachability(self, addr):
        lst = socket.socket()
        lst.bind(("0.0.0.0", 0))
        lst.listen(5)
        self.addCleanup(lst.close)
        port = lst.getsockname()[1]
        code = ("import socket\n"
                "s = socket.socket(); s.settimeout(3)\n"
                "try:\n"
                f"    s.connect(({addr!r}, {port})); print('connected')\n"
                "except OSError as e:\n"
                "    print(type(e).__name__)\n")
        r = self.probe(code)
        self.assertEqual(r.exit_code, 0, r.text)
        return r.text.strip()

    def test_host_primary_address_not_reachable(self):
        addr = primary_addr()
        if not addr:
            self.skipTest("no primary address")
        self.assertNotEqual(self._host_address_reachability(addr), "connected")

    def test_host_tailscale_address_not_reachable(self):
        tail = [a for a in local_addrs() if is_cgnat(a)]
        if not tail:
            self.skipTest("no 100.64.0.0/10 address on this host")
        for a in tail:
            with self.subTest(addr=a):
                self.assertNotEqual(self._host_address_reachability(a), "connected")

    def test_worktree_and_home_writable(self):
        r = self.probe("import os\nopen('w.txt','w').write('x')\n"
                       "open(os.environ['HOME'] + '/h.txt','w').write('x')\nprint('ok')")
        self.assertEqual(r.text.strip(), "ok", r.text)
        self.assertTrue((self.work / "w.txt").exists())
        self.assertTrue((self.root / "agent-home" / "implement" / "h.txt").exists())


if __name__ == "__main__":
    unittest.main()
