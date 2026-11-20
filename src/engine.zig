const std = @import("std");
pub const wal = @import("wal.zig");
pub const btree = @import("btree.zig");

pub const SnapshotInfo = struct {
    tx_id: u64,
    root_page_id: btree.PageId,
    generation: u64,
};

pub const EngineStats = struct {
    tree: btree.TreeStats,
    wal: wal.WalInspection,
    committed_root: btree.PageId,
    active_tx_id: u64,
    tx_in_progress: bool,
    snapshot_count: usize,
};

pub const VerificationReport = struct {
    wal: wal.WalInspection,
    committed_tree: btree.TreeStats,
    active_tree: ?btree.TreeStats,
    ok: bool,
};

pub const CompactionReport = struct {
    pages_before: usize,
    pages_after: usize,
    pages_reclaimed: usize,
    wal_bytes_before: usize,
    wal_bytes_after: usize,
    live_keys: usize,
    new_root_page_id: btree.PageId,
};

const PendingOp = union(enum) {
    put: struct { key: []u8, val: []u8 },
    delete: struct { key: []u8 },
};

pub const BerylEngine = struct {
    allocator: std.mem.Allocator,
    store: *btree.PageStore,
    tree: btree.CowBTree,
    wal_writer: wal.WalWriter,
    committed_root: btree.PageId,
    active_tx_id: u64,
    tx_in_progress: bool,
    tx_dirty: bool = false,
    snapshots: std.ArrayList(SnapshotInfo) = .empty,

    pub fn init(allocator: std.mem.Allocator) !BerylEngine {
        const store_ptr = try allocator.create(btree.PageStore);
        errdefer allocator.destroy(store_ptr);
        store_ptr.* = btree.PageStore.init(allocator);
        errdefer store_ptr.deinit();

        const tree = try btree.CowBTree.init(store_ptr);
        const root_id = tree.root_id;

        return BerylEngine{
            .allocator = allocator,
            .store = store_ptr,
            .tree = tree,
            .wal_writer = wal.WalWriter.init(allocator),
            .committed_root = root_id,
            .active_tx_id = 1,
            .tx_in_progress = false,
            .tx_dirty = false,
            .snapshots = .empty,
        };
    }

    pub fn deinit(self: *BerylEngine) void {
        self.snapshots.deinit(self.allocator);
        self.wal_writer.deinit();
        self.store.deinit();
        self.allocator.destroy(self.store);
    }

    pub fn beginTransaction(self: *BerylEngine) !u64 {
        if (self.tx_in_progress) return error.TransactionAlreadyActive;
        self.tx_in_progress = true;
        self.tx_dirty = false;
        return self.active_tx_id;
    }

    pub fn put(self: *BerylEngine, key: []const u8, value: []const u8) !void {
        if (key.len > btree.MAX_KEY_LEN or value.len > btree.MAX_VAL_LEN) {
            return error.KeyValueTooLarge;
        }

        const started_implicitly = !self.tx_in_progress;
        if (started_implicitly) {
            _ = try self.beginTransaction();
        }
        errdefer if (started_implicitly) {
            self.tx_in_progress = false;
            self.tx_dirty = false;
        };

        const wal_mark = self.wal_writer.buffer.items.len;
        errdefer self.wal_writer.truncate(wal_mark);

        try self.wal_writer.appendRecord(.{
            .put = .{
                .tx_id = self.active_tx_id,
                .key = key,
                .value = value,
            },
        });

        _ = try self.tree.put(key, value);
        self.tx_dirty = true;
    }

    pub fn delete(self: *BerylEngine, key: []const u8) !bool {
        if (key.len > btree.MAX_KEY_LEN) {
            return error.KeyValueTooLarge;
        }

        const current_root = if (self.tx_in_progress) self.tree.root_id else self.committed_root;
        if ((try self.tree.get(current_root, key)) == null) {
            return false;
        }

        const started_implicitly = !self.tx_in_progress;
        if (started_implicitly) {
            _ = try self.beginTransaction();
        }
        errdefer if (started_implicitly) {
            self.tx_in_progress = false;
            self.tx_dirty = false;
        };

        const wal_mark = self.wal_writer.buffer.items.len;
        errdefer self.wal_writer.truncate(wal_mark);

        try self.wal_writer.appendRecord(.{
            .delete = .{
                .tx_id = self.active_tx_id,
                .key = key,
            },
        });

        const outcome = try self.tree.delete(key);
        self.tx_dirty = true;
        return outcome.deleted;
    }

    pub fn get(self: *const BerylEngine, key: []const u8) !?btree.KeyValue {
        const root = if (self.tx_in_progress) self.tree.root_id else self.committed_root;
        return try self.tree.get(root, key);
    }

    pub fn getAtSnapshot(self: *const BerylEngine, root_id: btree.PageId, key: []const u8) !?btree.KeyValue {
        return try self.tree.get(root_id, key);
    }

    pub fn scanRange(
        self: *const BerylEngine,
        allocator: std.mem.Allocator,
        opts: btree.RangeOptions,
    ) ![]btree.KeyValue {
        const root = if (self.tx_in_progress) self.tree.root_id else self.committed_root;
        return try self.tree.scanRange(allocator, root, opts);
    }

    pub fn scanRangeAtSnapshot(
        self: *const BerylEngine,
        allocator: std.mem.Allocator,
        root_id: btree.PageId,
        opts: btree.RangeOptions,
    ) ![]btree.KeyValue {
        return try self.tree.scanRange(allocator, root_id, opts);
    }

    pub fn scanPrefix(
        self: *const BerylEngine,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        limit: ?usize,
    ) ![]btree.KeyValue {
        const root = if (self.tx_in_progress) self.tree.root_id else self.committed_root;
        return try self.tree.scanPrefix(allocator, root, prefix, limit);
    }

    pub fn scanPrefixAtSnapshot(
        self: *const BerylEngine,
        allocator: std.mem.Allocator,
        root_id: btree.PageId,
        prefix: []const u8,
        limit: ?usize,
    ) ![]btree.KeyValue {
        return try self.tree.scanPrefix(allocator, root_id, prefix, limit);
    }

    pub fn count(self: *const BerylEngine) !usize {
        const root = if (self.tx_in_progress) self.tree.root_id else self.committed_root;
        return try self.tree.count(root);
    }

    pub fn commit(self: *BerylEngine) !btree.PageId {
        if (!self.tx_in_progress) return self.committed_root;

        const new_root = self.tree.root_id;
        const tx_id = self.active_tx_id;
        const gen = self.tree.generation;

        const wal_mark = self.wal_writer.buffer.items.len;
        errdefer self.wal_writer.truncate(wal_mark);

        try self.wal_writer.appendRecord(.{
            .commit = .{
                .tx_id = tx_id,
                .root_page_id = new_root,
                .generation = gen,
            },
        });

        try self.snapshots.append(self.allocator, .{
            .tx_id = tx_id,
            .root_page_id = new_root,
            .generation = gen,
        });

        self.committed_root = new_root;
        self.active_tx_id += 1;
        self.tx_in_progress = false;
        self.tx_dirty = false;
        return self.committed_root;
    }

    pub fn rollback(self: *BerylEngine) void {
        if (!self.tx_in_progress) return;
        self.tree.root_id = self.committed_root;
        if (self.tx_dirty) {
            // Record explicit abort and advance tx_id so aborted ops can never
            // be conflated with a subsequent transaction during WAL replay.
            self.wal_writer.appendRecord(.{
                .abort = .{ .tx_id = self.active_tx_id },
            }) catch {};
            self.active_tx_id += 1;
        }
        self.tx_dirty = false;
        self.tx_in_progress = false;
    }

    pub fn checkpoint(self: *BerylEngine) !void {
        if (self.tx_in_progress) return error.CannotCheckpointActiveTx;
        try self.wal_writer.appendRecord(.{
            .checkpoint = .{
                .checkpoint_seq = self.active_tx_id,
                .root_page_id = self.committed_root,
            },
        });
    }

    pub fn getWalBytes(self: *const BerylEngine) []const u8 {
        return self.wal_writer.buffer.items;
    }

    pub fn getSnapshots(self: *const BerylEngine) []const SnapshotInfo {
        return self.snapshots.items;
    }

    pub fn stats(self: *const BerylEngine) !EngineStats {
        const root = if (self.tx_in_progress) self.tree.root_id else self.committed_root;
        const tree_stats = try self.tree.stats(root);
        const wal_insp = wal.inspectWal(self.getWalBytes());
        return .{
            .tree = tree_stats,
            .wal = wal_insp,
            .committed_root = self.committed_root,
            .active_tx_id = self.active_tx_id,
            .tx_in_progress = self.tx_in_progress,
            .snapshot_count = self.snapshots.items.len,
        };
    }

    pub fn verify(self: *const BerylEngine) !VerificationReport {
        const wal_insp = wal.inspectWal(self.getWalBytes());
        const committed_stats = try self.tree.verify(self.committed_root);
        const active_stats: ?btree.TreeStats = if (self.tx_in_progress and self.tree.root_id != self.committed_root)
            try self.tree.verify(self.tree.root_id)
        else
            null;

        return .{
            .wal = wal_insp,
            .committed_tree = committed_stats,
            .active_tree = active_stats,
            .ok = wal_insp.clean,
        };
    }

    /// Reclaims unreachable CoW pages and compacts the WAL down to the live committed state.
    pub fn compact(self: *BerylEngine) !CompactionReport {
        var empty_in: [0]btree.PageId = .{};
        var empty_out: [0]btree.PageId = .{};
        return try self.compactWithPinnedSnapshots(&empty_in, &empty_out);
    }

    /// Reclaims unreachable CoW pages while preserving `committed_root` plus all
    /// `pinned_roots`, deduplicating shared CoW subtrees and writing remapped
    /// root page IDs to `out_remapped`. Also rewrites the WAL to a minimal
    /// compacted checkpoint of the live committed state.
    pub fn compactWithPinnedSnapshots(
        self: *BerylEngine,
        pinned_roots: []const btree.PageId,
        out_remapped: []btree.PageId,
    ) !CompactionReport {
        if (self.tx_in_progress) return error.CannotCompactActiveTx;
        if (pinned_roots.len != out_remapped.len) return error.InvalidPinnedBuffer;

        const pages_before = self.store.allocatedPageCount();
        const wal_bytes_before = self.wal_writer.buffer.items.len;

        const new_store_ptr = try self.allocator.create(btree.PageStore);
        errdefer self.allocator.destroy(new_store_ptr);
        new_store_ptr.* = btree.PageStore.init(self.allocator);
        errdefer new_store_ptr.deinit();

        var remap = std.AutoHashMap(btree.PageId, btree.PageId).init(self.allocator);
        defer remap.deinit();

        const new_committed_root = try self.store.cloneReachableSubtree(
            new_store_ptr,
            self.committed_root,
            &remap,
        );

        const temp_remapped = try self.allocator.alloc(btree.PageId, pinned_roots.len);
        defer self.allocator.free(temp_remapped);
        for (pinned_roots, 0..) |old_root, i| {
            temp_remapped[i] = try self.store.cloneReachableSubtree(
                new_store_ptr,
                old_root,
                &remap,
            );
        }

        // Build minimal WAL from the live committed key-value set
        const live_items = try self.tree.scanRange(self.allocator, self.committed_root, .{});
        defer self.allocator.free(live_items);

        var new_wal = wal.WalWriter.init(self.allocator);
        errdefer new_wal.deinit();

        const compact_tx_id = self.active_tx_id;
        if (live_items.len > 0) {
            for (live_items) |*kv| {
                try new_wal.appendRecord(.{
                    .put = .{
                        .tx_id = compact_tx_id,
                        .key = kv.getKey(),
                        .value = kv.getValue(),
                    },
                });
            }
            try new_wal.appendRecord(.{
                .commit = .{
                    .tx_id = compact_tx_id,
                    .root_page_id = new_committed_root,
                    .generation = self.tree.generation,
                },
            });
        }
        try new_wal.appendRecord(.{
            .checkpoint = .{
                .checkpoint_seq = compact_tx_id,
                .root_page_id = new_committed_root,
            },
        });

        // Build remapped snapshots list containing any retained snapshots
        var new_snapshots: std.ArrayList(SnapshotInfo) = .empty;
        errdefer new_snapshots.deinit(self.allocator);

        var saw_committed = false;
        for (self.snapshots.items) |snap| {
            if (remap.get(snap.root_page_id)) |mapped_root| {
                if (mapped_root == new_committed_root) saw_committed = true;
                try new_snapshots.append(self.allocator, .{
                    .tx_id = snap.tx_id,
                    .root_page_id = mapped_root,
                    .generation = snap.generation,
                });
            }
        }
        if (!saw_committed and live_items.len > 0) {
            try new_snapshots.append(self.allocator, .{
                .tx_id = compact_tx_id,
                .root_page_id = new_committed_root,
                .generation = self.tree.generation,
            });
        }

        // Commit swap (infallible from here on)
        @memcpy(out_remapped, temp_remapped);

        const old_store = self.store;
        self.store = new_store_ptr;
        old_store.deinit();
        self.allocator.destroy(old_store);

        self.tree = btree.CowBTree.initWithRoot(self.store, new_committed_root, self.tree.generation);
        self.committed_root = new_committed_root;

        self.wal_writer.deinit();
        self.wal_writer = new_wal;

        self.snapshots.deinit(self.allocator);
        self.snapshots = new_snapshots;

        self.active_tx_id = compact_tx_id + 1;

        const pages_after = self.store.allocatedPageCount();
        const pages_reclaimed = if (pages_before >= pages_after) pages_before - pages_after else 0;

        return .{
            .pages_before = pages_before,
            .pages_after = pages_after,
            .pages_reclaimed = pages_reclaimed,
            .wal_bytes_before = wal_bytes_before,
            .wal_bytes_after = self.wal_writer.buffer.items.len,
            .live_keys = live_items.len,
            .new_root_page_id = new_committed_root,
        };
    }

    pub fn recoverFromWal(allocator: std.mem.Allocator, wal_data: []const u8) !BerylEngine {
        var engine = try BerylEngine.init(allocator);
        errdefer engine.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var reader = wal.WalReader.init(wal_data);

        var pending_by_tx = std.AutoHashMap(u64, std.ArrayList(PendingOp)).init(arena_alloc);
        var max_seen_tx_id: u64 = 0;
        var last_valid_offset: usize = 0;

        while (true) {
            const maybe_rec = reader.next(arena_alloc) catch |err| {
                // Stop replay at the exact offset of any torn/corrupted tail record
                switch (err) {
                    error.ChecksumMismatch,
                    error.TruncatedRecord,
                    error.InvalidMagic,
                    error.UnknownRecordType,
                    error.InvalidPayload,
                    => break,
                    else => return err,
                }
            };

            if (maybe_rec) |rec| {
                last_valid_offset = reader.cursor;
                switch (rec) {
                    .put => |p| {
                        max_seen_tx_id = @max(max_seen_tx_id, p.tx_id);
                        const gop = try pending_by_tx.getOrPut(p.tx_id);
                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                        const k_copy = try arena_alloc.dupe(u8, p.key);
                        const v_copy = try arena_alloc.dupe(u8, p.value);
                        try gop.value_ptr.append(arena_alloc, .{ .put = .{ .key = k_copy, .val = v_copy } });
                    },
                    .delete => |d| {
                        max_seen_tx_id = @max(max_seen_tx_id, d.tx_id);
                        const gop = try pending_by_tx.getOrPut(d.tx_id);
                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                        const k_copy = try arena_alloc.dupe(u8, d.key);
                        try gop.value_ptr.append(arena_alloc, .{ .delete = .{ .key = k_copy } });
                    },
                    .abort => |a| {
                        max_seen_tx_id = @max(max_seen_tx_id, a.tx_id);
                        _ = pending_by_tx.remove(a.tx_id);
                    },
                    .commit => |c| {
                        max_seen_tx_id = @max(max_seen_tx_id, c.tx_id);
                        if (pending_by_tx.fetchRemove(c.tx_id)) |entry| {
                            for (entry.value.items) |op| {
                                switch (op) {
                                    .put => |p| _ = try engine.tree.put(p.key, p.val),
                                    .delete => |d| _ = try engine.tree.delete(d.key),
                                }
                            }
                        }
                        engine.committed_root = engine.tree.root_id;
                        try engine.snapshots.append(allocator, .{
                            .tx_id = c.tx_id,
                            .root_page_id = engine.committed_root,
                            .generation = engine.tree.generation,
                        });
                    },
                    .checkpoint => |cp| {
                        max_seen_tx_id = @max(max_seen_tx_id, cp.checkpoint_seq);
                    },
                }
            } else {
                break;
            }
        }

        // Retain the clean validated WAL prefix so subsequent commits remain
        // durable across repeated crash-recovery cycles.
        if (last_valid_offset > 0) {
            try engine.wal_writer.buffer.appendSlice(allocator, wal_data[0..last_valid_offset]);
        }

        engine.tree.root_id = engine.committed_root;
        engine.active_tx_id = @max(engine.active_tx_id, max_seen_tx_id + 1);
        engine.tx_in_progress = false;
        engine.tx_dirty = false;

        return engine;
    }

    /// Loads an engine from a WAL file on disk (creating an empty engine if the
    /// file does not exist yet).
    pub fn openFile(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        sub_path: []const u8,
    ) !BerylEngine {
        const wal_bytes = dir.readFileAlloc(io, sub_path, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return try BerylEngine.init(allocator),
            else => return err,
        };
        defer allocator.free(wal_bytes);

        return try BerylEngine.recoverFromWal(allocator, wal_bytes);
    }

    /// Atomically persists the engine's WAL buffer to disk with fsync + rename.
    pub fn saveFile(
        self: *const BerylEngine,
        io: std.Io,
        dir: std.Io.Dir,
        sub_path: []const u8,
    ) !void {
        var atomic_file = try dir.createFileAtomic(io, sub_path, .{
            .replace = true,
            .make_path = true,
        });
        defer atomic_file.deinit(io);

        try atomic_file.file.writeStreamingAll(io, self.getWalBytes());
        atomic_file.file.sync(io) catch {};
        try atomic_file.replace(io);
    }
};

