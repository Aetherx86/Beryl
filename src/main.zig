const std = @import("std");
const builtin = @import("builtin");
pub const wal = @import("wal.zig");
pub const btree = @import("btree.zig");
pub const engine = @import("engine.zig");

const VERSION = "0.2.0";
const DEFAULT_DB_PATH = "beryl.wal";

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (ch < 0x20 or ch >= 0x7f) {
                    try w.print("\\u{x:0>4}", .{@as(u16, ch)});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout_writer.interface;

    var err_buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err_out = &stderr_writer.interface;

    var args_list: std.ArrayList([]const u8) = .empty;
    var arg_it = init.minimal.args.iterate();
    _ = arg_it.next(); // skip executable name
    while (arg_it.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    if (args_list.items.len == 0) {
        try printUsage(out);
        try out.flush();
        return;
    }

    const cmd = args_list.items[0];
    const rest = args_list.items[1..];

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        try printUsage(out);
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        try out.print("Beryl v{s} (Crash-Consistent CoW B-Tree & WAL Engine)\n", .{VERSION});
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "bench")) {
        try cmdBench(allocator, io, out, err_out, rest);
        try out.flush();
        try err_out.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "put")) {
        try cmdPut(allocator, io, out, err_out, rest);
        try out.flush();
        try err_out.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "get")) {
        try cmdGet(allocator, io, out, err_out, rest);
        try out.flush();
        try err_out.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "delete") or std.mem.eql(u8, cmd, "del")) {
        try cmdDelete(allocator, io, out, err_out, rest);
        try out.flush();
        try err_out.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "scan")) {
        try cmdScan(allocator, io, out, err_out, rest);
        try out.flush();
        try err_out.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "stats")) {
        try cmdStats(allocator, io, out, err_out, rest);
        try out.flush();
        try err_out.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "verify")) {
        try cmdVerify(allocator, io, out, err_out, rest);
        try out.flush();
        try err_out.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "compact")) {
        try cmdCompact(allocator, io, out, err_out, rest);
        try out.flush();
        try err_out.flush();
        return;
    }

    try err_out.print("Error: unknown command '{s}'\n", .{cmd});
    try printUsage(err_out);
    try err_out.flush();
}

fn printUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Beryl: Crash-Consistent Append-Only B-Tree & WAL Engine
        \\Usage: beryl <command> [options]
        \\
        \\Commands:
        \\  bench [count] [--json]
        \\      Run CoW B-Tree put/get/scan/delete/recovery benchmark
        \\  put [--db <path>] [--json] <key> <val>
        \\      Store key-value pair, commit transaction, and persist WAL
        \\  get [--db <path>] [--json] <key>
        \\      Retrieve committed value for key
        \\  delete [--db <path>] [--json] <key>
        \\      Delete key, commit transaction, and persist WAL
        \\  scan [--db <path>] [--prefix <p>] [--start <k>] [--end <k>] [--inclusive-end] [--limit <n>] [--json]
        \\      Scan ordered key-value pairs by range or prefix
        \\  stats [--db <path>] [--json]
        \\      Show B-Tree geometry, fill factor, page utilization, and WAL metrics
        \\  verify [--db <path>] [--json]
        \\      Validate WAL CRC32 framing and B-Tree structural/checksum invariants
        \\  compact [--db <path>] [--json]
        \\      Reclaim unreachable CoW pages, compact WAL, and persist atomically
        \\  --version, -v
        \\      Print engine version
        \\  --help, -h
        \\      Print this help message
        \\
        \\Default WAL file path: beryl.wal (override with --db <path>)
        \\
    );
}

