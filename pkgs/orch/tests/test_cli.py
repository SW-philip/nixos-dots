import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from orch import agents, cli, state
from orch.agents import Result
from orch.state import RunState


def call(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = cli.main(argv)
        except SystemExit as e:
            code = e.code
    return code, out.getvalue(), err.getvalue()


def make_fake(final, calls):
    class FakeOrch:
        def __init__(self, cfg, *, gh, git, run_agent, now=None):
            calls["init"] = dict(cfg=cfg, gh=gh, git=git, run_agent=run_agent)

        def run(self, repo, issue, implementer=None, reviewer=None, max_rounds=None):
            calls["run"] = (repo, issue, implementer, reviewer, max_rounds)
            return final

        def resume(self, run_id):
            calls["resume"] = run_id
            return final
    return FakeOrch


def st(run_id="20260101-000000-o-r-7", **kw):
    base = dict(run_id=run_id, repo="o/r", issue=7, implementer="claude",
                reviewer="codex", max_rounds=3)
    base.update(kw)
    return RunState(**base)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "orchhome"
        p = mock.patch.dict(os.environ, {"ORCH_HOME": str(self.home),
                                         "HOME": str(Path(self.tmp.name) / "h")})
        p.start()
        self.addCleanup(p.stop)
        self.cfgfile = Path(self.tmp.name) / "c.toml"
        self.cfgfile.write_text('max_rounds = 4\n')


class RunTests(Base):
    def run_cli(self, final, *extra, cmd=("run", "o/r", "7")):
        calls = {}
        with mock.patch.object(cli, "Orchestrator", make_fake(final, calls)):
            res = call([*cmd, "--config", str(self.cfgfile), *extra])
        return (*res, calls)

    def test_done_exit0_and_stdout_line(self):
        code, out, err, calls = self.run_cli(st(status="done", pr_url="https://x/pr/1"))
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), "done https://x/pr/1")
        self.assertEqual(calls["run"], ("o/r", 7, None, None, None))
        self.assertEqual(calls["init"]["cfg"]["max_rounds"], 4)

    def test_failed_and_needs_human_exit1(self):
        s = st(status="failed", reason="boom")
        code, out, _, _ = self.run_cli(s)
        self.assertEqual(code, 1)
        self.assertEqual(out.strip(), f"failed boom ({state.run_dir(s.run_id)})")
        s = st(status="needs-human", reason="not approved")
        code, out, _, _ = self.run_cli(s)
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("needs-human not approved ("))

    def test_flags_pass_through(self):
        _, _, _, calls = self.run_cli(st(status="done", pr_url="u"), "--impl", "codex",
                                      "--review", "claude", "--rounds", "2")
        self.assertEqual(calls["run"], ("o/r", 7, "codex", "claude", 2))

    def test_collaborators_are_real_modules(self):
        _, _, _, calls = self.run_cli(st(status="done", pr_url="u"))
        from orch import github, gitops
        self.assertIs(calls["init"]["gh"], github)
        self.assertIs(calls["init"]["git"], gitops)

    def test_same_agent_warns_but_runs(self):
        code, _, err, calls = self.run_cli(st(status="done", pr_url="u"),
                                           "--impl", "claude", "--review", "claude")
        self.assertEqual(code, 0)
        self.assertIn("same agent reviews its own work", err)
        self.assertIn("run", calls)

    def test_unknown_agent_exit2(self):
        code, _, _, calls = self.run_cli(st(status="done"), "--impl", "gpt")
        self.assertEqual(code, 2)
        self.assertNotIn("run", calls)

    def test_bad_config_exit2(self):
        self.cfgfile.write_text("max_rounds = 'x'\n")
        code, out, err, calls = self.run_cli(st(status="done"))
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn("max_rounds", err)
        self.assertNotIn("run", calls)

    def test_explicit_missing_config_exit2(self):
        for cmd in (("run", "o/r", "7"), ("resume", "20260101-000000-o-r-7")):
            calls = {}
            with mock.patch.object(cli, "Orchestrator", make_fake(st(status="done"), calls)):
                code, out, err = call([*cmd, "--config", str(self.home / "nope.toml")])
            self.assertEqual(code, 2)
            self.assertIn("config file not found", err)
            self.assertEqual(calls, {})
            self.assertFalse(self.home.exists())

    def test_config_directory_exit2(self):
        calls = {}
        with mock.patch.object(cli, "Orchestrator", make_fake(st(status="done"), calls)):
            code, _, err = call(["run", "o/r", "7", "--config", self.tmp.name])
        self.assertEqual(code, 2)
        self.assertIn("not a file", err)
        self.assertEqual(calls, {})

    def test_unreadable_config_exit2(self):
        with mock.patch.object(cli.config, "load", side_effect=PermissionError("denied")):
            code, _, err = call(["run", "o/r", "7", "--config", str(self.cfgfile)])
        self.assertEqual(code, 2)
        self.assertIn("denied", err)

    def test_default_config_absent_uses_defaults(self):
        calls = {}
        with mock.patch.object(cli, "Orchestrator", make_fake(st(status="done", pr_url="u"), calls)):
            code, _, _ = call(["run", "o/r", "7"])
        self.assertEqual(code, 0)
        self.assertEqual(calls["init"]["cfg"]["max_rounds"], 3)

    def test_valueerror_from_run_exit2(self):
        class Bad:
            def __init__(self, *a, **k):
                pass

            def run(self, *a, **k):
                raise ValueError("max_rounds must be an integer >= 0, got -1")
        with mock.patch.object(cli, "Orchestrator", Bad):
            code, out, err = call(["run", "o/r", "7", "--config", str(self.cfgfile)])
        self.assertEqual(code, 2)
        self.assertIn("max_rounds", err)

    def test_argument_bounds_exit2(self):
        cases = [(["o/r", "0"], "issue"), (["o/r", "-3"], "issue"), (["o/r", "x"], "issue"),
                 (["o/r", "1.5"], "issue"),
                 (["o/r", "7", "--rounds", "-1"], "rounds"),
                 (["o/r", "7", "--rounds", "11"], "rounds"),
                 (["o/r", "7", "--rounds", "x"], "rounds"),
                 (["/tmp/local", "7"], "repo"), (["./x/y", "7"], "repo"),
                 (["justname", "7"], "repo"), (["a/b/c", "7"], "repo"),
                 (["../..", "7"], "repo"), (["a/b c", "7"], "repo"), (["-x/y", "7"], "repo"),
                 (["o/r\n", "7"], "repo")]
        for argv, word in cases:
            with self.subTest(argv=argv):
                code, out, err, calls = self.run_cli(st(status="done"), cmd=("run", *argv))
                self.assertEqual(code, 2)
                self.assertIn(word, err)
                self.assertNotIn("run", calls)

    def test_argument_bounds_accept_edges(self):
        for rounds in ("0", "10"):
            _, _, _, calls = self.run_cli(st(status="done", pr_url="u"),
                                          "--rounds", rounds, cmd=("run", "Own.er-1/re_po.x", "1"))
            self.assertEqual(calls["run"][1:2], (1,))
            self.assertEqual(calls["run"][4], int(rounds))

    def test_resume(self):
        code, out, _, calls = self.run_cli(st(status="done", pr_url="u"),
                                           cmd=("resume", "20260101-000000-o-r-7"))
        self.assertEqual(code, 0)
        self.assertEqual(calls["resume"], "20260101-000000-o-r-7")
        self.assertEqual(out.strip(), "done u")

    def test_interrupt_reports_resume_hint_exit_130(self):
        from orch.runner import Interrupted

        class Orch:
            def __init__(self, *a, **k):
                pass

            def run(self, *a, **k):
                raise Interrupted("RID-1")

            def resume(self, run_id):
                raise KeyboardInterrupt
        with mock.patch.object(cli, "Orchestrator", Orch):
            code, out, err = call(["run", "o/r", "7"])
            self.assertEqual((code, out), (130, ""))
            self.assertIn("interrupted: orch resume RID-1", err)
            code, _, err = call(["resume", "20260101-000000-o-r-7"])
            self.assertEqual(code, 130)
            self.assertIn("interrupted: orch resume 20260101-000000-o-r-7", err)

    def test_resume_bad_id(self):
        for bad in ("../x", "a/b", "..", "."):
            code, _, _, calls = self.run_cli(st(status="done"), cmd=("resume", bad))
            self.assertEqual(code, 2, bad)
            self.assertNotIn("resume", calls)

    def test_issue_body_never_printed(self):
        s = st(status="failed", reason="boom")
        _, out, err, _ = self.run_cli(s)
        self.assertNotIn("body", out + err)


