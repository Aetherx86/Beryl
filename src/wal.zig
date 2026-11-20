const std = @import("std");

pub const RecordType = enum(u8) {
    put = 1,
    delete = 2,
    commit = 3,
    checkpoint = 4,
    abort = 5,
};

pub const WAL_MAGIC: u32 = 0x42455259; // "BERY"
pub const HEADER_SIZE: usize = 17; // magic(4) + type(1) + id_or_seq(8) + payload_len(4)
pub const TRAILER_SIZE: usize = 4; // crc32(4)
pub const MIN_RECORD_SIZE: usize = HEADER_SIZE + TRAILER_SIZE;

pub const WalRecord = union(RecordType) {
    put: struct {
        tx_id: u64,
        key: []const u8,
        value: []const u8,
    },
    delete: struct {
        tx_id: u64,
        key: []const u8,
    },
    commit: struct {
        tx_id: u64,
        root_page_id: u32,
        generation: u64,
    },
    checkpoint: struct {
        checkpoint_seq: u64,
        root_page_id: u32,
    },
    abort: struct {
        tx_id: u64,
    },
};

pub const WalInspection = struct {
    total_bytes: usize,
    valid_bytes: usize,
    trailing_corrupt_bytes: usize,
    total_records: usize,
    put_records: usize,
    delete_records: usize,
    commit_records: usize,
    abort_records: usize,
    checkpoint_records: usize,
    clean: bool,
    first_error: ?[]const u8,
};

pub const WalWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) WalWriter {
        return .{
            .allocator = allocator,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *WalWriter) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn reset(self: *WalWriter) void {
        self.buffer.clearRetainingCapacity();
    }

    pub fn truncate(self: *WalWriter, new_len: usize) void {
        if (new_len < self.buffer.items.len) {
            self.buffer.items.len = new_len;
        }
    }

    pub fn writtenBytes(self: *const WalWriter) []const u8 {
        return self.buffer.items;
    }

    pub fn appendRecord(self: *WalWriter, record: WalRecord) !void {
        const id_or_seq: u64 = switch (record) {
            .put => |p| p.tx_id,
            .delete => |d| d.tx_id,
            .commit => |c| c.tx_id,
            .checkpoint => |cp| cp.checkpoint_seq,
            .abort => |a| a.tx_id,
        };

        const payload_len_usize: usize = switch (record) {
            .put => |p| blk: {
                if (p.key.len > std.math.maxInt(u16)) return error.KeyTooLarge;
                if (p.value.len > std.math.maxInt(u32) - 6 - p.key.len) return error.ValueTooLarge;
                break :blk 2 + p.key.len + 4 + p.value.len;
            },
            .delete => |d| blk: {
                if (d.key.len > std.math.maxInt(u16)) return error.KeyTooLarge;
                break :blk 2 + d.key.len;
            },
            .commit => 4 + 8,
            .checkpoint => 4,
            .abort => 0,
        };

        const payload_len: u32 = @intCast(payload_len_usize);
        const total_len = HEADER_SIZE + payload_len_usize + TRAILER_SIZE;

        const start = self.buffer.items.len;
        errdefer self.buffer.items.len = start;

        try self.buffer.ensureUnusedCapacity(self.allocator, total_len);
        const frame = self.buffer.addManyAsSliceAssumeCapacity(total_len);

        // Header
        std.mem.writeInt(u32, frame[0..4], WAL_MAGIC, .little);
        frame[4] = @backingInt(record);
        std.mem.writeInt(u64, frame[5..13], id_or_seq, .little);
        std.mem.writeInt(u32, frame[13..17], payload_len, .little);

        // Payload
        const payload = frame[HEADER_SIZE .. HEADER_SIZE + payload_len_usize];
        switch (record) {
            .put => |p| {
                std.mem.writeInt(u16, payload[0..2], @intCast(p.key.len), .little);
                @memcpy(payload[2 .. 2 + p.key.len], p.key);
                std.mem.writeInt(u32, payload[2 + p.key.len ..][0..4], @intCast(p.value.len), .little);
                @memcpy(payload[6 + p.key.len .. 6 + p.key.len + p.value.len], p.value);
            },
            .delete => |d| {
                std.mem.writeInt(u16, payload[0..2], @intCast(d.key.len), .little);
                @memcpy(payload[2 .. 2 + d.key.len], d.key);
            },
            .commit => |c| {
                std.mem.writeInt(u32, payload[0..4], c.root_page_id, .little);
                std.mem.writeInt(u64, payload[4..12], c.generation, .little);
            },
            .checkpoint => |cp| {
                std.mem.writeInt(u32, payload[0..4], cp.root_page_id, .little);
            },
            .abort => {},
        }

        // Trailer CRC32 over header + payload
        const crc = std.hash.Crc32.hash(frame[0 .. HEADER_SIZE + payload_len_usize]);
        std.mem.writeInt(u32, frame[HEADER_SIZE + payload_len_usize ..][0..4], crc, .little);
    }
};

