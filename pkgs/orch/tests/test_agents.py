import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from orch import agents, sandbox
from orch.verdict import REVIEW_SCHEMA

FAKES = Path(__file__).parent / "fakes"
VERDICT = {"verdict": "approve", "summary": "fine", "findings": []}
_BOOT = (
    "import os, runpy, sys\n"
    "os.environ['FAKE_RECORD'], os.environ['FAKE_MODE'] = sys.argv[1:3]\n"
    "sys.argv = sys.argv[3:]\n"
    "runpy.run_path(sys.argv[0], run_name='__main__')\n")


class Base(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        root = Path(self._td.name).resolve()
        self.work = root / "work"
        self.work.mkdir()
        self.home = root / "home"
        self.rec = root / "record.json"
        self.log = root / "logs" / "out.log"
        self.out = root / "out.txt"

    def wrap(self, mode):
        # No /usr/bin/env: the Nix build sandbox has none. The bootstrap adds the
        # FAKE_* vars in-process and runs the fake as __main__.
        def w(cmd, env):
            return [sys.executable, "-c", _BOOT, str(self.rec), mode, *cmd]
        return w

    def run_fake(self, adapter, fake, mode, role="implement", timeout=20, **kw):
        return agents.run_agent(
            adapter, role, workdir=self.work, prompt="do the thing\nline2", home=self.home,
            writable=True, schema_path=Path("/s.json"), log_path=self.log, timeout=timeout,
            wrap=self.wrap(mode), binary=str(FAKES / fake), **kw)

    def record(self):
        return json.loads(self.rec.read_text())


class TestClaude(Base):
    def test_a_command_flags(self):
        a = agents.ClaudeAdapter()
        impl = a.command("implement", self.work, None, self.out, None)
        self.assertEqual(impl, ["claude", "-p", "--output-format", "json",
                                "--dangerously-skip-permissions"])
        rev = a.command("review", self.work, None, self.out, "opus")
        self.assertEqual(rev[-2:], ["--json-schema", json.dumps(REVIEW_SCHEMA)])
        self.assertEqual(rev[rev.index("--model") + 1], "opus")

    def test_b_parse_modes(self):
        for mode, role, text, parsed in [
            ("plain", "implement", "done", None),
            ("review-structured", "review", "ok", VERDICT),
            ("review-text", "review", None, VERDICT),
            ("badjson", "review", "not json\n", None),
        ]:
            with self.subTest(mode=mode):
                r = self.run_fake(agents.ClaudeAdapter(), "fake-claude",
                                  mode, role=role)
                self.assertEqual(r.parsed, parsed)
                if text is not None:
                    self.assertEqual(r.text, text)
                self.assertEqual(r.exit_code, 0)
                self.assertFalse(r.timed_out)

    def test_e_prompt_on_stdin(self):
        self.run_fake(agents.ClaudeAdapter(), "fake-claude", "plain")
        self.assertEqual(self.record()["stdin"], "do the thing\nline2")

    def test_f_env_scrubbed(self):
        leaked = {"SSH_AUTH_SOCK": "/s", "GH_TOKEN": "t", "GITHUB_TOKEN": "t"}
        with mock.patch.dict(os.environ, leaked):
            self.run_fake(agents.ClaudeAdapter(), "fake-claude", "plain")
        env = self.record()["env"]
        for k in leaked:
            self.assertNotIn(k, env)
        self.assertEqual(env["HOME"], str(self.home))
        self.assertEqual(env["CLAUDE_CONFIG_DIR"], str(self.home / ".claude"))

    def test_g_timeout_kills_group(self):
        r = self.run_fake(agents.ClaudeAdapter(), "fake-claude", "hang", timeout=1)
        self.assertTrue(r.timed_out)
        self.assertEqual(r.exit_code, -9)
        pid = self.record()["pid"]
        for _ in range(30):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.1)
        self.fail("fake survived the timeout")

    def test_h_nonzero_exit_returned(self):
        r = self.run_fake(agents.ClaudeAdapter(), "fake-claude", "fail")
        self.assertEqual(r.exit_code, 3)
        self.assertIn("boom", r.text)

    def test_i_log_written(self):
        self.run_fake(agents.ClaudeAdapter(), "fake-claude", "plain")
        self.assertIn("done", self.log.read_text())


