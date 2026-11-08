const std = @import("std");
pub const wal = @import("wal.zig");
pub const btree = @import("btree.zig");

pub const BerylEngine = struct {
    allocator: std.mem.Allocator,
    store: *btree.PageStore,
    tree: btree.CowBTree,
    wal_writer: wal.WalWriter,
    committed_root: btree.PageId,
    active_tx_id: u64,
    tx_in_progress: bool,

    pub fn init(allocator: std.mem.Allocator) !BerylEngine {
        const store_ptr = try allocator.create(btree.PageStore);
        errdefer allocator.destroy(store_ptr);
        store_ptr.* = btree.PageStore.init(allocator);

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
        };
    }

    pub fn deinit(self: *BerylEngine) void {
        self.wal_writer.deinit();
        self.store.deinit();
        self.allocator.destroy(self.store);
    }

    pub fn beginTransaction(self: *BerylEngine) !u64 {
        if (self.tx_in_progress) return error.TransactionAlreadyActive;
        self.tx_in_progress = true;
        return self.active_tx_id;
    }

    pub fn put(self: *BerylEngine, key: []const u8, value: []const u8) !void {
        if (!self.tx_in_progress) {
            _ = try self.beginTransaction();
        }

        try self.wal_writer.appendRecord(.{
            .put = .{
                .tx_id = self.active_tx_id,
                .key = key,
                .value = value,
            },
        });

        _ = try self.tree.put(key, value);
    }

    pub fn get(self: *const BerylEngine, key: []const u8) !?btree.KeyValue {
        const root = if (self.tx_in_progress) self.tree.root_id else self.committed_root;
        return try self.tree.get(root, key);
    }

    pub fn getAtSnapshot(self: *const BerylEngine, root_id: btree.PageId, key: []const u8) !?btree.KeyValue {
        return try self.tree.get(root_id, key);
    }

    pub fn commit(self: *BerylEngine) !btree.PageId {
        if (!self.tx_in_progress) return self.committed_root;

        const new_root = self.tree.root_id;
        try self.wal_writer.appendRecord(.{
            .commit = .{
                .tx_id = self.active_tx_id,
                .root_page_id = new_root,
                .generation = self.tree.generation,
            },
        });

        self.committed_root = new_root;
        self.active_tx_id += 1;
        self.tx_in_progress = false;
        return self.committed_root;
    }

    pub fn rollback(self: *BerylEngine) void {
        if (!self.tx_in_progress) return;
        self.tree.root_id = self.committed_root;
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

    pub fn recoverFromWal(allocator: std.mem.Allocator, wal_data: []const u8) !BerylEngine {
        var engine = try BerylEngine.init(allocator);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var reader = wal.WalReader.init(wal_data);

        var current_tx_id: u64 = 0;
        var pending_puts: std.ArrayList(struct { key: []u8, val: []u8 }) = .empty;
        defer {
            for (pending_puts.items) |item| {
                arena_alloc.free(item.key);
                arena_alloc.free(item.val);
            }
            pending_puts.deinit(arena_alloc);
        }

        while (true) {
            const maybe_rec = reader.next(arena_alloc) catch |err| {
                // If corrupted at end of file, stop recovery at last clean point
                if (err == error.ChecksumMismatch or err == error.TruncatedRecord) break;
                return err;
            };

            if (maybe_rec) |rec| {
                switch (rec) {
                    .put => |p| {
                        current_tx_id = p.tx_id;
                        const k_copy = try arena_alloc.dupe(u8, p.key);
                        const v_copy = try arena_alloc.dupe(u8, p.value);
                        try pending_puts.append(arena_alloc, .{ .key = k_copy, .val = v_copy });
                    },
                    .delete => {},
                    .commit => |c| {
                        // Replay all pending puts for this committed transaction
                        for (pending_puts.items) |item| {
                            _ = try engine.tree.put(item.key, item.val);
                        }
                        pending_puts.clearRetainingCapacity();
                        engine.committed_root = c.root_page_id;
                        engine.active_tx_id = c.tx_id + 1;
                    },
                    .checkpoint => |cp| {
                        engine.committed_root = cp.root_page_id;
                    },
                }
            } else {
                break;
            }
        }

        // Any pending puts not committed are naturally discarded!
        engine.tree.root_id = engine.committed_root;
        engine.tx_in_progress = false;

        return engine;
    }
};

test "BerylEngine commit and rollback" {
    var engine = try BerylEngine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try engine.beginTransaction();
    try engine.put("user:100", "Alice");
    _ = try engine.commit();

    const kv1 = (try engine.get("user:100")).?;
    try std.testing.expectEqualStrings("Alice", kv1.getValue());

    // Start uncommitted tx and rollback
    _ = try engine.beginTransaction();
    try engine.put("user:200", "Bob");
    engine.rollback();

    try std.testing.expect((try engine.get("user:200")) == null);
    const kv_recheck = (try engine.get("user:100")).?;
    try std.testing.expectEqualStrings("Alice", kv_recheck.getValue());
}

test "BerylEngine crash recovery with partial transaction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var wal_data: []const u8 = undefined;

    {
        var eng1 = try BerylEngine.init(alloc);
        defer eng1.deinit();

        _ = try eng1.beginTransaction();
        try eng1.put("k1", "committed_v1");
        _ = try eng1.commit();

        _ = try eng1.beginTransaction();
        try eng1.put("k2", "uncommitted_v2");
        // Simulate crash before commit!

        wal_data = try alloc.dupe(u8, eng1.getWalBytes());
    }

    // Recover from WAL
    var eng_recovered = try BerylEngine.recoverFromWal(alloc, wal_data);
    defer eng_recovered.deinit();

    const kv1 = (try eng_recovered.get("k1")).?;
    try std.testing.expectEqualStrings("committed_v1", kv1.getValue());

    const kv2 = try eng_recovered.get("k2");
    try std.testing.expect(kv2 == null);
}
