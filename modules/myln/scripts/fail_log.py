#!/usr/bin/env python3
"""
fail_log.py — NixOS build failure logger

Three modes:
  --log      Write a failure record (called by nrs wrapper on non-zero exit)
  --resolve  Mark open failures resolved (called by nrs wrapper on clean build)
  --query    Semantic search over past failures
"""

import argparse
import datetime
import hashlib
import math
import sqlite3
import struct
import subprocess
import sys
import time
from pathlib import Path


FAILURES_SCHEMA = """
CREATE TABLE IF NOT EXISTS failures (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp         INTEGER NOT NULL,
    build_target      TEXT NOT NULL,
    exit_code         INTEGER NOT NULL,
    stderr_raw        TEXT NOT NULL,
    top_error_lines   TEXT,
    config_context    TEXT,
    failure_commit    TEXT,
    resolution_diff   TEXT,
    resolution_commit TEXT,
    resolved_at       INTEGER
);
"""


def simple_bow_embed(text: str, dim: int = 384) -> list[float]:
    vec = [0.0] * dim
    for word in text.lower().split():
        h = int(hashlib.md5(word.encode()).hexdigest(), 16)
        vec[h % dim] += 1.0
    mag = math.sqrt(sum(x * x for x in vec))
    if mag > 0:
        vec = [x / mag for x in vec]
    return vec


def embed_via_server(text: str, url: str) -> list[float]:
    import requests
    resp = requests.post(url, json={"input": text, "model": "local"}, timeout=30)
    resp.raise_for_status()
    data = resp.json()["data"][0]["embedding"]
    if not isinstance(data, list) or len(data) < 2:
        raise ValueError(f"Bad embedding shape: {str(data)[:80]}")
    return data


def get_embed(text: str, dim: int, embed_url: str | None) -> list[float]:
    try:
        if embed_url:
            vec = embed_via_server(text, embed_url)
        else:
            raise RuntimeError("no server")
    except Exception:
        vec = simple_bow_embed(text, dim)
    if len(vec) < dim:
        vec.extend([0.0] * (dim - len(vec)))
    return vec[:dim]


def init_db(conn: sqlite3.Connection, ext_path: str) -> int:
    conn.enable_load_extension(True)
    ext = ext_path
    for suffix in [".so", ".dylib", ".dll"]:
        ext = ext.removesuffix(suffix)
    conn.load_extension(ext)
    conn.enable_load_extension(False)

    conn.executescript(FAILURES_SCHEMA)
    conn.commit()

    # Infer dim from doc_vectors (embed must run before fail_log touches the DB)
    row = conn.execute("SELECT embedding FROM doc_vectors LIMIT 1").fetchone()
    dim = len(row[0]) // 4 if row else 384

    conn.executescript(f"""
        CREATE VIRTUAL TABLE IF NOT EXISTS failure_vectors USING vec0(
            id INTEGER PRIMARY KEY,
            embedding FLOAT[{dim}]
        );
    """)
    conn.commit()
    return dim


def extract_top_error_lines(text: str, max_lines: int = 10) -> str:
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    hits = [
        l for l in lines
        if any(kw in l.lower() for kw in ("error:", "failed", "error[", "cannot"))
        and not l.startswith(("│", "╭", "╰", "✔", "✖"))
    ]
    if not hits:
        hits = lines
    return "\n".join(hits[:max_lines])


def current_commit(git_dir: str) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", git_dir, "rev-parse", "HEAD"], text=True
        ).strip()
    except Exception:
        return ""


