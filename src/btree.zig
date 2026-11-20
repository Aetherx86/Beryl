const std = @import("std");

pub const PAGE_SIZE: usize = 4096;
pub const BTREE_MAGIC: u32 = 0x42455254; // "BERT"
pub const MAX_KEYS: usize = 16;
pub const MIN_KEYS: usize = (MAX_KEYS - 1) / 2; // 7: guarantees byte-budget splits & merges fit in 4KB
pub const MAX_KEY_LEN: usize = 64;
pub const MAX_VAL_LEN: usize = 192;

pub const PageId = u32;
pub const INVALID_PAGE: PageId = 0;

comptime {
    // Prove worst-case (MAX_KEYS - 1) internal node always fits in PAGE_SIZE
    const worst_item_bytes = 2 + MAX_KEY_LEN + 2 + MAX_VAL_LEN;
    const max_safe_internal = @sizeOf(PageHeader) + (MAX_KEYS - 1) * worst_item_bytes + MAX_KEYS * 4;
    std.debug.assert(max_safe_internal <= PAGE_SIZE);

    // Prove worst-case merge of (MIN_KEYS - 1) + 1 + MIN_KEYS keys always fits in PAGE_SIZE
    const max_merged_keys = 2 * MIN_KEYS;
    const max_merged_internal = @sizeOf(PageHeader) + max_merged_keys * worst_item_bytes + (max_merged_keys + 1) * 4;
    std.debug.assert(max_merged_internal <= PAGE_SIZE);
    std.debug.assert(max_merged_keys <= MAX_KEYS);

    // Prove splitting at MAX_KEYS (byte-budget split) leaves both halves >= MIN_KEYS
    const split_mid = MAX_KEYS / 2;
    std.debug.assert(split_mid >= MIN_KEYS);
    std.debug.assert(MAX_KEYS - (split_mid + 1) >= MIN_KEYS);
}