class RunAgentClosureTests(Base):
    def closure(self, cfg=None):
        calls = {}
        with mock.patch.object(cli, "Orchestrator", make_fake(st(status="done"), calls)):
            call(["run", "o/r", "7", "--config", str(self.cfgfile)])
        return calls["init"]["run_agent"]

    @property
    def work(self):
        w = Path(self.tmp.name) / "runs" / "r1" / "work"
        w.mkdir(parents=True, exist_ok=True)
        return w

    def test_binds_registry_home_model_and_packaged_schema(self):
        self.cfgfile.write_text('[agents.codex]\nmodel = "m1"\n')
        fn = self.closure()
        captured = {}

        def fake(adapter, role, **kw):
            captured.update(adapter=adapter, role=role, **kw)
            return Result("", None, 0, False)
        with mock.patch.object(agents, "run_agent", fake):
            fn("review", "codex", workdir=self.work, prompt="p", writable=False,
               schema_path=Path("/evil/schema.json"), log_path=Path("/l"), timeout=9)
        self.assertIsInstance(captured["adapter"], agents.CodexAdapter)
        self.assertEqual(captured["role"], "review")
        self.assertEqual(captured["home"], self.work.parent / "agent-home" / "review")
        self.assertEqual(captured["model"], "m1")
        self.assertEqual(captured["timeout"], 9)
        self.assertEqual(captured["schema_path"],
                         Path(cli.__file__).parent / "schemas" / "review.json")
        self.assertTrue(captured["schema_path"].is_file())
        self.assertIsNone(captured.get("wrap"))
        self.assertIsNone(captured.get("binary"))

    def test_extra_ro_forwarded(self):
        fn = self.closure()
        captured = {}
        with mock.patch.object(agents, "run_agent",
                               lambda a, r, **kw: captured.update(kw) or Result("", None, 0, False)):
            fn("review", "claude", workdir=self.work, prompt="p", writable=False,
               schema_path=None, log_path=Path("/l"), timeout=9, extra_ro=(Path("/m"),))
        self.assertEqual(captured["extra_ro"], (Path("/m"),))

    def test_dns_config_forwarded(self):
        self.cfgfile.write_text('dns = "10.2.0.1"\n')
        fn = self.closure()
        captured = {}
        with mock.patch.object(agents, "run_agent",
                               lambda a, r, **kw: captured.update(kw) or Result("", None, 0, False)):
            fn("implement", "claude", workdir=self.work, prompt="p", writable=True,
               schema_path=None, log_path=Path("/l"), timeout=9)
        self.assertEqual(captured["dns"], "10.2.0.1")

    def test_per_run_home_lifecycle(self):
        fn = self.closure()
        auth = state.data_dir() / "agents" / "claude" / "home"
        (auth / ".claude").mkdir(parents=True)
        (auth / ".claude" / ".credentials.json").write_text('{"t": 1}')
        (auth / ".claude" / "settings.json").write_text("planted")
        seen = {}

        def refresh(adapter, role, **kw):
            h = kw["home"]
            seen["files"] = sorted(str(p.relative_to(h)) for p in h.rglob("*") if p.is_file())
            seen["home"] = h
            (h / ".claude" / ".credentials.json").write_text('{"t": 2}')
            (h / ".claude" / "settings.json").write_text("hostile")
            return Result("", None, 0, False)
        with mock.patch.object(agents, "run_agent", refresh):
            fn("implement", "claude", workdir=self.work, prompt="p", writable=True,
               schema_path=None, log_path=Path("/l"), timeout=9)
        self.assertEqual(seen["files"], [".claude/.credentials.json"])
        self.assertFalse(seen["home"].exists())
        self.assertEqual((auth / ".claude" / ".credentials.json").read_text(), '{"t": 2}')
        self.assertEqual((auth / ".claude" / "settings.json").read_text(), "planted")

    def test_per_run_home_removed_when_agent_raises(self):
        fn = self.closure()
        homes = []

        def boom(adapter, role, **kw):
            homes.append(kw["home"])
            self.assertTrue(kw["home"].is_dir())
            raise RuntimeError("agent blew up")
        with mock.patch.object(agents, "run_agent", boom), self.assertRaises(RuntimeError):
            fn("implement", "claude", workdir=self.work, prompt="p", writable=True,
               schema_path=None, log_path=Path("/l"), timeout=9)
        self.assertFalse(homes[0].exists())

    def test_per_run_home_removed_on_timeout_and_failure_results(self):
        fn = self.closure()
        for res in (Result("", None, -9, True), Result("boom", None, 3, False)):
            homes = []

            def ret(adapter, role, _res=res, **kw):
                homes.append(kw["home"])
                return _res
            with mock.patch.object(agents, "run_agent", ret):
                got = fn("review", "codex", workdir=self.work, prompt="p", writable=False,
                         schema_path=None, log_path=Path("/l"), timeout=9)
            self.assertIs(got, res)
            self.assertFalse(homes[0].exists())

    def test_implement_keeps_no_schema(self):
        fn = self.closure()
        captured = {}
        with mock.patch.object(agents, "run_agent",
                               lambda a, r, **kw: captured.update(kw) or Result("", None, 0, False)):
            fn("implement", "claude", workdir=self.work, prompt="p", writable=True,
               schema_path=None, log_path=Path("/l"), timeout=9)
        self.assertIsNone(captured["schema_path"])
        self.assertIsNone(captured["model"])
        self.assertTrue(captured["writable"])


