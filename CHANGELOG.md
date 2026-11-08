# Changelog

All notable changes to this project will be documented in this file.

## 0.1.0 - 2026-11-08

### Added
- Initial release of Beryl crash-consistent append-only B-Tree and WAL engine.
- Copy-on-Write (CoW) B-Tree node mutation with historical snapshot persistence.
- Deterministic Write-Ahead Log (WAL) record journaling with CRC32 frame checksums.
- Crash recovery scanner with automatic uncommitted partial transaction rollback.
- Native command-line interface and C-ABI export symbols for external language embedding.
