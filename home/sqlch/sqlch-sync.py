#!/usr/bin/env python3
"""Authority-aware merge of sqlch's library.json and favorites.json between
this host and one remote host over ssh.

Stations are keyed by sqlch's own "id" field. A station on only one side is
appended, unmodified, to the other side -- so a new station added on either
host propagates. A station present on BOTH sides with differing contents
converges to the AUTHORITATIVE host's copy (surface); play-tracking fields
(last_played, play_count) are merged by max, never a reason to overwrite on
their own. Nothing is ever deleted, so removing a station means removing it
on both hosts.

favorites.json rows are keyed by (source, id); the newest updated_at wins
(ties go to the authority) and tombstones propagate un-favorites.

Usage:  sqlch-sync <remote-host> [<is-authority: 1|0>]
"""
import json
import os
import subprocess
import sys
import time
from typing import Callable, NamedTuple

LOCAL_PATH = os.path.expanduser("~/.local/share/sqlch/library.json")
REMOTE_PATH = "~/.local/share/sqlch/library.json"
SSH_OPTS = ["-o", "ConnectTimeout=8", "-o", "BatchMode=yes"]

VOLATILE = ("last_played", "play_count")


def parse_authority(argv) -> bool:
    return len(argv) > 2 and argv[2] == "1"


def atomic_write(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(json.dumps(data, indent=2, sort_keys=True))
    os.replace(tmp, path)


def ssh_read(host, path, default=None):
    cmd = f"cat {path}"
    if default is not None:
        # a host that never favorited anything has no file yet
        cmd = f"if [ -f {path} ]; then cat {path}; else echo '{json.dumps(default)}'; fi"
    p = subprocess.run(["ssh", *SSH_OPTS, host, cmd], capture_output=True, timeout=15)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode(errors="replace").strip())
    return json.loads(p.stdout)


def ssh_write(host, path, data):
    payload = json.dumps(data, indent=2, sort_keys=True).encode()
    tmp = path + ".tmp"
    p = subprocess.run(["ssh", *SSH_OPTS, host, f"cat > {tmp}"], input=payload, timeout=15)
    if p.returncode != 0:
        raise RuntimeError(f"remote write failed (exit {p.returncode})")
    subprocess.run(["ssh", *SSH_OPTS, host, f"mv {tmp} {path}"], check=True, timeout=15)


def entry_differs(a: dict, b: dict) -> bool:
    aa = {k: v for k, v in a.items() if k not in VOLATILE}
    bb = {k: v for k, v in b.items() if k not in VOLATILE}
    return aa != bb


def merged_volatile(winner: dict, other: dict) -> dict:
    out = dict(winner)
    if "play_count" in winner or "play_count" in other:
        out["play_count"] = max(winner.get("play_count") or 0, other.get("play_count") or 0)
    if "last_played" in winner or "last_played" in other:
        lp = max(winner.get("last_played") or 0, other.get("last_played") or 0)
        out["last_played"] = lp or None
    return out


def merge(local: dict, remote: dict, is_authority: bool):
    """Return (new_local, new_remote, local_changed, remote_changed)."""
    local_by = {s["id"]: s for s in local["stations"]}
    remote_by = {s["id"]: s for s in remote["stations"]}

    new_local_by = dict(local_by)
    new_remote_by = dict(remote_by)

    for sid in sorted(local_by.keys() | remote_by.keys()):
        l = local_by.get(sid)
        r = remote_by.get(sid)
        if l is None:
            new_local_by[sid] = r
        elif r is None:
            new_remote_by[sid] = l
        elif entry_differs(l, r):
            winner, other = (l, r) if is_authority else (r, l)
            merged = merged_volatile(winner, other)
            new_local_by[sid] = merged
            new_remote_by[sid] = merged

    def rebuild(original, new_by):
        seen = set()
        out = []
        for s in original["stations"]:            # keep existing order
            out.append(new_by[s["id"]])
            seen.add(s["id"])
        for sid, s in new_by.items():              # then anything newly received
            if sid not in seen:
                out.append(s)
        result = dict(original)
        result["stations"] = out
        return result

    new_local = rebuild(local, new_local_by)
    new_remote = rebuild(remote, new_remote_by)
    return (
        new_local,
        new_remote,
        new_local["stations"] != local["stations"],
        new_remote["stations"] != remote["stations"],
    )


TOMBSTONE_TTL = 90 * 86400


