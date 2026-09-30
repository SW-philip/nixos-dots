"""Enumerate human login users. Pure core + thin pwd wrapper."""
from __future__ import annotations

import pwd

_NOLOGIN_SHELLS = frozenset({
    "/usr/sbin/nologin", "/sbin/nologin", "/usr/bin/nologin",
    "/run/current-system/sw/bin/nologin", "/bin/false", "/usr/bin/false",
})


def select_human_users(
    entries: list[tuple[str, int, str]],
    min_uid: int = 1000,
    max_uid: int = 60000,
) -> list[str]:
    names = [
        name for (name, uid, shell) in entries
        if min_uid <= uid <= max_uid and shell not in _NOLOGIN_SHELLS
    ]
    return sorted(names)


def list_human_users() -> list[str]:
    entries = [(e.pw_name, e.pw_uid, e.pw_shell) for e in pwd.getpwall()]
    return select_human_users(entries)
