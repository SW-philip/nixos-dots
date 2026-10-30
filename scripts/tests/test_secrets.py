import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "secrets.py")


def read(path):
    with open(path) as fh:
        return fh.read()


def sh(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw).stdout


class Secrets(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.repo = os.path.join(self.t, "repo")
        os.makedirs(os.path.join(self.repo, "secrets"))
        self.editor = os.path.join(self.t, "editor.txt")
        sh("age-keygen", "-o", self.editor)
        pub = sh("age-keygen", "-y", self.editor).strip()
        # sops finds .sops.yaml from the cwd, so encrypt from a dir that has none
        plain = os.path.join(self.t, "shared.yaml")
        with open(plain, "w") as fh:
            fh.write("api_key: hunter2\nold_thing: x\n")
        with open(os.path.join(self.repo, "secrets/shared.yaml"), "w") as fh:
            fh.write(sh("sops", "encrypt", "--age", pub, "shared.yaml", cwd=self.t))
        with open(os.path.join(self.t, "desktop.yaml"), "w") as fh:
            fh.write("desk_key: d\n")
        with open(os.path.join(self.repo, "secrets/desktop.yaml"), "w") as fh:
            fh.write(sh("sops", "encrypt", "--age", pub, "desktop.yaml", cwd=self.t))
        # a scrubbed public checkout: names kept, values gone (sops itself can't read these)
        with open(os.path.join(self.repo, "secrets/scrubbed.yaml"), "w") as fh:
            fh.write("scrubbed: ENC[REDACTED]\n")
        sh("git", "-C", self.repo, "init", "-q")
        sh("git", "-C", self.repo, "-c", "user.name=t", "-c", "user.email=t@t", "add", ".")
        sh(
            "git",
            "-C",
            self.repo,
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "init",
            env=dict(os.environ, GIT_AUTHOR_DATE="2026-10-01T00:00:00", GIT_COMMITTER_DATE="2026-10-01T00:00:00"),
        )
        self.decls = os.path.join(self.t, "decls")
        with open(self.decls, "w") as fh:
            fh.write(
                "desktop\tsecrets/shared.yaml\tapi_key\n"
                "surface\tsecrets/shared.yaml\tapi_key\n"
                "desktop\tsecrets/shared.yaml\tnew_key\n"
                "desktop\tsecrets/scrubbed.yaml\tscrubbed\n"
                "desktop\tsecrets/desktop.yaml\tdesk_key\n"
            )

    def tearDown(self):
        shutil.rmtree(self.t)

    def run_secrets(self, *args, stdin=""):
        env = dict(
            os.environ,
            SECRETS_REPO=self.repo,
            SECRETS_DECLS=self.decls,
            SECRETS_EDITOR_KEY=self.editor,
            SECRETS_DECRYPT="cat",
            SECRETS_TODAY="2026-10-27",
        )
        return subprocess.run(
            [sys.executable, SCRIPT, *args],
            input=stdin,
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )

    def decrypt(self, key):
        env = dict(os.environ, SOPS_AGE_KEY_FILE=self.editor)
        return sh("sops", "decrypt", "--extract", json.dumps([key]), "secrets/shared.yaml", cwd=self.repo, env=env)

    def meta(self):
        with open(os.path.join(self.repo, "secrets/meta.json")) as fh:
            return json.load(fh)

    def value_file(self, value):
        p = os.path.join(self.t, "value")
        with open(p, "w") as fh:
            fh.write(value)
        return p

    def test_list(self):
        r = self.run_secrets("list")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout, r"api_key\s+shared.yaml\s+desktop,surface\s+✓ set\s+added 26d ago")
        self.assertRegex(r.stdout, r"new_key\s+shared.yaml\s+desktop\s+✗ missing")
        self.assertRegex(r.stdout, r"scrubbed\s+scrubbed.yaml\s+desktop\s+✗ placeholder")
        self.assertRegex(r.stdout, r"old_thing\s+shared.yaml\s+nobody\s+· orphan")
        self.assertIn("5 secrets, 2 need a value, 0 expired", r.stdout)
        self.assertNotIn("hunter2", r.stdout + r.stderr)

    def test_set_missing(self):
        r = self.run_secrets("set", "new_key", "--from-file", self.value_file("s3cret"), stdin="y\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.decrypt("new_key"), "s3cret")
        self.assertEqual(self.meta()["secrets/shared.yaml:new_key"], {"added": "2026-10-27"})
        self.assertIn("deploy to pick it up: desktop", r.stdout)
        self.assertNotIn("s3cret", r.stdout + r.stderr)
        staged = sh("git", "-C", self.repo, "diff", "--cached", "--name-only").split()
        self.assertEqual(sorted(staged), ["secrets/meta.json", "secrets/shared.yaml"])

    def test_replace_is_a_rotation(self):
        r = self.run_secrets("replace", "api_key", "--from-file", self.value_file("fresh"), stdin="y\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("replacing api_key", r.stdout)
        self.assertEqual(self.decrypt("api_key"), "fresh")
        self.assertEqual(self.meta()["secrets/shared.yaml:api_key"], {"added": "2026-10-01", "rotated": "2026-10-27"})
        self.assertRegex(self.run_secrets("list").stdout, r"api_key .*added 26d ago\s+rotated today")

    def test_multiline_keeps_newlines(self):
        r = self.run_secrets("set", "new_key", "--from-file", self.value_file("A=1\nB=2\n"), stdin="y\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.decrypt("new_key"), "A=1\nB=2\n")

    def test_declining_writes_nothing(self):
        before = read(os.path.join(self.repo, "secrets/shared.yaml"))
        r = self.run_secrets("set", "api_key", "--from-file", self.value_file("nope"), stdin="n\n")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(read(os.path.join(self.repo, "secrets/shared.yaml")), before)
        self.assertFalse(os.path.exists(os.path.join(self.repo, "secrets/meta.json")))

    def test_orphan_refused(self):
        r = self.run_secrets("set", "old_thing", "--from-file", self.value_file("x"), stdin="y\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("isn't declared by any host", r.stderr)

    def test_unknown_name(self):
        r = self.run_secrets("set", "nope")
        self.assertEqual(r.returncode, 1)
        self.assertIn("no secret named nope", r.stderr)

    def test_expire_countdown(self):
        r = self.run_secrets("expire", "api_key", "+19d")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("expires in 19d", r.stdout)
        self.assertRegex(self.run_secrets("list").stdout, r"api_key .*expires in 19d")
        self.run_secrets("expire", "api_key", "2026-10-20")
        listing = self.run_secrets("list").stdout
        self.assertIn("EXPIRED 7d ago", listing)
        self.assertIn("1 expired", listing)
        self.run_secrets("expire", "api_key", "none")
        self.assertNotIn("expires", self.meta()["secrets/shared.yaml:api_key"])

    def test_expire_rejects_garbage(self):
        r = self.run_secrets("expire", "api_key", "soon")
        self.assertEqual(r.returncode, 1)
        self.assertIn("not a date", r.stderr)

    def registry(self):
        with open(os.path.join(self.repo, "secrets/registry.json")) as fh:
            return json.load(fh)

    def test_masked_value_refused(self):
        r = self.run_secrets("set", "new_key", "--from-file", self.value_file("[Interface]\nPrivateKey = *****\n"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("masked field", r.stderr)

    def test_wireguard_needs_its_private_key(self):
        conf = "[Interface]\nAddress = 10.2.0.2/32\n[Peer]\nPublicKey = " + "A" * 43 + "=\n"
        r = self.run_secrets("set", "new_key", "--from-file", self.value_file(conf))
        self.assertEqual(r.returncode, 1)
        self.assertIn("without a valid PrivateKey", r.stderr)
        good = "[Interface]\nPrivateKey = " + "B" * 43 + "=\n" + conf.split("\n", 1)[1]
        r = self.run_secrets("set", "new_key", "--from-file", self.value_file(good), stdin="y\n")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_add(self):
        r = self.run_secrets(
            "add", "github_token", "--hosts", "desktop", "--desc", "gh cli",
            "--from-file", self.value_file("ghp_x"), stdin="y\n",
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("/run/secrets/github_token", r.stdout)
        self.assertEqual(
            self.registry(),
            [{"name": "github_token", "file": "secrets/desktop.yaml", "hosts": ["desktop"], "description": "gh cli"}],
        )
        self.assertEqual(self.meta()["secrets/desktop.yaml:github_token"], {"added": "2026-10-27"})
        env = dict(os.environ, SOPS_AGE_KEY_FILE=self.editor)
        got = sh("sops", "decrypt", "--extract", '["github_token"]', "secrets/desktop.yaml", cwd=self.repo, env=env)
        self.assertEqual(got, "ghp_x")
        self.assertRegex(self.run_secrets("list").stdout, r"github_token\s+desktop.yaml\s+desktop\s+✓ set")

    def test_add_to_both_lands_in_shared(self):
        r = self.run_secrets(
            "add", "both_key", "--hosts", "surface,desktop", "--desc", "",
            "--from-file", self.value_file("v"), stdin="y\n",
        )  # fmt: skip
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.registry()[0]["file"], "secrets/shared.yaml")
        self.assertEqual(self.decrypt("both_key"), "v")

    def test_add_refuses_existing_and_bad_hosts(self):
        r = self.run_secrets("add", "api_key", "--hosts", "desktop", "--desc", "")
        self.assertIn("already exists", r.stderr)
        r = self.run_secrets("add", "fresh", "--hosts", "pi", "--desc", "")
        self.assertIn("hosts can be desktop, surface or both", r.stderr)
        r = self.run_secrets("add", "Bad-Name", "--hosts", "desktop", "--desc", "")
        self.assertIn("use lowercase letters", r.stderr)

    def test_rm_orphan(self):
        r = self.run_secrets("rm", "old_thing", stdin="y\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("old_thing", self.run_secrets("list").stdout)
        self.assertEqual(self.decrypt("api_key"), "hunter2")

    def test_rm_added_secret(self):
        self.run_secrets(
            "add", "tmp_key", "--hosts", "desktop,surface", "--desc", "",
            "--from-file", self.value_file("v"), stdin="y\n",
        )  # fmt: skip
        r = self.run_secrets("rm", "tmp_key", stdin="y\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.registry(), [])
        self.assertNotIn("secrets/shared.yaml:tmp_key", self.meta())
        self.assertNotIn("tmp_key", self.run_secrets("list").stdout)

    def test_rm_prefers_the_orphan_copy(self):
        # api_key also left behind in desktop.yaml, alongside the declared one in shared.yaml
        env = dict(os.environ, SOPS_AGE_KEY_FILE=self.editor)
        sh("sops", "set", "secrets/desktop.yaml", '["api_key"]', '"stale"', cwd=self.repo, env=env)
        listing = self.run_secrets("list").stdout
        self.assertRegex(listing, r"api_key\s+desktop.yaml\s+nobody\s+· orphan")
        r = self.run_secrets("rm", "api_key", stdin="y\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("delete secrets/desktop.yaml:api_key", r.stdout)
        self.assertNotRegex(self.run_secrets("list").stdout, r"api_key\s+desktop.yaml")
        self.assertEqual(self.decrypt("api_key"), "hunter2")
        # set still goes to the declared copy
        r = self.run_secrets("set", "api_key", "--from-file", self.value_file("new"), stdin="y\n")
        self.assertIn("replacing api_key in secrets/shared.yaml", r.stdout)

    def test_rm_asks_which_orphan(self):
        env = dict(os.environ, SOPS_AGE_KEY_FILE=self.editor)
        sh("sops", "set", "secrets/desktop.yaml", '["old_thing"]', '"x"', cwd=self.repo, env=env)
        r = self.run_secrets("rm", "old_thing", stdin="y\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("secrets/desktop.yaml:old_thing, secrets/shared.yaml:old_thing", r.stderr)
        r = self.run_secrets("rm", "secrets/desktop.yaml:old_thing", stdin="y\n")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_rm_refuses_config_declared(self):
        r = self.run_secrets("rm", "api_key", stdin="y\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("declared in the nix config", r.stderr)
        self.assertEqual(self.decrypt("api_key"), "hunter2")

    def with_password_hash(self):
        with open(self.decls, "a") as fh:
            fh.write("desktop\tsecrets/desktop.yaml\tlogin_password_hash\n")

    def test_passwd_stores_a_hash_that_verifies(self):
        self.with_password_hash()
        r = self.run_secrets("passwd", "login_password_hash", stdin="correct horse\ncorrect horse\ny\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("keep a root shell open", r.stdout)
        env = dict(os.environ, SOPS_AGE_KEY_FILE=self.editor)
        stored = sh("sops", "decrypt", "--extract", '["login_password_hash"]', "secrets/desktop.yaml",
                    cwd=self.repo, env=env)  # fmt: skip
        self.assertTrue(stored.startswith("$y$"))
        self.assertNotIn("correct horse", stored + r.stdout + r.stderr)
        # libxcrypt's crypt() re-derives the hash from its own salt: equal only for the right password
        check = 'print crypt($ARGV[0], $ARGV[1]) eq $ARGV[1] ? "ok" : "bad"'
        self.assertEqual(sh("perl", "-e", check, "correct horse", stored), "ok")
        self.assertEqual(sh("perl", "-e", check, "correct hors", stored), "bad")

    def test_passwd_mismatch_writes_nothing(self):
        self.with_password_hash()
        r = self.run_secrets("passwd", "login_password_hash", stdin="one\ntwo\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("differ", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.repo, "secrets/meta.json")))

    def test_passwd_only_for_hashes(self):
        r = self.run_secrets("passwd", "api_key")
        self.assertIn("isn't a *_password_hash", r.stderr)

    def test_value_never_in_argv(self):
        bindir = os.path.join(self.t, "bin")
        os.makedirs(bindir)
        real = sh("sh", "-c", "command -v sops").strip()
        with open(os.path.join(bindir, "sops"), "w") as fh:
            fh.write(f'#!/bin/sh\necho "$@" >> {self.t}/argv.log\nexec {real} "$@"\n')
        os.chmod(os.path.join(bindir, "sops"), 0o755)
        env_path = bindir + os.pathsep + os.environ["PATH"]
        env = dict(
            os.environ,
            PATH=env_path,
            SECRETS_REPO=self.repo,
            SECRETS_DECLS=self.decls,
            SECRETS_EDITOR_KEY=self.editor,
            SECRETS_DECRYPT="cat",
            SECRETS_TODAY="2026-10-27",
        )
        r = subprocess.run(
            [sys.executable, SCRIPT, "set", "new_key", "--from-file", self.value_file("argvleak")],
            input="y\n",
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        argv = read(os.path.join(self.t, "argv.log"))
        self.assertIn("--value-stdin", argv)
        self.assertNotIn("argvleak", argv)


if __name__ == "__main__":
    unittest.main()
