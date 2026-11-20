# Changelog

All notable changes to this project will be documented in this file.

## 0.2.0 - 2026-11-20

### Added
- Full Copy-on-Write B-Tree `delete` with in-order predecessor replacement, left/right sibling borrowing, node merging, and root height collapse while keeping historical snapshots immutable.
- Ordered `scanRange` and `scanPrefix` queries with optional limits and inclusive/exclusive upper bounds across live and historical snapshot roots.
- Structural and cryptographic B-Tree verifier (`CowBTree.verify`, `BerylEngine.verify`) checking CRC32 checksums, strict key ordering, ancestor bounds, occupancy, height uniformity, and page-ID consistency.
- Zero-allocation WAL stream inspector (`wal.inspectWal`) and explicit `RecordType.abort` journaling for transaction rollbacks.
- Live CoW page garbage collection and WAL compaction (`BerylEngine.compact` and `BerylEngine.compactWithPinnedSnapshots`) preserving deduplicated shared subtrees across pinned snapshots.
- Atomic file-backed WAL persistence (`BerylEngine.openFile`, `BerylEngine.saveFile`) using fsync and atomic rename.
- Expanded CLI with persistent `--db <path>`, `--json` output mode, and `delete`, `scan`, `stats`, `verify`, `compact`, and multi-phase `bench` subcommands.
- Expanded C-ABI exports: `beryl_begin`, `beryl_get`, `beryl_get_at`, `beryl_delete`, `beryl_checkpoint`, `beryl_compact`, `beryl_verify`, and `beryl_count`.
- Randomized differential model tests, page-budget stress tests, WAL bit-flip/truncation fault-injection tests, file-persistence round-trip tests, and C-ABI lifecycle tests.

### Fixed
- Fixed classic B-Tree leaf split promotion and internal-node in-place key update handling to eliminate duplicate promoted keys and stale reads on updated median keys.
- Aligned `PageHeader` to the documented 32-byte layout, extended page CRC32 to cover header fields plus payload, added `num_keys` bounds validation on deserialization, and added byte-budget-aware page splitting to prevent 4KB page overflows with maximal 64B keys and 192B values.
- Fixed WAL crash recovery to isolate pending operations by `tx_id`, replay deletes, honor aborts, preserve clean WAL prefixes across repeated crash-recovery cycles, avoid integer overflow on corrupted `payload_len` headers, and validate key/value sizes before journaling.

## 0.1.0 - 2026-11-08

### Added
- Initial release of Beryl crash-consistent append-only B-Tree and WAL engine.
- Copy-on-Write (CoW) B-Tree node mutation with historical snapshot persistence.
- Deterministic Write-Ahead Log (WAL) record journaling with CRC32 frame checksums.
- Crash recovery scanner with automatic uncommitted partial transaction rollback.
- Native command-line interface and C-ABI export symbols for external language embedding.
