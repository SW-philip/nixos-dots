#!/usr/bin/env python3
"""
embed.py — chunk local docs and store as vectors in sqlite-vec

How it works:
  1. Walk the provided paths (files or directories)
  2. Chunk each doc into overlapping windows
  3. Generate embeddings using llama-cpp's embedding endpoint (no external API)
  4. Store in sqlite-vec for fast cosine similarity search

Why sqlite-vec:
  Your entire corpus is a single .db file. Snapshot it with btrfs.
  Back it up. Move it between machines. Zero infrastructure.
"""

import argparse
import sqlite3
import json
import struct
import hashlib
import sys
import os
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from tqdm import tqdm


# ── Chunking ──────────────────────────────────────────────────────────────────

def chunk_text(text: str, chunk_size: int = 512, overlap: int = 64) -> list[str]:
    """
    Sliding window chunker. Splits on whitespace boundaries.
    overlap keeps context from bleeding off chunk edges.
    """
    words = text.split()
    chunks = []
    i = 0
    while i < len(words):
        chunk = " ".join(words[i:i + chunk_size])
        if chunk.strip():
            chunks.append(chunk)
        i += chunk_size - overlap
    return chunks


def chunk_nix(text: str, max_words: int = 200, overlap_lines: int = 5) -> list[str]:
    """
    Brace-depth-aware chunker for .nix files.
    Flushes at depth-0 boundaries so attribute sets stay whole.
    Falls back to a word-limit flush only when a single block exceeds max_words
    and depth is at a nested boundary (≤1), avoiding mid-block splits.
    """
    lines = text.splitlines(keepends=True)
    chunks: list[str] = []
    current: list[str] = []
    current_words = 0
    depth = 0

    for line in lines:
        # Strip inline comments before counting braces
        code_part = line.split('#', 1)[0]
        depth += code_part.count('{') - code_part.count('}')
        current.append(line)
        current_words += len(line.split())

        at_boundary = depth <= 0
        over_budget = current_words >= max_words and depth <= 1
        hard_limit = current_words >= max_words * 2  # never exceed 2x budget regardless of depth

        if at_boundary or over_budget or hard_limit:
            chunk = ''.join(current).strip()
            if chunk:
                chunks.append(chunk)
            current = current[-overlap_lines:]
            current_words = sum(len(l.split()) for l in current)
            if at_boundary:
                depth = 0  # guard against drift from string interpolation

    if current:
        chunk = ''.join(current).strip()
        if chunk:
            chunks.append(chunk)

    return chunks or [text.strip()]


def chunk_file(text: str, path: Path, chunk_size: int, overlap: int) -> list[str]:
    if path.suffix == ".nix":
        # Nix tokenizes at ~6 tok/word; cap lower to stay under 2048 ctx
        return chunk_nix(text, max_words=min(chunk_size, 150))
    return chunk_text(text, chunk_size, overlap)


def read_file(path: Path) -> str | None:
    """Read a file, skip binaries and anything too large."""
    try:
        if path.stat().st_size > 10 * 1024 * 1024:  # 10MB ceiling
            return None
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return None


INDEXABLE_EXTENSIONS = {
    ".nix", ".md", ".txt", ".py", ".sh", ".toml", ".yaml", ".yml",
    ".json", ".conf", ".cfg", ".ini", ".env", ".fish", ".bash", ".zsh",
    ".html", ".css", ".js", ".ts", ".rs", ".c", ".h",
}


SKIP_DIRS = {".git", "result", "__pycache__", ".cache", ".mozilla", ".pki", "chromium", "BraveSoftware", "secrets"}

# Large data/asset files that add noise without semantic value
SKIP_FILENAMES = {"teamcolors.json", "teamcolors-full.json", "boot_profile.html", "flake.lock", "sqlch.json"}

def collect_files(paths: list[str]) -> list[Path]:
    files = []
    for p in paths:
        path = Path(p).expanduser().resolve()
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            for f in path.rglob("*"):
                if not (f.is_file() and f.suffix in INDEXABLE_EXTENSIONS):
                    continue
                parts = f.parts
                if any(part in SKIP_DIRS for part in parts):
                    continue
                if f.name in SKIP_FILENAMES:
                    continue
                if "/nix/store/" in str(f):
                    continue
                # Skip symlinks that resolve into the nix store (HM-managed dotfiles)
                if f.is_symlink() and "/nix/store/" in str(f.resolve()):
                    continue
                files.append(f)
    return sorted(set(files))


# ── Embedding ─────────────────────────────────────────────────────────────────

def embed_via_server(text: str, url: str) -> list[float]:
    """POST to llama-server /v1/embeddings, return the float vector."""
    import requests
    resp = requests.post(url, json={"input": text, "model": "local"}, timeout=30)
    if not resp.ok:
        raise RuntimeError(f"HTTP {resp.status_code} from embedding server: {resp.text[:200]}")
    return resp.json()["data"][0]["embedding"]


def detect_server_dim(url: str) -> int:
    """Probe the server with a single space to learn the embedding dimension."""
    import requests
    resp = requests.post(url, json={"input": " ", "model": "local"}, timeout=10)
    resp.raise_for_status()
    return len(resp.json()["data"][0]["embedding"])


def server_available(url: str) -> bool:
    import requests
    try:
        resp = requests.post(url, json={"input": " ", "model": "local"}, timeout=5)
        return resp.ok
    except Exception:
        return False


