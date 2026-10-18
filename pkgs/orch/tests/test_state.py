import json
import os
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

from orch import state


class StateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        self._env = mock.patch.dict(os.environ, {"ORCH_HOME": str(self.home)})
        self._env.start()

    def tearDown(self):
        self._env.stop()
        self._tmp.cleanup()

    def make(self, run_id="r1", **kw):
        fields = dict(run_id=run_id, repo="SW-philip/nixos", issue=7,
                      implementer="claude", reviewer="codex", max_rounds=3)
        fields.update(kw)
        return state.RunState(**fields)

    def test_new_run_id(self):
        rid = state.new_run_id("SW-philip/nixos", 7, datetime(2026, 10, 17, 9, 5, 3))
        self.assertEqual(rid, "20261017-090503-sw-philip-nixos-7")

    def test_save_load_round_trip(self):
        s = self.make(step="review", status="needs-human", reason="cap",
                      round=2, branch="orch/7", base="main",
                      pr_url="https://github.com/x/y/pull/1",
                      rounds=[{"n": 1, "verdict": "changes"}])
        state.save(s)
        self.assertEqual(state.load("r1"), s)

    def test_gitdir_round_trips(self):
        state.save(self.make(gitdir="/m/worktrees/w"))
        self.assertEqual(state.load("r1").gitdir, "/m/worktrees/w")
        self.assertEqual(self.make().gitdir, "")

    def test_save_leaves_no_tmp_file(self):
        state.save(self.make())
        leftovers = list(state.run_dir("r1").glob("*.tmp"))
        self.assertEqual(leftovers, [])
        self.assertTrue((state.run_dir("r1") / "state.json").exists())

    def test_list_runs_newest_first_and_skips_corrupt(self):
        state.save(self.make("20260101-000000-a-1"))
        state.save(self.make("20260201-000000-a-2"))
        state.save(self.make("20260301-000000-a-3"))
        bad = state.run_dir("20260250-000000-bad-9")
        bad.mkdir(parents=True)
        (bad / "state.json").write_text("{not json")
        ids = [s.run_id for s in state.list_runs()]
        self.assertEqual(ids, ["20260301-000000-a-3",
                               "20260201-000000-a-2",
                               "20260101-000000-a-1"])

    def test_load_missing_raises(self):
        with self.assertRaises(FileNotFoundError):
            state.load("missing")

    def test_data_dir_honours_orch_home(self):
        self.assertEqual(state.data_dir(), self.home)


if __name__ == "__main__":
    unittest.main()
