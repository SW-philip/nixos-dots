"""Issue to draft PR state machine. Every step saves state before and after
so `resume` can continue after a crash; `failed` keeps its step for retry."""

import hashlib
import json
import os
import re
import traceback
import unicodedata
from datetime import datetime
from pathlib import Path

from . import prompts, state, verdict as vd
from .state import RunState

TERMINAL = ("done", "needs-human")
SCHEMA_PATH = Path(__file__).parent / "schemas" / "review.json"


class Interrupted(KeyboardInterrupt):
    """Ctrl-C mid-run; the run is saved as failed at its current step."""

    def __init__(self, run_id: str):
        super().__init__(run_id)
        self.run_id = run_id


class StepFailed(Exception):
    """A step failed in a way that `resume` should retry from the same step."""


def _single_line(text: str) -> str:
    text = "".join(" " if unicodedata.category(c) in ("Cc", "Cf", "Zl", "Zp") else c
                   for c in str(text))
    return re.sub(r"\s+", " ", text).strip()


ZWSP = "\u200b"
BODY_LIMIT = 60000
_CLOSING = re.compile(
    r"\b(close[sd]?|fix(?:es|ed)?|resolve[sd]?)(?=\s*:?\s*(?:#|\d|GH-\d|[\w.-]+/[\w.-]+(?:#|/issues/)|https?://|(?:www\.)?github\.com/))",
    re.I)


def _neutralize(text, limit: int = 500) -> str:
    """Defang model/issue-derived text for a PR body: no mentions, no closing
    keywords, no cross-references, no HTML."""
    text = _single_line(text)
    if len(text) > limit:
        text = text[:limit - 1] + "\u2026"
    text = text.replace("<", "&lt;").replace("@", "@" + ZWSP)
    text = _CLOSING.sub(lambda m: m.group(1) + ZWSP, text)
    return re.sub(r"#(?=\d)", "#" + ZWSP, text)


def pr_title(title: str, issue: int) -> str:
    one = _neutralize(title, 120)[:120].strip()
    return one or f"issue {issue}"


def branch_name(issue: int, title: str, run_id: str = "") -> str:
    """Unique per run (hash of the full run id, collision suffix included) whatever
    the clock resolution, but bounded: a long local repo path must not reach the ref."""
    slug = re.sub(r"[^a-z0-9]+", "-", str(title).lower()).strip("-")[:40].strip("-")
    name = f"orch/{issue}-{slug or 'issue'}"
    if not run_id:
        return name
    m = re.match(r"^(\d{8})-(\d{6})-", run_id)
    stamp = f"-{m.group(1)}{m.group(2)}" if m else ""
    return f"{name}{stamp}-{hashlib.sha256(run_id.encode()).hexdigest()[:8]}"


def mirror_path(repo: str) -> Path:
    base = Path(repo).name if Path(repo).exists() else repo.replace("/", "__")
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", base).lstrip(".-") or "repo"
    slug = slug.removesuffix(".git")
    return state.data_dir() / "repos" / f"{slug}.git"


def _finding_dicts(findings) -> list[dict]:
    return [{"severity": f.severity, "file": f.file, "line": f.line, "text": f.text}
            for f in findings]


def _findings(dicts) -> list[vd.Finding]:
    return [vd.Finding(d["severity"], d.get("file"), d.get("line"), d["text"]) for d in dicts]