def simple_bow_embed(text: str, dim: int = 384) -> list[float]:
    """
    Bag-of-words fallback embedding when no model is available.
    Not great for semantic search but works for exact/keyword retrieval.
    Deterministic hash-based projection into dim dimensions.
    """
    import math
    vec = [0.0] * dim
    words = text.lower().split()
    for word in words:
        h = int(hashlib.md5(word.encode()).hexdigest(), 16)
        idx = h % dim
        vec[idx] += 1.0
    # L2 normalize
    magnitude = math.sqrt(sum(x * x for x in vec))
    if magnitude > 0:
        vec = [x / magnitude for x in vec]
    return vec


# ── Database ──────────────────────────────────────────────────────────────────

def init_db(conn: sqlite3.Connection, ext_path: str, vector_dim: int):
    conn.enable_load_extension(True)
    conn.load_extension(ext_path.replace(".so", "").replace(".dylib", ""))
    conn.enable_load_extension(False)

    conn.executescript(f"""
        CREATE TABLE IF NOT EXISTS docs (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            source    TEXT NOT NULL,
            chunk_idx INTEGER NOT NULL,
            content   TEXT NOT NULL,
            hash      TEXT NOT NULL,
            UNIQUE (source, chunk_idx)
        );

        CREATE TABLE IF NOT EXISTS store_mappings (
            store_path    TEXT PRIMARY KEY,
            package_name  TEXT,
            source_file   TEXT,
            source_line   INTEGER,
            input_source  TEXT,
            mapped_at     INTEGER,
            flake_rev     TEXT
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS doc_vectors USING vec0(
            id INTEGER PRIMARY KEY,
            embedding FLOAT[{vector_dim}]
        );
    """)
    conn.commit()


def upsert_chunk(
    conn: sqlite3.Connection,
    source: str,
    chunk_idx: int,
    content: str,
    embedding: list[float],
):
    content_hash = hashlib.sha256(content.encode()).hexdigest()[:16]

    # Check if this chunk already exists with the same content
    existing = conn.execute(
        "SELECT id, hash FROM docs WHERE source = ? AND chunk_idx = ?",
        (source, chunk_idx),
    ).fetchone()

    if existing and existing[1] == content_hash:
        return  # unchanged, skip

    if existing:
        doc_id = existing[0]
        conn.execute(
            "UPDATE docs SET content = ?, hash = ? WHERE id = ?",
            (content, content_hash, doc_id),
        )
        packed = struct.pack(f"{len(embedding)}f", *embedding)
        conn.execute(
            "UPDATE doc_vectors SET embedding = ? WHERE id = ?",
            (packed, doc_id),
        )
    else:
        cur = conn.execute(
            "INSERT INTO docs (source, chunk_idx, content, hash) VALUES (?, ?, ?, ?)",
            (source, chunk_idx, content, content_hash),
        )
        doc_id = cur.lastrowid
        packed = struct.pack(f"{len(embedding)}f", *embedding)
        conn.execute(
            "INSERT INTO doc_vectors (id, embedding) VALUES (?, ?)",
            (doc_id, packed),
        )


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Index local docs into sqlite-vec")
    parser.add_argument("--db", required=True, help="Path to vector DB")
    parser.add_argument("--ext", required=True, help="Path to sqlite-vec extension .so")
    parser.add_argument("--paths", nargs="+", required=True, help="Files/dirs to index")
    parser.add_argument("--embed-url", default="http://127.0.0.1:8766/v1/embeddings",
                        help="llama-server embeddings endpoint")
    parser.add_argument("--workers", type=int, default=4,
                        help="Concurrent embedding requests (match server --parallel slots)")
    parser.add_argument("--dim", type=int, default=384, help="BOW fallback dimension")
    parser.add_argument("--chunk-size", type=int, default=200)
    parser.add_argument("--overlap", type=int, default=30)
    args = parser.parse_args()

    files = collect_files(args.paths)
    if not files:
        print("No indexable files found.", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(files)} files to index")

    use_server = server_available(args.embed_url)
    if use_server:
        dim = detect_server_dim(args.embed_url)
        print(f"Using embedding server: {args.embed_url}  (dim={dim})")
    else:
        dim = args.dim
        print(f"Embedding server not reachable at {args.embed_url}")
        print("Falling back to bag-of-words (keyword search only)")
        print("Start myln-embeddings.service for semantic search")

    conn = sqlite3.connect(args.db)
    init_db(conn, args.ext, dim)

    # Build flat list of all (source, chunk_idx, chunk_text) work items
    work = []
    for filepath in files:
        text = read_file(filepath)
        if not text:
            continue
        for i, chunk in enumerate(chunk_file(text, filepath, args.chunk_size, args.overlap)):
            work.append((str(filepath), i, chunk))

    def embed_one(item):
        source, i, chunk = item
        if use_server:
            try:
                return (source, i, chunk, embed_via_server(chunk, args.embed_url))
            except Exception as e:
                tqdm.write(f"  warn: {Path(source).name}[{i}] failed ({e}), using BOW")
                return (source, i, chunk, simple_bow_embed(chunk, dim))
        return (source, i, chunk, simple_bow_embed(chunk, dim))

    total_chunks = 0
    workers = args.workers if use_server else 1
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(embed_one, item): item for item in work}
        for fut in tqdm(as_completed(futures), total=len(work), desc="Indexing"):
            source, i, chunk, embedding = fut.result()
            upsert_chunk(conn, source, i, chunk, embedding)
            total_chunks += 1
            if total_chunks % 100 == 0:
                conn.commit()

    conn.commit()
    conn.close()
    print(f"\nIndexed {total_chunks} chunks from {len(files)} files → {args.db}")


if __name__ == "__main__":
    main()
