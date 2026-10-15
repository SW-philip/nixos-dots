import json
import subprocess

from uniremote.recenter import center_own_window


def fake_run(windows, calls):
    def run(cmd, **kw):
        calls.append(cmd)
        out = json.dumps(windows) if "--json" in cmd else ""
        return subprocess.CompletedProcess(cmd, 0, stdout=out, stderr="")
    return run


def test_centers_window_matching_pid():
    calls = []
    run = fake_run([{"id": 3, "pid": 111}, {"id": 9, "pid": 222}], calls)
    assert center_own_window(222, run=run) is True
    assert calls[-1] == ["niri", "msg", "action", "center-window", "--id", "9"]


def test_no_window_for_pid_does_nothing():
    calls = []
    run = fake_run([{"id": 3, "pid": 111}], calls)
    assert center_own_window(222, run=run) is False
    assert len(calls) == 1


def test_niri_missing_is_not_an_error():
    def run(cmd, **kw):
        raise FileNotFoundError("niri")
    assert center_own_window(222, run=run) is False