const RawFrame = struct {
    rec_type: RecordType,
    id_or_seq: u64,
    payload: []const u8,
    next_cursor: usize,
};

fn decodeFrame(data: []const u8, start_idx: usize) !RawFrame {
    if (data.len - start_idx < MIN_RECORD_SIZE) {
        return error.TruncatedRecord;
    }

    var pos = start_idx;
    const magic = std.mem.readInt(u32, data[pos..][0..4], .little);
    if (magic != WAL_MAGIC) return error.InvalidMagic;
    pos += 4;

    const raw_type = data[pos];
    pos += 1;
    const rec_type: RecordType = switch (raw_type) {
        1 => .put,
        2 => .delete,
        3 => .commit,
        4 => .checkpoint,
        5 => .abort,
        else => return error.UnknownRecordType,
    };

    const id_or_seq = std.mem.readInt(u64, data[pos..][0..8], .little);
    pos += 8;

    const payload_len: usize = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    // Overflow-safe remaining-bytes check
    const remaining = data.len - pos;
    if (remaining < TRAILER_SIZE or payload_len > remaining - TRAILER_SIZE) {
        return error.TruncatedRecord;
    }

    const payload_start = pos;
    pos += payload_len;

    const recorded_crc = std.mem.readInt(u32, data[pos..][0..4], .little);
    const crc_end = pos;
    pos += TRAILER_SIZE;

    const expected_crc = std.hash.Crc32.hash(data[start_idx..crc_end]);
    if (recorded_crc != expected_crc) {
        return error.ChecksumMismatch;
    }

    const payload = data[payload_start .. payload_start + payload_len];
    try validatePayload(rec_type, payload);

    return .{
        .rec_type = rec_type,
        .id_or_seq = id_or_seq,
        .payload = payload,
        .next_cursor = pos,
    };
}

fn validatePayload(rec_type: RecordType, payload: []const u8) !void {
    switch (rec_type) {
        .put => {
            if (payload.len < 6) return error.InvalidPayload;
            const klen: usize = std.mem.readInt(u16, payload[0..2], .little);
            if (payload.len - 6 < klen) return error.InvalidPayload;
            const vlen: usize = std.mem.readInt(u32, payload[2 + klen ..][0..4], .little);
            if (payload.len - 6 - klen != vlen) return error.InvalidPayload;
        },
        .delete => {
            if (payload.len < 2) return error.InvalidPayload;
            const klen: usize = std.mem.readInt(u16, payload[0..2], .little);
            if (payload.len - 2 != klen) return error.InvalidPayload;
        },
        .commit => {
            if (payload.len != 12) return error.InvalidPayload;
        },
        .checkpoint => {
            if (payload.len != 4) return error.InvalidPayload;
        },
        .abort => {
            if (payload.len != 0) return error.InvalidPayload;
        },
    }
}

