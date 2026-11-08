const std = @import("std");
pub const wal = @import("wal.zig");
pub const btree = @import("btree.zig");
pub const engine = @import("engine.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.next(); // skip prog name

    const cmd = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        std.debug.print("Beryl v0.1.0 (Crash-Consistent CoW B-Tree & WAL Engine)\n", .{});
        return;
    }

    if (std.mem.eql(u8, cmd, "bench")) {
        const count_str = args.next() orelse "1000";
        const count = std.fmt.parseInt(usize, count_str, 10) catch 1000;
        try runBenchmark(allocator, init.io, count);
        return;
    }

    if (std.mem.eql(u8, cmd, "put")) {
        const k = args.next() orelse {
            std.debug.print("Error: missing key\n", .{});
            return;
        };
        const v = args.next() orelse {
            std.debug.print("Error: missing value\n", .{});
            return;
        };
        var eng = try engine.BerylEngine.init(allocator);
        defer eng.deinit();

        try eng.put(k, v);
        const root = try eng.commit();
        std.debug.print("Committed key '{s}' = '{s}' at root page {d}\n", .{ k, v, root });
        return;
    }

    if (std.mem.eql(u8, cmd, "get")) {
        const k = args.next() orelse {
            std.debug.print("Error: missing key\n", .{});
            return;
        };
        var eng = try engine.BerylEngine.init(allocator);
        defer eng.deinit();

        // Query demo store
        try eng.put("demo_key", "demo_value");
        _ = try eng.commit();

        if (try eng.get(k)) |kv| {
            std.debug.print("{s}\n", .{kv.getValue()});
        } else {
            std.debug.print("Key '{s}' not found\n", .{k});
        }
        return;
    }

    printUsage();
}

fn printUsage() void {
    std.debug.print(
        \\Beryl: Crash-Consistent Append-Only B-Tree & WAL Engine
        \\Usage: beryl <command> [options]
        \\
        \\Commands:
        \\  bench <count>       Run CoW B-Tree insertion and WAL benchmark
        \\  put <key> <val>     Store key-value pair and commit transaction
        \\  get <key>           Retrieve value for key
        \\  --version, -v       Print engine version
        \\  --help, -h          Print this help message
        \\
    , .{});
}

fn runBenchmark(allocator: std.mem.Allocator, io: std.Io, count: usize) !void {
    var eng = try engine.BerylEngine.init(allocator);
    defer eng.deinit();

    std.debug.print("Running Beryl CoW B-Tree benchmark with {d} records...\n", .{count});

    const t0 = std.Io.Clock.Timestamp.now(io, .awake);

    var kbuf: [32]u8 = undefined;
    var vbuf: [64]u8 = undefined;

    _ = try eng.beginTransaction();
    for (0..count) |i| {
        const k = std.fmt.bufPrint(&kbuf, "bench_key_{d:0>6}", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&vbuf, "val_payload_{d:0>12}", .{i}) catch unreachable;
        try eng.put(k, v);

        if ((i + 1) % 100 == 0) {
            _ = try eng.commit();
            _ = try eng.beginTransaction();
        }
    }
    _ = try eng.commit();

    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const duration_ns = t0.durationTo(t1).raw.nanoseconds;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_sec = if (duration_ms > 0.0)
        (@as(f64, @floatFromInt(count)) / (duration_ms / 1000.0))
    else
        0.0;

    std.debug.print("Benchmark completed in {d:.2} ms ({d:.0} ops/sec)\n", .{ duration_ms, ops_sec });
}

// C-ABI Export Stubs for foreign language embedding
pub export fn beryl_create() ?*anyopaque {
    const allocator = std.heap.c_allocator;
    const eng_ptr = allocator.create(engine.BerylEngine) catch return null;
    eng_ptr.* = engine.BerylEngine.init(allocator) catch {
        allocator.destroy(eng_ptr);
        return null;
    };
    return @ptrCast(eng_ptr);
}

pub export fn beryl_destroy(handle: ?*anyopaque) void {
    if (handle == null) return;
    const eng_ptr: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    const allocator = eng_ptr.allocator;
    eng_ptr.deinit();
    allocator.destroy(eng_ptr);
}

pub export fn beryl_put(handle: ?*anyopaque, key_ptr: [*]const u8, key_len: usize, val_ptr: [*]const u8, val_len: usize) i32 {
    if (handle == null) return -1;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    const k = key_ptr[0..key_len];
    const v = val_ptr[0..val_len];
    eng.put(k, v) catch return -2;
    return 0;
}

pub export fn beryl_commit(handle: ?*anyopaque) u32 {
    if (handle == null) return 0;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    return eng.commit() catch 0;
}

pub export fn beryl_rollback(handle: ?*anyopaque) void {
    if (handle == null) return;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    eng.rollback();
}

test {
    _ = @import("wal.zig");
    _ = @import("btree.zig");
    _ = @import("engine.zig");
}