class StatusTests(Base):
    def test_empty(self):
        code, out, _ = call(["status"])
        self.assertEqual(code, 0)
        self.assertIn("no runs", out)

    def test_list_and_show(self):
        state.save(st("20260101-000000-o-r-7", status="done", step="done", round=1))
        state.save(st("20260102-000000-o-r-8", issue=8, status="failed", step="review"))
        code, out, _ = call(["status"])
        self.assertEqual(code, 0)
        self.assertIn("20260101-000000-o-r-7", out)
        self.assertIn("o/r#8", out)
        self.assertIn("failed", out)
        code, out, _ = call(["status", "20260101-000000-o-r-7"])
        self.assertEqual(json.loads(out)["status"], "done")

    def test_show_missing_and_bad_id(self):
        self.assertEqual(call(["status", "nope"])[0], 1)
        self.assertEqual(call(["status", "../etc"])[0], 2)


class CleanTests(Base):
    def setUp(self):
        super().setUp()
        self.rid = "20260101-000000-o-r-7"
        self.s = st(self.rid, status="done", branch="orch/7-x")
        state.save(self.s)
        self.d = state.run_dir(self.rid)
        (self.d / "work").mkdir()
        (self.d / "work" / "f").write_text("x")
        self.mirror = state.data_dir() / "repos" / "r.git"
        self.mirror.mkdir(parents=True)
        self.git = mock.Mock()
        p = mock.patch.object(cli, "gitops", self.git)
        p.start()
        self.addCleanup(p.stop)
        q = mock.patch.object(cli, "mirror_path", lambda repo: self.mirror)
        q.start()
        self.addCleanup(q.stop)

    def test_cleans_finished_run(self):
        code, _, err = call(["clean", self.rid])
        self.assertEqual(code, 0, err)
        self.assertFalse(self.d.exists())
        self.git.remove_worktree.assert_called_once_with(self.mirror, self.d / "work")
        self.git.delete_branch.assert_called_once_with(self.mirror, "orch/7-x")

    def test_no_mirror_skips_git(self):
        self.mirror.rmdir()
        code, _, _ = call(["clean", self.rid])
        self.assertEqual(code, 0)
        self.assertFalse(self.d.exists())
        self.git.remove_worktree.assert_not_called()

    def test_no_branch_no_delete(self):
        state.save(st(self.rid, status="failed"))
        call(["clean", self.rid])
        self.git.delete_branch.assert_not_called()

    def test_force_cleans_running(self):
        state.save(st(self.rid, status="running", branch="orch/7-x"))
        code, _, err = call(["clean", self.rid, "--force"])
        self.assertEqual(code, 0, err)
        self.assertFalse(self.d.exists())
        self.git.delete_branch.assert_called_once_with(self.mirror, "orch/7-x")

    def test_force_still_validates(self):
        for bad in ("..", "a/b"):
            self.assertNotEqual(call(["clean", bad, "--force"])[0], 0)
        link = state.data_dir() / "runs" / "20260101-000000-o-r-9"
        link.symlink_to(self.d)
        code, _, err = call(["clean", link.name, "--force"])
        self.assertEqual(code, 1)
        self.assertIn("not a plain run directory", err)
        self.assertTrue(self.d.exists())

    def test_refuses_running(self):
        state.save(st(self.rid, status="running"))
        code, _, err = call(["clean", self.rid])
        self.assertEqual(code, 1)
        self.assertIn("running", err)
        self.assertTrue(self.d.exists())
        self.git.remove_worktree.assert_not_called()

    def test_refuses_bad_ids(self):
        victim = Path(self.tmp.name) / "victim"
        victim.mkdir()
        for bad in ("../../victim", "a/b", "..", ".", "", "x y"):
            code, _, _ = call(["clean", bad])
            self.assertEqual(code, 2, bad)
        self.assertTrue(victim.exists())

    def test_refuses_symlinked_run_dir(self):
        target = Path(self.tmp.name) / "target"
        target.mkdir()
        (target / "keep").write_text("k")
        link = state.data_dir() / "runs" / "linkrun"
        link.symlink_to(target)
        code, _, err = call(["clean", "linkrun"])
        self.assertEqual(code, 1)
        self.assertTrue((target / "keep").exists())
        self.assertTrue(link.is_symlink())
        self.git.remove_worktree.assert_not_called()

    def test_git_failure_keeps_run_dir(self):
        self.git.remove_worktree.side_effect = RuntimeError("nope")
        code, _, _ = call(["clean", self.rid])
        self.assertEqual(code, 1)
        self.assertTrue(self.d.exists())


