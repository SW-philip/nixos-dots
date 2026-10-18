"""Run state on disk. One directory per run; state.json is rewritten
atomically before and after every step so a crashed run can resume."""

import hashlib
import json
import os
import re
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path

STEPS = ("fetch", "worktree", "implement", "review", "fix", "publish", "done")


def data_dir() -> Path:
    base = os.environ.get("ORCH_HOME")
    return Path(base) if base else Path.home() / ".local" / "share" / "orch"


def new_run_id(repo: str, issue: int, now: datetime | None = None) -> str:
    stamp = (now or datetime.now()).strftime("%Y%m%d-%H%M%S")
    slug = re.sub(r"[^A-Za-z0-9]+", "-", repo).strip("-").lower()
    if len(slug) > 60:
        slug = slug[:60].rstrip("-") + "-" + hashlib.sha256(repo.encode()).hexdigest()[:8]
    return f"{stamp}-{slug}-{issue}"


@dataclass
class RunState:
    run_id: str
    repo: str
    issue: int
    implementer: str
    reviewer: str
    max_rounds: int
    step: str = "fetch"        # next step to execute
    status: str = "running"    # running | done | needs-human | failed
    reason: str = ""
    round: int = 0
    branch: str = ""
    base: str = ""
    pr_url: str | None = None
    rounds: list = field(default_factory=list)
    gitdir: str = ""  # trusted worktree admin dir inside the mirror


def run_dir(run_id: str) -> Path:
    return data_dir() / "runs" / run_id


def save(state: RunState) -> None:
    d = run_dir(state.run_id)
    d.mkdir(parents=True, exist_ok=True)
    tmp = d / "state.json.tmp"
    tmp.write_text(json.dumps(asdict(state), indent=2))
    tmp.replace(d / "state.json")


def load(run_id: str) -> RunState:
    raw = json.loads((run_dir(run_id) / "state.json").read_text())
    return RunState(**raw)


def list_runs() -> list[RunState]:
    root = data_dir() / "runs"
    out = []
    for d in sorted(root.iterdir(), reverse=True) if root.is_dir() else []:
        try:
            out.append(load(d.name))
        except (OSError, ValueError, TypeError):
            continue
    return out