test "BerylEngine commit, delete, and rollback" {
    var engine = try BerylEngine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try engine.beginTransaction();
    try engine.put("user:100", "Alice");
    try engine.put("user:101", "Charlie");
    const snap1 = try engine.commit();

    const kv1 = (try engine.get("user:100")).?;
    try std.testing.expectEqualStrings("Alice", kv1.getValue());

    // Start uncommitted tx with put + delete and rollback
    _ = try engine.beginTransaction();
    try engine.put("user:200", "Bob");
    try std.testing.expect(try engine.delete("user:100"));
    try std.testing.expect((try engine.get("user:100")) == null);
    engine.rollback();

    try std.testing.expect((try engine.get("user:200")) == null);
    const kv_recheck = (try engine.get("user:100")).?;
    try std.testing.expectEqualStrings("Alice", kv_recheck.getValue());

    // Commit a real deletion and verify historical snapshot still has old key
    _ = try engine.beginTransaction();
    try std.testing.expect(try engine.delete("user:101"));
    try std.testing.expect(!(try engine.delete("user:999")));
    _ = try engine.commit();

    try std.testing.expect((try engine.get("user:101")) == null);
    try std.testing.expectEqualStrings("Charlie", (try engine.getAtSnapshot(snap1, "user:101")).?.getValue());
}

