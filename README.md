# Beryl

Crash-Consistent Append-Only B-Tree & WAL Engine

A high-performance embedded key-value storage engine built on an immutable Copy-on-Write (CoW) B-Tree and a deterministic Write-Ahead Log (WAL), written in Zig.

## Architecture

- Purely Persistent CoW B-Tree: Every page mutation creates a new versioned node. Root pointers advance monotonically, ensuring historic snapshots remain readable without locking.
- Deterministic WAL Journal: Every mutation is journaled with length-prefixed records and CRC32 checksums before committing to the tree.
- Crash-Consistent Recovery: On initialization, Beryl scans the WAL, verifies record integrity, replays all committed transactions, and discards partial in-flight writes.
- Predictable Allocation: Backed by arena allocators and fixed-size 4096-byte pages, matching native hardware virtual memory page boundaries.
- C-ABI Dynamic Library: Exposes standard shared library symbols for embedding in C, Rust, Python, and Go environments without external SQLite or RocksDB dependencies.

## Data Model & Page Layout

```
+-------------------------------------------------------------+
| Page Header (32 bytes)                                      |
| Magic (4B) | PageId (4B) | Generation (8B) | NumKeys (2B)   |
| IsLeaf (1B)| Reserved (9B)| CRC32 Checksum (4B)             |
+-------------------------------------------------------------+
| Ordered Key-Value Slots (up to 16 keys per 4KB node)        |
+-------------------------------------------------------------+
| Child Page Pointers (Internal nodes only: num_keys + 1)     |
+-------------------------------------------------------------+
```

## CLI Usage

```bash
# Run CoW B-Tree benchmark
beryl bench 1000

# Put key-value pair and commit
beryl put config:cluster_id eu-west-01

# Retrieve value
beryl get config:cluster_id
```

## C-ABI Interface

```c
void* beryl_create(void);
void beryl_destroy(void* handle);
int32_t beryl_put(void* handle, const uint8_t* key, size_t key_len, const uint8_t* val, size_t val_len);
uint32_t beryl_commit(void* handle);
void beryl_rollback(void* handle);
```

## Building and Testing

```bash
# Run unit tests
zig build test

# Build native binary and shared library
zig build -Doptimize=ReleaseFast
```

## License

MIT License - Copyright (c) 2026 Jeong Hoon Kim