def _fav_key(r):
    if isinstance(r, dict) and r.get("source") and r.get("id"):
        return (r["source"], r["id"])
    return None


def merge_favorites(local: list, remote: list, is_authority: bool, now=None):
    """Return (new_local, new_remote, local_changed, remote_changed).

    Per (source, id) the row with the larger updated_at wins (missing = 0);
    a tie goes to the authority host. Tombstones (removed) merge like any row,
    which is how an un-favorite propagates; ones older than TOMBSTONE_TTL are
    dropped from both sides. Rows without a key pass through on their own side.
    """
    now = time.time() if now is None else now
    cutoff = now - TOMBSTONE_TTL

    def ts(r):
        return r.get("updated_at") or 0

    local_by = {k: r for r in local if (k := _fav_key(r))}
    remote_by = {k: r for r in remote if (k := _fav_key(r))}

    winners = {}
    for k in local_by.keys() | remote_by.keys():
        lrow, rrow = local_by.get(k), remote_by.get(k)
        if lrow is None or rrow is None:
            win = lrow or rrow
        elif ts(lrow) != ts(rrow):
            win = lrow if ts(lrow) > ts(rrow) else rrow
        else:
            win = lrow if is_authority else rrow
        if win.get("removed") and ts(win) < cutoff:
            continue
        winners[k] = win

    def rebuild(original):
        out, seen = [], set()
        for row in original:
            k = _fav_key(row)
            if k is None:
                out.append(row)
            elif k in winners:
                out.append(winners[k])
                seen.add(k)
        out.extend(winners[k] for k in sorted(winners.keys() - seen))
        return out

    new_local, new_remote = rebuild(local), rebuild(remote)
    return new_local, new_remote, new_local != local, new_remote != remote


class Target(NamedTuple):
    label: str
    local_path: str
    remote_path: str
    merge: Callable
    empty: object  # None: no local file means nothing to sync


TARGETS = [
    Target("library", LOCAL_PATH, REMOTE_PATH, merge, None),
    Target("favorites",
           os.path.expanduser("~/.local/share/sqlch/favorites.json"),
           "~/.local/share/sqlch/favorites.json", merge_favorites, []),
]


def sync_target(host, t, is_authority):
    def load_local():
        if os.path.exists(t.local_path):
            return json.load(open(t.local_path))
        return None if t.empty is None else list(t.empty)

    local = load_local()
    if local is None:
        print(f"sqlch-sync: no local {t.label} yet, nothing to sync")
        return

    try:
        remote = ssh_read(host, t.remote_path, t.empty)
    except Exception as e:
        print(f"sqlch-sync: {host} unreachable ({e}), skipping {t.label}")
        return

    _, _, lc, rc = t.merge(local, remote, is_authority)
    if not (lc or rc):
        print(f"sqlch-sync: {t.label} already in sync")
        return

    wrote_local = wrote_remote = False

    if lc:
        local = load_local()                      # shrink race window
        new_local, _, lc, _ = t.merge(local, remote, is_authority)
        if lc:
            atomic_write(t.local_path, new_local)
            local = new_local
            wrote_local = True

    if rc:
        try:
            remote = ssh_read(host, t.remote_path, t.empty)
            _, new_remote, _, rc = t.merge(local, remote, is_authority)
            if rc:
                ssh_write(host, t.remote_path, new_remote)
                wrote_remote = True
        except Exception as e:
            print(f"sqlch-sync: {host} unreachable during {t.label} write ({e}), skipping")
            return

    if wrote_local and wrote_remote:
        print(f"sqlch-sync: {t.label}: wrote local + remote")
    elif wrote_local:
        print(f"sqlch-sync: {t.label}: wrote local")
    elif wrote_remote:
        print(f"sqlch-sync: {t.label}: wrote remote")
    else:
        print(f"sqlch-sync: {t.label}: nothing to write")


def main():
    remote_host = sys.argv[1] if len(sys.argv) > 1 else None
    is_authority = parse_authority(sys.argv)

    if not remote_host:
        print("sqlch-sync: no remote host given", file=sys.stderr)
        sys.exit(1)

    failed = False
    for t in TARGETS:
        try:
            sync_target(remote_host, t, is_authority)
        except Exception as e:  # one broken file must not block the other target
            print(f"sqlch-sync: {t.label} failed ({e})", file=sys.stderr)
            failed = True
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