class TestHomeDirs(Base):
    def test_run_agent_creates_home_and_config_dirs_0700(self):
        for adapter, fake, sub in [(agents.ClaudeAdapter(), "fake-claude", ".claude"),
                                   (agents.CodexAdapter(), "fake-codex", ".codex")]:
            with self.subTest(sub=sub):
                self.home = Path(self._td.name) / f"home{sub}"
                self.run_fake(adapter, fake, "plain")
                self.assertEqual(self.home.stat().st_mode & 0o777, 0o700)
                self.assertEqual((self.home / sub).stat().st_mode & 0o777, 0o700)

    def test_existing_loose_home_tightened(self):
        self.home.mkdir(mode=0o755)
        self.home.chmod(0o755)
        self.run_fake(agents.CodexAdapter(), "fake-codex", "plain")
        self.assertEqual(self.home.stat().st_mode & 0o777, 0o700)


class TestRunHome(Base):
    ADAPTERS = (agents.ClaudeAdapter(), agents.CodexAdapter())

    def setUp(self):
        super().setUp()
        self.auth = Path(self._td.name) / "auth"
        self.rh = Path(self._td.name) / "run" / "agent-home" / "implement"

    def put(self, root, rel, text, mode=0o600):
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        p.chmod(mode)
        return p

    def test_credential_files_declared(self):
        self.assertEqual(agents.ClaudeAdapter.credential_files, (".claude/.credentials.json",))
        self.assertEqual(agents.CodexAdapter.credential_files, (".codex/auth.json",))

    def test_only_credentials_seeded(self):
        for a in self.ADAPTERS:
            with self.subTest(a=a.name):
                auth = self.auth / a.name
                for rel in ("settings.json", "CLAUDE.md", ".claude/settings.json",
                            ".claude/CLAUDE.md", ".codex/config.toml", ".codex/hooks.json"):
                    self.put(auth, rel, "evil")
                self.put(auth, a.credential_files[0], '{"t": 1}')
                rh = self.rh / a.name
                agents.prepare_run_home(a, auth, rh)
                found = sorted(str(p.relative_to(rh)) for p in rh.rglob("*") if p.is_file())
                self.assertEqual(found, [a.credential_files[0]])
                cred = rh / a.credential_files[0]
                self.assertEqual(cred.read_text(), '{"t": 1}')
                self.assertEqual(cred.stat().st_mode & 0o777, 0o600)
                self.assertEqual(rh.stat().st_mode & 0o777, 0o700)
                self.assertEqual(cred.parent.stat().st_mode & 0o777, 0o700)

    def test_hostile_run_does_not_affect_next(self):
        a = agents.ClaudeAdapter()
        self.put(self.auth, a.credential_files[0], '{"t": 1}')
        agents.prepare_run_home(a, self.auth, self.rh)
        self.put(self.rh, ".claude/settings.json", '{"hooks": "evil"}')
        self.put(self.rh, "CLAUDE.md", "evil")
        agents.finish_run_home(a, self.auth, self.rh)
        self.assertFalse((self.auth / ".claude" / "settings.json").exists())
        self.assertFalse((self.auth / "CLAUDE.md").exists())
        agents.prepare_run_home(a, self.auth, self.rh)
        self.assertFalse((self.rh / ".claude" / "settings.json").exists())
        self.assertFalse((self.rh / "CLAUDE.md").exists())

    def test_refreshed_credentials_copied_back(self):
        a = agents.CodexAdapter()
        auth = self.put(self.auth, a.credential_files[0], '{"t": 1}', mode=0o644)
        agents.prepare_run_home(a, self.auth, self.rh)
        (self.rh / a.credential_files[0]).write_text('{"t": 2}')
        agents.finish_run_home(a, self.auth, self.rh)
        self.assertEqual(auth.read_text(), '{"t": 2}')
        self.assertEqual(auth.stat().st_mode & 0o777, 0o600)
        self.assertEqual([p.name for p in auth.parent.iterdir()], ["auth.json"])

    def test_first_credentials_created_in_auth_store(self):
        a = agents.ClaudeAdapter()
        agents.prepare_run_home(a, self.auth, self.rh)
        self.put(self.rh, a.credential_files[0], '{"t": 3}')
        agents.finish_run_home(a, self.auth, self.rh)
        self.assertEqual((self.auth / a.credential_files[0]).read_text(), '{"t": 3}')

    def test_symlinked_credential_skipped_both_ways(self):
        a = agents.ClaudeAdapter()
        secret = Path(self._td.name) / "secret"
        secret.write_text('{"s": 1}')
        cred = self.auth / a.credential_files[0]
        cred.parent.mkdir(parents=True)
        cred.symlink_to(secret)
        agents.prepare_run_home(a, self.auth, self.rh)
        self.assertFalse((self.rh / a.credential_files[0]).exists())
        self.assertFalse((self.rh / a.credential_files[0]).is_symlink())
        cred.unlink()
        self.put(self.auth, a.credential_files[0], '{"t": 1}')
        agents.prepare_run_home(a, self.auth, self.rh)
        rc = self.rh / a.credential_files[0]
        rc.unlink()
        rc.symlink_to(secret)
        agents.finish_run_home(a, self.auth, self.rh)
        self.assertEqual((self.auth / a.credential_files[0]).read_text(), '{"t": 1}')

    def test_symlinked_config_dir_skipped_on_copy_back(self):
        a = agents.ClaudeAdapter()
        self.put(self.auth, a.credential_files[0], '{"t": 1}')
        agents.prepare_run_home(a, self.auth, self.rh)
        elsewhere = Path(self._td.name) / "elsewhere"
        self.put(elsewhere, ".credentials.json", '{"t": "stolen"}')
        shutil.rmtree(self.rh / ".claude")
        (self.rh / ".claude").symlink_to(elsewhere)
        agents.finish_run_home(a, self.auth, self.rh)
        self.assertEqual((self.auth / a.credential_files[0]).read_text(), '{"t": 1}')
        self.assertEqual((elsewhere / ".credentials.json").read_text(), '{"t": "stolen"}')

    def test_oversize_and_non_json_copy_back_ignored(self):
        a = agents.CodexAdapter()
        auth = self.put(self.auth, a.credential_files[0], '{"t": 1}')
        for bad in ("not json", "[1, 2]", '{"pad": "' + "x" * agents.CRED_MAX_BYTES + '"}'):
            with self.subTest(n=len(bad)):
                agents.prepare_run_home(a, self.auth, self.rh)
                (self.rh / a.credential_files[0]).write_text(bad)
                agents.finish_run_home(a, self.auth, self.rh)
                self.assertEqual(auth.read_text(), '{"t": 1}')
                self.assertFalse(self.rh.exists())

    def test_oversize_not_seeded(self):
        a = agents.CodexAdapter()
        self.put(self.auth, a.credential_files[0], "x" * (agents.CRED_MAX_BYTES + 1))
        agents.prepare_run_home(a, self.auth, self.rh)
        self.assertFalse((self.rh / a.credential_files[0]).exists())

    def test_removed_even_with_read_only_subdirs(self):
        a = agents.ClaudeAdapter()
        agents.prepare_run_home(a, self.auth, self.rh)
        sub = self.rh / "ro" / "deeper"
        sub.mkdir(parents=True)
        (sub / "f").write_text("x")
        sub.chmod(0o500)
        (self.rh / "ro").chmod(0o500)
        agents.finish_run_home(a, self.auth, self.rh)
        self.assertFalse(self.rh.exists())

    def test_stale_run_home_replaced(self):
        a = agents.ClaudeAdapter()
        self.put(self.rh, "leftover", "x")
        agents.prepare_run_home(a, self.auth, self.rh)
        self.assertFalse((self.rh / "leftover").exists())

    def test_distinct_homes_per_role_via_cli(self):
        from orch import cli
        seen = []

        def fake(adapter, role, **kw):
            seen.append(kw["home"])
            return agents.Result("", None, 0, False)
        work = Path(self._td.name) / "runs" / "r1" / "work"
        work.mkdir(parents=True)
        fn = cli._make_run_agent({"agents": {}})
        with mock.patch.object(agents, "run_agent", fake), \
                mock.patch.dict(os.environ, {"ORCH_HOME": str(Path(self._td.name) / "orch")}):
            for role in ("implement", "review"):
                fn(role, "claude", workdir=work, prompt="p", writable=True,
                   schema_path=None, log_path=Path("/l"), timeout=1)
        self.assertEqual(seen, [work.parent / "agent-home" / "implement",
                                work.parent / "agent-home" / "review"])
        self.assertFalse((work.parent / "agent-home" / "implement").exists())


