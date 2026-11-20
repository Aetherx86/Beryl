# Beryl

Crash-Consistent Append-Only B-Tree & WAL Engine

A high-performance embedded key-value storage engine built on an immutable Copy-on-Write (CoW) B-Tree and a deterministic Write-Ahead Log (WAL), written in Zig.

## Architecture

- Purely Persistent CoW B-Tree: Every insert, update, and rebalancing delete creates new versioned 4096-byte pages with binary-search lookup and byte-budget-aware splitting. Historical root snapshots remain immutable and lock-free readable.
- Ordered Range & Prefix Scans: Supports lexicographical range queries (`[start, end)` / `[start, end]`) with optional limits and prefix scans over live state or any historical snapshot root.
- Deterministic WAL Journal: Mutations (`put`, `delete`), transaction boundaries (`commit`, `abort`), and `checkpoint` markers are framed with length prefixes and CRC32 checksums covering header and payload.
- Crash-Consistent Recovery & Integrity Verification: `recoverFromWal` groups operations by transaction ID, replays committed writes and deletes, discards aborted or partial in-flight transactions, and strips torn tail records. `verify` validates both WAL CRC32 framing and B-Tree ordering, balance, height, and page-header checksum invariants.
- Live Compaction & Snapshot GC: `compact` and `compactWithPinnedSnapshots` reclaim unreachable CoW pages while preserving shared subtrees across pinned snapshots, and rewrite the WAL to a minimal live checkpoint.
- Atomic File Persistence & C-ABI Library: Persists WAL files via `fsync` + atomic rename and exposes a C-ABI shared library (`libberyl`) for embedding in C, Rust, Python, and Go.

## Data Model & Page Layout

```
+-------------------------------------------------------------+
| Page Header (32 bytes, CRC32 covers header + payload)       |
| Magic (4B) | PageId (4B) | Generation (8B) | NumKeys (2B)   |
| IsLeaf (1B)| Reserved (9B)| CRC32 Checksum (4B)             |
+-------------------------------------------------------------+
| Ordered Key-Value Slots (up to 16 keys per 4KB node)        |
+-------------------------------------------------------------+
| Child Page Pointers (Internal nodes only: num_keys + 1)     |
+-------------------------------------------------------------+
```

## CLI Usage

All stateful commands persist to `beryl.wal` by default (override with `--db <path>`) and support `--json` for structured output.

```bash
# Put key-value pairs and commit
beryl put --db store.wal config:cluster_id eu-west-01
beryl put --db store.wal config:replicas 3

# Retrieve value
beryl get --db store.wal config:cluster_id

# Ordered prefix or range scans
beryl scan --db store.wal --prefix config:
beryl scan --db store.wal --start config:a --end config:z --limit 10 --json

# Delete key
beryl delete --db store.wal config:replicas

# Inspect stats, verify integrity, and compact dead pages / WAL history
beryl stats --db store.wal --json
beryl verify --db store.wal
beryl compact --db store.wal

# Run CoW B-Tree + WAL benchmark (put, get, scan, recovery, delete, compact)
beryl bench 1000
beryl bench 1000 --json
```

## C-ABI Interface

```c
void*    beryl_create(void);
void     beryl_destroy(void* handle);
uint64_t beryl_begin(void* handle);
int32_t  beryl_put(void* handle, const uint8_t* key, size_t key_len, const uint8_t* val, size_t val_len);
int32_t  beryl_get(void* handle, const uint8_t* key, size_t key_len, uint8_t* out_buf, size_t out_cap, size_t* out_len);
int32_t  beryl_get_at(void* handle, uint32_t root_id, const uint8_t* key, size_t key_len, uint8_t* out_buf, size_t out_cap, size_t* out_len);
int32_t  beryl_delete(void* handle, const uint8_t* key, size_t key_len);
uint32_t beryl_commit(void* handle);
void     beryl_rollback(void* handle);
int32_t  beryl_checkpoint(void* handle);
int32_t  beryl_compact(void* handle);
int32_t  beryl_verify(void* handle);
size_t   beryl_count(void* handle);
```

## Building and Testing

```bash
# Run unit and differential property tests
zig build test

# Build native binary and shared library
zig build -Doptimize=ReleaseFast
```

## License

MIT License - Copyright (c) 2026 Jeong Hoon Kim
