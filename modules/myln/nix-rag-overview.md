# NixOS Config RAG System

A local retrieval-augmented generation setup that lets you query your NixOS config files and get answers grounded in your actual configuration — no cloud, no external APIs required.

## Concept

Three scripts, one SQLite database, one llama-cpp server:

```
your config files  →  embed.py  →  vectors.db
build errors       →  map_store.py  →  vectors.db
query              →  retrieve.py  →  context for LLM prompt
nrs wrapper        →  fail_log.py  →  vectors.db
```

Everything lives in `vectors.db`. Back it up, snapshot it with btrfs, move it between machines.

## Scripts

### `embed.py`
Walks your config directories, chunks each file, and stores embeddings in `sqlite-vec`. Has a brace-depth-aware chunker for `.nix` files so attribute sets don't get split mid-block. Falls back to bag-of-words if the embedding server isn't running (keyword search still works, just not semantic).

### `map_store.py`
Maps `/nix/store/` derivation paths back to the config file that declared them. Only runs when a path appears in a build error — lazy, cache-on-failure. Uses `nix derivation show` to inspect the drv, then searches the indexed docs for the package name.

Also handles `flake.lock` sync: detects when an input's rev changes and invalidates stale mappings for that input.

### `retrieve.py`
Embeds a query the same way the docs were, runs cosine similarity search via `sqlite-vec`, and prints context chunks for injection into an LLM prompt. For any chunk sourced from the nix store, it checks `store_mappings` and prepends the mapping (package name, source file, flake input, confidence) so the LLM knows where the path came from.

### `fail_log.py`
Post-mortem failure logger. Called by the `nrs` wrapper on non-zero exit. Stores the full stderr, embeds the top error lines, snapshots the current retrieve.py context, and records the git commit at time of failure. On the next clean build for the same target, the wrapper calls `fail_log.py --resolve` which grabs `git diff <failure_commit> <clean_commit>` and writes it back to the failure record.

Query mode prints the nearest past failure and its resolution diff:
```bash
python fail_log.py --db vectors.db --ext vec0.so --query "$(cat ${cfg.storePath}/last-stderr)"
```

`last-stderr` lives in `cfg.storePath` (not `/tmp`) — survives reboots and impermanence.

## Database Schema

```sql
docs              -- raw chunk text, source path, chunk index, content hash
doc_vectors       -- vec0 virtual table, one float[] per chunk (same id as docs)
store_mappings    -- store path → package name, source file, line, flake input
flake_lock_state  -- last-seen rev per flake input, for invalidation

failures (
  id,
  timestamp,
  build_target,       -- nixosConfigurations.SWphil (keep column, scope later)
  exit_code,
  stderr_raw,         -- full dump, no trimming
  top_error_lines,    -- what got embedded (documents what the vector represents)
  config_context,     -- retrieve.py snapshot at failure time
  failure_commit,     -- git sha at time of failure
  resolution_diff,    -- git diff from failure_commit to resolution_commit
  resolution_commit,  -- first clean build sha after this failure
  resolved_at         -- timestamp of clean build
)
failure_vectors   -- vec0 virtual table, embedding of top_error_lines (same id as failures)
```

The `config_context` snapshot is intentional: your config changes. Storing what retrieve.py returned *at failure time* lets you reconstruct what the config looked like when it broke, without needing btrfs snapshots of the whole tree.

## Dependencies

- `sqlite-vec` extension (`.so` / `.dylib`) — path will be a nix store hash; resolve at runtime or pin in a derivation
- `llama-cpp` running a local embedding model on `http://127.0.0.1:8766/v1/embeddings`
- `requests`, `tqdm` (Python)
- `nix` CLI (for `nix derivation show` in `map_store.py`)
- `git` CLI (for diff capture in `fail_log.py`)

## Typical Workflow

```bash
# 1. Index your config
python embed.py --db vectors.db --ext vec0.so --paths ~/nixos ~/.config

# 2. Build via nrs wrapper (handles logging automatically on failure)
nrs  # alias wraps nix build .#nixosConfigurations.SWphil

# 3. Query config
python retrieve.py --db vectors.db --ext vec0.so --query "how is ghostty configured" --embed-url http://127.0.0.1:8766/v1/embeddings

# 4. Query past failures
python fail_log.py --db vectors.db --ext vec0.so --query "$(cat /var/lib/myln/last-stderr)"

# 5. Re-sync after flake update
python map_store.py --db vectors.db --ext vec0.so --sync-lock /etc/nixos/flake.lock
```

## Key Design Decisions

- **Lazy store mapping** — paths are only mapped when they appear in errors. No need to scan the whole store.
- **Cache-on-failure** — repeated failures on the same path are instant lookups.
- **Incremental re-indexing** — `embed.py` hashes each file against the stored `content_hash` and rechunks only dirty files. Clean files are skipped entirely.
- **Two-stage store resolution** — if `map_store.py` returns multiple candidates for a path, a second pass filters by `flake_input` (encoded in the drv) to narrow the field, then ranks survivors by cosine similarity against the derivation context. Top-1 by confidence wins.
- **BOW fallback** — the system degrades gracefully if the embedding server isn't running. You lose semantic search but keyword retrieval still works.
- **Single-file DB** — `sqlite-vec` keeps everything in one portable file. No vector DB infrastructure.
- **Nix-aware chunking** — `.nix` files are chunked at brace-depth boundaries, not arbitrary word counts, so attribute sets stay coherent in retrieval.
- **Post-mortem only** — the `nrs` failure hook runs after exit, not during. No buffering race with Nix's output. The build runs exactly as always; the wrapper only does work when it's done.
- **State machine resolution** — fail → clean build for same target → diff captured automatically. No manual steps on the happy path.
- **build_target scoped to SWphil for now** — column exists for future expansion to SWsurface, costs nothing to carry.

## Integration Points

### 1. Diagnosis context injection

`myln-diagnose` currently sends raw journal errors to the LLM with no config context. Before building the diagnosis prompt, it should run `retrieve.py` using the top error lines as queries and prepend the returned chunks. The LLM then reasons against actual config, not just error strings in a vacuum.

```
errors-raw-$DATE.txt
  → top-N error lines as queries
  → retrieve.py → config chunks
  → prompt: chunks + errors + "analyze this"
  → llama-completion → report-$DATE.md
```

The context injection happens between harvest and the LLM pass. `myln-harvest` is unchanged; `myln-diagnose` gains a retrieve step.

### 2. nrs failure hook

The `nrs` alias becomes a wrapper. The build runs normally, stderr captured via `tee` to a tempfile so output still displays in real time. On non-zero exit:

1. Call `fail_log.py --log` with the tempfile, current git sha, and build target
2. `fail_log.py` embeds top error lines, runs `retrieve.py` to snapshot config context, writes the failure record
3. Query `failure_vectors` for nearest past failure and print: when it happened, what broke, what the resolution diff was
4. Exit

On the next clean build:

1. `fail_log.py --resolve` finds **all** unresolved failures for `SWphil`
2. For each: captures `git diff <failure_commit> HEAD` independently
3. Writes `resolution_diff`, `resolution_commit`, `resolved_at` per record

Each failure gets its own diff from its own commit, so a sequence of A→B→clean doesn't collapse A's resolution into B's diff.

A clean `nrs` with no prior unresolved failure is untouched — no overhead on the happy path.

### 3. Known gaps

- `nix derivation show` may fail for eval errors and type mismatches (drv was never written). Store mapping is a no-op for this class; `retrieve.py` still runs against the raw error message.
- Embedding server partial failure (up but returning malformed output) should be caught with a shape check on the embedding response before committing to the DB.