class TestCodex(Base):
    def test_c_command(self):
        a = agents.CodexAdapter()
        impl = a.command("implement", self.work, Path("/s.json"), self.out, None)
        self.assertIn("--dangerously-bypass-approvals-and-sandbox", impl)
        self.assertEqual(impl[impl.index("-C") + 1], str(self.work))
        self.assertEqual(impl[-3:], ["-o", str(self.out), "-"])
        self.assertNotIn("--output-schema", impl)
        self.assertNotIn("-m", impl)
        rev = a.command("review", self.work, Path("/s.json"), self.out, "m1")
        self.assertEqual(rev[rev.index("--output-schema") + 1], "/s.json")
        self.assertEqual(rev[rev.index("-m") + 1], "m1")
        self.assertEqual(rev[-3:], ["-o", str(self.out), "-"])

    def test_d_reads_out_file(self):
        a = agents.CodexAdapter()
        # run_agent chooses out_path itself; the fake writes wherever -o points
        r = self.run_fake(a, "fake-codex", "review", role="review")
        self.assertEqual(r.parsed["verdict"], "changes")
        r = self.run_fake(a, "fake-codex", "plain")
        self.assertEqual(r.text, "implemented")
        self.assertEqual(self.record()["env"]["CODEX_HOME"], str(self.home / ".codex"))

    def test_g_timeout(self):
        r = self.run_fake(agents.CodexAdapter(), "fake-codex", "hang", timeout=1)
        self.assertTrue(r.timed_out)
        self.assertEqual(r.exit_code, -9)