pub const PageHeader = extern struct {
    magic: u32,
    page_id: PageId,
    generation: u64,
    num_keys: u16,
    is_leaf: u8,
    reserved: [9]u8,
    checksum: u32,

    comptime {
        std.debug.assert(@sizeOf(PageHeader) == 32);
    }
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

    pub fn serializedSize(self: *const BTreeNode) usize {
        var size: usize = @sizeOf(PageHeader);
        for (0..self.num_keys) |i| {
            const kv = &self.items[i];
            size += 2 + @as(usize, kv.key_len) + 2 + @as(usize, kv.val_len);
        }
        if (!self.is_leaf) {
            size += (@as(usize, self.num_keys) + 1) * 4;
        }
        return size;
    }

    pub fn trySerialize(self: *const BTreeNode, out_page: *[PAGE_SIZE]u8) !void {
        if (self.num_keys > MAX_KEYS) return error.PageOverflow;
        if (self.serializedSize() > PAGE_SIZE) return error.PageOverflow;

        @memset(out_page, 0);
        var header = PageHeader{
            .magic = BTREE_MAGIC,
            .page_id = self.page_id,
            .generation = self.generation,
            .num_keys = self.num_keys,
            .is_leaf = if (self.is_leaf) 1 else 0,
            .reserved = @splat(0),
            .checksum = 0,
        };

        @memcpy(out_page[0..@sizeOf(PageHeader)], std.mem.asBytes(&header));

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

        // Cover header (with zeroed checksum field) + serialized payload
        const crc = std.hash.Crc32.hash(out_page[0..offset]);
        header.checksum = crc;
        @memcpy(out_page[0..@sizeOf(PageHeader)], std.mem.asBytes(&header));
    }

    pub fn serialize(self: *const BTreeNode, out_page: *[PAGE_SIZE]u8) void {
        self.trySerialize(out_page) catch @panic("BTreeNode exceeds PAGE_SIZE");
    }

    pub fn deserialize(in_page: *const [PAGE_SIZE]u8) !BTreeNode {
        var header: PageHeader = undefined;
        @memcpy(std.mem.asBytes(&header), in_page[0..@sizeOf(PageHeader)]);
        if (header.magic != BTREE_MAGIC) return error.InvalidBTreeMagic;
        if (header.is_leaf > 1) return error.PageCorrupted;
        if (header.num_keys > MAX_KEYS) return error.PageCorrupted;

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

        // Recompute CRC32 over header (with zeroed checksum slot) + payload
        const checksum_offset = @offsetOf(PageHeader, "checksum");
        const zero_crc = [4]u8{ 0, 0, 0, 0 };
        var hasher = std.hash.Crc32.init();
        hasher.update(in_page[0..checksum_offset]);
        hasher.update(&zero_crc);
        hasher.update(in_page[@sizeOf(PageHeader)..offset]);
        if (hasher.final() != header.checksum) {
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

    pub fn allocatedPageCount(self: *const PageStore) usize {
        return self.pages.items.len;
    }

    pub fn allocatePage(self: *PageStore) !PageId {
        if (self.next_page_id == std.math.maxInt(PageId)) return error.PageIdExhausted;
        const pid = self.next_page_id;
        var zero_page: [PAGE_SIZE]u8 = undefined;
        @memset(&zero_page, 0);
        try self.pages.append(self.allocator, zero_page);
        self.next_page_id += 1;
        return pid;
    }

    pub fn getPage(self: *PageStore, pid: PageId) !*[PAGE_SIZE]u8 {
        if (pid == 0 or pid >= self.next_page_id) return error.InvalidPageId;
        const idx = pid - 1;
        return &self.pages.items[idx];
    }

    pub fn getPageConst(self: *const PageStore, pid: PageId) !*const [PAGE_SIZE]u8 {
        if (pid == 0 or pid >= self.next_page_id) return error.InvalidPageId;
        const idx = pid - 1;
        return &self.pages.items[idx];
    }

    pub fn readNode(self: *const PageStore, pid: PageId) !BTreeNode {
        const page = try self.getPageConst(pid);
        return try BTreeNode.deserialize(page);
    }

    pub fn writeNode(self: *PageStore, node: *const BTreeNode) !void {
        const page = try self.getPage(node.page_id);
        try node.trySerialize(page);
    }

    /// Recursively clones the reachable B-Tree rooted at `pid` into `dest`,
    /// preserving CoW sharing for any pages already mapped in `remap`.
    pub fn cloneReachableSubtree(
        self: *const PageStore,
        dest: *PageStore,
        pid: PageId,
        remap: *std.AutoHashMap(PageId, PageId),
    ) !PageId {
        if (remap.get(pid)) |existing_new_pid| {
            return existing_new_pid;
        }

        var node = try self.readNode(pid);
        if (!node.is_leaf) {
            for (0..node.num_keys + 1) |i| {
                node.children[i] = try self.cloneReachableSubtree(dest, node.children[i], remap);
            }
        }

        const new_pid = try dest.allocatePage();
        node.page_id = new_pid;
        try dest.writeNode(&node);
        try remap.put(pid, new_pid);
        return new_pid;
    }
};

pub const RangeOptions = struct {
    start_key: ?[]const u8 = null,
    end_key: ?[]const u8 = null,
    inclusive_end: bool = false,
    limit: ?usize = null,
};

pub const DeleteOutcome = struct {
    root_id: PageId,
    deleted: bool,
};

pub const TreeStats = struct {
    root_page_id: PageId,
    generation: u64,
    height: usize,
    key_count: usize,
    leaf_pages: usize,
    internal_pages: usize,
    reachable_pages: usize,
    total_allocated_pages: usize,
    dead_pages: usize,
    avg_fill_factor: f64,
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

    fn lowerBound(node: *const BTreeNode, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = node.num_keys;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, node.items[mid].getKey(), key) == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    pub fn get(self: *const CowBTree, root_id: PageId, key: []const u8) !?KeyValue {
        var current_pid = root_id;
        while (current_pid != INVALID_PAGE) {
            const node = try self.store.readNode(current_pid);
            const i = lowerBound(&node, key);

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
        const kv = try KeyValue.init(key, value);
        const next_gen = self.generation + 1;
        const prev_gen = self.generation;
        self.generation = next_gen;
        errdefer self.generation = prev_gen;

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

    fn splitLeafNode(self: *CowBTree, left_node: *BTreeNode) !InsertResult {
        const mid: usize = left_node.num_keys / 2;
        const median_kv = left_node.items[mid];
        const right_pid = try self.store.allocatePage();
        var right_node = BTreeNode.initEmpty(right_pid, true, self.generation);

        for (mid + 1..left_node.num_keys) |k| {
            right_node.items[k - (mid + 1)] = left_node.items[k];
        }
        right_node.num_keys = @as(u16, @intCast(left_node.num_keys - (mid + 1)));
        left_node.num_keys = @as(u16, @intCast(mid));

        try self.store.writeNode(left_node);
        try self.store.writeNode(&right_node);

        return .{
            .new_page_id = left_node.page_id,
            .split = .{
                .median = median_kv,
                .right_pid = right_pid,
            },
        };
    }

    fn splitInternalNode(self: *CowBTree, left_node: *BTreeNode) !InsertResult {
        const mid: usize = left_node.num_keys / 2;
        const median_kv = left_node.items[mid];
        const right_pid = try self.store.allocatePage();
        var right_node = BTreeNode.initEmpty(right_pid, false, self.generation);

        for (mid + 1..left_node.num_keys) |k| {
            right_node.items[k - (mid + 1)] = left_node.items[k];
        }
        for (mid + 1..left_node.num_keys + 1) |k| {
            right_node.children[k - (mid + 1)] = left_node.children[k];
        }
        right_node.num_keys = @as(u16, @intCast(left_node.num_keys - (mid + 1)));
        left_node.num_keys = @as(u16, @intCast(mid));

        try self.store.writeNode(left_node);
        try self.store.writeNode(&right_node);

        return .{
            .new_page_id = left_node.page_id,
            .split = .{
                .median = median_kv,
                .right_pid = right_pid,
            },
        };
    }

    fn insertSplitIntoInternal(node: *BTreeNode, idx: usize, split: SplitResult) void {
        var j: usize = node.num_keys;
        while (j > idx) : (j -= 1) {
            node.items[j] = node.items[j - 1];
            node.children[j + 1] = node.children[j];
        }
        node.items[idx] = split.median;
        node.children[idx + 1] = split.right_pid;
        node.num_keys += 1;
    }

    fn nodeNeedsSplit(node: *const BTreeNode) bool {
        return node.num_keys > MAX_KEYS or node.serializedSize() > PAGE_SIZE;
    }

    fn insertNode(self: *CowBTree, pid: PageId, kv: KeyValue) !InsertResult {
        const old_node = try self.store.readNode(pid);
        var new_node = old_node;
        new_node.generation = self.generation;

        const new_pid = try self.store.allocatePage();
        new_node.page_id = new_pid;

        const i = lowerBound(&new_node, kv.getKey());

        if (new_node.is_leaf) {
            if (i < new_node.num_keys and std.mem.order(u8, kv.getKey(), new_node.items[i].getKey()) == .eq) {
                new_node.items[i] = kv;
                if (!nodeNeedsSplit(&new_node)) {
                    try self.store.writeNode(&new_node);
                    return .{ .new_page_id = new_pid, .split = null };
                }
                return try self.splitLeafNode(&new_node);
            }

            var j: usize = new_node.num_keys;
            while (j > i) : (j -= 1) {
                new_node.items[j] = new_node.items[j - 1];
            }
            new_node.items[i] = kv;
            new_node.num_keys += 1;

            if (!nodeNeedsSplit(&new_node)) {
                try self.store.writeNode(&new_node);
                return .{ .new_page_id = new_pid, .split = null };
            }

            return try self.splitLeafNode(&new_node);
        } else {
            // Classic B-Tree: update key directly if stored in this internal node
            if (i < new_node.num_keys and std.mem.order(u8, kv.getKey(), new_node.items[i].getKey()) == .eq) {
                new_node.items[i] = kv;
                if (!nodeNeedsSplit(&new_node)) {
                    try self.store.writeNode(&new_node);
                    return .{ .new_page_id = new_pid, .split = null };
                }
                return try self.splitInternalNode(&new_node);
            }

            const child_pid = new_node.children[i];
            const child_res = try self.insertNode(child_pid, kv);
            new_node.children[i] = child_res.new_page_id;

            if (child_res.split) |split| {
                insertSplitIntoInternal(&new_node, i, split);

                if (!nodeNeedsSplit(&new_node)) {
                    try self.store.writeNode(&new_node);
                    return .{ .new_page_id = new_pid, .split = null };
                }

                return try self.splitInternalNode(&new_node);
            } else {
                try self.store.writeNode(&new_node);
                return .{ .new_page_id = new_pid, .split = null };
            }
        }
    }

    const DeleteNodeResult = struct {
        new_page_id: PageId,
        deleted: bool,
        underflow: bool,
        split: ?SplitResult = null,
    };

    const ExtractMaxResult = struct {
        kv: KeyValue,
        new_page_id: PageId,
        underflow: bool,
        split: ?SplitResult = null,
    };

    pub fn delete(self: *CowBTree, key: []const u8) !DeleteOutcome {
        if (key.len > MAX_KEY_LEN) return error.KeyValueTooLarge;

        // Avoid allocating CoW pages if key is absent
        if ((try self.get(self.root_id, key)) == null) {
            return .{ .root_id = self.root_id, .deleted = false };
        }

        const prev_gen = self.generation;
        self.generation = prev_gen + 1;
        errdefer self.generation = prev_gen;

        const res = try self.deleteNode(self.root_id, key);
        if (!res.deleted) {
            self.generation = prev_gen;
            return .{ .root_id = self.root_id, .deleted = false };
        }

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
            const new_root = try self.store.readNode(res.new_page_id);
            if (!new_root.is_leaf and new_root.num_keys == 0) {
                self.root_id = new_root.children[0];
            } else {
                self.root_id = res.new_page_id;
            }
        }

        return .{ .root_id = self.root_id, .deleted = true };
    }

    fn deleteNode(self: *CowBTree, pid: PageId, key: []const u8) !DeleteNodeResult {
        const old_node = try self.store.readNode(pid);
        const i = lowerBound(&old_node, key);

        if (old_node.is_leaf) {
            if (i >= old_node.num_keys or std.mem.order(u8, key, old_node.items[i].getKey()) != .eq) {
                return .{ .new_page_id = pid, .deleted = false, .underflow = false };
            }

            const new_pid = try self.store.allocatePage();
            var new_node = old_node;
            new_node.page_id = new_pid;
            new_node.generation = self.generation;

            var j: usize = i;
            while (j + 1 < new_node.num_keys) : (j += 1) {
                new_node.items[j] = new_node.items[j + 1];
            }
            new_node.num_keys -= 1;

            try self.store.writeNode(&new_node);
            return .{
                .new_page_id = new_pid,
                .deleted = true,
                .underflow = new_node.num_keys < MIN_KEYS,
            };
        }

        if (i < old_node.num_keys and std.mem.order(u8, key, old_node.items[i].getKey()) == .eq) {
            // Key resides in this internal node: replace with in-order predecessor from children[i]
            const ext = try self.extractMax(old_node.children[i]);

            const new_pid = try self.store.allocatePage();
            var new_node = old_node;
            new_node.page_id = new_pid;
            new_node.generation = self.generation;

            new_node.items[i] = ext.kv;
            new_node.children[i] = ext.new_page_id;

            if (ext.split) |split| {
                insertSplitIntoInternal(&new_node, i, split);
            } else if (ext.underflow) {
                try self.rebalanceChild(&new_node, i);
            }

            return try self.finishInternalDelete(&new_node);
        }

        const child_res = try self.deleteNode(old_node.children[i], key);
        if (!child_res.deleted) {
            return .{ .new_page_id = pid, .deleted = false, .underflow = false };
        }

        const new_pid = try self.store.allocatePage();
        var new_node = old_node;
        new_node.page_id = new_pid;
        new_node.generation = self.generation;
        new_node.children[i] = child_res.new_page_id;

        if (child_res.split) |split| {
            insertSplitIntoInternal(&new_node, i, split);
        } else if (child_res.underflow) {
            try self.rebalanceChild(&new_node, i);
        }

        return try self.finishInternalDelete(&new_node);
    }

    fn finishInternalDelete(self: *CowBTree, node: *BTreeNode) !DeleteNodeResult {
        if (nodeNeedsSplit(node)) {
            const split_res = try self.splitInternalNode(node);
            return .{
                .new_page_id = split_res.new_page_id,
                .deleted = true,
                .underflow = false,
                .split = split_res.split,
            };
        }
        try self.store.writeNode(node);
        return .{
            .new_page_id = node.page_id,
            .deleted = true,
            .underflow = node.num_keys < MIN_KEYS,
        };
    }

    fn extractMax(self: *CowBTree, pid: PageId) !ExtractMaxResult {
        const old_node = try self.store.readNode(pid);
        const new_pid = try self.store.allocatePage();
        var new_node = old_node;
        new_node.page_id = new_pid;
        new_node.generation = self.generation;

        if (new_node.is_leaf) {
            std.debug.assert(new_node.num_keys > 0);
            const max_kv = new_node.items[new_node.num_keys - 1];
            new_node.num_keys -= 1;
            try self.store.writeNode(&new_node);
            return .{
                .kv = max_kv,
                .new_page_id = new_pid,
                .underflow = new_node.num_keys < MIN_KEYS,
            };
        }

        const last_child_idx: usize = new_node.num_keys;
        const child_ext = try self.extractMax(new_node.children[last_child_idx]);
        new_node.children[last_child_idx] = child_ext.new_page_id;

        if (child_ext.split) |split| {
            insertSplitIntoInternal(&new_node, last_child_idx, split);
        } else if (child_ext.underflow) {
            try self.rebalanceChild(&new_node, last_child_idx);
        }

        if (nodeNeedsSplit(&new_node)) {
            const split_res = try self.splitInternalNode(&new_node);
            return .{
                .kv = child_ext.kv,
                .new_page_id = split_res.new_page_id,
                .underflow = false,
                .split = split_res.split,
            };
        }

        try self.store.writeNode(&new_node);
        return .{
            .kv = child_ext.kv,
            .new_page_id = new_pid,
            .underflow = new_node.num_keys < MIN_KEYS,
        };
    }

    fn rebalanceChild(self: *CowBTree, parent: *BTreeNode, idx: usize) !void {
        var child = try self.store.readNode(parent.children[idx]);

        // Try borrowing from left sibling
        if (idx > 0) {
            var left = try self.store.readNode(parent.children[idx - 1]);
            if (left.num_keys > MIN_KEYS) {
                const new_left_pid = try self.store.allocatePage();
                left.page_id = new_left_pid;
                left.generation = self.generation;

                const new_child_pid = try self.store.allocatePage();
                child.page_id = new_child_pid;
                child.generation = self.generation;

                // Shift child items right by 1
                var j: usize = child.num_keys;
                while (j > 0) : (j -= 1) {
                    child.items[j] = child.items[j - 1];
                }
                if (!child.is_leaf) {
                    var c: usize = child.num_keys + 1;
                    while (c > 0) : (c -= 1) {
                        child.children[c] = child.children[c - 1];
                    }
                    child.children[0] = left.children[left.num_keys];
                }

                child.items[0] = parent.items[idx - 1];
                child.num_keys += 1;

                parent.items[idx - 1] = left.items[left.num_keys - 1];
                left.num_keys -= 1;
                parent.children[idx - 1] = new_left_pid;
                parent.children[idx] = new_child_pid;

                try self.store.writeNode(&left);
                try self.store.writeNode(&child);
                return;
            }
        }

        // Try borrowing from right sibling
        if (idx < parent.num_keys) {
            var right = try self.store.readNode(parent.children[idx + 1]);
            if (right.num_keys > MIN_KEYS) {
                const new_right_pid = try self.store.allocatePage();
                right.page_id = new_right_pid;
                right.generation = self.generation;

                const new_child_pid = try self.store.allocatePage();
                child.page_id = new_child_pid;
                child.generation = self.generation;

                child.items[child.num_keys] = parent.items[idx];
                if (!child.is_leaf) {
                    child.children[child.num_keys + 1] = right.children[0];
                }
                child.num_keys += 1;

                parent.items[idx] = right.items[0];
                for (0..right.num_keys - 1) |k| {
                    right.items[k] = right.items[k + 1];
                }
                if (!right.is_leaf) {
                    for (0..right.num_keys) |k| {
                        right.children[k] = right.children[k + 1];
                    }
                }
                right.num_keys -= 1;
                parent.children[idx] = new_child_pid;
                parent.children[idx + 1] = new_right_pid;

                try self.store.writeNode(&right);
                try self.store.writeNode(&child);
                return;
            }
        }

        // Merge with left or right sibling
        if (idx > 0) {
            var merged = try self.store.readNode(parent.children[idx - 1]);
            const merged_pid = try self.store.allocatePage();
            merged.page_id = merged_pid;
            merged.generation = self.generation;

            const base: usize = merged.num_keys;
            merged.items[base] = parent.items[idx - 1];
            for (0..child.num_keys) |k| {
                merged.items[base + 1 + k] = child.items[k];
            }
            if (!merged.is_leaf) {
                for (0..child.num_keys + 1) |k| {
                    merged.children[base + 1 + k] = child.children[k];
                }
            }
            merged.num_keys = @as(u16, @intCast(base + 1 + child.num_keys));
            try self.store.writeNode(&merged);

            parent.children[idx - 1] = merged_pid;
            var j: usize = idx - 1;
            while (j + 1 < parent.num_keys) : (j += 1) {
                parent.items[j] = parent.items[j + 1];
                parent.children[j + 1] = parent.children[j + 2];
            }
            parent.num_keys -= 1;
        } else {
            const right = try self.store.readNode(parent.children[1]);
            const merged_pid = try self.store.allocatePage();
            child.page_id = merged_pid;
            child.generation = self.generation;

            const base: usize = child.num_keys;
            child.items[base] = parent.items[0];
            for (0..right.num_keys) |k| {
                child.items[base + 1 + k] = right.items[k];
            }
            if (!child.is_leaf) {
                for (0..right.num_keys + 1) |k| {
                    child.children[base + 1 + k] = right.children[k];
                }
            }
            child.num_keys = @as(u16, @intCast(base + 1 + right.num_keys));
            try self.store.writeNode(&child);

            parent.children[0] = merged_pid;
            var j: usize = 0;
            while (j + 1 < parent.num_keys) : (j += 1) {
                parent.items[j] = parent.items[j + 1];
                parent.children[j + 1] = parent.children[j + 2];
            }
            parent.num_keys -= 1;
        }
    }

    pub fn scanRange(
        self: *const CowBTree,
        allocator: std.mem.Allocator,
        root_id: PageId,
        opts: RangeOptions,
    ) ![]KeyValue {
        var results: std.ArrayList(KeyValue) = .empty;
        errdefer results.deinit(allocator);

        if (opts.limit) |lim| {
            if (lim == 0) return try results.toOwnedSlice(allocator);
        }
        if (opts.start_key) |sk| {
            if (opts.end_key) |ek| {
                const ord = std.mem.order(u8, sk, ek);
                if (ord == .gt or (ord == .eq and !opts.inclusive_end)) {
                    return try results.toOwnedSlice(allocator);
                }
            }
        }

        _ = try self.scanNode(allocator, root_id, opts, &results);
        return try results.toOwnedSlice(allocator);
    }

    fn scanNode(
        self: *const CowBTree,
        allocator: std.mem.Allocator,
        pid: PageId,
        opts: RangeOptions,
        results: *std.ArrayList(KeyValue),
    ) !bool {
        if (opts.limit) |lim| {
            if (results.items.len >= lim) return true;
        }

        const node = try self.store.readNode(pid);
        const start_idx: usize = if (opts.start_key) |sk| lowerBound(&node, sk) else 0;

        var i: usize = start_idx;
        while (i <= node.num_keys) : (i += 1) {
            if (!node.is_leaf) {
                const skip_left_child = (i == start_idx) and
                    (opts.start_key != null) and
                    (i < node.num_keys) and
                    (std.mem.order(u8, node.items[i].getKey(), opts.start_key.?) == .eq);

                if (!skip_left_child) {
                    const done = try self.scanNode(allocator, node.children[i], opts, results);
                    if (done) return true;
                }
            }

            if (i < node.num_keys) {
                const item = &node.items[i];
                var hit_exact_inclusive_end = false;
                if (opts.end_key) |ek| {
                    const ord = std.mem.order(u8, item.getKey(), ek);
                    if (ord == .gt or (ord == .eq and !opts.inclusive_end)) {
                        return true;
                    }
                    if (ord == .eq and opts.inclusive_end) {
                        hit_exact_inclusive_end = true;
                    }
                }

                try results.append(allocator, item.*);
                if (opts.limit) |lim| {
                    if (results.items.len >= lim) return true;
                }
                if (hit_exact_inclusive_end) {
                    return true;
                }
            }
        }

        return false;
    }

    pub fn scanPrefix(
        self: *const CowBTree,
        allocator: std.mem.Allocator,
        root_id: PageId,
        prefix: []const u8,
        limit: ?usize,
    ) ![]KeyValue {
        if (prefix.len == 0) {
            return try self.scanRange(allocator, root_id, .{ .limit = limit });
        }
        if (prefix.len > MAX_KEY_LEN) {
            return try allocator.alloc(KeyValue, 0);
        }

        var upper_buf: [MAX_KEY_LEN]u8 = undefined;
        @memcpy(upper_buf[0..prefix.len], prefix);
        var upper_len: ?usize = null;

        var idx: usize = prefix.len;
        while (idx > 0) {
            idx -= 1;
            if (upper_buf[idx] < 0xFF) {
                upper_buf[idx] += 1;
                upper_len = idx + 1;
                break;
            }
        }

        const end_key: ?[]const u8 = if (upper_len) |len| upper_buf[0..len] else null;
        return try self.scanRange(allocator, root_id, .{
            .start_key = prefix,
            .end_key = end_key,
            .inclusive_end = false,
            .limit = limit,
        });
    }

    pub fn count(self: *const CowBTree, root_id: PageId) !usize {
        return try self.countNode(root_id);
    }

    fn countNode(self: *const CowBTree, pid: PageId) !usize {
        const node = try self.store.readNode(pid);
        var total: usize = node.num_keys;
        if (!node.is_leaf) {
            for (0..node.num_keys + 1) |i| {
                total += try self.countNode(node.children[i]);
            }
        }
        return total;
    }

    const VerifyAcc = struct {
        leaf_depth: ?usize = null,
        key_count: usize = 0,
        leaf_pages: usize = 0,
        internal_pages: usize = 0,
        visited_pages: usize = 0,
        max_pages: usize,
    };

    /// Validates all B-Tree structural, ordering, balance, and CRC32 invariants
    /// for the tree rooted at `root_id`, returning computed statistics.
    pub fn verify(self: *const CowBTree, root_id: PageId) !TreeStats {
        var acc = VerifyAcc{
            .max_pages = self.store.allocatedPageCount(),
        };
        try self.verifyNode(root_id, 0, true, null, null, &acc);

        const reachable = acc.leaf_pages + acc.internal_pages;
        const total_alloc = self.store.allocatedPageCount();
        const dead = if (total_alloc >= reachable) total_alloc - reachable else 0;
        const capacity = reachable * MAX_KEYS;
        const fill = if (capacity > 0)
            @as(f64, @floatFromInt(acc.key_count)) / @as(f64, @floatFromInt(capacity))
        else
            0.0;

        return .{
            .root_page_id = root_id,
            .generation = self.generation,
            .height = (acc.leaf_depth orelse 0) + 1,
            .key_count = acc.key_count,
            .leaf_pages = acc.leaf_pages,
            .internal_pages = acc.internal_pages,
            .reachable_pages = reachable,
            .total_allocated_pages = total_alloc,
            .dead_pages = dead,
            .avg_fill_factor = fill,
        };
    }

    pub fn stats(self: *const CowBTree, root_id: PageId) !TreeStats {
        return try self.verify(root_id);
    }

    fn verifyNode(
        self: *const CowBTree,
        pid: PageId,
        depth: usize,
        is_root: bool,
        min_bound: ?[]const u8,
        max_bound: ?[]const u8,
        acc: *VerifyAcc,
    ) !void {
        acc.visited_pages += 1;
        if (acc.visited_pages > acc.max_pages) return error.CycleDetected;

        const node = try self.store.readNode(pid);
        if (node.page_id != pid) return error.PageIdMismatch;

        if (is_root) {
            if (!node.is_leaf and node.num_keys == 0) return error.EmptyInternalRoot;
        } else {
            if (node.num_keys < MIN_KEYS) return error.UnderflowViolation;
        }

        for (0..node.num_keys) |i| {
            const k = node.items[i].getKey();
            if (min_bound) |mb| {
                if (std.mem.order(u8, mb, k) != .lt) return error.BoundsViolation;
            }
            if (max_bound) |xb| {
                if (std.mem.order(u8, k, xb) != .lt) return error.BoundsViolation;
            }
            if (i > 0) {
                if (std.mem.order(u8, node.items[i - 1].getKey(), k) != .lt) {
                    return error.KeyOrderViolation;
                }
            }
        }

        acc.key_count += node.num_keys;

        if (node.is_leaf) {
            acc.leaf_pages += 1;
            if (acc.leaf_depth) |expected_depth| {
                if (depth != expected_depth) return error.HeightMismatch;
            } else {
                acc.leaf_depth = depth;
            }
        } else {
            acc.internal_pages += 1;
            for (0..node.num_keys + 1) |i| {
                const child_pid = node.children[i];
                if (child_pid == INVALID_PAGE) return error.InvalidChildPointer;

                const child_min: ?[]const u8 = if (i == 0) min_bound else node.items[i - 1].getKey();
                const child_max: ?[]const u8 = if (i == node.num_keys) max_bound else node.items[i].getKey();
                try self.verifyNode(child_pid, depth + 1, false, child_min, child_max, acc);
            }
        }
    }
};

test "B-Tree serialization, deserialization, and header checksum integrity" {
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

    // Tampering with generation in the header must fail checksum verification
    var tampered = page;
    tampered[8] ^= 0x01;
    try std.testing.expectError(error.ChecksumMismatch, BTreeNode.deserialize(&tampered));

    // Malformed num_keys > MAX_KEYS must fail safely without panicking
    var corrupt_keys = page;
    std.mem.writeInt(u16, corrupt_keys[@offsetOf(PageHeader, "num_keys")..][0..2], MAX_KEYS + 5, .little);
    try std.testing.expectError(error.PageCorrupted, BTreeNode.deserialize(&corrupt_keys));
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
    const del_out = try tree.delete("key1");
    try std.testing.expect(del_out.deleted);
    const snap3 = del_out.root_id;

    try std.testing.expect((try tree.get(snap3, "key1")) == null);
    try std.testing.expectEqualStrings("val2", (try tree.get(snap3, "key2")).?.getValue());

    const r2_k1 = (try tree.get(snap2, "key1")).?;
    const r2_k2 = (try tree.get(snap2, "key2")).?;
    try std.testing.expectEqualStrings("val1", r2_k1.getValue());
    try std.testing.expectEqualStrings("val2", r2_k2.getValue());

    const r1_k1 = (try tree.get(snap1, "key1")).?;
    try std.testing.expectEqualStrings("val1", r1_k1.getValue());
    try std.testing.expect((try tree.get(snap1, "key2")) == null);

    try std.testing.expect((try tree.get(snap0, "key1")) == null);
}

test "B-Tree node split, promoted-key updates, and multi-key retrieval" {
    var store = PageStore.init(std.testing.allocator);
    defer store.deinit();

    var tree = try CowBTree.init(&store);

    var buf_k: [16]u8 = undefined;
    var buf_v: [16]u8 = undefined;
    for (0..64) |i| {
        const k = std.fmt.bufPrint(&buf_k, "key_{d:0>3}", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&buf_v, "val_{d:0>3}", .{i}) catch unreachable;
        _ = try tree.put(k, v);
    }

    const snap_before_update = tree.root_id;
    _ = try tree.verify(snap_before_update);

    // Update EVERY key including promoted internal-node median keys!
    for (0..64) |i| {
        const k = std.fmt.bufPrint(&buf_k, "key_{d:0>3}", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&buf_v, "upd_{d:0>3}", .{i}) catch unreachable;
        _ = try tree.put(k, v);
    }
    const stats = try tree.verify(tree.root_id);
    try std.testing.expectEqual(@as(usize, 64), stats.key_count);

    for (0..64) |i| {
        const k = std.fmt.bufPrint(&buf_k, "key_{d:0>3}", .{i}) catch unreachable;
        const expected_new = std.fmt.bufPrint(&buf_v, "upd_{d:0>3}", .{i}) catch unreachable;
        const kv_new = (try tree.get(tree.root_id, k)).?;
        try std.testing.expectEqualStrings(expected_new, kv_new.getValue());

        // Historical snapshot still retains original values
        const expected_old = std.fmt.bufPrint(&buf_v, "val_{d:0>3}", .{i}) catch unreachable;
        const kv_old = (try tree.get(snap_before_update, k)).?;
        try std.testing.expectEqualStrings(expected_old, kv_old.getValue());
    }
}

test "B-Tree byte-budget splitting with max-size 64B keys and 192B values" {
    var store = PageStore.init(std.testing.allocator);
    defer store.deinit();

    var tree = try CowBTree.init(&store);

    var key_buf: [MAX_KEY_LEN]u8 = undefined;
    var val_buf: [MAX_VAL_LEN]u8 = undefined;

    // Insert 40 maximal-length entries (260 bytes serialized each)
    for (0..40) |i| {
        @memset(&key_buf, 'k');
        @memset(&val_buf, 'v');
        _ = std.fmt.bufPrint(key_buf[0..12], "maxk_{d:0>6}_", .{i}) catch unreachable;
        _ = std.fmt.bufPrint(val_buf[0..12], "maxv_{d:0>6}_", .{i}) catch unreachable;
        _ = try tree.put(&key_buf, &val_buf);
        _ = try tree.verify(tree.root_id);
    }

    const st = try tree.verify(tree.root_id);
    try std.testing.expectEqual(@as(usize, 40), st.key_count);

    // Delete all 40 maximal-length entries in reverse order and verify every step
    var idx: usize = 40;
    while (idx > 0) {
        idx -= 1;
        @memset(&key_buf, 'k');
        _ = std.fmt.bufPrint(key_buf[0..12], "maxk_{d:0>6}_", .{idx}) catch unreachable;
        const out = try tree.delete(&key_buf);
        try std.testing.expect(out.deleted);
        _ = try tree.verify(tree.root_id);
    }
    try std.testing.expectEqual(@as(usize, 0), try tree.count(tree.root_id));
}

test "B-Tree range scan and prefix scan with historical snapshots" {
    var store = PageStore.init(std.testing.allocator);
    defer store.deinit();

    var tree = try CowBTree.init(&store);

    var buf_k: [32]u8 = undefined;
    var buf_v: [32]u8 = undefined;
    for (0..50) |i| {
        const prefix = if (i < 20) "alpha:" else if (i < 35) "beta:" else "gamma:";
        const k = std.fmt.bufPrint(&buf_k, "{s}{d:0>3}", .{ prefix, i }) catch unreachable;
        const v = std.fmt.bufPrint(&buf_v, "v{d}", .{i}) catch unreachable;
        _ = try tree.put(k, v);
    }

    const full_snap = tree.root_id;

    // Range scan [alpha:010, beta:025) exclusive
    const range_excl = try tree.scanRange(std.testing.allocator, full_snap, .{
        .start_key = "alpha:010",
        .end_key = "beta:025",
        .inclusive_end = false,
    });
    defer std.testing.allocator.free(range_excl);
    try std.testing.expectEqual(@as(usize, 15), range_excl.len);
    try std.testing.expectEqualStrings("alpha:010", range_excl[0].getKey());
    try std.testing.expectEqualStrings("beta:024", range_excl[range_excl.len - 1].getKey());

    // Range scan [alpha:010, beta:025] inclusive with limit
    const range_incl = try tree.scanRange(std.testing.allocator, full_snap, .{
        .start_key = "alpha:010",
        .end_key = "beta:025",
        .inclusive_end = true,
    });
    defer std.testing.allocator.free(range_incl);
    try std.testing.expectEqual(@as(usize, 16), range_incl.len);
    try std.testing.expectEqualStrings("beta:025", range_incl[range_incl.len - 1].getKey());

    const range_limited = try tree.scanRange(std.testing.allocator, full_snap, .{
        .start_key = "alpha:010",
        .limit = 5,
    });
    defer std.testing.allocator.free(range_limited);
    try std.testing.expectEqual(@as(usize, 5), range_limited.len);

    // Prefix scan
    const betas = try tree.scanPrefix(std.testing.allocator, full_snap, "beta:", null);
    defer std.testing.allocator.free(betas);
    try std.testing.expectEqual(@as(usize, 15), betas.len);
    try std.testing.expectEqualStrings("beta:020", betas[0].getKey());
    try std.testing.expectEqualStrings("beta:034", betas[14].getKey());

    // Prefix scan with 0xFF bytes
    _ = try tree.put("\xff\xffa", "1");
    _ = try tree.put("\xff\xffb", "2");
    const ff_res = try tree.scanPrefix(std.testing.allocator, tree.root_id, "\xff\xff", null);
    defer std.testing.allocator.free(ff_res);
    try std.testing.expectEqual(@as(usize, 2), ff_res.len);
}

test "B-Tree randomized differential model test (put, update, delete, scan, verify)" {
    var store = PageStore.init(std.testing.allocator);
    defer store.deinit();

    var tree = try CowBTree.init(&store);

    var oracle = std.StringHashMap([]u8).init(std.testing.allocator);
    defer {
        var it = oracle.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        oracle.deinit();
    }

    var prng = std.Random.DefaultPrng.init(0xBEEF_CAFE_2026);
    const rng = prng.random();

    var kbuf: [32]u8 = undefined;
    var vbuf: [64]u8 = undefined;

    const key_space: usize = 120;

    // 450 randomized operations covering splits, updates, borrows, merges, and root collapses
    for (0..450) |step| {
        const key_num = rng.uintLessThan(usize, key_space);
        const key = std.fmt.bufPrint(&kbuf, "k_{d:0>3}", .{key_num}) catch unreachable;

        const op = rng.uintLessThan(u8, 100);
        if (op < 60) {
            // Put or update
            const val = std.fmt.bufPrint(&vbuf, "val_step_{d}_k_{d}", .{ step, key_num }) catch unreachable;
            _ = try tree.put(key, val);

            if (oracle.getPtr(key)) |existing_val| {
                std.testing.allocator.free(existing_val.*);
                existing_val.* = try std.testing.allocator.dupe(u8, val);
            } else {
                const k_owned = try std.testing.allocator.dupe(u8, key);
                const v_owned = try std.testing.allocator.dupe(u8, val);
                try oracle.put(k_owned, v_owned);
            }
        } else {
            // Delete
            const out = try tree.delete(key);
            if (oracle.fetchRemove(key)) |removed| {
                try std.testing.expect(out.deleted);
                std.testing.allocator.free(removed.key);
                std.testing.allocator.free(removed.value);
            } else {
                try std.testing.expect(!out.deleted);
            }
        }

        // Verify all B-Tree invariants after EVERY single mutation
        const st = try tree.verify(tree.root_id);
        try std.testing.expectEqual(@as(usize, oracle.count()), st.key_count);
    }

    // Full scan must match oracle in strict sorted order
    const all_items = try tree.scanRange(std.testing.allocator, tree.root_id, .{});
    defer std.testing.allocator.free(all_items);
    try std.testing.expectEqual(@as(usize, oracle.count()), all_items.len);

    for (all_items, 0..) |item, idx| {
        if (idx > 0) {
            try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, all_items[idx - 1].getKey(), item.getKey()));
        }
        const expected = oracle.get(item.getKey()).?;
        try std.testing.expectEqualStrings(expected, item.getValue());
    }

    // Drain every remaining key down to an empty tree (tests full collapse to height 1)
    for (all_items) |item| {
        const out = try tree.delete(item.getKey());
        try std.testing.expect(out.deleted);
        _ = try tree.verify(tree.root_id);
    }
    const final_stats = try tree.verify(tree.root_id);
    try std.testing.expectEqual(@as(usize, 0), final_stats.key_count);
    try std.testing.expectEqual(@as(usize, 1), final_stats.height);
}

test "B-Tree value-expansion byte-budget split and 3-level mixed-size rebalancing" {
    var store = PageStore.init(std.testing.allocator);
    defer store.deinit();

    var tree = try CowBTree.init(&store);

    var key_buf: [MAX_KEY_LEN]u8 = undefined;
    var big_val: [MAX_VAL_LEN]u8 = undefined;
    @memset(&big_val, 'X');

    // Fill a single leaf with 16 max-length keys and short values (fits in 4096 bytes)
    for (0..MAX_KEYS) |i| {
        @memset(&key_buf, 'a');
        _ = std.fmt.bufPrint(key_buf[0..10], "k_{d:0>6}_", .{i}) catch unreachable;
        _ = try tree.put(&key_buf, "s");
    }
    try std.testing.expectEqual(@as(usize, 1), (try tree.verify(tree.root_id)).height);

    // Expand all 16 values in place to 192B -> MUST trigger byte-budget split without PageOverflow
    for (0..MAX_KEYS) |i| {
        @memset(&key_buf, 'a');
        _ = std.fmt.bufPrint(key_buf[0..10], "k_{d:0>6}_", .{i}) catch unreachable;
        _ = std.fmt.bufPrint(big_val[0..10], "v_{d:0>6}_", .{i}) catch unreachable;
        _ = try tree.put(&key_buf, &big_val);
        _ = try tree.verify(tree.root_id);
    }
    try std.testing.expect((try tree.verify(tree.root_id)).height >= 2);

    // Grow to a 3-level tree (320 mixed short/max keys)
    for (MAX_KEYS..320) |i| {
        @memset(&key_buf, 'a');
        _ = std.fmt.bufPrint(key_buf[0..10], "k_{d:0>6}_", .{i}) catch unreachable;
        if (i % 3 == 0) {
            _ = std.fmt.bufPrint(big_val[0..10], "v_{d:0>6}_", .{i}) catch unreachable;
            _ = try tree.put(&key_buf, &big_val);
        } else {
            _ = try tree.put(&key_buf, "tiny");
        }
    }
    const peak_snap = tree.root_id;
    const peak_stats = try tree.verify(peak_snap);
    try std.testing.expectEqual(@as(usize, 320), peak_stats.key_count);
    try std.testing.expect(peak_stats.height >= 3);

    // Delete in strided order (hitting internal nodes, borrows, merges, and predecessor replacements)
    var step: usize = 0;
    while (step < 320) : (step += 1) {
        const idx = (step * 73) % 320; // 73 is coprime to 320
        @memset(&key_buf, 'a');
        _ = std.fmt.bufPrint(key_buf[0..10], "k_{d:0>6}_", .{idx}) catch unreachable;
        const out = try tree.delete(&key_buf);
        try std.testing.expect(out.deleted);
        if (step % 10 == 0 or step == 319) {
            _ = try tree.verify(tree.root_id);
        }
    }

    try std.testing.expectEqual(@as(usize, 0), try tree.count(tree.root_id));
    // Peak 3-level snapshot must remain 100% intact and verifiable!
    const snap_check = try tree.verify(peak_snap);
    try std.testing.expectEqual(@as(usize, 320), snap_check.key_count);
}
