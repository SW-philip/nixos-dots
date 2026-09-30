import importlib.util
import pathlib

spec = importlib.util.spec_from_file_location(
    "osk_focus_policy", pathlib.Path(__file__).with_name("osk-focus-policy.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def win(i, app, focused=False):
    return {"id": i, "app_id": app, "is_focused": focused}


def test_initial_state_and_focus_moves():
    t = m.FocusTracker()
    assert t.feed({"WindowsChanged": {"windows": [
        win(2, "com.mitchellh.ghostty", True), win(4, "firefox")]}}) == "com.mitchellh.ghostty"
    assert t.feed({"WindowFocusChanged": {"id": 4}}) == "firefox"
    assert t.feed({"WindowFocusChanged": {"id": None}}) is None


def test_open_and_close():
    t = m.FocusTracker()
    assert t.feed({"WindowOpenedOrChanged": {"window": win(7, "firefox", True)}}) == "firefox"
    assert t.feed({"WindowClosed": {"id": 7}}) is None
    assert t.feed({"Unrelated": {}}) is None