PASTA = "/nix/store/x-passt/bin/pasta"
_REAL_FIND_PASTA = agents._find_pasta
_REAL_FIND_IP = agents._find_ip


class TestDefaultWrap(Base):
    def setUp(self):
        super().setUp()
        for p in (mock.patch.object(agents, "_find_pasta", lambda: PASTA),
                  mock.patch.object(agents, "_find_ip", lambda: "/nix/store/x-iproute2/bin/ip"),
                  mock.patch.object(sandbox, "network_plan",
                                    lambda ip, dns=None: sandbox.NetPlan("eth0", "10.0.0.1", dns or "9.9.9.9"))):
            p.start()
            self.addCleanup(p.stop)

    def _run_recorded(self):
        calls = []

        class FakeProc:
            pid = 1
            returncode = 0

            def communicate(self, input=None, timeout=None):
                return ("out", None)

            def kill(self):
                pass

        def fake_popen(argv, **kw):
            calls.append((argv, kw))
            return FakeProc()

        leaked = {"SSH_AUTH_SOCK": "/s", "GH_TOKEN": "t", "GITHUB_TOKEN": "t"}
        with mock.patch.dict(os.environ, leaked), \
                mock.patch.object(agents, "STORE_PREFIX", str(FAKES.resolve()) + "/"), \
                mock.patch.object(subprocess, "Popen", fake_popen):
            agents.run_agent(
                agents.ClaudeAdapter(), "implement", workdir=self.work, prompt="p",
                home=self.home, writable=True, schema_path=None, log_path=self.log,
                timeout=5, binary=str(FAKES / "fake-claude"))
        return calls[0]

    def test_j_bwrap_first_and_setenv_allowed(self):
        argv, kw = self._run_recorded()
        self.assertEqual(argv[0], PASTA)
        self.assertEqual(argv[argv.index("--") + 1], "bwrap")
        for bad in ("--share-net", "--unshare-all", "--unshare-net"):
            self.assertNotIn(bad, argv)
        self.assertEqual(argv[argv.index("--outbound-if4") + 1], "eth0")
        self.assertEqual(argv[argv.index("--dns-host") + 1], "9.9.9.9")
        self.assertIn("-4", argv[:argv.index("--")])
        i = argv.index("/etc/resolv.conf")
        resolv = Path(argv[i - 1])
        self.assertEqual(argv[i - 2], "--ro-bind")
        self.assertEqual(resolv.read_text(), "nameserver 192.0.2.53\n")
        self.assertFalse(resolv.is_relative_to(self.home))
        self.assertFalse(resolv.is_relative_to(self.work))
        keys = [argv[i + 1] for i, a in enumerate(argv) if a == "--setenv"]
        self.assertTrue(keys)
        for k in keys:
            self.assertIn(k, sandbox.ALLOWED_ENV)

    def test_no_secrets_in_argv_or_env(self):
        argv, kw = self._run_recorded()
        blob = "\0".join(argv) + "\0" + "\0".join(f"{k}={v}" for k, v in kw["env"].items())
        for k in ("SSH_AUTH_SOCK", "GH_TOKEN", "GITHUB_TOKEN"):
            self.assertNotIn(k, blob)
        self.assertEqual(set(kw["env"]), {"PATH"})

    def test_fail_closed_without_pasta(self):
        with mock.patch.object(agents, "_find_pasta", _REAL_FIND_PASTA), \
                mock.patch.dict(os.environ, {"PATH": "/nonexistent"}), \
                mock.patch.object(subprocess, "Popen", side_effect=AssertionError("spawned")), \
                mock.patch.object(agents, "STORE_PREFIX", str(FAKES.resolve()) + "/"):
            with self.assertRaisesRegex(FileNotFoundError, "pasta"):
                agents.run_agent(
                    agents.ClaudeAdapter(), "implement", workdir=self.work, prompt="p",
                    home=self.home, writable=True, schema_path=None, log_path=self.log,
                    timeout=5, binary=str(FAKES / "fake-claude"))

    def _run_default(self, **kw):
        return agents.run_agent(
            agents.ClaudeAdapter(), "implement", workdir=self.work, prompt="p",
            home=self.home, writable=True, schema_path=None, log_path=self.log,
            timeout=5, binary=str(FAKES / "fake-claude"), **kw)

    def test_fail_closed_without_route(self):
        with mock.patch.object(sandbox, "network_plan",
                               mock.Mock(side_effect=sandbox.NoRoute("no route to the internet"))), \
                mock.patch.object(subprocess, "Popen", side_effect=AssertionError("spawned")), \
                mock.patch.object(agents, "STORE_PREFIX", str(FAKES.resolve()) + "/"):
            with self.assertRaises(sandbox.NoRoute):
                self._run_default()

    def test_fail_closed_when_ip_missing_or_outside_store(self):
        d = Path(self._td.name) / "bin"
        d.mkdir()
        (d / "ip").write_text("#!/bin/sh\n")
        (d / "ip").chmod(0o755)
        for path in ("/nonexistent", str(d)):
            with self.subTest(path=path), \
                    mock.patch.object(agents, "_find_ip", _REAL_FIND_IP), \
                    mock.patch.dict(os.environ, {"PATH": path}), \
                    mock.patch.object(subprocess, "Popen", side_effect=AssertionError("spawned")), \
                    mock.patch.object(agents, "_find_pasta", lambda: PASTA), \
                    mock.patch.object(agents, "STORE_PREFIX", str(FAKES.resolve()) + "/"):
                with self.assertRaisesRegex(sandbox.NoRoute, "ip"):
                    self._run_default()

    def test_dns_config_reaches_plan_and_argv_and_log(self):
        calls = []

        class P:
            pid, returncode = 1, 0

            def communicate(self, input=None, timeout=None):
                return ("out\n", None)
        with mock.patch.object(agents, "STORE_PREFIX", str(FAKES.resolve()) + "/"), \
                mock.patch.object(subprocess, "Popen", lambda argv, **kw: calls.append(argv) or P()), \
                mock.patch.object(sandbox, "network_plan",
                                  lambda ip, dns=None: sandbox.NetPlan("wg0", None, dns, "config")):
            self._run_default(dns="10.2.0.1")
        argv = calls[0]
        self.assertEqual(argv[argv.index("--outbound-if4") + 1], "wg0")
        self.assertEqual(argv[argv.index("--dns-host") + 1], "10.2.0.1")
        self.assertEqual(self.log.read_text(),
                         "orch: network dev=wg0 gateway=- dns-host=10.2.0.1 (config)\nout\n")

    def test_pasta_outside_store_rejected(self):
        d = Path(self._td.name) / "bin"
        d.mkdir()
        (d / "pasta").write_text("#!/bin/sh\n")
        (d / "pasta").chmod(0o755)
        with mock.patch.object(agents, "_find_pasta", _REAL_FIND_PASTA), \
                mock.patch.dict(os.environ, {"PATH": str(d)}):
            with self.assertRaisesRegex(ValueError, "pasta"):
                agents._find_pasta()

    def test_pasta_keeps_its_name_when_symlink_into_store(self):
        store = Path(self._td.name) / "store"
        store.mkdir()
        (store / "passt").write_text("#!/bin/sh\n")
        (store / "passt").chmod(0o755)
        d = Path(self._td.name) / "bin"
        d.mkdir()
        (d / "pasta").symlink_to(store / "passt")
        with mock.patch.object(agents, "_find_pasta", _REAL_FIND_PASTA), \
                mock.patch.object(agents, "STORE_PREFIX", str(store.resolve()) + "/"), \
                mock.patch.dict(os.environ, {"PATH": str(d)}):
            self.assertEqual(agents._find_pasta(), str(d / "pasta"))

    def test_extra_ro_reaches_bwrap(self):
        mirror = Path(self._td.name) / "m.git"
        calls = []

        class P:
            pid, returncode = 1, 0

            def communicate(self, input=None, timeout=None):
                return ("out", None)
        with mock.patch.object(agents, "STORE_PREFIX", str(FAKES.resolve()) + "/"), \
                mock.patch.object(subprocess, "Popen", lambda argv, **kw: calls.append(argv) or P()):
            agents.run_agent(
                agents.ClaudeAdapter(), "review", workdir=self.work, prompt="p",
                home=self.home, writable=False, schema_path=None, log_path=self.log,
                timeout=5, binary=str(FAKES / "fake-claude"), extra_ro=(mirror,))
        argv = calls[0]
        i = argv.index(str(mirror))
        self.assertEqual(argv[i - 1:i + 2], ["--ro-bind", str(mirror), str(mirror)])

    def test_keyboard_interrupt_kills_agent_group(self):
        killed = []

        class P:
            pid, returncode = 4242, None

            def communicate(self, input=None, timeout=None):
                raise KeyboardInterrupt
        with mock.patch.object(agents, "STORE_PREFIX", str(FAKES.resolve()) + "/"), \
                mock.patch.object(subprocess, "Popen", lambda argv, **kw: P()), \
                mock.patch.object(os, "killpg", lambda pid, sig: killed.append((pid, sig))), \
                self.assertRaises(KeyboardInterrupt):
            agents.run_agent(
                agents.ClaudeAdapter(), "implement", workdir=self.work, prompt="p",
                home=self.home, writable=True, schema_path=None, log_path=self.log,
                timeout=5, binary=str(FAKES / "fake-claude"))
        self.assertEqual(killed[0][0], 4242)

    def test_nested_paths_rejected_before_spawn(self):
        with mock.patch.object(subprocess, "Popen", side_effect=AssertionError("spawned")):
            with self.assertRaises(ValueError):
                agents.run_agent(
                    agents.ClaudeAdapter(), "implement", workdir=self.work, prompt="p",
                    home=self.work / "home", writable=True, schema_path=None,
                    log_path=self.log, timeout=5, binary=str(FAKES / "fake-claude"))