pub const WalReader = struct {
    data: []const u8,
    cursor: usize = 0,

    pub fn init(data: []const u8) WalReader {
        return .{
            .data = data,
            .cursor = 0,
        };
    }

    pub fn next(self: *WalReader, arena: std.mem.Allocator) !?WalRecord {
        if (self.cursor >= self.data.len) return null;

        const frame = try decodeFrame(self.data, self.cursor);
        const payload = frame.payload;

        const rec: WalRecord = switch (frame.rec_type) {
            .put => blk: {
                const klen: usize = std.mem.readInt(u16, payload[0..2], .little);
                const k_slice = try arena.alloc(u8, klen);
                errdefer arena.free(k_slice);
                @memcpy(k_slice, payload[2 .. 2 + klen]);

                const vlen: usize = std.mem.readInt(u32, payload[2 + klen ..][0..4], .little);
                const v_slice = try arena.alloc(u8, vlen);
                @memcpy(v_slice, payload[6 + klen .. 6 + klen + vlen]);

                break :blk .{
                    .put = .{
                        .tx_id = frame.id_or_seq,
                        .key = k_slice,
                        .value = v_slice,
                    },
                };
            },
            .delete => blk: {
                const klen: usize = std.mem.readInt(u16, payload[0..2], .little);
                const k_slice = try arena.alloc(u8, klen);
                @memcpy(k_slice, payload[2 .. 2 + klen]);

                break :blk .{
                    .delete = .{
                        .tx_id = frame.id_or_seq,
                        .key = k_slice,
                    },
                };
            },
            .commit => .{
                .commit = .{
                    .tx_id = frame.id_or_seq,
                    .root_page_id = std.mem.readInt(u32, payload[0..4], .little),
                    .generation = std.mem.readInt(u64, payload[4..12], .little),
                },
            },
            .checkpoint => .{
                .checkpoint = .{
                    .checkpoint_seq = frame.id_or_seq,
                    .root_page_id = std.mem.readInt(u32, payload[0..4], .little),
                },
            },
            .abort => .{
                .abort = .{
                    .tx_id = frame.id_or_seq,
                },
            },
        };

        self.cursor = frame.next_cursor;
        return rec;
    }
};

pub fn inspectWal(data: []const u8) WalInspection {
    var report = WalInspection{
        .total_bytes = data.len,
        .valid_bytes = 0,
        .trailing_corrupt_bytes = 0,
        .total_records = 0,
        .put_records = 0,
        .delete_records = 0,
        .commit_records = 0,
        .abort_records = 0,
        .checkpoint_records = 0,
        .clean = true,
        .first_error = null,
    };

    var cursor: usize = 0;
    while (cursor < data.len) {
        const frame = decodeFrame(data, cursor) catch |err| {
            report.clean = false;
            report.first_error = @errorName(err);
            report.valid_bytes = cursor;
            report.trailing_corrupt_bytes = data.len - cursor;
            return report;
        };

        report.total_records += 1;
        switch (frame.rec_type) {
            .put => report.put_records += 1,
            .delete => report.delete_records += 1,
            .commit => report.commit_records += 1,
            .checkpoint => report.checkpoint_records += 1,
            .abort => report.abort_records += 1,
        }
        cursor = frame.next_cursor;
    }

    report.valid_bytes = cursor;
    return report;
}