fn cmdPut(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    args: []const []const u8,
) !void {
    var db_path: []const u8 = DEFAULT_DB_PATH;
    var json_mode = false;
    var pos: [2]?[]const u8 = .{ null, null };
    var pos_count: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--db")) {
            if (i + 1 >= args.len) {
                try err_out.writeAll("Error: --db requires a file path\n");
                return;
            }
            i += 1;
            db_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json_mode = true;
        } else if (pos_count < 2) {
            pos[pos_count] = args[i];
            pos_count += 1;
        }
    }

    const k = pos[0] orelse {
        try err_out.writeAll("Error: missing key\n");
        return;
    };
    const v = pos[1] orelse {
        try err_out.writeAll("Error: missing value\n");
        return;
    };

    var eng = try engine.BerylEngine.openFile(allocator, io, std.Io.Dir.cwd(), db_path);
    defer eng.deinit();

    try eng.put(k, v);
    const root = try eng.commit();
    try eng.saveFile(io, std.Io.Dir.cwd(), db_path);

    if (json_mode) {
        try out.writeAll("{\"ok\":true,\"op\":\"put\",\"key\":");
        try writeJsonString(out, k);
        try out.writeAll(",\"value\":");
        try writeJsonString(out, v);
        try out.print(",\"root_page_id\":{d},\"wal_bytes\":{d}}}\n", .{ root, eng.getWalBytes().len });
    } else {
        try out.print("Committed key '{s}' = '{s}' at root page {d}\n", .{ k, v, root });
    }
}

fn cmdGet(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    args: []const []const u8,
) !void {
    var db_path: []const u8 = DEFAULT_DB_PATH;
    var json_mode = false;
    var key: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--db")) {
            if (i + 1 >= args.len) {
                try err_out.writeAll("Error: --db requires a file path\n");
                return;
            }
            i += 1;
            db_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json_mode = true;
        } else if (key == null) {
            key = args[i];
        }
    }

    const k = key orelse {
        try err_out.writeAll("Error: missing key\n");
        return;
    };

    var eng = try engine.BerylEngine.openFile(allocator, io, std.Io.Dir.cwd(), db_path);
    defer eng.deinit();

    if (try eng.get(k)) |kv| {
        if (json_mode) {
            try out.writeAll("{\"found\":true,\"key\":");
            try writeJsonString(out, kv.getKey());
            try out.writeAll(",\"value\":");
            try writeJsonString(out, kv.getValue());
            try out.writeAll("}\n");
        } else {
            try out.print("{s}\n", .{kv.getValue()});
        }
    } else {
        if (json_mode) {
            try out.writeAll("{\"found\":false,\"key\":");
            try writeJsonString(out, k);
            try out.writeAll("}\n");
        } else {
            try out.print("Key '{s}' not found\n", .{k});
        }
    }
}

fn cmdDelete(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    args: []const []const u8,
) !void {
    var db_path: []const u8 = DEFAULT_DB_PATH;
    var json_mode = false;
    var key: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--db")) {
            if (i + 1 >= args.len) {
                try err_out.writeAll("Error: --db requires a file path\n");
                return;
            }
            i += 1;
            db_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json_mode = true;
        } else if (key == null) {
            key = args[i];
        }
    }

    const k = key orelse {
        try err_out.writeAll("Error: missing key\n");
        return;
    };

    var eng = try engine.BerylEngine.openFile(allocator, io, std.Io.Dir.cwd(), db_path);
    defer eng.deinit();

    const deleted = try eng.delete(k);
    var root = eng.committed_root;
    if (deleted) {
        root = try eng.commit();
        try eng.saveFile(io, std.Io.Dir.cwd(), db_path);
    }

    if (json_mode) {
        try out.print("{{\"ok\":true,\"op\":\"delete\",\"deleted\":{s},\"key\":", .{if (deleted) "true" else "false"});
        try writeJsonString(out, k);
        try out.print(",\"root_page_id\":{d}}}\n", .{root});
    } else if (deleted) {
        try out.print("Deleted key '{s}' at root page {d}\n", .{ k, root });
    } else {
        try out.print("Key '{s}' not found\n", .{k});
    }
}

