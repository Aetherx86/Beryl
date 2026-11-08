const std = @import("std");

pub const RecordType = enum(u8) {
    put = 1,
    delete = 2,
    commit = 3,
    checkpoint = 4,
};

pub const WAL_MAGIC: u32 = 0x42455259; // "BERY"

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

    pub fn appendRecord(self: *WalWriter, record: WalRecord) !void {
        var header: [17]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], WAL_MAGIC, .little);
        header[4] = @intFromEnum(record);

        switch (record) {
            .put => |p| {
                std.mem.writeInt(u64, header[5..13], p.tx_id, .little);
                const payload_len: u32 = @as(u32, @intCast(2 + p.key.len + 4 + p.value.len));
                std.mem.writeInt(u32, header[13..17], payload_len, .little);

                var payload: std.ArrayList(u8) = .empty;
                defer payload.deinit(self.allocator);

                var klen_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &klen_buf, @as(u16, @intCast(p.key.len)), .little);
                try payload.appendSlice(self.allocator, &klen_buf);
                try payload.appendSlice(self.allocator, p.key);

                var vlen_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &vlen_buf, @as(u32, @intCast(p.value.len)), .little);
                try payload.appendSlice(self.allocator, &vlen_buf);
                try payload.appendSlice(self.allocator, p.value);

                // Compute CRC over header + payload
                var full_rec: std.ArrayList(u8) = .empty;
                defer full_rec.deinit(self.allocator);
                try full_rec.appendSlice(self.allocator, &header);
                try full_rec.appendSlice(self.allocator, payload.items);

                const crc = std.hash.Crc32.hash(full_rec.items);
                var crc_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &crc_buf, crc, .little);

                try self.buffer.appendSlice(self.allocator, full_rec.items);
                try self.buffer.appendSlice(self.allocator, &crc_buf);
            },
            .delete => |d| {
                std.mem.writeInt(u64, header[5..13], d.tx_id, .little);
                const payload_len: u32 = @as(u32, @intCast(2 + d.key.len));
                std.mem.writeInt(u32, header[13..17], payload_len, .little);

                var payload: std.ArrayList(u8) = .empty;
                defer payload.deinit(self.allocator);

                var klen_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &klen_buf, @as(u16, @intCast(d.key.len)), .little);
                try payload.appendSlice(self.allocator, &klen_buf);
                try payload.appendSlice(self.allocator, d.key);

                var full_rec: std.ArrayList(u8) = .empty;
                defer full_rec.deinit(self.allocator);
                try full_rec.appendSlice(self.allocator, &header);
                try full_rec.appendSlice(self.allocator, payload.items);

                const crc = std.hash.Crc32.hash(full_rec.items);
                var crc_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &crc_buf, crc, .little);

                try self.buffer.appendSlice(self.allocator, full_rec.items);
                try self.buffer.appendSlice(self.allocator, &crc_buf);
            },
            .commit => |c| {
                std.mem.writeInt(u64, header[5..13], c.tx_id, .little);
                const payload_len: u32 = 4 + 8;
                std.mem.writeInt(u32, header[13..17], payload_len, .little);

                var payload_buf: [12]u8 = undefined;
                std.mem.writeInt(u32, payload_buf[0..4], c.root_page_id, .little);
                std.mem.writeInt(u64, payload_buf[4..12], c.generation, .little);

                var full_rec: std.ArrayList(u8) = .empty;
                defer full_rec.deinit(self.allocator);
                try full_rec.appendSlice(self.allocator, &header);
                try full_rec.appendSlice(self.allocator, &payload_buf);

                const crc = std.hash.Crc32.hash(full_rec.items);
                var crc_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &crc_buf, crc, .little);

                try self.buffer.appendSlice(self.allocator, full_rec.items);
                try self.buffer.appendSlice(self.allocator, &crc_buf);
            },
            .checkpoint => |cp| {
                std.mem.writeInt(u64, header[5..13], cp.checkpoint_seq, .little);
                const payload_len: u32 = 4;
                std.mem.writeInt(u32, header[13..17], payload_len, .little);

                var payload_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, payload_buf[0..4], cp.root_page_id, .little);

                var full_rec: std.ArrayList(u8) = .empty;
                defer full_rec.deinit(self.allocator);
                try full_rec.appendSlice(self.allocator, &header);
                try full_rec.appendSlice(self.allocator, &payload_buf);

                const crc = std.hash.Crc32.hash(full_rec.items);
                var crc_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &crc_buf, crc, .little);

                try self.buffer.appendSlice(self.allocator, full_rec.items);
                try self.buffer.appendSlice(self.allocator, &crc_buf);
            },
        }
    }
};

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
        if (self.data.len - self.cursor < 17 + 4) {
            // Incomplete header / corrupted tail
            return null;
        }

        const start_idx = self.cursor;
        const magic = std.mem.readInt(u32, self.data[self.cursor..][0..4], .little);
        if (magic != WAL_MAGIC) return error.InvalidMagic;
        self.cursor += 4;

        const raw_type = self.data[self.cursor];
        self.cursor += 1;
        const rec_type = switch (raw_type) {
            1 => RecordType.put,
            2 => RecordType.delete,
            3 => RecordType.commit,
            4 => RecordType.checkpoint,
            else => return error.UnknownRecordType,
        };

        const id_or_seq = std.mem.readInt(u64, self.data[self.cursor..][0..8], .little);
        self.cursor += 8;

        const payload_len = std.mem.readInt(u32, self.data[self.cursor..][0..4], .little);
        self.cursor += 4;

        if (self.data.len - self.cursor < payload_len + 4) {
            return error.TruncatedRecord;
        }

        const payload_start = self.cursor;
        self.cursor += payload_len;

        const recorded_crc = std.mem.readInt(u32, self.data[self.cursor..][0..4], .little);
        self.cursor += 4;

        const expected_crc = std.hash.Crc32.hash(self.data[start_idx .. self.cursor - 4]);
        if (recorded_crc != expected_crc) {
            return error.ChecksumMismatch;
        }

        const payload = self.data[payload_start .. payload_start + payload_len];

        switch (rec_type) {
            .put => {
                if (payload.len < 6) return error.InvalidPayload;
                const klen = std.mem.readInt(u16, payload[0..2], .little);
                if (payload.len < 6 + klen) return error.InvalidPayload;

                const k_slice = try arena.alloc(u8, klen);
                @memcpy(k_slice, payload[2 .. 2 + klen]);

                const vlen = std.mem.readInt(u32, payload[2 + klen .. 6 + klen][0..4], .little);
                if (payload.len < 6 + klen + vlen) return error.InvalidPayload;

                const v_slice = try arena.alloc(u8, vlen);
                @memcpy(v_slice, payload[6 + klen .. 6 + klen + vlen]);

                return WalRecord{
                    .put = .{
                        .tx_id = id_or_seq,
                        .key = k_slice,
                        .value = v_slice,
                    },
                };
            },
            .delete => {
                if (payload.len < 2) return error.InvalidPayload;
                const klen = std.mem.readInt(u16, payload[0..2], .little);
                if (payload.len < 2 + klen) return error.InvalidPayload;

                const k_slice = try arena.alloc(u8, klen);
                @memcpy(k_slice, payload[2 .. 2 + klen]);

                return WalRecord{
                    .delete = .{
                        .tx_id = id_or_seq,
                        .key = k_slice,
                    },
                };
            },
            .commit => {
                if (payload.len < 12) return error.InvalidPayload;
                const root_id = std.mem.readInt(u32, payload[0..4], .little);
                const gen = std.mem.readInt(u64, payload[4..12], .little);
                return WalRecord{
                    .commit = .{
                        .tx_id = id_or_seq,
                        .root_page_id = root_id,
                        .generation = gen,
                    },
                };
            },
            .checkpoint => {
                if (payload.len < 4) return error.InvalidPayload;
                const root_id = std.mem.readInt(u32, payload[0..4], .little);
                return WalRecord{
                    .checkpoint = .{
                        .checkpoint_seq = id_or_seq,
                        .root_page_id = root_id,
                    },
                };
            },
        }
    }
};

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
        .commit = .{ .tx_id = 1, .root_page_id = 42, .generation = 1 },
    });
    try writer.appendRecord(.{
        .checkpoint = .{ .checkpoint_seq = 1, .root_page_id = 42 },
    });

    var reader = WalReader.init(writer.buffer.items);
    var count: usize = 0;
    while (try reader.next(alloc)) |rec| {
        count += 1;
        if (count == 1) {
            try std.testing.expectEqualStrings("alpha", rec.put.key);
            try std.testing.expectEqualStrings("payload-alpha", rec.put.value);
        } else if (count == 3) {
            try std.testing.expectEqual(@as(u32, 42), rec.commit.root_page_id);
            try std.testing.expectEqual(@as(u64, 1), rec.commit.generation);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), count);
}