class Orchestrator:
    def __init__(self, cfg, *, gh, git, run_agent, now=datetime.now):
        self.cfg, self.gh, self.git, self.run_agent, self.now = cfg, gh, git, run_agent, now

    def run(self, repo, issue, implementer=None, reviewer=None, max_rounds=None) -> RunState:
        if max_rounds is None:
            max_rounds = self.cfg["max_rounds"]
        if isinstance(max_rounds, bool) or not isinstance(max_rounds, int) or max_rounds < 0:
            raise ValueError(f"max_rounds must be an integer >= 0, got {max_rounds!r}")
        run_id = base_id = state.new_run_id(repo, issue, self.now())
        k = 1
        while state.run_dir(run_id).exists():
            k += 1
            run_id = f"{base_id}-{k}"
        st = RunState(
            run_id=run_id, repo=repo, issue=issue,
            implementer=implementer or self.cfg["implementer"],
            reviewer=reviewer or self.cfg["reviewer"],
            max_rounds=max_rounds)
        state.save(st)
        return self._drive(st)

    def resume(self, run_id: str) -> RunState:
        st = state.load(run_id)
        if st.status in TERMINAL:
            return st
        st.status, st.reason = "running", ""
        state.save(st)
        return self._drive(st)

    def _drive(self, st: RunState) -> RunState:
        steps = {"fetch": self._fetch, "worktree": self._worktree,
                 "implement": self._implement, "fix": self._implement,
                 "review": self._review, "publish": self._publish}
        while st.status == "running" and st.step in steps:
            step = st.step
            state.save(st)
            try:
                steps[step](st)
            except KeyboardInterrupt:
                st.status, st.reason = "failed", "interrupted"
                state.save(st)
                raise Interrupted(st.run_id) from None
            except StepFailed as e:
                st.status, st.reason = "failed", str(e)
            except Exception as e:
                st.status, st.reason = "failed", f"{step}: {_single_line(e)}"
                self._error_log(st)
            state.save(st)
        return st

    def _error_log(self, st) -> None:
        try:
            fd = os.open(self._dir(st) / "error.log", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(traceback.format_exc())
        except OSError:
            pass

    def _dir(self, st) -> Path:
        return state.run_dir(st.run_id)

    def _issue(self, st) -> dict:
        return json.loads((self._dir(st) / "issue.json").read_text())

    def _fetch(self, st):
        issue = self.gh.issue_view(st.repo, st.issue)
        (self._dir(st) / "issue.json").write_text(json.dumps(issue, indent=2))
        st.step = "worktree"

    def _worktree(self, st):
        issue = self._issue(st)
        mirror = mirror_path(st.repo)
        mirror.parent.mkdir(parents=True, exist_ok=True)
        base = self.git.ensure_mirror(st.repo, mirror)
        work = self._dir(st) / "work"
        branch = branch_name(st.issue, issue.get("title", ""), st.run_id)
        # A previous attempt of this same run may have left either behind; the
        # branch name is unique to this run, so deleting it never touches another's.
        self.git.remove_worktree(mirror, work)
        self.git.delete_branch(mirror, branch)
        # Already pushed by an earlier attempt: recreating it would diverge from
        # origin and the push would be rejected, so take a fresh name.
        k = 1
        base_branch = branch
        while self.git.ref_exists(mirror, f"refs/remotes/origin/{branch}"):
            k += 1
            branch = f"{base_branch}-r{k}"
        gitdir = self.git.add_worktree(mirror, work, branch, base)
        st.branch, st.base, st.gitdir = branch, base, str(gitdir)
        st.step = "implement"

    def _implement(self, st):
        issue, n = self._issue(st), st.round
        work = self._dir(st) / "work"
        findings = None
        if n > 0:
            prev = next(r for r in reversed(st.rounds) if r["round"] == n - 1)
            findings = _findings(prev["must_fix"])
        res = self.run_agent(
            "implement", st.implementer, workdir=work, writable=True, schema_path=None,
            prompt=prompts.implement_prompt(issue, findings),
            log_path=self._dir(st) / "rounds" / str(n) / "impl.log",
            timeout=self.cfg["timeout_s"], extra_ro=(mirror_path(st.repo),))
        if res.timed_out:
            raise StepFailed("implementer timed out")
        if res.exit_code != 0:
            raise StepFailed(f"implementer exited {res.exit_code}")
        title = pr_title(issue.get("title", ""), st.issue)
        changed = self.git.commit_all(work, f"orch: {title} (round {n})", st.gitdir)
        if not changed:
            if n == 0:
                # A crash between commit_all and the state save leaves the round-0
                # commit in place; resuming then finds nothing new to stage.
                if self.git.commits_ahead(work, st.base, st.gitdir) == 0:
                    raise StepFailed("agent made no changes")
            else:
                st.rounds = [r for r in st.rounds if r["round"] != n]
                st.rounds.append({"round": n, "verdict": "no-change", "findings": [],
                                  "must_fix": [], "no_change": True})
        st.step = "review"

    def _review(self, st):
        issue, n = self._issue(st), st.round
        work = self._dir(st) / "work"
        diff = self.git.diff(work, st.base, st.gitdir)
        res = self.run_agent(
            "review", st.reviewer, workdir=work, writable=False, schema_path=SCHEMA_PATH,
            prompt=prompts.review_prompt(issue, diff, n),
            log_path=self._dir(st) / "rounds" / str(n) / "review.log",
            timeout=self.cfg["timeout_s"], extra_ro=(mirror_path(st.repo),))
        if res.timed_out:
            raise StepFailed("reviewer timed out")
        if res.exit_code != 0:
            raise StepFailed(f"reviewer exited {res.exit_code}")
        v = vd.parse_verdict(res.parsed if res.parsed is not None else res.text)
        prior = [r for r in st.rounds if r["round"] == n]
        entry = {"round": n, "verdict": v.verdict, "summary": v.summary,
                 "findings": _finding_dicts(v.findings),
                 "must_fix": _finding_dicts(vd.must_fix(v))}
        if any(r.get("no_change") for r in prior):
            entry["no_change"] = True
        st.rounds = [r for r in st.rounds if r["round"] != n] + [entry]
        rdir = self._dir(st) / "rounds" / str(n)
        rdir.mkdir(parents=True, exist_ok=True)
        (rdir / "review.json").write_text(json.dumps(entry, indent=2))
        if vd.approved(v):
            st.step = "publish"
        elif n >= st.max_rounds:
            st.status = "needs-human"
            st.reason = f"not approved after {n} rounds"
            self._report(st, issue)
        else:
            st.round = n + 1
            st.step = "fix"

    def _table(self, st) -> str:
        rows = ["| round | verdict | blockers | majors | minors |", "|---|---|---|---|---|"]
        for r in sorted(st.rounds, key=lambda r: r["round"]):
            count = lambda s: sum(1 for f in r["findings"] if f["severity"] == s)  # noqa: E731
            label = r["verdict"] + (" (no change)" if r.get("no_change") and
                                    r["verdict"] != "no-change" else "")
            label = _neutralize(label, 40)
            rows.append(f"| {r['round']} | {label} | {count('blocker')} | "
                        f"{count('major')} | {count('minor')} |")
        return "\n".join(rows)

    def _report(self, st, issue):
        last = max(st.rounds, key=lambda r: r["round"])
        text = (f"# orch run {st.run_id}\n\nIssue: {issue.get('url', st.issue)}\n\n"
                f"Status: {st.status} ({st.reason})\n\nBranch: {st.branch}\n\n"
                f"{self._table(st)}\n\n## Last findings\n\n"
                f"{vd.format_findings(_findings(last['findings']))}\n")
        (self._dir(st) / "report.md").write_text(text)

    def _publish(self, st):
        issue = self._issue(st)
        last = max(st.rounds, key=lambda r: r["round"])
        minors = [f for f in last["findings"] if f["severity"] == "minor"]
        url = issue.get("url")
        closes = (f"Closes {url}\n\n" if isinstance(url, str)
                  and re.fullmatch(r"https://github\.com/[\w.-]+/[\w.-]+/issues/\d+", url)
                  else "")
        self._report(st, issue)
        body = (f"{closes}Final verdict: {_neutralize(last['verdict'], 40)}\n\n"
                f"{_neutralize(last.get('summary', ''), 2000)}\n\n{self._table(st)}\n")
        lines = []
        for f in minors:
            loc = ""
            if f.get("file"):
                loc = " " + _neutralize(f["file"], 200)
                if f.get("line") is not None:
                    loc += f":{int(f['line'])}"
            lines.append(f"- [minor]{loc} {_neutralize(f['text'], 500)}")
        if lines:
            head = "\n## Remaining minor findings\n\n"
            report = self._dir(st) / "report.md"
            foot = lambda k: f"\n\u2026(truncated; {k} more findings in {report})\n"  # noqa: E731
            used, kept = len(body) + len(head), []
            for i, ln in enumerate(lines):
                if used + len(ln) + 1 + len(foot(len(lines) - i)) > BODY_LIMIT:
                    break
                kept.append(ln)
                used += len(ln) + 1
            body += head + "\n".join(kept) + "\n"
            if len(kept) < len(lines):
                body += foot(len(lines) - len(kept))
        try:
            self.git.push(mirror_path(st.repo), st.branch)
            # A retry after a lost `gh pr create` response must not open a second PR.
            url = self.gh.find_pr(st.repo, st.branch) or self.gh.create_draft_pr(
                st.repo, st.branch, st.base, pr_title(issue.get("title", ""), st.issue), body)
        except Exception as e:
            raise StepFailed(f"publish: {e}") from e
        st.pr_url, st.step, st.status = url, "done", "done"
