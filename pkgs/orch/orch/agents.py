import json
import os
import shutil
import signal
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import sandbox
from .verdict import REVIEW_SCHEMA, extract_json


@dataclass
class Result:
    text: str
    parsed: dict | None
    exit_code: int
    timed_out: bool


STORE_PREFIX = "/nix/store/"
MAX_RESULT_BYTES = 1 << 20


def _read_result_file(path: Path) -> str | None:
    """The agent controls this path: refuse symlinks, non-regular and oversized files."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_RESULT_BYTES:
            return None
        with os.fdopen(fd, "rb", closefd=False) as f:
            data = f.read(MAX_RESULT_BYTES + 1)
        if len(data) > MAX_RESULT_BYTES:
            return None
        return data.decode(errors="replace")
    except OSError:
        return None
    finally:
        os.close(fd)


def ensure_home(adapter, home: Path) -> None:
    """The agent CLIs refuse to start when their config dir does not exist."""
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    home.chmod(0o700)
    for value in adapter.home_env(home).values():
        p = Path(value)
        if p != home and p.is_relative_to(home):
            p.mkdir(parents=True, exist_ok=True, mode=0o700)


CRED_MAX_BYTES = 1 << 20


def _read_cred(root: Path, rel: str) -> bytes | None:
    """Read root/rel without following a symlink at any component below root (the
    agent controls its home). Only small regular files qualify."""
    parts = Path(rel).parts
    fds = []
    try:
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        fds.append(fd)
        for comp in parts[:-1]:
            fd = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            fds.append(fd)
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        fds.append(fd)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > CRED_MAX_BYTES:
            return None
        with os.fdopen(fd, "rb", closefd=False) as f:
            data = f.read(CRED_MAX_BYTES + 1)
        return data if len(data) <= CRED_MAX_BYTES else None
    except OSError:
        return None
    finally:
        for fd in fds:
            os.close(fd)


def _write_cred(root: Path, rel: str, data: bytes) -> None:
    dest = root / rel
    dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = dest.with_name(f".{dest.name}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, dest)
    finally:
        tmp.unlink(missing_ok=True)


def _rmtree(path: Path) -> None:
    for dirpath, dirnames, _ in os.walk(path):
        for d in [dirpath, *(os.path.join(dirpath, n) for n in dirnames)]:
            if not os.path.islink(d):
                os.chmod(d, 0o700)
    shutil.rmtree(path, ignore_errors=True)


def prepare_run_home(adapter, auth_home: Path, run_home: Path) -> None:
    """A fresh home holding only the adapter's credential files: whatever a previous
    run planted in the auth store (settings, hooks, CLAUDE.md, config.toml) stays out."""
    run_home = Path(run_home)
    if run_home.is_symlink():
        run_home.unlink()
    elif run_home.exists():
        _rmtree(run_home)
    ensure_home(adapter, run_home)
    for rel in adapter.credential_files:
        data = _read_cred(Path(auth_home), rel)
        if data is not None:
            _write_cred(run_home, rel, data)


def finish_run_home(adapter, auth_home: Path, run_home: Path) -> None:
    """Persist refreshed tokens, then drop the home."""
    auth_home, run_home = Path(auth_home), Path(run_home)
    for rel in adapter.credential_files:
        data = _read_cred(run_home, rel)
        if data is None or data == _read_cred(auth_home, rel):
            continue
        try:
            if not isinstance(json.loads(data), dict):
                continue
            _write_cred(auth_home, rel, data)
        except (ValueError, OSError):
            continue
    _rmtree(run_home)


class Adapter:
    name: str
    binary: str
    credential_files: tuple[str, ...] = ()

    def home_env(self, home: Path) -> dict[str, str]:
        raise NotImplementedError

    def command(self, role: str, workdir: Path, schema_path: Path | None,
                out_path: Path, model: str | None) -> list[str]:
        raise NotImplementedError

    def stdin(self, prompt: str) -> str:
        return prompt

    def parse(self, role: str, stdout: str, out_path: Path) -> tuple[str, dict | None]:
        raise NotImplementedError


class ClaudeAdapter(Adapter):
    name = "claude"
    binary = "claude"
    credential_files = (".claude/.credentials.json",)

    def home_env(self, home):
        return {"HOME": str(home), "CLAUDE_CONFIG_DIR": str(home / ".claude")}

    def command(self, role, workdir, schema_path, out_path, model):
        cmd = [self.binary, "-p", "--output-format", "json", "--dangerously-skip-permissions"]
        if model:
            cmd += ["--model", model]
        if role == "review":
            cmd += ["--json-schema", json.dumps(REVIEW_SCHEMA)]
        return cmd

    def parse(self, role, stdout, out_path):
        try:
            obj = json.loads(stdout)
        except ValueError:
            obj = None
        if not isinstance(obj, dict):
            return stdout, extract_json(stdout) if role == "review" else None
        text = obj.get("result")
        text = text if isinstance(text, str) else ""
        structured = obj.get("structured_output")
        if isinstance(structured, dict):
            return text, structured
        return text, extract_json(text) if role == "review" else None


class CodexAdapter(Adapter):
    name = "codex"
    binary = "codex"
    credential_files = (".codex/auth.json",)

    def home_env(self, home):
        return {"HOME": str(home), "CODEX_HOME": str(home / ".codex")}

    def command(self, role, workdir, schema_path, out_path, model):
        cmd = [self.binary, "exec", "--dangerously-bypass-approvals-and-sandbox",
               "--skip-git-repo-check", "-C", str(workdir)]
        if model:
            cmd += ["-m", model]
        if role == "review":
            cmd += ["--output-schema", str(schema_path)]
        return cmd + ["-o", str(out_path), "-"]

    def parse(self, role, stdout, out_path):
        text = _read_result_file(Path(out_path))
        if text is None:
            text = stdout
        return text, extract_json(text) if role == "review" else None


REGISTRY = {"claude": ClaudeAdapter, "codex": CodexAdapter}


def _find_pasta() -> str:
    found = shutil.which("pasta")
    if not found:
        raise FileNotFoundError(
            "pasta (passt) not found on PATH; refusing to run an agent on the host network")
    resolved = os.path.realpath(found)
    if not resolved.startswith(STORE_PREFIX):
        raise ValueError(f"pasta {resolved} is not under /nix/store; "
                         "refusing to run an agent on the host network")
    # passt picks pasta mode from argv[0], and the store file is named "passt".
    return found


def _find_ip() -> str:
    found = shutil.which("ip")
    if not found:
        raise sandbox.NoRoute("no route to the internet (ip not found on PATH; "
                              "refusing to start an agent without it)")
    if not os.path.realpath(found).startswith(STORE_PREFIX):
        raise sandbox.NoRoute(f"no route to the internet (ip {found} is not under /nix/store; "
                              "refusing to start an agent)")
    return found


def run_agent(adapter, role, *, workdir, prompt, home, writable, schema_path, log_path,
              timeout, model=None, wrap=None, binary=None, extra_ro=(), dns=None) -> Result:
    home, workdir, log_path = Path(home), Path(workdir), Path(log_path)
    found = binary or shutil.which(adapter.binary)
    if not found:
        raise FileNotFoundError(f"{adapter.name} not found on PATH")
    resolved = os.path.realpath(found)
    if wrap is None and not resolved.startswith(STORE_PREFIX):
        raise ValueError(f"{adapter.name} binary {resolved} is not under /nix/store; "
                         "the sandbox only exposes the store")
    pasta = _find_pasta() if wrap is None else None
    plan = None
    if wrap is None:
        plan = sandbox.network_plan(_find_ip(), dns)
    ensure_home(adapter, home)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    out_path = home / f"{adapter.name}-last-message.txt"
    if out_path.is_dir() and not out_path.is_symlink():
        shutil.rmtree(out_path)
    else:
        out_path.unlink(missing_ok=True)

    env = sandbox.clean_env({
        **adapter.home_env(home),
        "PATH": sandbox.store_path() + ":" + os.path.dirname(resolved),
    })
    cmd = adapter.command(role, workdir, schema_path, out_path, model)
    cmd[0] = resolved
    if wrap is None:
        resolv = home.parent / "resolv.conf"
        resolv.write_text(sandbox.RESOLV_CONF)
        resolv.chmod(0o644)
        argv = sandbox.net_wrap(
            sandbox.bwrap_argv(cmd=cmd, workdir=workdir, writable=writable, home=home,
                               env=env, extra_ro=tuple(extra_ro), resolv_conf=resolv),
            pasta=pasta, iface=plan.dev, dns_host=plan.dns_host)
        proc_env = {"PATH": os.environ["PATH"]}
    else:
        argv = wrap(cmd, env)
        proc_env = env

    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, start_new_session=True,
                            env=proc_env)
    timed_out = False
    try:
        out, _ = proc.communicate(adapter.stdin(prompt), timeout=timeout)
        code = proc.returncode
    except KeyboardInterrupt:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        raise
    except subprocess.TimeoutExpired as e:
        timed_out = True
        code = -9
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            out, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            out = ""
        if not out and e.output:
            out = e.output if isinstance(e.output, str) else e.output.decode(errors="replace")
    out = out or ""
    log_path.write_text((plan.describe() + "\n" if plan else "") + out)
    text, parsed = adapter.parse(role, out, out_path)
    return Result(text, parsed, code, timed_out)