fn cmdScan(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    args: []const []const u8,
) !void {
    var db_path: []const u8 = DEFAULT_DB_PATH;
    var json_mode = false;
    var prefix: ?[]const u8 = null;
    var start_key: ?[]const u8 = null;
    var end_key: ?[]const u8 = null;
    var inclusive_end = false;
    var limit: ?usize = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--db")) {
            if (i + 1 >= args.len) {
                try err_out.writeAll("Error: --db requires a file path\n");
                return;
            }
            i += 1;
            db_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--prefix")) {
            if (i + 1 >= args.len) {
                try err_out.writeAll("Error: --prefix requires a value\n");
                return;
            }
            i += 1;
            prefix = args[i];
        } else if (std.mem.eql(u8, args[i], "--start")) {
            if (i + 1 >= args.len) {
                try err_out.writeAll("Error: --start requires a key\n");
                return;
            }
            i += 1;
            start_key = args[i];
        } else if (std.mem.eql(u8, args[i], "--end")) {
            if (i + 1 >= args.len) {
                try err_out.writeAll("Error: --end requires a key\n");
                return;
            }
            i += 1;
            end_key = args[i];
        } else if (std.mem.eql(u8, args[i], "--inclusive-end")) {
            inclusive_end = true;
        } else if (std.mem.eql(u8, args[i], "--limit")) {
            if (i + 1 >= args.len) {
                try err_out.writeAll("Error: --limit requires an integer\n");
                return;
            }
            i += 1;
            limit = std.fmt.parseInt(usize, args[i], 10) catch {
                try err_out.print("Error: invalid limit '{s}'\n", .{args[i]});
                return;
            };
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json_mode = true;
        }
    }

    var eng = try engine.BerylEngine.openFile(allocator, io, std.Io.Dir.cwd(), db_path);
    defer eng.deinit();

    const items = if (prefix) |p|
        try eng.scanPrefix(allocator, p, limit)
    else
        try eng.scanRange(allocator, .{
            .start_key = start_key,
            .end_key = end_key,
            .inclusive_end = inclusive_end,
            .limit = limit,
        });
    defer allocator.free(items);

    if (json_mode) {
        try out.print("{{\"count\":{d},\"entries\":[", .{items.len});
        for (items, 0..) |*kv, idx| {
            if (idx > 0) try out.writeByte(',');
            try out.writeAll("{\"key\":");
            try writeJsonString(out, kv.getKey());
            try out.writeAll(",\"value\":");
            try writeJsonString(out, kv.getValue());
            try out.writeByte('}');
        }
        try out.writeAll("]}\n");
    } else {
        for (items) |*kv| {
            try out.print("{s}\t{s}\n", .{ kv.getKey(), kv.getValue() });
        }
    }
}

fn cmdStats(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    args: []const []const u8,
) !void {
    var db_path: []const u8 = DEFAULT_DB_PATH;
    var json_mode = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--db")) {
            if (i + 1 >= args.len) {
                try err_out.writeAll("Error: --db requires a file path\n");
                return;
            }
            i += 1;
            db_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json_mode = true;
        }
    }

    var eng = try engine.BerylEngine.openFile(allocator, io, std.Io.Dir.cwd(), db_path);
    defer eng.deinit();

    const st = try eng.stats();
    if (json_mode) {
        try out.print(
            \\{{"db":
        , .{});
        try writeJsonString(out, db_path);
        try out.print(
            \\,"root_page_id":{d},"generation":{d},"height":{d},"key_count":{d},"leaf_pages":{d},"internal_pages":{d},"reachable_pages":{d},"total_allocated_pages":{d},"dead_pages":{d},"avg_fill_factor":{d:.4},"wal_bytes":{d},"wal_records":{d},"wal_clean":{s},"snapshots":{d}}}
            \\
        , .{
            st.committed_root,
            st.tree.generation,
            st.tree.height,
            st.tree.key_count,
            st.tree.leaf_pages,
            st.tree.internal_pages,
            st.tree.reachable_pages,
            st.tree.total_allocated_pages,
            st.tree.dead_pages,
            st.tree.avg_fill_factor,
            st.wal.total_bytes,
            st.wal.total_records,
            if (st.wal.clean) "true" else "false",
            st.snapshot_count,
        });
    } else {
        try out.print(
            \\Database:            {s}
            \\Committed Root Page: {d} (generation {d})
            \\B-Tree Height:       {d}
            \\Live Keys:           {d}
            \\Pages (Leaf/Int):    {d} / {d} ({d} reachable, {d} allocated, {d} dead)
            \\Avg Fill Factor:     {d:.1}%
            \\WAL Size / Records:  {d} bytes / {d} records (clean={s})
            \\Snapshots:           {d}
            \\
        , .{
            db_path,
            st.committed_root,
            st.tree.generation,
            st.tree.height,
            st.tree.key_count,
            st.tree.leaf_pages,
            st.tree.internal_pages,
            st.tree.reachable_pages,
            st.tree.total_allocated_pages,
            st.tree.dead_pages,
            st.tree.avg_fill_factor * 100.0,
            st.wal.total_bytes,
            st.wal.total_records,
            if (st.wal.clean) "true" else "false",
            st.snapshot_count,
        });
    }
}