test "BerylEngine crash recovery with partial transaction, rollbacks, deletes, and torn tail" {
    var eng1 = try BerylEngine.init(std.testing.allocator);
    defer eng1.deinit();

    // Tx 1: committed
    _ = try eng1.beginTransaction();
    try eng1.put("k1", "committed_v1");
    try eng1.put("k_del", "to_be_deleted");
    _ = try eng1.commit();

    // Tx 2: explicitly rolled back (must NEVER resurrect after WAL recovery!)
    _ = try eng1.beginTransaction();
    try eng1.put("k_rolled_back", "ghost_val");
    engine_rollback_check: {
        eng1.rollback();
        break :engine_rollback_check;
    }

    // Tx 3: committed delete + update
    _ = try eng1.beginTransaction();
    try std.testing.expect(try eng1.delete("k_del"));
    try eng1.put("k1", "updated_v1");
    _ = try eng1.commit();
    try eng1.checkpoint();

    // Tx 4: uncommitted (simulated crash before commit) + corrupted tail bytes
    _ = try eng1.beginTransaction();
    try eng1.put("k2", "uncommitted_v2");

    var corrupted_wal = std.ArrayList(u8).empty;
    defer corrupted_wal.deinit(std.testing.allocator);
    try corrupted_wal.appendSlice(std.testing.allocator, eng1.getWalBytes());
    try corrupted_wal.appendSlice(std.testing.allocator, &[_]u8{ 0x59, 0x52, 0x45, 0x42, 0x01, 0xFF, 0xAA });

    // Recover from WAL with torn tail
    var eng_recovered = try BerylEngine.recoverFromWal(std.testing.allocator, corrupted_wal.items);
    defer eng_recovered.deinit();

    try std.testing.expectEqualStrings("updated_v1", (try eng_recovered.get("k1")).?.getValue());
    try std.testing.expect((try eng_recovered.get("k_del")) == null);
    try std.testing.expect((try eng_recovered.get("k_rolled_back")) == null);
    try std.testing.expect((try eng_recovered.get("k2")) == null);

    // Recovered engine must remain durable across a SECOND write + recovery cycle
    try eng_recovered.put("k3", "post_recovery_v3");
    _ = try eng_recovered.commit();

    const report = try eng_recovered.verify();
    try std.testing.expect(report.ok);
    try std.testing.expectEqual(@as(usize, 2), report.committed_tree.key_count);

    var eng_recovered_2 = try BerylEngine.recoverFromWal(std.testing.allocator, eng_recovered.getWalBytes());
    defer eng_recovered_2.deinit();

    try std.testing.expectEqualStrings("updated_v1", (try eng_recovered_2.get("k1")).?.getValue());
    try std.testing.expectEqualStrings("post_recovery_v3", (try eng_recovered_2.get("k3")).?.getValue());
    try std.testing.expect((try eng_recovered_2.get("k2")) == null);
    try std.testing.expect((try eng_recovered_2.get("k_rolled_back")) == null);
}

