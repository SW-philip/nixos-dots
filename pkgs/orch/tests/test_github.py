import json
import subprocess
import unittest

from orch.github import GhError, create_draft_pr, find_pr, issue_view


class FakeRun:
    def __init__(self, stdout="", returncode=0, stderr=""):
        self.calls = []
        self.res = subprocess.CompletedProcess([], returncode, stdout, stderr)

    def __call__(self, argv, **kw):
        self.calls.append((argv, kw))
        return self.res


class IssueViewTests(unittest.TestCase):
    def test_parses_and_argv(self):
        run = FakeRun(json.dumps({"number": 3, "title": "t"}))
        self.assertEqual(issue_view("o/r", 3, run=run), {"number": 3, "title": "t"})
        argv, kw = run.calls[0]
        self.assertEqual(argv, ["gh", "issue", "view", "3", "--repo", "o/r",
                                "--json", "number,title,body,labels,url"])
        self.assertFalse(kw.get("shell", False))

    def test_failure_and_bad_json(self):
        with self.assertRaises(GhError) as cm:
            issue_view("o/r", 3, run=FakeRun(returncode=1, stderr="boom"))
        self.assertIn("boom", str(cm.exception))
        with self.assertRaises(GhError):
            issue_view("o/r", 3, run=FakeRun("not json"))
        with self.assertRaises(GhError):
            issue_view("o/r", 3, run=FakeRun("[1]"))


class PrTests(unittest.TestCase):
    def test_draft_pr(self):
        run = FakeRun("Creating...\nhttps://github.com/o/r/pull/9\n\n")
        url = create_draft_pr("o/r", "orch/3-x", "main", "-title", "body $(x)", run=run)
        self.assertEqual(url, "https://github.com/o/r/pull/9")
        argv, kw = run.calls[0]
        self.assertEqual(argv, ["gh", "pr", "create", "--draft", "--repo", "o/r",
                                "--head", "orch/3-x", "--base", "main",
                                "--title", "-title", "--body-file", "-"])
        self.assertEqual(kw["input"], "body $(x)")

    def test_non_url_and_failure(self):
        with self.assertRaises(GhError):
            create_draft_pr("o/r", "b", "main", "t", "b", run=FakeRun("nope\n"))
        with self.assertRaises(GhError):
            create_draft_pr("o/r", "b", "main", "t", "b", run=FakeRun(returncode=1))


class QueueRun(FakeRun):
    def __init__(self, *outs):
        super().__init__()
        self.outs = list(outs)

    def __call__(self, argv, **kw):
        self.calls.append((argv, kw))
        return subprocess.CompletedProcess([], 0, self.outs.pop(0), "")


class FindPrTests(unittest.TestCase):
    URL = "https://github.com/o/r/pull/4"

    def test_argv_and_hit(self):
        run = QueueRun(json.dumps([{"url": self.URL}]))
        self.assertEqual(find_pr("o/r", "orch/3-x", run=run), self.URL)
        self.assertEqual(len(run.calls), 1)
        self.assertEqual(run.calls[0][0], ["gh", "pr", "list", "--repo", "o/r", "--head", "orch/3-x",
                                           "--state", "open", "--json", "url", "--limit", "1"])

    def test_none_when_no_pr_at_all(self):
        run = QueueRun("[]", "[]")
        self.assertIsNone(find_pr("o/r", "b", run=run))
        self.assertEqual(run.calls[1][0][run.calls[1][0].index("--state") + 1], "all")

    def test_closed_or_merged_is_error(self):
        with self.assertRaisesRegex(GhError, "a closed or merged PR already exists for b"):
            find_pr("o/r", "b", run=QueueRun("[]", json.dumps([{"url": self.URL}])))

    def test_strict_url_and_errors(self):
        for bad in ("nope", "{}", '[{"url": 3}]', "[1]", '[{"url": "http://x"}]',
                    '[{"url": "https://evil.example/o/r/pull/4"}]',
                    '[{"url": "https://github.com/o/r/pull/4\\nx"}]',
                    '[{"url": "https://github.com/o/r/issues/4"}]'):
            with self.subTest(bad=bad), self.assertRaises(GhError):
                find_pr("o/r", "b", run=QueueRun(bad))
        with self.assertRaises(GhError):
            find_pr("o/r", "b", run=FakeRun(returncode=1, stderr="x"))


if __name__ == "__main__":
    unittest.main()