fn cmdVerify(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    args: []const []const u8,
) !void {
    var db_path: []const u8 = DEFAULT_DB_PATH;
    var json_mode = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--db")) {
            if (i + 1 >= args.len) {
                try err_out.writeAll("Error: --db requires a file path\n");
                return;
            }
            i += 1;
            db_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json_mode = true;
        }
    }

    const raw_wal = std.Io.Dir.cwd().readFileAlloc(io, db_path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => try allocator.alloc(u8, 0),
        else => return err,
    };
    defer allocator.free(raw_wal);

    const raw_insp = wal.inspectWal(raw_wal);

    var eng = try engine.BerylEngine.recoverFromWal(allocator, raw_wal);
    defer eng.deinit();

    const tree_stats = try eng.tree.verify(eng.committed_root);

    if (json_mode) {
        try out.print(
            \\{{"ok":{s},"wal_clean":{s},"wal_bytes":{d},"wal_valid_bytes":{d},"wal_trailing_corrupt_bytes":{d},"wal_records":{d},"tree_height":{d},"key_count":{d},"reachable_pages":{d}
        , .{
            if (raw_insp.clean) "true" else "false",
            if (raw_insp.clean) "true" else "false",
            raw_insp.total_bytes,
            raw_insp.valid_bytes,
            raw_insp.trailing_corrupt_bytes,
            raw_insp.total_records,
            tree_stats.height,
            tree_stats.key_count,
            tree_stats.reachable_pages,
        });
        if (raw_insp.first_error) |e| {
            try out.writeAll(",\"wal_error\":");
            try writeJsonString(out, e);
        }
        try out.writeAll("}\n");
    } else {
        try out.print(
            \\WAL Integrity:    {s} ({d}/{d} bytes valid, {d} records)
            \\B-Tree Integrity: OK (height={d}, keys={d}, reachable_pages={d})
            \\
        , .{
            if (raw_insp.clean) "OK" else (raw_insp.first_error orelse "CORRUPT"),
            raw_insp.valid_bytes,
            raw_insp.total_bytes,
            raw_insp.total_records,
            tree_stats.height,
            tree_stats.key_count,
            tree_stats.reachable_pages,
        });
    }
}

fn cmdCompact(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    args: []const []const u8,
) !void {
    var db_path: []const u8 = DEFAULT_DB_PATH;
    var json_mode = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--db")) {
            if (i + 1 >= args.len) {
                try err_out.writeAll("Error: --db requires a file path\n");
                return;
            }
            i += 1;
            db_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json_mode = true;
        }
    }

    var eng = try engine.BerylEngine.openFile(allocator, io, std.Io.Dir.cwd(), db_path);
    defer eng.deinit();

    const rep = try eng.compact();
    try eng.saveFile(io, std.Io.Dir.cwd(), db_path);

    if (json_mode) {
        try out.print(
            \\{{"ok":true,"live_keys":{d},"pages_before":{d},"pages_after":{d},"pages_reclaimed":{d},"wal_bytes_before":{d},"wal_bytes_after":{d},"new_root_page_id":{d}}}
            \\
        , .{
            rep.live_keys,
            rep.pages_before,
            rep.pages_after,
            rep.pages_reclaimed,
            rep.wal_bytes_before,
            rep.wal_bytes_after,
            rep.new_root_page_id,
        });
    } else {
        try out.print(
            \\Compacted {s}: {d} live keys, pages {d} -> {d} (reclaimed {d}), WAL {d} -> {d} bytes
            \\
        , .{
            db_path,
            rep.live_keys,
            rep.pages_before,
            rep.pages_after,
            rep.pages_reclaimed,
            rep.wal_bytes_before,
            rep.wal_bytes_after,
        });
    }
}