test "BerylEngine compaction reclaims dead pages, shrinks WAL, and preserves pinned snapshots" {
    var eng = try BerylEngine.init(std.testing.allocator);
    defer eng.deinit();

    var kbuf: [24]u8 = undefined;
    var vbuf: [32]u8 = undefined;

    // Populate initial state and pin snapshot 1
    _ = try eng.beginTransaction();
    for (0..30) |i| {
        const k = std.fmt.bufPrint(&kbuf, "item:{d:0>3}", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&vbuf, "gen1:{d:0>3}", .{i}) catch unreachable;
        try eng.put(k, v);
    }
    const pinned_snap = try eng.commit();

    // Churn overwrites and deletions to accumulate dead CoW pages and WAL history
    for (0..4) |round| {
        _ = try eng.beginTransaction();
        for (0..30) |i| {
            const k = std.fmt.bufPrint(&kbuf, "item:{d:0>3}", .{i}) catch unreachable;
            const v = std.fmt.bufPrint(&vbuf, "round{d}:{d:0>3}", .{ round, i }) catch unreachable;
            try eng.put(k, v);
        }
        _ = try eng.commit();
    }

    _ = try eng.beginTransaction();
    for (15..30) |i| {
        const k = std.fmt.bufPrint(&kbuf, "item:{d:0>3}", .{i}) catch unreachable;
        _ = try eng.delete(k);
    }
    _ = try eng.commit();

    // Compact while pinning `pinned_snap`
    var remapped: [1]btree.PageId = undefined;
    const comp = try eng.compactWithPinnedSnapshots(&[_]btree.PageId{pinned_snap}, &remapped);

    try std.testing.expect(comp.pages_reclaimed > 0);
    try std.testing.expect(comp.pages_after < comp.pages_before);
    try std.testing.expect(comp.wal_bytes_after < comp.wal_bytes_before);
    try std.testing.expectEqual(@as(usize, 15), comp.live_keys);

    // Verify compacted live state
    const ver = try eng.verify();
    try std.testing.expect(ver.ok);
    try std.testing.expectEqual(@as(usize, 15), ver.committed_tree.key_count);
    try std.testing.expectEqualStrings("round3:000", (try eng.get("item:000")).?.getValue());
    try std.testing.expect((try eng.get("item:020")) == null);

    // Pinned historical snapshot survived compaction with remapped root page ID!
    try std.testing.expectEqualStrings("gen1:000", (try eng.getAtSnapshot(remapped[0], "item:000")).?.getValue());
    try std.testing.expectEqualStrings("gen1:020", (try eng.getAtSnapshot(remapped[0], "item:020")).?.getValue());

    // Recovering from the compacted WAL reproduces the exact live state
    var recovered = try BerylEngine.recoverFromWal(std.testing.allocator, eng.getWalBytes());
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 15), try recovered.count());
    try std.testing.expectEqualStrings("round3:014", (try recovered.get("item:014")).?.getValue());
    try std.testing.expect((try recovered.get("item:015")) == null);
}

