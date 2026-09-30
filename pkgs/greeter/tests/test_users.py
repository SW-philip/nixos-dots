from greeter.users import select_human_users

# (name, uid, shell)
ENTRIES = [
    ("root", 0, "/run/current-system/sw/bin/bash"),
    ("greeter", 990, "/run/current-system/sw/bin/nologin"),
    ("philip", 1000, "/run/current-system/sw/bin/zsh"),
    ("guest", 1001, "/run/current-system/sw/bin/bash"),
    ("nobody", 65534, "/run/current-system/sw/bin/nologin"),
    ("svc", 1002, "/run/current-system/sw/bin/nologin"),
]


def test_only_human_uids_with_login_shells():
    assert select_human_users(ENTRIES) == ["guest", "philip"]


def test_sorted_alphabetically():
    out = select_human_users(ENTRIES)
    assert out == sorted(out)