class TestResultFile(Base):
    def _codex(self, prepare):
        out = self.home / "codex-last-message.txt"
        self.home.mkdir(parents=True, exist_ok=True)
        prepare(out)

        def w(cmd, env):
            return [sys.executable, "-c", "print('codex stdout')"]
        return agents.run_agent(
            agents.CodexAdapter(), "implement", workdir=self.work, prompt="p", home=self.home,
            writable=True, schema_path=None, log_path=self.log, timeout=10, wrap=w,
            binary=str(FAKES / "fake-codex"))

    def test_symlink_not_followed(self):
        secret = Path(self._td.name) / "secret"
        secret.write_text("TOPSECRET")
        r = self._codex(lambda out: out.symlink_to(secret))
        self.assertNotIn("TOPSECRET", r.text)
        self.assertIn("codex stdout", r.text)
        self.assertEqual(secret.read_text(), "TOPSECRET")

    def test_directory_falls_back(self):
        # pre-run cleanup removes a planted directory; one created during the run is skipped
        def w(cmd, env):
            return [sys.executable, "-c",
                    f"import os; os.mkdir({str(self.home / 'codex-last-message.txt')!r}); print('codex stdout')"]
        r = agents.run_agent(
            agents.CodexAdapter(), "implement", workdir=self.work, prompt="p", home=self.home,
            writable=True, schema_path=None, log_path=self.log, timeout=10, wrap=w,
            binary=str(FAKES / "fake-codex"))
        self.assertIn("codex stdout", r.text)
        (self.home / "codex-last-message.txt").rmdir()
        r = self._codex(lambda out: out.mkdir())
        self.assertIn("codex stdout", r.text)

    def test_regular_file_read(self):
        out = self.home / "codex-last-message.txt"

        def w(cmd, env):
            return [sys.executable, "-c", f"open({str(out)!r}, 'w').write('written\\n')"]
        r = agents.run_agent(
            agents.CodexAdapter(), "implement", workdir=self.work, prompt="p", home=self.home,
            writable=True, schema_path=None, log_path=self.log, timeout=10, wrap=w,
            binary=str(FAKES / "fake-codex"))
        self.assertEqual(r.text, "written\n")

    def test_oversized_falls_back_to_stdout(self):
        out = self.home / "codex-last-message.txt"

        def w(cmd, env):
            return [sys.executable, "-c",
                    f"open({str(out)!r}, 'wb').write(bytes({agents.MAX_RESULT_BYTES + 1})); print('small')"]
        r = agents.run_agent(
            agents.CodexAdapter(), "implement", workdir=self.work, prompt="p", home=self.home,
            writable=True, schema_path=None, log_path=self.log, timeout=10, wrap=w,
            binary=str(FAKES / "fake-codex"))
        self.assertEqual(r.text, "small\n")

    def test_preexisting_symlink_unlinked_not_followed(self):
        secret = Path(self._td.name) / "secret"
        secret.write_text("TOPSECRET")
        self.home.mkdir(parents=True)
        (self.home / "codex-last-message.txt").symlink_to(secret)
        agents.run_agent(
            agents.CodexAdapter(), "implement", workdir=self.work, prompt="p", home=self.home,
            writable=True, schema_path=None, log_path=self.log, timeout=10,
            wrap=lambda c, e: [sys.executable, "-c", "pass"], binary=str(FAKES / "fake-codex"))
        self.assertFalse((self.home / "codex-last-message.txt").is_symlink())
        self.assertEqual(secret.read_text(), "TOPSECRET")