fn cmdBench(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    args: []const []const u8,
) !void {
    var count: usize = 1000;
    var json_mode = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else {
            count = std.fmt.parseInt(usize, arg, 10) catch {
                try err_out.print("Error: invalid benchmark count '{s}'\n", .{arg});
                return;
            };
        }
    }

    var eng = try engine.BerylEngine.init(allocator);
    defer eng.deinit();

    var kbuf: [32]u8 = undefined;
    var vbuf: [64]u8 = undefined;

    // 1. Batched Put benchmark
    const t_put_0 = std.Io.Clock.Timestamp.now(io, .awake);
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
    const t_put_1 = std.Io.Clock.Timestamp.now(io, .awake);

    // 2. Point Get benchmark
    const t_get_0 = std.Io.Clock.Timestamp.now(io, .awake);
    var hits: usize = 0;
    for (0..count) |i| {
        const k = std.fmt.bufPrint(&kbuf, "bench_key_{d:0>6}", .{i}) catch unreachable;
        if (try eng.get(k)) |_| hits += 1;
    }
    const t_get_1 = std.Io.Clock.Timestamp.now(io, .awake);

    // 3. Full ordered range scan benchmark
    const t_scan_0 = std.Io.Clock.Timestamp.now(io, .awake);
    const scanned = try eng.scanPrefix(allocator, "bench_key_", null);
    defer allocator.free(scanned);
    const t_scan_1 = std.Io.Clock.Timestamp.now(io, .awake);

    // 4. WAL Crash Recovery benchmark
    const wal_snapshot = eng.getWalBytes();
    const t_rec_0 = std.Io.Clock.Timestamp.now(io, .awake);
    var recovered = try engine.BerylEngine.recoverFromWal(allocator, wal_snapshot);
    defer recovered.deinit();
    const t_rec_1 = std.Io.Clock.Timestamp.now(io, .awake);

    // 5. Delete half + Compact benchmark
    const del_count = count / 2;
    const t_del_0 = std.Io.Clock.Timestamp.now(io, .awake);
    _ = try eng.beginTransaction();
    for (0..del_count) |i| {
        const k = std.fmt.bufPrint(&kbuf, "bench_key_{d:0>6}", .{i}) catch unreachable;
        _ = try eng.delete(k);
        if ((i + 1) % 100 == 0) {
            _ = try eng.commit();
            _ = try eng.beginTransaction();
        }
    }
    _ = try eng.commit();
    const t_del_1 = std.Io.Clock.Timestamp.now(io, .awake);

    const comp = try eng.compact();
    const st = try eng.verify();

    const put_ms = durationMs(t_put_0, t_put_1);
    const get_ms = durationMs(t_get_0, t_get_1);
    const scan_ms = durationMs(t_scan_0, t_scan_1);
    const rec_ms = durationMs(t_rec_0, t_rec_1);
    const del_ms = durationMs(t_del_0, t_del_1);

    const put_ops = opsPerSec(count, put_ms);
    const get_ops = opsPerSec(hits, get_ms);
    const del_ops = opsPerSec(del_count, del_ms);

    if (json_mode) {
        try out.print(
            \\{{"records":{d},"put_ms":{d:.3},"put_ops_sec":{d:.0},"get_ms":{d:.3},"get_ops_sec":{d:.0},"scan_count":{d},"scan_ms":{d:.3},"recover_ms":{d:.3},"delete_count":{d},"delete_ms":{d:.3},"delete_ops_sec":{d:.0},"compaction":{{"pages_before":{d},"pages_after":{d},"pages_reclaimed":{d},"wal_bytes_before":{d},"wal_bytes_after":{d}}},"verified":{s}}}
            \\
        , .{
            count,
            put_ms,
            put_ops,
            get_ms,
            get_ops,
            scanned.len,
            scan_ms,
            rec_ms,
            del_count,
            del_ms,
            del_ops,
            comp.pages_before,
            comp.pages_after,
            comp.pages_reclaimed,
            comp.wal_bytes_before,
            comp.wal_bytes_after,
            if (st.ok) "true" else "false",
        });
    } else {
        try out.print(
            \\Beryl CoW B-Tree & WAL Benchmark ({d} records)
            \\  Put:      {d:.2} ms ({d:.0} ops/sec)
            \\  Get:      {d:.2} ms ({d:.0} ops/sec, hits={d})
            \\  Scan:     {d:.2} ms ({d} entries)
            \\  Recover:  {d:.2} ms ({d} WAL bytes)
            \\  Delete:   {d:.2} ms ({d:.0} ops/sec, {d} keys)
            \\  Compact:  pages {d} -> {d} (reclaimed {d}), WAL {d} -> {d} bytes
            \\  Verify:   {s}
            \\
        , .{
            count,
            put_ms,
            put_ops,
            get_ms,
            get_ops,
            hits,
            scan_ms,
            scanned.len,
            rec_ms,
            wal_snapshot.len,
            del_ms,
            del_ops,
            del_count,
            comp.pages_before,
            comp.pages_after,
            comp.pages_reclaimed,
            comp.wal_bytes_before,
            comp.wal_bytes_after,
            if (st.ok) "OK" else "FAILED",
        });
    }
}

