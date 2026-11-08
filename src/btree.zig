const std = @import("std");

pub const PAGE_SIZE: usize = 4096;
pub const BTREE_MAGIC: u32 = 0x42455254; // "BERT"
pub const MAX_KEYS: usize = 16;
pub const MAX_KEY_LEN: usize = 64;
pub const MAX_VAL_LEN: usize = 192;

pub const PageId = u32;
pub const INVALID_PAGE: PageId = 0;

pub const PageHeader = extern struct {
    magic: u32,
    page_id: PageId,
    generation: u64,
    is_leaf: u8,
    num_keys: u16,
    reserved: [13]u8,
    checksum: u32,
};

pub const KeyValue = struct {
    key: [MAX_KEY_LEN]u8,
    key_len: u16,
    val: [MAX_VAL_LEN]u8,
    val_len: u16,

    pub fn init(k: []const u8, v: []const u8) !KeyValue {
        if (k.len > MAX_KEY_LEN or v.len > MAX_VAL_LEN) return error.KeyValueTooLarge;
        var kv = KeyValue{
            .key = undefined,
            .key_len = @as(u16, @intCast(k.len)),
            .val = undefined,
            .val_len = @as(u16, @intCast(v.len)),
        };
        @memset(&kv.key, 0);
        @memset(&kv.val, 0);
        @memcpy(kv.key[0..k.len], k);
        @memcpy(kv.val[0..v.len], v);
        return kv;
    }

    pub fn getKey(self: *const KeyValue) []const u8 {
        return self.key[0..self.key_len];
    }

    pub fn getValue(self: *const KeyValue) []const u8 {
        return self.val[0..self.val_len];
    }
};

pub const BTreeNode = struct {
    page_id: PageId,
    generation: u64,
    is_leaf: bool,
    num_keys: u16,
    items: [MAX_KEYS + 1]KeyValue,
    children: [MAX_KEYS + 2]PageId,

    pub fn initEmpty(page_id: PageId, is_leaf: bool, generation: u64) BTreeNode {
        var node = BTreeNode{
            .page_id = page_id,
            .generation = generation,
            .is_leaf = is_leaf,
            .num_keys = 0,
            .items = undefined,
            .children = undefined,
        };
        @memset(&node.children, INVALID_PAGE);
        return node;
    }

    pub fn serialize(self: *const BTreeNode, out_page: *[PAGE_SIZE]u8) void {
        @memset(out_page, 0);
        var header = PageHeader{
            .magic = BTREE_MAGIC,
            .page_id = self.page_id,
            .generation = self.generation,
            .is_leaf = if (self.is_leaf) 1 else 0,
            .num_keys = self.num_keys,
            .reserved = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .checksum = 0,
        };

        var offset: usize = @sizeOf(PageHeader);
        for (0..self.num_keys) |i| {
            const kv = &self.items[i];
            std.mem.writeInt(u16, out_page[offset..][0..2], kv.key_len, .little);
            offset += 2;
            @memcpy(out_page[offset .. offset + kv.key_len], kv.getKey());
            offset += kv.key_len;

            std.mem.writeInt(u16, out_page[offset..][0..2], kv.val_len, .little);
            offset += 2;
            @memcpy(out_page[offset .. offset + kv.val_len], kv.getValue());
            offset += kv.val_len;
        }

        if (!self.is_leaf) {
            for (0..self.num_keys + 1) |i| {
                std.mem.writeInt(u32, out_page[offset..][0..4], self.children[i], .little);
                offset += 4;
            }
        }

        const crc = std.hash.Crc32.hash(out_page[@sizeOf(PageHeader)..offset]);
        header.checksum = crc;

        const header_bytes = std.mem.asBytes(&header);
        @memcpy(out_page[0..@sizeOf(PageHeader)], header_bytes);
    }

    pub fn deserialize(in_page: *const [PAGE_SIZE]u8) !BTreeNode {
        var header: PageHeader = undefined;
        @memcpy(std.mem.asBytes(&header), in_page[0..@sizeOf(PageHeader)]);
        if (header.magic != BTREE_MAGIC) return error.InvalidBTreeMagic;

        var node = BTreeNode{
            .page_id = header.page_id,
            .generation = header.generation,
            .is_leaf = (header.is_leaf != 0),
            .num_keys = header.num_keys,
            .items = undefined,
            .children = undefined,
        };
        @memset(&node.children, INVALID_PAGE);

        var offset: usize = @sizeOf(PageHeader);
        for (0..node.num_keys) |i| {
            if (offset + 2 > PAGE_SIZE) return error.PageCorrupted;
            const klen = std.mem.readInt(u16, in_page[offset..][0..2], .little);
            offset += 2;
            if (klen > MAX_KEY_LEN or offset + klen > PAGE_SIZE) return error.PageCorrupted;
            const key_bytes = in_page[offset .. offset + klen];
            offset += klen;

            if (offset + 2 > PAGE_SIZE) return error.PageCorrupted;
            const vlen = std.mem.readInt(u16, in_page[offset..][0..2], .little);
            offset += 2;
            if (vlen > MAX_VAL_LEN or offset + vlen > PAGE_SIZE) return error.PageCorrupted;
            const val_bytes = in_page[offset .. offset + vlen];
            offset += vlen;

            node.items[i] = try KeyValue.init(key_bytes, val_bytes);
        }

        if (!node.is_leaf) {
            for (0..node.num_keys + 1) |i| {
                if (offset + 4 > PAGE_SIZE) return error.PageCorrupted;
                node.children[i] = std.mem.readInt(u32, in_page[offset..][0..4], .little);
                offset += 4;
            }
        }

        const expected_crc = std.hash.Crc32.hash(in_page[@sizeOf(PageHeader)..offset]);
        if (expected_crc != header.checksum) {
            return error.ChecksumMismatch;
        }

        return node;
    }
};

