import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from orch import gitops, sandbox
from orch.gitops import GitError


def g(cwd, *args, env=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                          text=True, env=env).stdout.strip()


class GitTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        home = self.tmp / "home"
        home.mkdir()
        env = {"HOME": str(home), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        p = mock.patch.dict(os.environ, env)
        p.start()
        self.addCleanup(p.stop)
        self.origin = self.tmp / "origin"
        self.origin.mkdir()
        g(self.origin, "init", "-b", "main")
        self.commit_origin("a.txt", "one")
        g(self.origin, "branch", "other")

    def commit_origin(self, name, text):
        (self.origin / name).write_text(text)
        g(self.origin, "add", "-A")
        g(self.origin, "commit", "-m", f"add {name}")


class LocaleTests(GitTestCase):
    def test_child_env_pins_locale(self):
        with mock.patch.dict(os.environ, {"LANG": "de_DE.UTF-8", "LC_ALL": "de_DE.UTF-8",
                                          "LANGUAGE": "de"}):
            env = gitops._clean_env(os.environ)
        self.assertEqual((env["LC_ALL"], env["LANGUAGE"]), ("C", ""))


class RepoUrlTests(GitTestCase):
    def test_a_path_vs_slug(self):
        self.assertEqual(gitops.repo_url(str(self.origin)), str(self.origin.resolve()))
        self.assertEqual(gitops.repo_url("SW-philip/x"), "git@github.com:SW-philip/x.git")

    def test_rejects_odd_strings(self):
        for bad in ["--upload-pack=evil", "a/b/c", "x", "a b/c", "-a/b", "a/b;rm"]:
            with self.assertRaises(GitError, msg=bad):
                gitops.repo_url(bad)


class MirrorTests(GitTestCase):
    def setUp(self):
        super().setUp()
        self.mirror = self.tmp / "mirror.git"
        self.work = self.tmp / "work"

    def test_b_ensure_mirror_clones_and_refetches(self):
        self.assertEqual(gitops.ensure_mirror(str(self.origin), self.mirror), "main")
        self.assertEqual(g(self.mirror, "config", "remote.origin.fetch"),
                         "+refs/heads/*:refs/remotes/origin/*")
        self.commit_origin("b.txt", "two")
        new = g(self.origin, "rev-parse", "main")
        gitops.ensure_mirror(str(self.origin), self.mirror)
        self.assertEqual(g(self.mirror, "rev-parse", "origin/main"), new)

    def test_c_add_worktree(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        self.gd = gitops.add_worktree(self.mirror, self.work, "orch/1-x", "main")
        self.assertEqual(g(self.work, "branch", "--show-current"), "orch/1-x")
        self.assertEqual(g(self.work, "rev-parse", "HEAD"), g(self.origin, "rev-parse", "main"))

    def test_d_commit_all(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        self.gd = gitops.add_worktree(self.mirror, self.work, "orch/1-x", "main")
        self.assertFalse(gitops.commit_all(self.work, "nothing", self.gd))
        (self.work / "n.txt").write_text("hi")
        self.assertTrue(gitops.commit_all(self.work, "add n", self.gd))
        self.assertEqual(g(self.work, "log", "-1", "--format=%an <%ae>"), "orch <orch@localhost>")

    def test_e_diff_and_truncation(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        self.gd = gitops.add_worktree(self.mirror, self.work, "orch/1-x", "main")
        (self.work / "n.txt").write_text("hello world\n")
        gitops.commit_all(self.work, "add n", self.gd)
        d = gitops.diff(self.work, "main", self.gd)
        self.assertIn("+hello world", d)
        self.assertNotIn("[diff truncated]", d)
        with mock.patch.object(gitops, "DIFF_LIMIT", 20):
            t = gitops.diff(self.work, "main", self.gd)
        self.assertEqual(t, d[:20] + "\n[diff truncated]")

    def test_f_push_only_that_branch(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        self.gd = gitops.add_worktree(self.mirror, self.work, "orch/1-x", "main")
        (self.work / "n.txt").write_text("hi")
        gitops.commit_all(self.work, "add n", self.gd)
        # local-only branch in the mirror must not travel
        g(self.mirror, "branch", "local-only", "origin/main")
        before = {b: g(self.origin, "rev-parse", b) for b in ("main", "other")}
        gitops.push(self.mirror, "orch/1-x")
        self.assertEqual({b: g(self.origin, "rev-parse", b) for b in ("main", "other")}, before)
        self.assertEqual(g(self.origin, "rev-parse", "orch/1-x"), g(self.work, "rev-parse", "HEAD"))
        branches = g(self.origin, "branch", "--format=%(refname:short)").split()
        self.assertNotIn("local-only", branches)

    def test_g_error_carries_stderr(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        with self.assertRaises(GitError) as cm:
            gitops.add_worktree(self.mirror, self.work, "orch/1-x", "nope")
        self.assertIn("origin/nope", str(cm.exception))

    def test_branch_validation(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        for bad in ["-evil", "a..b", "has space", "", "x.lock"]:
            with self.assertRaises(GitError, msg=bad):
                gitops.add_worktree(self.mirror, self.work, bad, "main")
            with self.assertRaises(GitError, msg=bad):
                gitops.push(self.mirror, bad)

    def test_remove_worktree(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        self.gd = gitops.add_worktree(self.mirror, self.work, "orch/1-x", "main")
        (self.work / "junk").write_text("x")
        gitops.remove_worktree(self.mirror, self.work)
        self.assertFalse(self.work.exists())

    def test_b2_gitdir_under_mirror_and_distinct(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        gd1 = gitops.add_worktree(self.mirror, self.work, "orch/1-x", "main")
        other = self.tmp / "elsewhere" / "work"
        other.parent.mkdir()
        gd2 = gitops.add_worktree(self.mirror, other, "orch/2-y", "main")
        for gd in (gd1, gd2):
            self.assertIn(self.mirror.resolve() / "worktrees", gd.parents)
        self.assertNotEqual(gd1, gd2)

    def test_d2_commit_all_errors_on_broken_repo(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        self.work.mkdir()
        with self.assertRaises(GitError):
            gitops.commit_all(self.work, "m", self.tmp / "bogus")

    def test_e2_bad_base(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        gd = gitops.add_worktree(self.mirror, self.work, "orch/1-x", "main")
        for bad in ["-x", "a..b", ""]:
            with self.assertRaises(GitError, msg=bad):
                gitops.add_worktree(self.mirror, self.tmp / "w2", "orch/2", bad)
            with self.assertRaises(GitError, msg=bad):
                gitops.diff(self.work, bad, gd)

    def test_c_env_injection_scrubbed(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        gd = gitops.add_worktree(self.mirror, self.work, "orch/1-x", "main")
        decoy = self.tmp / "decoy"
        marker = self.tmp / "marker"
        evil = f"touch {marker}"
        inj = {"GIT_EXTERNAL_DIFF": evil, "GIT_SSH_COMMAND": evil, "GIT_DIR": str(decoy),
               "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.fsmonitor",
               "GIT_CONFIG_VALUE_0": evil, "GIT_EXEC_PATH": str(decoy),
               "GIT_WORK_TREE": str(decoy), "GIT_ASKPASS": evil}
        seen = []
        real = subprocess.run

        def rec(cmd, **kw):
            if "check-ref-format" not in cmd:
                seen.append(kw["env"])
            return real(cmd, **kw)

        (self.work / "a.txt").write_text("changed")
        with mock.patch.dict(os.environ, inj), mock.patch.object(subprocess, "run", rec):
            self.assertTrue(gitops.commit_all(self.work, "m", gd))
            self.assertIn("+changed", gitops.diff(self.work, "main", gd))
        self.assertFalse(marker.exists())
        for env in seen:
            for k in inj:
                if k not in ("GIT_DIR", "GIT_WORK_TREE"):
                    self.assertNotIn(k, env)
            self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")
            self.assertEqual(env["GIT_DIR"], str(gd))
            self.assertEqual(env["GIT_WORK_TREE"], str(self.work))

    def test_a_attack_replaced_dotgit(self):
        mirror_branch = "orch/1-x"
        gitops.ensure_mirror(str(self.origin), self.mirror)
        gd = gitops.add_worktree(self.mirror, self.work, mirror_branch, "main")
        attacker = self.tmp / "attacker"
        attacker.mkdir()
        g(attacker, "init", "--bare", "-b", "main")
        markers = self.tmp / "markers"
        markers.mkdir()
        # simulate the sandboxed agent
        (self.work / ".git").unlink()
        g(self.work, "init", "-b", "main")
        cfg = ["config", "--local"]
        g(self.work, *cfg, "core.fsmonitor", f"touch {markers}/fsmonitor; echo")
        g(self.work, *cfg, "core.hooksPath", str(self.work / ".git" / "hooks"))
        g(self.work, *cfg, "core.sshCommand", f"touch {markers}/ssh; false")
        g(self.work, *cfg, "diff.external", f"touch {markers}/extdiff; true")
        g(self.work, *cfg, "filter.x.clean", f"touch {markers}/filter; cat")
        g(self.work, *cfg, "remote.origin.url", str(attacker))
        g(self.work, *cfg, "remote.origin.pushurl", f"ext::touch {markers}/ext")
        hooks = self.work / ".git" / "hooks"
        hooks.mkdir(exist_ok=True)
        for h in ("pre-commit", "commit-msg", "post-commit", "pre-push", "reference-transaction"):
            hp = hooks / h
            hp.write_text(f"#!/bin/sh\ntouch {markers}/{h}\n")
            hp.chmod(0o755)
        (self.work / ".gitattributes").write_text("*.txt filter=x\n")
        (self.work / "a.txt").write_text("changed by agent\n")

        self.assertTrue(gitops.commit_all(self.work, "agent work", gd))
        d = gitops.diff(self.work, "main", gd)
        self.assertIn("+changed by agent", d)
        gitops.push(self.mirror, mirror_branch)

        self.assertEqual(list(markers.iterdir()), [])
        head = g(self.tmp, "--git-dir", str(gd), "rev-parse", "HEAD")
        self.assertEqual(g(self.mirror, "rev-parse", mirror_branch), head)
        self.assertEqual(g(self.origin, "rev-parse", mirror_branch), head)
        self.assertEqual(g(attacker, "branch", "--list"), "")

    def listed(self):
        return g(self.mirror, "worktree", "list", "--porcelain")

    def test_remove_normal(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        gd = gitops.add_worktree(self.mirror, self.work, "orch/1-x", "main")
        gitops.remove_worktree(self.mirror, self.work)
        self.assertFalse(self.work.exists())
        self.assertFalse(gd.exists())

    def test_remove_after_agent_replaced_dotgit(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        gd = gitops.add_worktree(self.mirror, self.work, "orch/1-x", "main")
        secret = self.tmp / "secret.txt"
        secret.write_text("keep")
        (self.work / ".git").unlink()
        g(self.work, "init", "-b", "main")
        (self.work / "f.txt").write_text("x")
        (self.work / "link").symlink_to(secret)
        (self.work / "dirlink").symlink_to(self.tmp)
        gitops.remove_worktree(self.mirror, self.work)
        self.assertFalse(self.work.exists())
        self.assertFalse(gd.exists())
        self.assertNotIn(str(self.work), self.listed())
        self.assertEqual(secret.read_text(), "keep")
        self.assertTrue((self.tmp / "origin").exists())

    def test_remove_missing_work(self):
        gitops.ensure_mirror(str(self.origin), self.mirror)
        gitops.remove_worktree(self.mirror, self.work)


class CommitsAheadTests(GitTestCase):
    def test_counts_commits_over_base(self):
        mirror, work = self.tmp / "mirror.git", self.tmp / "work"
        gitops.ensure_mirror(str(self.origin), mirror)
        gd = gitops.add_worktree(mirror, work, "orch/1-x", "main")
        self.assertEqual(gitops.commits_ahead(work, "main", gd), 0)
        (work / "n.txt").write_text("n")
        gitops.commit_all(work, "m", gd)
        self.assertEqual(gitops.commits_ahead(work, "main", gd), 1)
        with self.assertRaises(GitError):
            gitops.commits_ahead(work, "-x", gd)


class UserConfigTests(GitTestCase):
    def test_global_config_not_applied_to_commit_and_diff(self):
        mirror, work = self.tmp / "mirror.git", self.tmp / "work"
        gitops.ensure_mirror(str(self.origin), mirror)
        gd = gitops.add_worktree(mirror, work, "orch/1-x", "main")
        marker = self.tmp / "marker"
        script = self.tmp / "filter.py"
        script.write_text("import pathlib, sys\n"
                          f"pathlib.Path({str(marker)!r}).touch()\n"
                          "sys.stdout.write(sys.stdin.read())\n")
        home = self.tmp / "home"
        (home / ".gitconfig").write_text(
            f'[filter "evil"]\n\tclean = "{sys.executable}" "{script}"\n'
            "[diff]\n\tnoprefix = true\n")
        (work / ".gitattributes").write_text("*.txt filter=evil\n")
        (work / "a.txt").write_text("changed")
        with mock.patch.dict(os.environ, {"HOME": str(home)}):
            os.environ.pop("GIT_CONFIG_GLOBAL", None)
            self.assertTrue(gitops.commit_all(work, "m", gd))
            out = gitops.diff(work, "main", gd)
        self.assertFalse(marker.exists())
        self.assertIn("diff --git a/a.txt b/a.txt", out)


class SandboxGitTests(GitTestCase):
    """Real bwrap: the agent's git must read the mirror but not write it."""

    def jail(self, cmd, work, writable, extra_ro):
        env = {"HOME": str(self.tmp / "jhome"), "PATH": os.path.dirname(cmd[0])}
        argv = sandbox.bwrap_argv(cmd=cmd, workdir=work, writable=writable,
                                  home=self.tmp / "jhome", env=env, extra_ro=extra_ro)
        return subprocess.run(argv, capture_output=True, text=True)

    def test_git_reads_but_cannot_commit(self):
        git = os.path.realpath(shutil.which("git") or "/nonexistent")
        py = os.path.realpath(sys.executable)
        if not (shutil.which("bwrap") and git.startswith("/nix/store/")
                and py.startswith("/nix/store/")):
            self.skipTest("needs bwrap and a store git/python")
        self.mirror, self.work = self.tmp / "mirror.git", self.tmp / "work"
        (self.tmp / "jhome").mkdir()
        (self.tmp / "probe").mkdir()
        if self.jail([py, "-c", "pass"], self.tmp / "probe", True, ()).returncode != 0:
            self.skipTest("bwrap cannot run here")
        gitops.ensure_mirror(str(self.origin), self.mirror)
        gitops.add_worktree(self.mirror, self.work, "orch/1-x", "main")
        log = ["git", "-C", str(self.work), "log", "--oneline", "-1"]
        log[0] = git
        no = self.jail(log, self.work, True, ())
        self.assertNotEqual(no.returncode, 0)
        r = self.jail(log, self.work, True, (self.mirror,))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("add a.txt", r.stdout)
        c = self.jail([git, "-c", "user.name=a", "-c", "user.email=a@b", "-C", str(self.work),
                       "commit", "--allow-empty", "-m", "x"], self.work, True, (self.mirror,))
        self.assertNotEqual(c.returncode, 0)
        self.assertIn("ead-only", c.stderr)


if __name__ == "__main__":
    unittest.main()