class TestStoreBinary(Base):
    def _popen_guard(self):
        return mock.patch.object(subprocess, "Popen", side_effect=AssertionError("spawned"))

    def _run(self, binary, wrap=None):
        return agents.run_agent(
            agents.ClaudeAdapter(), "implement", workdir=self.work, prompt="p", home=self.home,
            writable=True, schema_path=None, log_path=self.log, timeout=5, binary=str(binary),
            wrap=wrap)

    def test_non_store_binary_rejected(self):
        with self._popen_guard(), self.assertRaisesRegex(ValueError, "not under /nix/store"):
            self._run(FAKES / "fake-claude")

    def test_symlink_to_non_store_rejected(self):
        link = Path(self._td.name) / "claude"
        link.symlink_to(FAKES / "fake-claude")
        with self._popen_guard(), self.assertRaisesRegex(ValueError, "not under /nix/store"):
            self._run(link)

    def test_injected_wrap_skips_check_and_uses_realpath(self):
        link = Path(self._td.name) / "claude"
        link.symlink_to(FAKES / "fake-claude")
        self._run(link, wrap=self.wrap("plain"))
        self.assertEqual(self.record()["argv"][0:1], ["-p"])
        seen = []
        self._run(link, wrap=lambda cmd, env: seen.append((cmd, env)) or [sys.executable, "-c", "pass"])
        self.assertEqual(seen[0][0][0], os.path.realpath(link))
        self.assertTrue(seen[0][1]["PATH"].endswith(str(FAKES.resolve())))


class TestMissing(Base):
    def test_k_missing_binary(self):
        with mock.patch.dict(os.environ, {"PATH": "/nonexistent"}):
            with self.assertRaises(FileNotFoundError):
                agents.run_agent(
                    agents.ClaudeAdapter(), "implement", workdir=self.work, prompt="p",
                    home=self.home, writable=True, schema_path=None, log_path=self.log, timeout=5)


if __name__ == "__main__":
    unittest.main()