pub const PageStore = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayList([PAGE_SIZE]u8) = .empty,
    next_page_id: PageId = 1,

    pub fn init(allocator: std.mem.Allocator) PageStore {
        return .{
            .allocator = allocator,
            .pages = .empty,
            .next_page_id = 1,
        };
    }

    pub fn deinit(self: *PageStore) void {
        self.pages.deinit(self.allocator);
    }

    pub fn allocatePage(self: *PageStore) !PageId {
        const pid = self.next_page_id;
        self.next_page_id += 1;
        var zero_page: [PAGE_SIZE]u8 = undefined;
        @memset(&zero_page, 0);
        try self.pages.append(self.allocator, zero_page);
        return pid;
    }

    pub fn getPage(self: *PageStore, pid: PageId) !*[PAGE_SIZE]u8 {
        if (pid == 0 or pid >= self.next_page_id) return error.InvalidPageId;
        const idx = pid - 1;
        return &self.pages.items[idx];
    }

    pub fn readNode(self: *PageStore, pid: PageId) !BTreeNode {
        const page = try self.getPage(pid);
        return try BTreeNode.deserialize(page);
    }

    pub fn writeNode(self: *PageStore, node: *const BTreeNode) !void {
        const page = try self.getPage(node.page_id);
        node.serialize(page);
    }
};

