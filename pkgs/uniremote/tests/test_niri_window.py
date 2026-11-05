import json
import subprocess

from uniremote.niri_window import resize_own_window


def fake_run(windows, calls):
    def run(cmd, **kw):
        calls.append(cmd)
        out = json.dumps(windows) if "--json" in cmd else ""
        return subprocess.CompletedProcess(cmd, 0, stdout=out, stderr="")
    return run


def test_sets_the_width_of_the_window_matching_pid():
    calls = []
    run = fake_run([{"id": 3, "pid": 111}, {"id": 9, "pid": 222}], calls)
    assert resize_own_window(222, 660, run=run) is True
    assert calls[-1] == ["niri", "msg", "action", "set-window-width", "--id", "9", "660"]


def test_width_is_sent_as_a_plain_integer():
    calls = []
    run = fake_run([{"id": 1, "pid": 5}], calls)
    resize_own_window(5, 659.6, run=run)
    assert calls[-1][-1] == "659"


def test_no_window_for_pid_does_nothing():
    calls = []
    run = fake_run([{"id": 3, "pid": 111}], calls)
    assert resize_own_window(222, 660, run=run) is False
    assert len(calls) == 1


def test_niri_missing_is_not_an_error():
    def run(cmd, **kw):
        raise FileNotFoundError("niri")
    assert resize_own_window(222, 660, run=run) is False


def test_failed_command_is_not_an_error():
    def run(cmd, **kw):
        if "--json" in cmd:
            return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps([{"id": 1, "pid": 5}]), stderr="")
        raise subprocess.CalledProcessError(1, cmd)
    assert resize_own_window(5, 660, run=run) is False