class LoginTests(Base):
    def setUp(self):
        super().setUp()
        self.bindir = Path(self.tmp.name) / "bin"
        self.bindir.mkdir()
        for n in ("claude", "codex"):
            (self.bindir / n).write_text("#!/bin/sh\n")
            (self.bindir / n).chmod(0o755)
        self.bindir = self.bindir.resolve()
        p = mock.patch.dict(os.environ, {
            "PATH": f"{self.bindir}:/opt/other/bin", "GH_TOKEN": "secret1",
            "SSH_AUTH_SOCK": "/s", "ANTHROPIC_API_KEY": "secret2", "TERM": "xterm", "LANG": "C"})
        p.start()
        self.addCleanup(p.stop)

    def login(self, name, rc=0):
        with mock.patch.object(cli.subprocess, "run",
                               return_value=mock.Mock(returncode=rc)) as m:
            res = call(["login", name])
        return res, m

    def check_env(self, env, name, cfgvar):
        home = state.data_dir() / "agents" / name / "home"
        self.assertEqual(set(env), {"HOME", "PATH", "TERM", "LANG", cfgvar})
        self.assertEqual(env["HOME"], str(home))
        self.assertEqual(env["PATH"], str(self.bindir))
        self.assertNotIn("secret", " ".join(env.values()))
        self.assertEqual(os.stat(home).st_mode & 0o777, 0o700)
        sub = home / ("." + name)
        self.assertEqual(os.stat(sub).st_mode & 0o777, 0o700)
        return home

    def test_claude(self):
        (code, out, err), m = self.login("claude")
        self.assertEqual(code, 0)
        argv = m.call_args.args[0]
        self.assertEqual(argv, [str(self.bindir / "claude")])
        env = m.call_args.kwargs["env"]
        home = self.check_env(env, "claude", "CLAUDE_CONFIG_DIR")
        self.assertEqual(env["CLAUDE_CONFIG_DIR"], str(home / ".claude"))
        self.assertIn("/login", err + out)

    def test_codex(self):
        (code, _, _), m = self.login("codex")
        self.assertEqual(m.call_args.args[0], [str(self.bindir / "codex"), "login"])
        env = m.call_args.kwargs["env"]
        home = self.check_env(env, "codex", "CODEX_HOME")
        self.assertEqual(env["CODEX_HOME"], str(home / ".codex"))

    def test_exit_code_passthrough(self):
        (code, _, _), _ = self.login("codex", rc=3)
        self.assertEqual(code, 3)

    def test_unknown_agent(self):
        self.assertEqual(call(["login", "gpt"])[0], 2)

    def test_binary_missing(self):
        with mock.patch.dict(os.environ, {"PATH": "/nonexistent"}):
            with mock.patch.object(cli.subprocess, "run") as m:
                code, _, err = call(["login", "claude"])
        self.assertEqual(code, 1)
        m.assert_not_called()
        self.assertIn("not found", err)

    def test_existing_home_tightened(self):
        home = state.data_dir() / "agents" / "claude" / "home"
        home.mkdir(parents=True, mode=0o755)
        home.chmod(0o755)
        self.login("claude")
        self.assertEqual(os.stat(home).st_mode & 0o777, 0o700)


class EntryTests(unittest.TestCase):
    def test_help(self):
        import subprocess
        import sys
        r = subprocess.run([sys.executable, "-m", "orch", "--help"], capture_output=True,
                           text=True, cwd=Path(__file__).parent.parent)
        self.assertEqual(r.returncode, 0, r.stderr)
        for w in ("run", "resume", "status", "clean", "login"):
            self.assertIn(w, r.stdout)


if __name__ == "__main__":
    unittest.main()