pub const CowBTree = struct {
    store: *PageStore,
    root_id: PageId,
    generation: u64,

    pub fn init(store: *PageStore) !CowBTree {
        const root_id = try store.allocatePage();
        const root_node = BTreeNode.initEmpty(root_id, true, 1);
        try store.writeNode(&root_node);

        return CowBTree{
            .store = store,
            .root_id = root_id,
            .generation = 1,
        };
    }

    pub fn initWithRoot(store: *PageStore, root_id: PageId, generation: u64) CowBTree {
        return .{
            .store = store,
            .root_id = root_id,
            .generation = generation,
        };
    }

    pub fn get(self: *const CowBTree, root_id: PageId, key: []const u8) !?KeyValue {
        var current_pid = root_id;
        while (current_pid != INVALID_PAGE) {
            const node = try self.store.readNode(current_pid);
            var i: usize = 0;
            while (i < node.num_keys and std.mem.order(u8, key, node.items[i].getKey()) == .gt) {
                i += 1;
            }

            if (i < node.num_keys and std.mem.order(u8, key, node.items[i].getKey()) == .eq) {
                return node.items[i];
            }

            if (node.is_leaf) {
                return null;
            }

            current_pid = node.children[i];
        }
        return null;
    }

    pub const SplitResult = struct {
        median: KeyValue,
        right_pid: PageId,
    };

    pub const InsertResult = struct {
        new_page_id: PageId,
        split: ?SplitResult,
    };

    pub fn put(self: *CowBTree, key: []const u8, value: []const u8) !PageId {
        self.generation += 1;
        const kv = try KeyValue.init(key, value);
        const res = try self.insertNode(self.root_id, kv);

        if (res.split) |split| {
            const new_root_id = try self.store.allocatePage();
            var new_root = BTreeNode.initEmpty(new_root_id, false, self.generation);
            new_root.num_keys = 1;
            new_root.items[0] = split.median;
            new_root.children[0] = res.new_page_id;
            new_root.children[1] = split.right_pid;
            try self.store.writeNode(&new_root);
            self.root_id = new_root_id;
        } else {
            self.root_id = res.new_page_id;
        }

        return self.root_id;
    }

    fn insertNode(self: *CowBTree, pid: PageId, kv: KeyValue) !InsertResult {
        const old_node = try self.store.readNode(pid);
        var new_node = old_node;
        new_node.generation = self.generation;

        const new_pid = try self.store.allocatePage();
        new_node.page_id = new_pid;

        if (new_node.is_leaf) {
            var i: usize = 0;
            while (i < new_node.num_keys and std.mem.order(u8, kv.getKey(), new_node.items[i].getKey()) == .gt) {
                i += 1;
            }

            if (i < new_node.num_keys and std.mem.order(u8, kv.getKey(), new_node.items[i].getKey()) == .eq) {
                new_node.items[i] = kv;
                try self.store.writeNode(&new_node);
                return .{ .new_page_id = new_pid, .split = null };
            }

            var j: usize = new_node.num_keys;
            while (j > i) : (j -= 1) {
                new_node.items[j] = new_node.items[j - 1];
            }
            new_node.items[i] = kv;
            new_node.num_keys += 1;

            if (new_node.num_keys <= MAX_KEYS) {
                try self.store.writeNode(&new_node);
                return .{ .new_page_id = new_pid, .split = null };
            }

            // Split leaf node
            const mid = new_node.num_keys / 2;
            const right_pid = try self.store.allocatePage();
            var right_node = BTreeNode.initEmpty(right_pid, true, self.generation);

            for (mid..new_node.num_keys) |k| {
                right_node.items[k - mid] = new_node.items[k];
            }
            right_node.num_keys = @as(u16, @intCast(new_node.num_keys - mid));
            new_node.num_keys = @as(u16, @intCast(mid));

            try self.store.writeNode(&new_node);
            try self.store.writeNode(&right_node);

            return .{
                .new_page_id = new_pid,
                .split = .{
                    .median = right_node.items[0],
                    .right_pid = right_pid,
                },
            };
        } else {
            var i: usize = 0;
            while (i < new_node.num_keys and std.mem.order(u8, kv.getKey(), new_node.items[i].getKey()) == .gt) {
                i += 1;
            }

            const child_pid = new_node.children[i];
            const child_res = try self.insertNode(child_pid, kv);
            new_node.children[i] = child_res.new_page_id;

            if (child_res.split) |split| {
                var j: usize = new_node.num_keys;
                while (j > i) : (j -= 1) {
                    new_node.items[j] = new_node.items[j - 1];
                    new_node.children[j + 1] = new_node.children[j];
                }
                new_node.items[i] = split.median;
                new_node.children[i + 1] = split.right_pid;
                new_node.num_keys += 1;

                if (new_node.num_keys <= MAX_KEYS) {
                    try self.store.writeNode(&new_node);
                    return .{ .new_page_id = new_pid, .split = null };
                }

                // Split internal node
                const mid = new_node.num_keys / 2;
                const median_kv = new_node.items[mid];
                const right_pid = try self.store.allocatePage();
                var right_node = BTreeNode.initEmpty(right_pid, false, self.generation);

                for (mid + 1..new_node.num_keys) |k| {
                    right_node.items[k - (mid + 1)] = new_node.items[k];
                }
                for (mid + 1..new_node.num_keys + 1) |k| {
                    right_node.children[k - (mid + 1)] = new_node.children[k];
                }
                right_node.num_keys = @as(u16, @intCast(new_node.num_keys - (mid + 1)));
                new_node.num_keys = @as(u16, @intCast(mid));

                try self.store.writeNode(&new_node);
                try self.store.writeNode(&right_node);

                return .{
                    .new_page_id = new_pid,
                    .split = .{
                        .median = median_kv,
                        .right_pid = right_pid,
                    },
                };
            } else {
                try self.store.writeNode(&new_node);
                return .{ .new_page_id = new_pid, .split = null };
            }
        }
    }
};