def do_log(args: argparse.Namespace, conn: sqlite3.Connection, dim: int) -> None:
    stderr_raw = Path(args.stderr_file).read_text(errors="replace")
    top_error_lines = extract_top_error_lines(stderr_raw)

    config_context = ""
    if args.config_context_file and Path(args.config_context_file).exists():
        config_context = Path(args.config_context_file).read_text(errors="replace")

    failure_commit = args.failure_commit or current_commit(args.git_dir)

    embed_text = top_error_lines or stderr_raw[:500]
    vec = get_embed(embed_text, dim, args.embed_url)
    packed = struct.pack(f"{dim}f", *vec)

    cur = conn.execute(
        """INSERT INTO failures
           (timestamp, build_target, exit_code, stderr_raw,
            top_error_lines, config_context, failure_commit)
           VALUES (?, ?, ?, ?, ?, ?, ?)""",
        (int(time.time()), args.target, args.exit_code,
         stderr_raw, top_error_lines, config_context, failure_commit),
    )
    failure_id = cur.lastrowid
    conn.execute(
        "INSERT INTO failure_vectors (id, embedding) VALUES (?, ?)",
        (failure_id, packed),
    )
    conn.commit()

    # Print nearest past failure for context
    rows = conn.execute(
        """
        SELECT f.timestamp, f.top_error_lines, f.resolved_at, f.resolution_diff,
               vec_distance_cosine(v.embedding, ?) AS dist
        FROM failure_vectors v
        JOIN failures f ON f.id = v.id
        WHERE f.id != ?
        ORDER BY dist ASC
        LIMIT 1
        """,
        (packed, failure_id),
    ).fetchall()

    if config_context:
        print(f"\n── Relevant config context ──")
        print(config_context[:800])

    if rows:
        ts, top_lines, resolved_at, rdiff, dist = rows[0]
        when = datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")
        status = "resolved" if resolved_at else "UNRESOLVED"
        print(f"\n── Nearest past failure  dist={dist:.3f}  {when}  [{status}] ──")
        if top_lines:
            print(top_lines[:300])
        if rdiff:
            print(f"\n── Resolution diff ──\n{rdiff[:800]}")

    print(f"\nLogged failure #{failure_id}", file=sys.stderr)


def do_resolve(args: argparse.Namespace, conn: sqlite3.Connection) -> None:
    resolution_commit = args.resolution_commit or current_commit(args.git_dir)

    open_failures = conn.execute(
        "SELECT id, failure_commit FROM failures WHERE build_target = ? AND resolved_at IS NULL",
        (args.target,),
    ).fetchall()

    if not open_failures:
        return

    for fid, fc in open_failures:
        diff = ""
        if fc and resolution_commit:
            try:
                diff = subprocess.check_output(
                    ["git", "-C", args.git_dir, "diff", fc, resolution_commit],
                    text=True,
                )
            except Exception as e:
                diff = f"(diff failed: {e})"
        conn.execute(
            """UPDATE failures
               SET resolution_diff = ?, resolution_commit = ?, resolved_at = ?
               WHERE id = ?""",
            (diff, resolution_commit, int(time.time()), fid),
        )

    conn.commit()
    print(f"Resolved {len(open_failures)} failure(s) for {args.target}", file=sys.stderr)


def do_query(args: argparse.Namespace, conn: sqlite3.Connection, dim: int) -> None:
    vec = get_embed(args.query, dim, args.embed_url)
    packed = struct.pack(f"{dim}f", *vec)

    rows = conn.execute(
        """
        SELECT f.id, f.timestamp, f.top_error_lines,
               f.resolved_at, f.resolution_diff,
               vec_distance_cosine(v.embedding, ?) AS dist
        FROM failure_vectors v
        JOIN failures f ON f.id = v.id
        ORDER BY dist ASC
        LIMIT ?
        """,
        (packed, args.top_k),
    ).fetchall()

    if not rows:
        print("No past failures found.")
        return

    for fid, ts, top_lines, resolved_at, rdiff, dist in rows:
        when = datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")
        status = "resolved" if resolved_at else "open"
        print(f"\n── Failure #{fid}  dist={dist:.3f}  [{status}]  {when} ──")
        if top_lines:
            print(top_lines[:400])
        if rdiff:
            print(f"\n── Resolution diff ──\n{rdiff[:1200]}")


def main() -> None:
    p = argparse.ArgumentParser(description="myln build failure logger")
    p.add_argument("--db", required=True)
    p.add_argument("--ext", required=True)
    p.add_argument("--embed-url", default=None)
    p.add_argument("--target", default="nixosConfigurations.desktop")
    p.add_argument("--git-dir", default="/home/prepko/nixos")

    # log mode
    p.add_argument("--log", action="store_true")
    p.add_argument("--stderr-file")
    p.add_argument("--exit-code", type=int, default=1)
    p.add_argument("--failure-commit", default=None)
    p.add_argument("--config-context-file", default=None)

    # resolve mode
    p.add_argument("--resolve", action="store_true")
    p.add_argument("--resolution-commit", default=None)

    # query mode
    p.add_argument("--query", default=None)
    p.add_argument("--top-k", type=int, default=3)

    args = p.parse_args()

    conn = sqlite3.connect(args.db)
    dim = init_db(conn, args.ext)

    if args.log:
        if not args.stderr_file:
            p.error("--log requires --stderr-file")
        do_log(args, conn, dim)
    elif args.resolve:
        do_resolve(args, conn)
    elif args.query:
        do_query(args, conn, dim)
    else:
        p.print_help()
        sys.exit(1)

    conn.close()


if __name__ == "__main__":
    main()