fn durationMs(t0: std.Io.Clock.Timestamp, t1: std.Io.Clock.Timestamp) f64 {
    const ns = t0.durationTo(t1).raw.nanoseconds;
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn opsPerSec(ops: usize, ms: f64) f64 {
    return if (ms > 0.0) @as(f64, @floatFromInt(ops)) / (ms / 1000.0) else 0.0;
}

fn cAbiAllocator() std.mem.Allocator {
    return if (builtin.link_libc) std.heap.c_allocator else std.heap.smp_allocator;
}

// C-ABI Exports for foreign language embedding
pub export fn beryl_create() ?*anyopaque {
    const allocator = cAbiAllocator();
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

pub export fn beryl_begin(handle: ?*anyopaque) u64 {
    if (handle == null) return 0;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    return eng.beginTransaction() catch 0;
}

pub export fn beryl_put(handle: ?*anyopaque, key_ptr: [*]const u8, key_len: usize, val_ptr: [*]const u8, val_len: usize) i32 {
    if (handle == null) return -1;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    const k = key_ptr[0..key_len];
    const v = val_ptr[0..val_len];
    eng.put(k, v) catch return -2;
    return 0;
}

pub export fn beryl_get(
    handle: ?*anyopaque,
    key_ptr: [*]const u8,
    key_len: usize,
    out_buf: ?[*]u8,
    out_cap: usize,
    out_len: ?*usize,
) i32 {
    if (handle == null) return -1;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    const k = key_ptr[0..key_len];
    const maybe_kv = eng.get(k) catch return -2;
    return copyKvToCOut(maybe_kv, out_buf, out_cap, out_len);
}

pub export fn beryl_get_at(
    handle: ?*anyopaque,
    root_id: u32,
    key_ptr: [*]const u8,
    key_len: usize,
    out_buf: ?[*]u8,
    out_cap: usize,
    out_len: ?*usize,
) i32 {
    if (handle == null) return -1;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    const k = key_ptr[0..key_len];
    const maybe_kv = eng.getAtSnapshot(root_id, k) catch return -2;
    return copyKvToCOut(maybe_kv, out_buf, out_cap, out_len);
}

fn copyKvToCOut(maybe_kv: ?btree.KeyValue, out_buf: ?[*]u8, out_cap: usize, out_len: ?*usize) i32 {
    const kv = maybe_kv orelse {
        if (out_len) |ol| ol.* = 0;
        return 1;
    };
    const val = kv.getValue();
    if (out_len) |ol| ol.* = val.len;
    if (val.len > out_cap) return -3;
    if (val.len > 0) {
        const dst = out_buf orelse return -3;
        @memcpy(dst[0..val.len], val);
    }
    return 0;
}

pub export fn beryl_delete(handle: ?*anyopaque, key_ptr: [*]const u8, key_len: usize) i32 {
    if (handle == null) return -1;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    const k = key_ptr[0..key_len];
    const deleted = eng.delete(k) catch return -2;
    return if (deleted) 0 else 1;
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

pub export fn beryl_checkpoint(handle: ?*anyopaque) i32 {
    if (handle == null) return -1;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    eng.checkpoint() catch return -2;
    return 0;
}

pub export fn beryl_compact(handle: ?*anyopaque) i32 {
    if (handle == null) return -1;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    _ = eng.compact() catch return -2;
    return 0;
}

pub export fn beryl_verify(handle: ?*anyopaque) i32 {
    if (handle == null) return -1;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    const rep = eng.verify() catch return -2;
    return if (rep.ok) 0 else -3;
}

pub export fn beryl_count(handle: ?*anyopaque) usize {
    if (handle == null) return 0;
    const eng: *engine.BerylEngine = @ptrCast(@alignCast(handle.?));
    return eng.count() catch 0;
}

test "C-ABI lifecycle, snapshot reads, deletes, verify, and compaction" {
    const h = beryl_create() orelse return error.OutOfMemory;
    defer beryl_destroy(h);

    try std.testing.expectEqual(@as(i32, 0), beryl_put(h, "alpha", 5, "first", 5));
    const snap1 = beryl_commit(h);
    try std.testing.expect(snap1 != 0);

    try std.testing.expectEqual(@as(u64, 2), beryl_begin(h));
    try std.testing.expectEqual(@as(i32, 0), beryl_put(h, "alpha", 5, "second", 6));
    try std.testing.expectEqual(@as(i32, 0), beryl_put(h, "beta", 4, "value_b", 7));
    const snap2 = beryl_commit(h);
    try std.testing.expect(snap2 != snap1);
    try std.testing.expectEqual(@as(usize, 2), beryl_count(h));

    // Read current value
    var buf: [64]u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), beryl_get(h, "alpha", 5, &buf, buf.len, &out_len));
    try std.testing.expectEqualStrings("second", buf[0..out_len]);

    // Buffer too small returns -3 and sets required out_len
    try std.testing.expectEqual(@as(i32, -3), beryl_get(h, "alpha", 5, &buf, 2, &out_len));
    try std.testing.expectEqual(@as(usize, 6), out_len);

    // Historical snapshot read returns original value
    try std.testing.expectEqual(@as(i32, 0), beryl_get_at(h, snap1, "alpha", 5, &buf, buf.len, &out_len));
    try std.testing.expectEqualStrings("first", buf[0..out_len]);
    try std.testing.expectEqual(@as(i32, 1), beryl_get_at(h, snap1, "beta", 4, &buf, buf.len, &out_len));

    // Delete + rollback leaves key intact; delete + commit removes key
    try std.testing.expectEqual(@as(i32, 0), beryl_delete(h, "beta", 4));
    beryl_rollback(h);
    try std.testing.expectEqual(@as(usize, 2), beryl_count(h));

    try std.testing.expectEqual(@as(i32, 0), beryl_delete(h, "beta", 4));
    _ = beryl_commit(h);
    try std.testing.expectEqual(@as(usize, 1), beryl_count(h));
    try std.testing.expectEqual(@as(i32, 1), beryl_delete(h, "beta", 4));

    try std.testing.expectEqual(@as(i32, 0), beryl_checkpoint(h));
    try std.testing.expectEqual(@as(i32, 0), beryl_compact(h));
    try std.testing.expectEqual(@as(i32, 0), beryl_verify(h));
}

test {
    _ = @import("wal.zig");
    _ = @import("btree.zig");
    _ = @import("engine.zig");
}
