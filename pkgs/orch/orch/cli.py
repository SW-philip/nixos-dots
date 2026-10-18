"""Command line entry point. Progress goes to stderr, the one-line result to stdout."""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from . import agents, config, github, gitops, sandbox, state
from .runner import SCHEMA_PATH, Orchestrator, mirror_path

_RUN_ID = re.compile(r"^[A-Za-z0-9._-]+$")


def _log(msg: str) -> None:
    print(f"orch: {msg}", file=sys.stderr, flush=True)


def _run_id(value: str) -> str:
    if not _RUN_ID.fullmatch(value) or value in (".", ".."):
        raise argparse.ArgumentTypeError(f"invalid run id {value!r}")
    return value


_REPO = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")


def _repo(value: str) -> str:
    # Dot-only segments would make "../.." an existing local path for gitops.
    if not _REPO.fullmatch(value) or any(set(p) == {"."} for p in value.split("/")):
        raise argparse.ArgumentTypeError(f"repo must look like owner/name, got {value!r}")
    return value


def _issue(value: str) -> int:
    try:
        n = int(value)
    except ValueError:
        n = 0
    if n < 1:
        raise argparse.ArgumentTypeError(f"issue must be an integer >= 1, got {value!r}")
    return n


def _rounds(value: str) -> int:
    try:
        n = int(value)
    except ValueError:
        n = -1
    if not 0 <= n <= 10:
        raise argparse.ArgumentTypeError(f"rounds must be an integer from 0 to 10, got {value!r}")
    return n


def _agent_home(name: str) -> Path:
    return state.data_dir() / "agents" / name / "home"


def _make_run_agent(cfg):
    def run_agent(role, agent_name, *, workdir, prompt, writable, schema_path,
                  log_path, timeout, extra_ro=()):
        _log(f"{role}: {agent_name} working in {workdir}")
        adapter, auth = agents.REGISTRY[agent_name](), _agent_home(agent_name)
        run_home = Path(workdir).parent / "agent-home" / role
        agents.prepare_run_home(adapter, auth, run_home)
        try:
            return agents.run_agent(
                adapter, role, workdir=workdir, prompt=prompt,
                home=run_home, writable=writable,
                # The run's own copy of the schema lives where the agent could have
                # tampered with it; always hand the sandbox the packaged one.
                schema_path=SCHEMA_PATH if schema_path is not None else None,
                log_path=log_path, timeout=timeout,
                model=config.agent_model(cfg, agent_name), extra_ro=extra_ro,
                dns=cfg.get("dns"))
        finally:
            agents.finish_run_home(adapter, auth, run_home)
    return run_agent


def _result(st) -> int:
    if st.status == "done":
        print(f"done {st.pr_url}")
        return 0
    print(f"{st.status} {st.reason} ({state.run_dir(st.run_id)})")
    return 1


def _load_config(path):
    if path is not None:
        if not path.exists():
            raise ValueError(f"config file not found: {path}")
        if not path.is_file():
            raise ValueError(f"config file is not a file: {path}")
    try:
        return config.load(path)
    except OSError as e:
        raise ValueError(f"cannot read config file: {e}") from e


def _cmd_run(args) -> int:
    cfg = _load_config(args.config)
    impl, rev = args.impl or cfg["implementer"], args.review or cfg["reviewer"]
    if impl == rev:
        print(f"orch: warning: same agent reviews its own work ({impl})", file=sys.stderr)
    orch = Orchestrator(cfg, gh=github, git=gitops, run_agent=_make_run_agent(cfg))
    _log(f"starting {args.repo}#{args.issue} (implement: {impl}, review: {rev})")
    return _result(orch.run(args.repo, args.issue, args.impl, args.review, args.rounds))


def _cmd_resume(args) -> int:
    cfg = _load_config(args.config)
    orch = Orchestrator(cfg, gh=github, git=gitops, run_agent=_make_run_agent(cfg))
    _log(f"resuming {args.run_id}")
    return _result(orch.resume(args.run_id))