test "WAL write and read round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var writer = WalWriter.init(alloc);
    defer writer.deinit();

    try writer.appendRecord(.{
        .put = .{ .tx_id = 1, .key = "alpha", .value = "payload-alpha" },
    });
    try writer.appendRecord(.{
        .put = .{ .tx_id = 1, .key = "beta", .value = "payload-beta" },
    });
    try writer.appendRecord(.{
        .delete = .{ .tx_id = 1, .key = "alpha" },
    });
    try writer.appendRecord(.{
        .commit = .{ .tx_id = 1, .root_page_id = 42, .generation = 3 },
    });
    try writer.appendRecord(.{
        .abort = .{ .tx_id = 2 },
    });
    try writer.appendRecord(.{
        .checkpoint = .{ .checkpoint_seq = 2, .root_page_id = 42 },
    });

    var reader = WalReader.init(writer.buffer.items);
    var count: usize = 0;
    while (try reader.next(alloc)) |rec| {
        count += 1;
        switch (count) {
            1 => {
                try std.testing.expectEqualStrings("alpha", rec.put.key);
                try std.testing.expectEqualStrings("payload-alpha", rec.put.value);
            },
            3 => try std.testing.expectEqualStrings("alpha", rec.delete.key),
            4 => {
                try std.testing.expectEqual(@as(u32, 42), rec.commit.root_page_id);
                try std.testing.expectEqual(@as(u64, 3), rec.commit.generation);
            },
            5 => try std.testing.expectEqual(@as(u64, 2), rec.abort.tx_id),
            6 => try std.testing.expectEqual(@as(u32, 42), rec.checkpoint.root_page_id),
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 6), count);

    const insp = inspectWal(writer.buffer.items);
    try std.testing.expect(insp.clean);
    try std.testing.expectEqual(@as(usize, 6), insp.total_records);
    try std.testing.expectEqual(@as(usize, 2), insp.put_records);
    try std.testing.expectEqual(@as(usize, 1), insp.delete_records);
    try std.testing.expectEqual(@as(usize, 1), insp.commit_records);
    try std.testing.expectEqual(@as(usize, 1), insp.abort_records);
    try std.testing.expectEqual(@as(usize, 1), insp.checkpoint_records);
    try std.testing.expectEqual(writer.buffer.items.len, insp.valid_bytes);
}

test "WAL detects bit-flips, truncation, and overflowing payload headers" {
    var writer = WalWriter.init(std.testing.allocator);
    defer writer.deinit();

    try writer.appendRecord(.{
        .put = .{ .tx_id = 7, .key = "sensor:1", .value = "ok" },
    });
    const first_rec_len = writer.buffer.items.len;
    try writer.appendRecord(.{
        .commit = .{ .tx_id = 7, .root_page_id = 9, .generation = 2 },
    });

    // Every single byte bit-flip in the first record must be detected
    const original = try std.testing.allocator.dupe(u8, writer.buffer.items);
    defer std.testing.allocator.free(original);

    for (0..first_rec_len) |idx| {
        const corrupted = try std.testing.allocator.dupe(u8, original);
        defer std.testing.allocator.free(corrupted);
        corrupted[idx] ^= 0x01;

        const insp = inspectWal(corrupted);
        try std.testing.expect(!insp.clean);
        try std.testing.expectEqual(@as(usize, 0), insp.valid_bytes);
    }

    // Truncating anywhere inside the second record must still validate record 1 cleanly
    for (first_rec_len + 1..original.len) |cut| {
        const insp = inspectWal(original[0..cut]);
        try std.testing.expect(!insp.clean);
        try std.testing.expectEqual(@as(usize, 1), insp.total_records);
        try std.testing.expectEqual(first_rec_len, insp.valid_bytes);
        try std.testing.expectEqual(cut - first_rec_len, insp.trailing_corrupt_bytes);
    }

    // Crafted header with payload_len = 0xFFFFFFFF must not integer-overflow
    var crafted: [HEADER_SIZE + TRAILER_SIZE]u8 = undefined;
    @memset(&crafted, 0);
    std.mem.writeInt(u32, crafted[0..4], WAL_MAGIC, .little);
    crafted[4] = @backingInt(RecordType.put);
    std.mem.writeInt(u32, crafted[13..17], std.math.maxInt(u32), .little);

    var reader = WalReader.init(&crafted);
    try std.testing.expectError(error.TruncatedRecord, reader.next(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 0), reader.cursor);
}
