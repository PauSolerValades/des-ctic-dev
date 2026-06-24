const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const argz = @import("eazy_args");
const traces = @import("traces");

const Arg = argz.Argument;
const Opt = argz.Option;
const Flag = argz.Flag;

const ParseErrors = argz.ParseErrors;

const BucketWriter = struct {
    file: Io.File,
    writer: Io.File.Writer,
    buffer: [16 * 1024]u8,

    fn init(self: *@This(), io_: Io, dir: Io.Dir, index: usize) !void {
        var name_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name_buf, "{d}_bucket.ssv", .{index});
        self.file = try dir.createFile(io_, path, .{ .truncate = true });
        self.writer = self.file.writer(io_, &self.buffer);
    }

    fn deinit(self: *@This(), io_: Io) void {
        self.file.close(io_);
    }

    fn iface(self: *@This()) *Io.Writer {
        return &self.writer.interface;
    }
};

const def = .{
    .name = "specific",
    .description = "Parses the .bin traces into a usable dataset",
    .required = .{
        Arg([]const u8, "traces", "Folder were all traces are located."),
    },
    .options = .{
        Opt(usize, "buckets", "b", 256, "How many bucket the program hashed the info."),
    },
    .flags = .{},
};

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;

    var bufferr: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &bufferr);
    const stderr = &stderr_writer.interface;

    const io = init.io;
    // const arena = init.arena.allocator();
    const gpa = init.gpa;
    // const cwd = Io.Dir.cwd();
    //
    var iter = init.minimal.args.iterate();
    const args = argz.parseArgsPosix(def, &iter, stdout, stderr) catch |err| {
        switch (err) {
            ParseErrors.HelpShown => try stdout.flush(),
            else => try stderr.flush(),
        }
        std.process.exit(0);
    };

    const tracesDir = Io.Dir.cwd().openDir(io, args.traces, .{ .access_sub_paths = false, .iterate = true }) catch |err| {
        try stderr.print("Failed to open traces dir '{s}': {}\n", .{ args.traces, err });
        try stderr.flush();
        std.process.exit(1);
    };
    defer tracesDir.close(io);

    var ids: std.ArrayList(usize) = .empty;
    defer ids.deinit(gpa);

    obtainRunIds(io, gpa, tracesDir, &ids) catch |err| {
        try stderr.print("Failed to read traces dir '{s}': {}\n", .{ args.traces, err });
        try stderr.flush();
        std.process.exit(1);
    };

    const num_buckets = args.buckets;

    const bucket_ifaces = try gpa.alloc(*Io.Writer, num_buckets);
    defer gpa.free(bucket_ifaces);

    const bucketsDir = createOrClearBucketsDir(io) catch |err| {
        try stderr.print("Oof cannot init buckets dir: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };

    const bucket_writers = try gpa.alloc(BucketWriter, num_buckets);
    defer {
        for (bucket_writers) |*bw| bw.deinit(io);
        gpa.free(bucket_writers);
    }
    for (bucket_writers, bucket_ifaces, 0..) |*bw, *iface, i| {
        try bw.init(io, bucketsDir, i);
        iface.* = bw.iface();
    }

    for (ids.items) |id| {
        try processCreation(io, id, bucket_ifaces, &tracesDir);
        try processPropagation(io, id, bucket_ifaces, &tracesDir);
        try processRepost(io, id, bucket_ifaces, &tracesDir);
    }

    for (bucket_ifaces) |b| try b.flush();
    // what we have to do per trace:
    // 1. Reconstruct the cascade. -> compute things about the cascade
    // 2. Calculate Post Lifetime

    // we can go in a middle ground, which could be the "cascades" folder.
    // The folder would contain a big file with cascades.
    // - per cada node, guardem 1. qui l'ha propagat, 2. quan l'ha propagat. En essència totes les cascades són una taula d'una base de dades
    // tal que
    // - root_post_id: quina cascada és
    // - user_id: usuari que ha repiulat
    // - propagation_timestamp: quan s'ha fet la propagació (no el repost, sinó quan ha arribat)
    // - repost_timestamp: owo
    // amb això pots recrear una cascada sencera, part per part, i treure'n les dades necessàries, per exemple:
    // 1. Viralitat estructural
    // 2. Nombre de nodes.
    // 3. profunditat.
    // 4. Temps de vida del post.
    // i diverses coses que farien falta.

    // HOW TO: el com és curiós.
    // 1. llegir creation trace i identificar les roots de les cascades. (eg, store the ids in a hashmap, and the timelines in an array)
    // 2. llegir propagation, i anar afegint les propagacions d'una en una. ULL: una creació també és una propagació, així que hi haurà cert overlap
    // no sé però si lo millor seria un csv amb totes les cascades, posar-ho directament en una base de dades o fer-ho fitxer per fitxer.
    //
    // Lògica:
    // fn 1
    // open creation file
    // defer close creation file
    // return create roots: HashMap(u64, timestamp)
    //
    //
    // fn2 createCascade()
    // open propagation_file
    // defer close propagation file
    // for line in file:
    //
}

fn processRepost(io: Io, id: usize, bucket_writers: []*Io.Writer, traceDir: *const Io.Dir) !void {

    // open the creation file
    var rt_trace_buf: [32]u8 = undefined;
    const rt_trace_name = try std.fmt.bufPrint(&rt_trace_buf, "{d}-action_trace.bin", .{id});

    const prop_file = try traceDir.openFile(io, rt_trace_name, .{ .mode = .read_only });
    var buffer: [4 * 1024]u8 = undefined;
    var trace_reader = prop_file.reader(io, &buffer);
    const trace = &trace_reader.interface;

    while (try nextTrace(traces.TraceAction, trace)) |pc| {
        if (pc.type != .repost) continue;

        const hashed_id = std.hash.Wyhash.hash(0, std.mem.asBytes(&pc.post_id));
        const bucket_id = hashed_id % bucket_writers.len;

        // run_id post_id user_id type timestamp
        try bucket_writers[bucket_id].print("{d} {d} {d} {s} {d}\n", .{ id, pc.post_id, pc.user_id, "repost", pc.time });
    }

    return;
}

fn processPropagation(io: Io, id: usize, bucket_writers: []*Io.Writer, traceDir: *const Io.Dir) !void {

    // open the creation file
    var prop_trace_buf: [32]u8 = undefined;
    const prop_trace_name = try std.fmt.bufPrint(&prop_trace_buf, "{d}-propagation_trace.bin", .{id});

    const prop_file = try traceDir.openFile(io, prop_trace_name, .{ .mode = .read_only });
    var buffer: [4 * 1024]u8 = undefined;
    var trace_reader = prop_file.reader(io, &buffer);
    const trace = &trace_reader.interface;

    while (try nextTrace(traces.TracePropagation, trace)) |pc| {
        const hashed_id = std.hash.Wyhash.hash(0, std.mem.asBytes(&pc.type));
        const bucket_id = hashed_id % bucket_writers.len;

        // run_id post_id user_id type timestamp
        try bucket_writers[bucket_id].print("{d} {d} {d} {s} {d}\n", .{ id, pc.type, pc.user_id, "propagation", pc.time });
    }

    return;
}

fn processCreation(io: Io, id: usize, bucket_writers: []*Io.Writer, traceDir: *const Io.Dir) !void {

    // open the creation file
    var creation_trace_buf: [32]u8 = undefined;
    const creation_trace_name = try std.fmt.bufPrint(&creation_trace_buf, "{d}-create_trace.bin", .{id});

    const creation_file = try traceDir.openFile(io, creation_trace_name, .{ .mode = .read_only });
    var buffer: [4 * 1024]u8 = undefined;
    var trace_reader = creation_file.reader(io, &buffer);
    const trace = &trace_reader.interface;

    while (try nextTrace(traces.TraceCreate, trace)) |pc| {
        const hashed_id = std.hash.Wyhash.hash(0, std.mem.asBytes(&pc.post_id));
        const bucket_id = hashed_id % bucket_writers.len;

        // run_id post_id user_id type timestamp
        try bucket_writers[bucket_id].print("{d} {d} {d} {s} {d}\n", .{ id, pc.post_id, pc.user_id, "creation", pc.time });
    }

    return;
}

fn nextTrace(comptime T: type, reader: *Io.Reader) !?T {
    const bytes = reader.take(@sizeOf(T)) catch |err| {
        switch (err) {
            error.EndOfStream => return null,
            error.ReadFailed => return err,
        }
    };
    return std.mem.bytesAsValue(T, bytes).*;
}

fn createOrClearBucketsDir(io: Io) !Io.Dir {
    _ = try Io.Dir.cwd().createDirPathStatus(io, "buckets", .default_dir);

    const bucketsDir = try Io.Dir.cwd().openDir(io, "buckets", .{ .access_sub_paths = false, .iterate = true });

    var dir_iter = bucketsDir.iterate();
    while (try dir_iter.next(io)) |entry| {
        try bucketsDir.deleteFile(io, entry.name);
    }

    return bucketsDir;
}

// fn processCreation(
//     id,
// )
//
fn obtainRunIds(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    list: *std.ArrayList(usize),
) (error{ NoRunId, OutOfMemory } || std.fmt.ParseIntError || Io.Dir.Iterator.Error)!void {
    const Set = @import("set").Set;

    var iterator = dir.iterate();
    var run_ids: Set(usize) = .empty;
    defer run_ids.deinit(gpa);
    while (true) {
        const element = try iterator.next(io);

        if (element) |entry| {
            const len = entry.name.len;
            if (!std.mem.eql(u8, entry.name[len - 4 .. len], ".bin")) continue;

            const id = getRunId(entry.name) catch continue;
            _ = try run_ids.add(gpa, id);
        } else {
            break;
        }
    }

    // Copy the set into an array list for easy iteration
    var set_iter = run_ids.iterator();
    while (set_iter.next()) |id| {
        try list.append(gpa, id.*);
    }

    return;
}

fn getRunId(filename: []const u8) (error{NoRunId} || std.fmt.ParseIntError)!usize {
    const marker = "-";
    const index = std.mem.indexOf(u8, filename, marker);
    if (index) |i| {
        return try std.fmt.parseInt(usize, filename[0..i], 10);
    } else {
        return error.NoRunId;
    }
}