def _cmd_status(args) -> int:
    if args.run_id:
        try:
            st = state.load(args.run_id)
        except (OSError, ValueError, TypeError) as e:
            print(f"orch: cannot read run {args.run_id}: {e}", file=sys.stderr)
            return 1
        print(json.dumps(st.__dict__, indent=2))
        return 0
    runs = state.list_runs()
    if not runs:
        print("no runs")
        return 0
    rows = [("RUN", "ISSUE", "STATUS", "STEP", "ROUND")]
    rows += [(r.run_id, f"{r.repo}#{r.issue}", r.status, r.step, str(r.round)) for r in runs]
    widths = [max(len(row[i]) for row in rows) for i in range(5)]
    for row in rows:
        print("  ".join(c.ljust(w) for c, w in zip(row, widths)).rstrip())
    return 0


def _cmd_clean(args) -> int:
    runs = (state.data_dir() / "runs").resolve()
    d = state.run_dir(args.run_id)
    if d.is_symlink() or not d.is_dir() or d.resolve().parent != runs:
        print(f"orch: refusing to clean {d}: not a plain run directory", file=sys.stderr)
        return 1
    try:
        st = state.load(args.run_id)
    except (OSError, ValueError, TypeError) as e:
        print(f"orch: cannot read run {args.run_id}: {e}", file=sys.stderr)
        return 1
    if st.status == "running" and not args.force:
        print(f"orch: run {args.run_id} is running; refusing to clean (--force to override)",
              file=sys.stderr)
        return 1
    mirror, work = mirror_path(st.repo), d / "work"
    try:
        if mirror.is_dir():
            gitops.remove_worktree(mirror, work)
            if st.branch:
                gitops.delete_branch(mirror, st.branch)
    except Exception as e:
        print(f"orch: git cleanup failed, run directory kept: {e}", file=sys.stderr)
        return 1
    shutil.rmtree(d)
    _log(f"removed {args.run_id}")
    return 0


def _cmd_login(args) -> int:
    adapter = agents.REGISTRY[args.agent]()
    found = shutil.which(adapter.binary)
    if not found:
        print(f"orch: {adapter.binary} not found on PATH", file=sys.stderr)
        return 1
    resolved = os.path.realpath(found)
    home = _agent_home(args.agent)
    agents.ensure_home(adapter, home)
    env = sandbox.clean_env({"HOME": str(home), "PATH": os.path.dirname(resolved),
                             **adapter.home_env(home)})
    if args.agent == "claude":
        argv = [resolved]
        print("orch: when claude starts, type /login", file=sys.stderr)
    else:
        argv = [resolved, "login"]
    return subprocess.run(argv, env=env, cwd=home, check=False).returncode


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="orch", description="Issue to draft PR orchestrator")
    sub = p.add_subparsers(dest="cmd", required=True)
    known = config.KNOWN_AGENTS

    def runlike(name, help_):
        sp = sub.add_parser(name, help=help_)
        sp.add_argument("--config", type=Path, default=None)
        return sp

    sp = runlike("run", "work an issue into a draft PR")
    sp.add_argument("repo", type=_repo)
    sp.add_argument("issue", type=_issue)
    sp.add_argument("--impl", choices=known)
    sp.add_argument("--review", choices=known)
    sp.add_argument("--rounds", type=_rounds)
    sp.set_defaults(fn=_cmd_run)
    sp = runlike("resume", "continue an interrupted run")
    sp.add_argument("run_id", type=_run_id)
    sp.set_defaults(fn=_cmd_resume)
    sp = sub.add_parser("status", help="list runs or show one")
    sp.add_argument("run_id", nargs="?", type=_run_id)
    sp.set_defaults(fn=_cmd_status)
    sp = sub.add_parser("clean", help="remove a finished run")
    sp.add_argument("run_id", type=_run_id)
    sp.add_argument("--force", action="store_true", help="also clean a run still marked running")
    sp.set_defaults(fn=_cmd_clean)
    sp = sub.add_parser("login", help="log an agent in to its private home")
    sp.add_argument("agent", choices=known)
    sp.set_defaults(fn=_cmd_login)
    return p


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        return args.fn(args)
    except ValueError as e:
        print(f"orch: {e}", file=sys.stderr)
        return 2
    except KeyboardInterrupt as e:
        run_id = getattr(e, "run_id", None) or getattr(args, "run_id", None)
        print(f"interrupted: orch resume {run_id}" if run_id else "interrupted",
              file=sys.stderr)
        return 130
