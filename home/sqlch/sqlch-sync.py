#!/usr/bin/env python3
"""Authority-aware union-merge of sqlch's library.json between this host and
one remote host over ssh.

Stations are keyed by sqlch's own "id" field. A station on only one side is
appended, unmodified, to the other side -- so a new station added on either
host propagates. A station present on BOTH sides with differing contents
converges to the AUTHORITATIVE host's copy (surface); play-tracking fields
(last_played, play_count) are merged by max, never a reason to overwrite on
their own. Nothing is ever deleted, so removing a station means removing it
on both hosts.

Usage:  sqlch-sync <remote-host> [<is-authority: 1|0>]
"""
import json
import os
import subprocess
import sys

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


def ssh_read(host, path):
    p = subprocess.run(
        ["ssh", *SSH_OPTS, host, f"cat {path}"],
        capture_output=True, timeout=15,
    )
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


def main():
    remote_host = sys.argv[1] if len(sys.argv) > 1 else None
    is_authority = parse_authority(sys.argv)

    if not remote_host:
        print("sqlch-sync: no remote host given", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(LOCAL_PATH):
        print("sqlch-sync: no local library yet, nothing to sync")
        return

    local = json.load(open(LOCAL_PATH))

    try:
        remote = ssh_read(remote_host, REMOTE_PATH)
    except Exception as e:
        print(f"sqlch-sync: {remote_host} unreachable ({e}), skipping")
        return

    _, _, lc, rc = merge(local, remote, is_authority)
    if not (lc or rc):
        print("sqlch-sync: already in sync")
        return

    wrote_local = False
    wrote_remote = False

    if lc:
        local = json.load(open(LOCAL_PATH))       # shrink race window
        new_local, _, lc, _ = merge(local, remote, is_authority)
        if lc:
            atomic_write(LOCAL_PATH, new_local)
            local = new_local
            wrote_local = True

    if rc:
        try:
            remote = ssh_read(remote_host, REMOTE_PATH)
            _, new_remote, _, rc = merge(local, remote, is_authority)
            if rc:
                ssh_write(remote_host, REMOTE_PATH, new_remote)
                wrote_remote = True
        except Exception as e:
            print(f"sqlch-sync: {remote_host} unreachable during write ({e}), skipping")
            return

    if wrote_local and wrote_remote:
        print("sqlch-sync: wrote local + remote")
    elif wrote_local:
        print("sqlch-sync: wrote local")
    elif wrote_remote:
        print("sqlch-sync: wrote remote")
    else:
        print("sqlch-sync: nothing to write")


if __name__ == "__main__":
    main()