test "B-Tree serialization and deserialization" {
    var node = BTreeNode.initEmpty(1, true, 42);
    node.num_keys = 2;
    node.items[0] = try KeyValue.init("foo", "bar");
    node.items[1] = try KeyValue.init("hello", "world");

    var page: [PAGE_SIZE]u8 = undefined;
    node.serialize(&page);

    const recovered = try BTreeNode.deserialize(&page);
    try std.testing.expectEqual(@as(PageId, 1), recovered.page_id);
    try std.testing.expectEqual(@as(u64, 42), recovered.generation);
    try std.testing.expectEqual(@as(u16, 2), recovered.num_keys);
    try std.testing.expectEqualStrings("foo", recovered.items[0].getKey());
    try std.testing.expectEqualStrings("bar", recovered.items[0].getValue());
    try std.testing.expectEqualStrings("hello", recovered.items[1].getKey());
    try std.testing.expectEqualStrings("world", recovered.items[1].getValue());
}

test "CoW B-Tree snapshot immutability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = PageStore.init(alloc);
    defer store.deinit();

    var tree = try CowBTree.init(&store);
    const snap0 = tree.root_id;

    const snap1 = try tree.put("key1", "val1");
    const snap2 = try tree.put("key2", "val2");

    const r2_k1 = (try tree.get(snap2, "key1")).?;
    const r2_k2 = (try tree.get(snap2, "key2")).?;
    try std.testing.expectEqualStrings("val1", r2_k1.getValue());
    try std.testing.expectEqualStrings("val2", r2_k2.getValue());

    const r1_k1 = (try tree.get(snap1, "key1")).?;
    try std.testing.expectEqualStrings("val1", r1_k1.getValue());
    try std.testing.expect((try tree.get(snap1, "key2")) == null);

    try std.testing.expect((try tree.get(snap0, "key1")) == null);
}

test "B-Tree node split and multi-key retrieval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = PageStore.init(alloc);
    defer store.deinit();

    var tree = try CowBTree.init(&store);

    var buf_k: [16]u8 = undefined;
    var buf_v: [16]u8 = undefined;
    for (0..20) |i| {
        const k = std.fmt.bufPrint(&buf_k, "key_{d:0>3}", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&buf_v, "val_{d:0>3}", .{i}) catch unreachable;
        _ = try tree.put(k, v);
    }

    for (0..20) |i| {
        const k = std.fmt.bufPrint(&buf_k, "key_{d:0>3}", .{i}) catch unreachable;
        const expected_v = std.fmt.bufPrint(&buf_v, "val_{d:0>3}", .{i}) catch unreachable;
        const kv = (try tree.get(tree.root_id, k)).?;
        try std.testing.expectEqualStrings(expected_v, kv.getValue());
    }
}
