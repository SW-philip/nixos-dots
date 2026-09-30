#!/usr/bin/env python3
"""
map_store.py — map /nix/store derivation paths back to your config source files

How it works:
  1. Extract a store path from a build error (piped in or --path argument)
  2. Run `nix derivation show` to get the derivation graph
  3. Pull the package name from the drv
  4. Search the indexed docs table for config chunks mentioning that package
  5. Write the mapping to store_mappings table for fast future lookups
  6. Print what it found (or didn't)

Paths are only ever mapped when they appear in errors — no need to scan the
whole store. The cache means repeated failures on the same path are instant.

Usage:
  # Pipe a build error in:
  nix build .#nixosConfigurations.mymachine 2>&1 | python map_store.py --db vectors.db --ext vec0.so

  # Direct path:
  python map_store.py --db vectors.db --ext vec0.so --path /nix/store/xxxxx-ghostty-1.0.drv

  # Watch a build live — maps paths as errors appear in real time:
  python map_store.py --db vectors.db --ext vec0.so --watch -- nix build .#nixosConfigurations.mymachine

  # Check flake.lock for changes and invalidate stale mappings:
  python map_store.py --db vectors.db --ext vec0.so --sync-lock /etc/nixos/flake.lock
"""

import argparse
import sqlite3
import subprocess
import json
import re
import sys
import os
import time
import hashlib
from pathlib import Path


# ── DB setup ──────────────────────────────────────────────────────────────────

SCHEMA = """
CREATE TABLE IF NOT EXISTS store_mappings (
    store_path    TEXT PRIMARY KEY,
    package_name  TEXT,
    source_file   TEXT,        -- best match in your indexed config, NULL if unknown
    source_line   INTEGER,     -- line number, NULL if not found
    input_source  TEXT,        -- flake input name (e.g. "ghostty", "nixpkgs")
    confidence    TEXT,        -- "exact", "semantic", "package_only", "unknown"
    mapped_at     INTEGER,     -- unix timestamp
    flake_rev     TEXT         -- flake input rev at time of mapping
);

CREATE TABLE IF NOT EXISTS flake_lock_state (
    input_name    TEXT PRIMARY KEY,
    rev           TEXT NOT NULL,
    last_seen     INTEGER NOT NULL
);
"""


def init_db(conn: sqlite3.Connection, ext_path: str):
    conn.enable_load_extension(True)
    ext = ext_path
    for suffix in [".so", ".dylib", ".dll"]:
        ext = ext.removesuffix(suffix)
    conn.load_extension(ext)
    conn.enable_load_extension(False)
    conn.executescript(SCHEMA)
    conn.commit()


# ── Store path extraction ─────────────────────────────────────────────────────

DRV_RE = re.compile(r"/nix/store/[a-z0-9]{32}-[a-zA-Z0-9._+%-]+-[0-9][^\s\"']*\.drv")
STORE_RE = re.compile(r"/nix/store/[a-z0-9]{32}-[a-zA-Z0-9._+%-]+-[0-9][^\s\"']*")


def extract_store_paths(text: str) -> list[str]:
    """Pull all store/drv paths out of a block of text. Prefer .drv paths."""
    drvs = DRV_RE.findall(text)
    if drvs:
        return list(dict.fromkeys(drvs))  # deduplicated, order preserved
    # Fall back to non-drv store paths if no .drv found
    return list(dict.fromkeys(STORE_RE.findall(text)))


def parse_package_name(store_path: str) -> str | None:
    """
    Extract human-readable package name from a store path.
    /nix/store/xxxx-ghostty-1.0.0.drv  →  ghostty
    /nix/store/xxxx-python3-3.11.9      →  python3
    """
    basename = Path(store_path).name
    # Strip the hash prefix (32 hex chars + dash)
    without_hash = re.sub(r"^[a-z0-9]{32}-", "", basename)
    # Strip .drv suffix
    without_drv = without_hash.removesuffix(".drv")
    # Strip trailing version numbers (e.g. -1.0.0, -20240101)
    name = re.sub(r"-[0-9][a-zA-Z0-9._-]*$", "", without_drv)
    return name or None


