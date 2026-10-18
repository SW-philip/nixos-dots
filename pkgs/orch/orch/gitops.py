import os
import re
import shutil
import subprocess
from pathlib import Path

DIFF_LIMIT = 200000
_SLUG = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
_FETCH_SPEC = "+refs/heads/*:refs/remotes/origin/*"


class GitError(Exception):
    pass


_KEEP_GIT_ENV = ("GIT_TERMINAL_PROMPT", "GIT_CONFIG_NOSYSTEM")
_KEEP_GIT_PREFIX = ("GIT_AUTHOR_", "GIT_COMMITTER_")
# Per-invocation overrides of anything the worktree (agent-writable) could set.
_HARDEN = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
           "-c", "core.sshCommand=ssh", "-c", "protocol.ext.allow=never",
           "-c", "core.untrackedCache=false"]


def _clean_env(base, extra=None):
    # Allowlist GIT_* rather than denylist: any other variable (GIT_DIR,
    # GIT_CONFIG_*, GIT_EXTERNAL_DIFF, GIT_SSH*, ...) can redirect or run code.
    env = {k: v for k, v in base.items()
           if not k.startswith("GIT_") or k in _KEEP_GIT_ENV or k.startswith(_KEEP_GIT_PREFIX)}
    env["GIT_TERMINAL_PROMPT"] = "0"
    # stderr is matched in delete_branch; keep it independent of the user's locale
    env["LC_ALL"] = "C"
    env["LANGUAGE"] = ""
    env.update(extra or {})
    return env


def _run(*args, cwd=None, gitdir=None, work=None, env=None, extra_env=None, ok=(0,), config=()):
    """Run git. With gitdir/work, GIT_DIR/GIT_WORK_TREE pin the repo so a
    replaced work/.git is never consulted."""
    extra = dict(extra_env or {})
    if gitdir is not None:
        extra["GIT_DIR"] = str(gitdir)
    if work is not None:
        extra["GIT_WORK_TREE"] = str(work)
    cmd = ["git", *_HARDEN, *config, *args]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd,
                             env=_clean_env(os.environ if env is None else env, extra))
    except OSError as e:
        raise GitError(f"git {' '.join(args)} failed: {e}") from e
    if res.returncode not in ok:
        raise GitError(f"git {' '.join(args)} failed: {(res.stderr or '').strip()}")
    return res


def _git(*args, **kw):
    return _run(*args, **kw).stdout


def _check_branch(branch):
    if not branch or branch.startswith("-"):
        raise GitError(f"invalid branch name: {branch!r}")
    try:
        _git("check-ref-format", "--branch", branch)
    except GitError as e:
        raise GitError(f"invalid branch name: {branch!r}") from e


def repo_url(repo: str) -> str:
    if repo and not repo.startswith("-") and Path(repo).exists():
        return str(Path(repo).resolve())
    if not _SLUG.match(repo) or repo.startswith("-"):
        raise GitError(f"invalid repo: {repo!r}")
    return f"git@github.com:{repo}.git"


def ensure_mirror(repo: str, mirror_dir: Path) -> str:
    mirror_dir = Path(mirror_dir)
    if not mirror_dir.exists():
        _git("clone", "--bare", "--", repo_url(repo), str(mirror_dir))
        _git("-C", str(mirror_dir), "config", "remote.origin.fetch", _FETCH_SPEC)
    _git("-C", str(mirror_dir), "fetch", "--prune", "origin")
    try:
        ref = _git("-C", str(mirror_dir), "symbolic-ref", "--short",
                   "refs/remotes/origin/HEAD").strip()
        return ref.removeprefix("origin/")
    except GitError:
        return _git("-C", str(mirror_dir), "symbolic-ref", "--short", "HEAD").strip()


def add_worktree(mirror: Path, work: Path, branch: str, base: str) -> Path:
    _check_branch(branch)
    _check_branch(base)
    _git("-C", str(mirror), "worktree", "add", "-b", branch, "--", str(work), f"origin/{base}")
    gitdir = Path(_git("rev-parse", "--absolute-git-dir", cwd=work).strip()).resolve()
    if Path(mirror).resolve() / "worktrees" not in gitdir.parents:
        raise GitError(f"worktree admin dir {gitdir} is not under {mirror}/worktrees")
    return gitdir


# Commit and diff run over agent-written content: the user's global config
# (filter/diff drivers) must not apply to it. push keeps it for credentials.
_NO_USER_CONFIG = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}


def commit_all(work: Path, message: str, gitdir: str | Path) -> bool:
    pin = dict(cwd=work, gitdir=gitdir, work=work)
    _git("add", "-A", extra_env=_NO_USER_CONFIG, **pin)
    staged = _run("diff", "--cached", "--quiet", "--no-ext-diff", ok=(0, 1),
                  extra_env=_NO_USER_CONFIG, **pin)
    if staged.returncode == 0:
        return False
    _git("commit", "--no-verify", "-m", message,
         config=["-c", "user.name=orch", "-c", "user.email=orch@localhost"],
         extra_env={**_IDENT, **_NO_USER_CONFIG}, **pin)
    return True


# Caller-set GIT_AUTHOR_*/GIT_COMMITTER_* would otherwise beat -c user.*
_IDENT = {"GIT_AUTHOR_NAME": "orch", "GIT_AUTHOR_EMAIL": "orch@localhost",
          "GIT_COMMITTER_NAME": "orch", "GIT_COMMITTER_EMAIL": "orch@localhost"}


def commits_ahead(work: Path, base: str, gitdir: str | Path) -> int:
    _check_branch(base)
    out = _git("rev-list", "--count", f"origin/{base}..HEAD", cwd=work, gitdir=gitdir, work=work)
    return int(out.strip())


def diff(work: Path, base: str, gitdir: str | Path) -> str:
    _check_branch(base)
    out = _git("diff", "--no-ext-diff", "--no-textconv", f"origin/{base}...HEAD", "--",
               cwd=work, gitdir=gitdir, work=work, extra_env=_NO_USER_CONFIG)
    if len(out) > DIFF_LIMIT:
        return out[:DIFF_LIMIT] + "\n[diff truncated]"
    return out


def push(mirror: Path, branch: str) -> None:
    _check_branch(branch)
    ref = f"refs/heads/{branch}"
    _git("--git-dir", str(mirror), "push", "--no-verify", "origin", f"{ref}:{ref}")


def ref_exists(mirror: Path, ref: str) -> bool:
    return _run("-C", str(mirror), "show-ref", "--verify", "--quiet", "--", ref,
                ok=(0, 1)).returncode == 0


def delete_branch(mirror: Path, branch: str) -> None:
    _check_branch(branch)
    res = _run("-C", str(mirror), "branch", "-D", "--", branch, ok=(0, 1))
    if res.returncode and "not found" not in (res.stderr or ""):
        raise GitError(f"git branch -D failed: {(res.stderr or '').strip()}")


def remove_worktree(mirror: Path, work: Path) -> None:
    try:
        _git("-C", str(mirror), "worktree", "remove", "--force", "--", str(work))
        return
    except GitError:
        pass
    # An agent-replaced work/.git fails git's validation even with --force.
    work = Path(work)
    try:
        if work.is_symlink():
            work.unlink()
        else:
            shutil.rmtree(work)
    except FileNotFoundError:
        pass
    except OSError as e:
        raise GitError(f"cannot remove {work}: {e}") from e
    _git("-C", str(mirror), "worktree", "prune")
