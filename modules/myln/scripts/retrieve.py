#!/usr/bin/env python3
"""
retrieve.py — query the sqlite-vec store, return top-k context chunks

Called by the 'ask' shell script. Prints context to stdout for injection
into the llama-cpp prompt.

The query is embedded the same way the docs were (BOW or model).
Cosine similarity via sqlite-vec's vec_distance_cosine().
"""

import argparse
import sqlite3
import hashlib
import struct
import math
import sys
import os
from pathlib import Path


def simple_bow_embed(text: str, dim: int = 384) -> list[float]:
    vec = [0.0] * dim
    words = text.lower().split()
    for word in words:
        h = int(hashlib.md5(word.encode()).hexdigest(), 16)
        idx = h % dim
        vec[idx] += 1.0
    magnitude = math.sqrt(sum(x * x for x in vec))
    if magnitude > 0:
        vec = [x / magnitude for x in vec]
    return vec


def embed_via_server(text: str, url: str) -> list[float]:
    """POST to llama-server /v1/embeddings, return the float vector."""
    import requests
    resp = requests.post(url, json={"input": text, "model": "local"}, timeout=30)
    resp.raise_for_status()
    return resp.json()["data"][0]["embedding"]


def get_vector_dim(conn: sqlite3.Connection) -> int:
    """Infer vector dimension from the first stored vector."""
    row = conn.execute("SELECT embedding FROM doc_vectors LIMIT 1").fetchone()
    if not row:
        return 384
    # packed floats: 4 bytes each
    return len(row[0]) // 4


def retrieve(
    db_path: str,
    ext_path: str,
    query: str,
    top_k: int = 5,
    model_path: str | None = None,
) -> list[dict]:
    conn = sqlite3.connect(db_path)
    conn.enable_load_extension(True)
    # sqlite-vec extension path: strip the .so/.dylib since SQLite adds it
    ext = ext_path
    for suffix in [".so", ".dylib", ".dll"]:
        ext = ext.removesuffix(suffix)
    conn.load_extension(ext)
    conn.enable_load_extension(False)

    dim = get_vector_dim(conn)

    use_model = model_path is not None
    if use_model:
        try:
            query_vec = embed_via_server(query, model_path)
        except Exception:
            query_vec = simple_bow_embed(query, dim)
    else:
        query_vec = simple_bow_embed(query, dim)

    # Pad or truncate if dim mismatch (shouldn't happen if embed/retrieve use same settings)
    if len(query_vec) < dim:
        query_vec.extend([0.0] * (dim - len(query_vec)))
    query_vec = query_vec[:dim]

    packed = struct.pack(f"{dim}f", *query_vec)

    rows = conn.execute(
        """
        SELECT
            d.source,
            d.chunk_idx,
            d.content,
            vec_distance_cosine(v.embedding, ?) AS distance
        FROM doc_vectors v
        JOIN docs d ON d.id = v.id
        ORDER BY distance ASC
        LIMIT ?
        """,
        (packed, top_k),
    ).fetchall()

    conn.close()

    return [
        {
            "source": row[0],
            "chunk_idx": row[1],
            "content": row[2],
            "distance": row[3],
        }
        for row in rows
    ]


def format_context(chunks: list[dict], conn: sqlite3.Connection | None = None) -> str:
    parts = []
    for chunk in chunks:
        source = chunk["source"]
        header_lines = []

        if "/nix/store/" in source:
            # Try to inject mapping context if we have a DB connection
            if conn is not None:
                row = conn.execute(
                    "SELECT package_name, source_file, source_line, input_source, confidence "
                    "FROM store_mappings WHERE store_path = ?",
                    (source,)
                ).fetchone()
                if row:
                    pkg, src, line, inp, conf = row
                    header_lines.append(f"[STORE PATH MAPPING — confidence: {conf}]")
                    if pkg:
                        header_lines.append(f"Package: {pkg}")
                    if src:
                        loc = f"{src}:{line}" if line else src
                        header_lines.append(f"Declared in: {loc}")
                    if inp:
                        header_lines.append(f"Flake input: {inp}")

            # Fall back to the short label if no mapping found
            if not header_lines:
                source = "nix-store:" + source.split("/")[-1]

        label = "\n".join(header_lines) if header_lines else f"[{source}]"
        parts.append(f"{label}\n{chunk['content']}")
    return "\n\n---\n\n".join(parts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    parser.add_argument("--ext", required=True)
    parser.add_argument("--query", required=True)
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--embed-url", default=None,
                        help="llama-server embeddings endpoint (omit to use BOW fallback)")
    parser.add_argument("--json", action="store_true", help="Output raw JSON")
    args = parser.parse_args()

    chunks = retrieve(args.db, args.ext, args.query, args.top_k, args.embed_url)

    if not chunks:
        print("(no relevant context found)", file=sys.stderr)
        sys.exit(0)

    if args.json:
        import json
        print(json.dumps(chunks, indent=2))
    else:
        # Open a bare connection (no vec extension needed) just for store mappings
        conn = sqlite3.connect(args.db)
        print(format_context(chunks, conn))
        conn.close()


if __name__ == "__main__":
    main()