# ── Derivation graph query ────────────────────────────────────────────────────

def query_derivation(store_path: str) -> dict | None:
    """
    Run `nix derivation show` and return the parsed JSON.
    Returns None on failure (path not in store, nix not available, etc.)
    """
    try:
        result = subprocess.run(
            ["nix", "derivation", "show", store_path],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode != 0:
            return None
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return None


def extract_input_source(drv_data: dict, store_path: str) -> str | None:
    """
    Try to identify which flake input this derivation came from.
    Looks at env vars and input names in the derivation graph.
    This is best-effort — many derivations won't have a clear attribution.
    """
    if not drv_data:
        return None
    drv = drv_data.get(store_path, {})
    env = drv.get("env", {})

    # Some derivations embed their source input in env vars
    for key in ("src", "pname", "name"):
        val = env.get(key, "")
        if val and "/nix/store/" not in val:
            return val

    return None


# ── Config source search ──────────────────────────────────────────────────────

def search_config_for_package(conn: sqlite3.Connection, package_name: str) -> list[dict]:
    """
    Search the indexed docs for chunks that mention this package name.
    Returns candidates ranked by mention count, excluding nix store paths.
    """
    if not package_name:
        return []

    rows = conn.execute(
        """
        SELECT source, chunk_idx, content
        FROM docs
        WHERE content LIKE ?
          AND source NOT LIKE '/nix/store/%'
        ORDER BY
            -- prefer .nix files
            CASE WHEN source LIKE '%.nix' THEN 0 ELSE 1 END,
            source
        LIMIT 10
        """,
        (f"%{package_name}%",),
    ).fetchall()

    results = []
    for source, chunk_idx, content in rows:
        # Find the line number of the first mention within this chunk
        line_num = find_line_in_file(source, package_name)
        results.append({
            "source": source,
            "chunk_idx": chunk_idx,
            "content": content,
            "line": line_num,
        })
    return results


def find_line_in_file(filepath: str, term: str) -> int | None:
    """Scan the actual file for the first line containing term. Returns 1-indexed line."""
    try:
        with open(filepath, "r", errors="ignore") as f:
            for i, line in enumerate(f, 1):
                if term in line:
                    return i
    except OSError:
        pass
    return None


# ── flake.lock sync ───────────────────────────────────────────────────────────

def load_flake_lock(lock_path: str) -> dict:
    with open(lock_path) as f:
        return json.load(f)


def get_input_revs(lock: dict) -> dict[str, str]:
    """Extract {input_name: rev} from flake.lock nodes."""
    revs = {}
    nodes = lock.get("nodes", {})
    for name, node in nodes.items():
        if name == "root":
            continue
        locked = node.get("locked", {})
        rev = locked.get("rev") or locked.get("narHash")
        if rev:
            revs[name] = rev
    return revs


def sync_flake_lock(conn: sqlite3.Connection, lock_path: str) -> list[str]:
    """
    Compare current flake.lock against stored state.
    Invalidate store_mappings for any inputs that changed.
    Returns list of invalidated input names.
    """
    lock = load_flake_lock(lock_path)
    current_revs = get_input_revs(lock)
    now = int(time.time())

    invalidated = []
    for input_name, rev in current_revs.items():
        existing = conn.execute(
            "SELECT rev FROM flake_lock_state WHERE input_name = ?",
            (input_name,)
        ).fetchone()

        if existing is None:
            # First time seeing this input — just record it
            conn.execute(
                "INSERT INTO flake_lock_state (input_name, rev, last_seen) VALUES (?, ?, ?)",
                (input_name, rev, now)
            )
        elif existing[0] != rev:
            # Rev changed — invalidate mappings for this input
            deleted = conn.execute(
                "DELETE FROM store_mappings WHERE input_source = ?",
                (input_name,)
            ).rowcount
            conn.execute(
                "UPDATE flake_lock_state SET rev = ?, last_seen = ? WHERE input_name = ?",
                (rev, now, input_name)
            )
            invalidated.append(input_name)
            if deleted:
                print(f"  invalidated {deleted} mapping(s) for {input_name} (rev changed)")

    conn.commit()
    return invalidated


# ── Mapping ───────────────────────────────────────────────────────────────────

def map_store_path(conn: sqlite3.Connection, store_path: str, verbose: bool = False) -> dict:
    """
    Core mapping logic for a single store path.
    Returns the mapping result dict.
    """
    # Check cache first
    cached = conn.execute(
        "SELECT package_name, source_file, source_line, input_source, confidence FROM store_mappings WHERE store_path = ?",
        (store_path,)
    ).fetchone()

    if cached:
        pkg, src, line, inp, conf = cached
        if verbose:
            print(f"  [cached] {store_path}")
            print(f"    package:    {pkg}")
            print(f"    source:     {src}:{line}" if line else f"    source:     {src}")
            print(f"    input:      {inp}")
            print(f"    confidence: {conf}")
        return {"store_path": store_path, "package_name": pkg,
                "source_file": src, "source_line": line,
                "input_source": inp, "confidence": conf, "cached": True}

    # Not cached — do the work
    package_name = parse_package_name(store_path)
    drv_data = None
    input_source = None
    flake_rev = None

    if store_path.endswith(".drv"):
        drv_data = query_derivation(store_path)
        input_source = extract_input_source(drv_data, store_path)

    # Search config for this package name
    candidates = search_config_for_package(conn, package_name) if package_name else []

    source_file = None
    source_line = None
    confidence = "unknown"

    if candidates:
        best = candidates[0]
        source_file = best["source"]
        source_line = best["line"]
        # If the package name appears directly as an attribute (e.g. `ghostty` on its own line)
        # call it exact, otherwise semantic
        confidence = "exact" if source_line else "semantic"
    elif package_name:
        confidence = "package_only"

    now = int(time.time())
    conn.execute(
        """
        INSERT OR REPLACE INTO store_mappings
            (store_path, package_name, source_file, source_line, input_source,
             confidence, mapped_at, flake_rev)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (store_path, package_name, source_file, source_line,
         input_source, confidence, now, flake_rev)
    )
    conn.commit()

    result = {
        "store_path": store_path,
        "package_name": package_name,
        "source_file": source_file,
        "source_line": source_line,
        "input_source": input_source,
        "confidence": confidence,
        "cached": False,
    }

    if verbose:
        print(f"  {store_path}")
        print(f"    package:    {package_name or '(unknown)'}")
        print(f"    source:     {source_file}:{source_line}" if source_line else f"    source:     {source_file or '(not found)'}")
        print(f"    input:      {input_source or '(unknown)'}")
        print(f"    confidence: {confidence}")

    return result


def format_mapping_context(conn: sqlite3.Connection, store_path: str) -> str | None:
    """
    Called by retrieve.py to inject mapping context into a prompt.
    Returns a formatted string block, or None if no mapping exists.
    """
    row = conn.execute(
        "SELECT package_name, source_file, source_line, input_source, confidence FROM store_mappings WHERE store_path = ?",
        (store_path,)
    ).fetchone()

    if not row:
        return None

    pkg, src, line, inp, conf = row
    parts = [f"[STORE PATH MAPPING — confidence: {conf}]"]
    if pkg:
        parts.append(f"Package: {pkg}")
    if src:
        loc = f"{src}:{line}" if line else src
        parts.append(f"Declared in: {loc}")
    if inp:
        parts.append(f"Flake input: {inp}")
    return "\n".join(parts)


# ── Watch mode ───────────────────────────────────────────────────────────────

def watch_build(conn: sqlite3.Connection, cmd: list[str], verbose: bool = False) -> int:
    """
    Run `cmd`, stream its stderr to the terminal, and map any store paths that
    appear in error lines on the fly. Returns the process exit code.

    Only lines that look like errors (contain a store path alongside typical
    error keywords) trigger a mapping — normal build progress lines are passed
    through untouched.
    """
    ERROR_HINTS = re.compile(
        r"\b(error|failed|cannot|undefined|missing|conflict|collision)\b", re.IGNORECASE
    )

    mapped_this_run: set[str] = set()

    proc = subprocess.Popen(
        cmd,
        stderr=subprocess.PIPE,
        stdout=sys.stdout,  # let stdout (progress bars etc.) flow through
        text=True,
        bufsize=1,
    )

    print(f"[map_store] watching: {' '.join(cmd)}", file=sys.stderr)

    for line in proc.stderr:
        sys.stderr.write(line)  # always pass through

        paths = extract_store_paths(line)
        if not paths:
            continue

        # Only map if the line looks like it carries an error
        if not ERROR_HINTS.search(line):
            continue

        for path in paths:
            if path in mapped_this_run:
                continue  # already handled this session
            mapped_this_run.add(path)

            print(f"\n[map_store] mapping error path: {path}", file=sys.stderr)
            map_store_path(conn, path, verbose=verbose)

    proc.wait()

    if mapped_this_run:
        print(
            f"\n[map_store] mapped {len(mapped_this_run)} path(s) this run. "
            f"Re-run with --path to re-inspect any of them.",
            file=sys.stderr,
        )
    else:
        print("[map_store] build finished, no error paths found.", file=sys.stderr)

    return proc.returncode


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Map nix store paths that appear in build errors to config source files"
    )
    parser.add_argument("--db", required=True, help="Path to vectors.db")
    parser.add_argument("--ext", required=True, help="Path to sqlite-vec extension")
    parser.add_argument("--path", help="A single /nix/store/... path to map")
    parser.add_argument(
        "--watch", action="store_true",
        help="Run the command after -- and map any store paths that appear in errors"
    )
    parser.add_argument("--sync-lock", metavar="FLAKE_LOCK",
                        help="Path to flake.lock — sync state and invalidate stale mappings")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    parser.add_argument("--verbose", "-v", action="store_true")
    # Everything after -- is the build command for --watch
    args, remainder = parser.parse_known_args()

    conn = sqlite3.connect(args.db)
    init_db(conn, args.ext)

    results = []

    # flake.lock sync (can combine with other modes)
    if args.sync_lock:
        print(f"Syncing flake.lock: {args.sync_lock}")
        invalidated = sync_flake_lock(conn, args.sync_lock)
        if not invalidated:
            print("  No changes detected.")
        else:
            print(f"  Invalidated inputs: {', '.join(invalidated)}")

    # --watch: run a build command and map error paths live
    if args.watch:
        if not remainder:
            parser.error("--watch requires a build command after --, e.g.: --watch -- nix build .#")
        # Strip a leading '--' separator if present
        cmd = remainder[1:] if remainder[0] == "--" else remainder
        exit_code = watch_build(conn, cmd, verbose=args.verbose)
        conn.close()
        sys.exit(exit_code)

    # --path: map a single path directly
    if args.path:
        result = map_store_path(conn, args.path, verbose=args.verbose)
        results.append(result)

    # Stdin pipe: extract paths from build error text
    elif not args.sync_lock and not sys.stdin.isatty():
        text = sys.stdin.read()
        paths = extract_store_paths(text)
        if not paths:
            print("No store paths found in input.", file=sys.stderr)
            sys.exit(1)
        print(f"Found {len(paths)} store path(s):")
        for p in paths:
            result = map_store_path(conn, p, verbose=True)
            results.append(result)

    conn.close()

    if args.json and results:
        print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