test "BerylEngine file-backed persistence round-trip and compaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;

    {
        var eng = try BerylEngine.openFile(std.testing.allocator, io, tmp.dir, "store.wal");
        defer eng.deinit();

        try eng.put("cfg:region", "ap-northeast-2");
        try eng.put("cfg:replicas", "3");
        _ = try eng.commit();
        try eng.saveFile(io, tmp.dir, "store.wal");
    }

    {
        var eng = try BerylEngine.openFile(std.testing.allocator, io, tmp.dir, "store.wal");
        defer eng.deinit();

        try std.testing.expectEqualStrings("ap-northeast-2", (try eng.get("cfg:region")).?.getValue());
        try std.testing.expectEqualStrings("3", (try eng.get("cfg:replicas")).?.getValue());

        try std.testing.expect(try eng.delete("cfg:replicas"));
        try eng.put("cfg:tier", "nvme");
        _ = try eng.commit();
        _ = try eng.compact();
        try eng.saveFile(io, tmp.dir, "store.wal");
    }

    {
        var eng = try BerylEngine.openFile(std.testing.allocator, io, tmp.dir, "store.wal");
        defer eng.deinit();

        try std.testing.expectEqual(@as(usize, 2), try eng.count());
        try std.testing.expectEqualStrings("ap-northeast-2", (try eng.get("cfg:region")).?.getValue());
        try std.testing.expectEqualStrings("nvme", (try eng.get("cfg:tier")).?.getValue());
        try std.testing.expect((try eng.get("cfg:replicas")) == null);
    }
}

test "BerylEngine input validation does not pollute WAL or active transaction" {
    var eng = try BerylEngine.init(std.testing.allocator);
    defer eng.deinit();

    const oversized_key: [btree.MAX_KEY_LEN + 1]u8 = @splat('k');
    const oversized_val: [btree.MAX_VAL_LEN + 1]u8 = @splat('v');

    try std.testing.expectError(error.KeyValueTooLarge, eng.put(&oversized_key, "ok"));
    try std.testing.expect(!eng.tx_in_progress);
    try std.testing.expectEqual(@as(usize, 0), eng.getWalBytes().len);

    try std.testing.expectError(error.KeyValueTooLarge, eng.put("ok", &oversized_val));
    try std.testing.expect(!eng.tx_in_progress);
    try std.testing.expectEqual(@as(usize, 0), eng.getWalBytes().len);

    try std.testing.expectError(error.KeyValueTooLarge, eng.delete(&oversized_key));
    try std.testing.expect(!eng.tx_in_progress);
    try std.testing.expectEqual(@as(usize, 0), eng.getWalBytes().len);
}
