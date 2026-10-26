from lix_logout.commands import ACTIONS
from lix_logout.menu import ARMED_LABELS, ROWS, action_for_key, header_text


def test_rows_cover_every_command_action_in_order():
    assert [r.action for r in ROWS] == ["lock", "logout", "reboot", "shutdown"]
    assert {r.action for r in ROWS} == set(ACTIONS)


def test_keys_are_unique_single_letters():
    keys = [r.key for r in ROWS]
    assert keys == ["l", "o", "r", "s"]


def test_action_for_key_is_case_insensitive():
    assert action_for_key("R") == "reboot"
    assert action_for_key("o") == "logout"


def test_action_for_key_unknown_is_none():
    assert action_for_key("x") is None
    assert action_for_key("") is None


def test_only_destructive_rows_have_armed_labels():
    assert set(ARMED_LABELS) == {"reboot", "shutdown"}


def test_header_text():
    assert header_text("SWphil", "prepko") == "SWphil · prepko"
