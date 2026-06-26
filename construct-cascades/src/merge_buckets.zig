const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Packed (run_id: u32, post_id: u32) into a single u64 so sorting on this
/// integer is equivalent to sorting by (run_id, post_id) as a tuple.
const CascadeKey = u64;

const Event = struct {
    time: f64,
    line: []const u8,
};

const KeyVal = struct { key: CascadeKey, events: std.ArrayListUnmanaged(Event) };

pub fn mergeBuckets(io: Io, gpa: Allocator, num_buckets: usize, buckets_path: []const u8, output_path: []const u8, stderr: *Io.Writer) (error{ WriteFailed, OutOfMemory } || Io.Dir.OpenError || Io.File.OpenError)!void {
    const buckets_dir = try Io.Dir.cwd().openDir(io, "buckets", .{});
    defer buckets_dir.close(io);

    // Single streaming writer for cascades.ssv — OS controls the offset.
    // This means eventual multithreading is straightforward: each worker
    // gets a range of buckets and a pre-computed write offset, then writes
    // directly without coordination.
    //
    const cascades_file = try Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
    defer cascades_file.close(io);

    var cascades_buf: [64 * 1024]u8 = undefined;
    var cascades_writer = cascades_file.writer(io, &cascades_buf);
    const cascades = &cascades_writer.interface;

    var total_lines: usize = 0;
    var bucket_idx: usize = 0;
    while (bucket_idx < num_buckets) : (bucket_idx += 1) {
        var name_buf: [64]u8 = undefined;
        const bucket_path = try std.fmt.bufPrint(&name_buf, "{s}/{d}_bucket.ssv", .{ buckets_path, bucket_idx });

        const file = buckets_dir.openFile(io, bucket_path, .{}) catch |err| {
            try stderr.print("warning - could not open bucket '{s}', skipping it. The output WILL BE INCOMPLETE. Error: {}\n", .{ bucket_path, err });
            try stderr.flush();
            continue;
        };
        defer file.close(io);

        var rbuf: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &rbuf);
        const content = reader.interface.allocRemaining(gpa, .unlimited) catch |err| {
            try stderr.print("warning - could not allocate memory for bucket '{s}', skipping it. The output WILL BE INCOMPLETE. Error: {}\n", .{ bucket_path, err });
            try stderr.flush();
            continue;
        };
        defer gpa.free(content);

        // Group lines by (run_id, post_id)
        var map = std.AutoHashMap(CascadeKey, std.ArrayListUnmanaged(Event)).init(gpa);
        defer {
            var it = map.valueIterator();
            while (it.next()) |v| v.deinit(gpa);
            map.deinit();
        }

        cascadeHashMapFromBucket(gpa, content, &map) catch |err| {
            try stderr.print("warning - bucket {d}: failed to build map: {}\n", .{ bucket_idx, err });
            try stderr.flush();
            continue;
        };

        const sorted = try gpa.alloc(KeyVal, map.count());
        defer {
            for (sorted) |*kv| kv.events.deinit(gpa);
            gpa.free(sorted);
        }
        sortBucketCascades(&map, sorted);

        for (sorted) |kv| {
            total_lines += kv.events.items.len;
            for (kv.events.items) |ev| {
                try cascades.writeAll(ev.line);
                try cascades.writeAll("\n");
            }
        }

        buckets_dir.deleteFile(io, bucket_path) catch {};
    }

    try cascades.flush();
}

/// Populates the map from the bucket content. Event.line slices point into
/// content, so the caller must keep content alive until after the write.
fn cascadeHashMapFromBucket(
    gpa: Allocator,
    content: []const u8,
    map: *std.AutoHashMap(CascadeKey, std.ArrayListUnmanaged(Event)),
) !void {
    var pos: usize = 0;
    var line_no: usize = 0;
    while (pos < content.len) {
        const line_start = pos;
        const line_end = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        const line = content[line_start..line_end];
        pos = line_end + 1;
        line_no += 1;

        if (line.len == 0) continue;

        const parsed = parseLine(line) catch {
            std.debug.print("warning: bucket {d}:{d}: malformed line -- '{s}'\n", .{ 0, line_no, line });
            continue;
        };

        const key = (@as(u64, parsed.run_id) << 32) | @as(u64, parsed.post_id);

        const gop = try map.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(gpa, .{ .time = parsed.time, .line = line });
    }
}

/// Sorts the cascades in any order with the run_id post_id key, so the
/// cascades appear in the same order as appearence.
/// DO NOT CONFUSE with the order withing the cascade: that is already
/// guaranteed by the trace properties
fn sortBucketCascades(
    map: *std.AutoHashMap(CascadeKey, std.ArrayListUnmanaged(Event)),
    out: []KeyVal,
) void {
    std.debug.assert(out.len == map.count());

    var i: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{ .key = entry.key_ptr.*, .events = entry.value_ptr.* };
        entry.value_ptr.* = .empty;
    }

    std.mem.sort(KeyVal, out, {}, struct {
        fn lt(_: void, a: KeyVal, b: KeyVal) bool {
            return a.key < b.key;
        }
    }.lt);
}

const ParsedLine = struct {
    run_id: u32,
    post_id: u32,
    time: f64,
};

fn parseLine(line: []const u8) !ParsedLine {
    // Format: "run_id post_id user_id type timestamp"
    var parts: [5][]const u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;

    for (line, 0..) |c, i| {
        if (c == ' ') {
            if (count < 5) {
                parts[count] = line[start..i];
                count += 1;
            }
            start = i + 1;
            if (count >= 5) break;
        }
    }
    if (start < line.len and count < 5) {
        parts[count] = line[start..];
        count += 1;
    }

    if (count < 5) return error.MalformedLine;

    const run_id = try std.fmt.parseInt(u32, parts[0], 10);
    const post_id = try std.fmt.parseInt(u32, parts[1], 10);
    const time = try std.fmt.parseFloat(f64, parts[4]);

    return .{ .run_id = run_id, .post_id = post_id, .time = time };
}
