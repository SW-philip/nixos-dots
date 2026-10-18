import json
import re
import subprocess


class GhError(Exception):
    pass


def _run(run, argv, **kw):
    try:
        res = run(argv, capture_output=True, text=True, **kw)
    except OSError as e:
        raise GhError(f"{' '.join(argv[:3])} failed: {e}") from e
    if res.returncode != 0:
        raise GhError(f"{' '.join(argv[:3])} failed: {(res.stderr or '').strip()}")
    return res.stdout


def issue_view(repo: str, number: int, run=subprocess.run) -> dict:
    out = _run(run, ["gh", "issue", "view", str(number), "--repo", repo,
                     "--json", "number,title,body,labels,url"])
    try:
        data = json.loads(out)
    except ValueError as e:
        raise GhError(f"gh issue view: bad JSON: {e}") from e
    if not isinstance(data, dict):
        raise GhError("gh issue view: expected a JSON object")
    return data


_PR_URL = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+")


def _pr_list(run, repo, branch, state):
    out = _run(run, ["gh", "pr", "list", "--repo", repo, "--head", branch,
                     "--state", state, "--json", "url", "--limit", "1"])
    try:
        data = json.loads(out)
    except ValueError as e:
        raise GhError(f"gh pr list: bad JSON: {e}") from e
    if not isinstance(data, list):
        raise GhError("gh pr list: expected a JSON array")
    if not data:
        return None
    url = data[0].get("url") if isinstance(data[0], dict) else None
    if not isinstance(url, str) or not _PR_URL.fullmatch(url):
        raise GhError("gh pr list: no PR URL in output")
    return url


def find_pr(repo: str, branch: str, run=subprocess.run) -> str | None:
    """The open PR for the branch, or None. A closed or merged one is an error:
    it is not a finished publish and a second `gh pr create` would be wrong."""
    url = _pr_list(run, repo, branch, "open")
    if url is None and _pr_list(run, repo, branch, "all") is not None:
        raise GhError(f"a closed or merged PR already exists for {branch}")
    return url


def create_draft_pr(repo, branch, base, title, body, run=subprocess.run) -> str:
    out = _run(run, ["gh", "pr", "create", "--draft", "--repo", repo, "--head", branch,
                     "--base", base, "--title", title, "--body-file", "-"], input=body)
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    if not lines or not lines[-1].startswith("http"):
        raise GhError(f"gh pr create: no PR URL in output: {out.strip()[:200]!r}")
    return lines[-1]
