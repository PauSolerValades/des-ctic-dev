const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Random = std.Random;
const eql = std.mem.eql;
const Io = std.Io;

const argz = @import("eazy_args");

const structs = @import("config.zig");

const simulation = @import("simulation.zig");

const loader = @import("json_loading.zig");
const gn = @import("graph_network.zig");
const entities = @import("entities.zig");

const Distribution = structs.Distribution;
const SimConfig = structs.SimConfig;
const SimResults = structs.SimResults;

const User = simulation.User;
const Post = simulation.Post;
const TimelineEvent = simulation.TimelineEvent;

const Arg = argz.Argument;
const ParseErrors = argz.ParseErrors;

const def = .{
    .name = "v4",
    .description = "Bsky sim",
    .required = .{
        Arg([]const u8, "data", "Data file containing the network definition"),
    },
    .options = .{
        argz.Option([]const u8, "name", "n", "", "Dataset name for trace folder (default: derived from data path)"),
    },
};

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;

    var bufferr: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &bufferr);
    const stderr = &stderr_writer.interface;

    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const cwd = Io.Dir.cwd();

    var iter = init.minimal.args.iterate();
    const args = argz.parseArgsPosix(def, &iter, stdout, stderr) catch |err| {
        switch (err) {
            ParseErrors.HelpShown => try stdout.flush(),
            else => try stderr.flush(),
        }
        std.process.exit(0);
    };

    var arena_json: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const data_alloc = arena_json.allocator();

    const config = try SimConfig.calibrate(gpa);
    defer config.deinit(gpa);

    const startTimeLoadData = Io.Timestamp.now(init.io, .real);
    const sampled_topology = try loader.BinaryGraph.create(init.io, data_alloc, args.data);
    const elapsedTimeLoadData = startTimeLoadData.untilNow(init.io, .real);

    try stdout.print("Time Elapsed Loading Data: {d} ms\n", .{elapsedTimeLoadData.toMilliseconds()});
    try stdout.flush();

    const seed = if (config.seed) |s| s else blk: {
        var os_seed: u64 = undefined;
        init.io.random(std.mem.asBytes(&os_seed));
        break :blk os_seed;
    };

    var prng = Random.DefaultPrng.init(seed);
    const rng = prng.random();

    const startTimeWireData = Io.Timestamp.now(init.io, .real);
    var graph: gn.Topology = try .create(init.io, gpa, arena, rng, sampled_topology);
    defer graph.delete(gpa, arena);
    const elapsedTimeWireData = startTimeWireData.untilNow(init.io, .real);

    // the lifetime of this data ends here
    var samp_top_var = sampled_topology;
    samp_top_var.delete(data_alloc);
    arena_json.deinit();

    try stdout.print("Time Elapsed Wiring Data: {d} ms\n", .{elapsedTimeWireData.toMilliseconds()});
    try stdout.flush();

    try stdout.writeAll("Running the simulation\n");
    try stdout.flush();

    // create the results folder
    // cwd.access(init.io, "results", .{}) catch |err| switch (err) {
    //     error.FileNotFound => try cwd.createDir(init.io, "results", .{ .mode = Oo755} ),
    //     else => return err,
    // };

    // const timestamp = Io.Clock.real.now(init.io);
    // buffers to hold the formatted file paths to avoid dynamic memory
    // var trace_path_buffer: [256]u8 = undefined;
    // const traca_path = try std.fmt.bufPrint(&traca_path_buffer, "traca_{d}.txt", .{timestamp});

    const action_name = "action_trace.bin";
    const session_name = "session_trace.bin";
    const create_name = "create_trace.bin";
    const propagation_name = "propagation_trace.bin";

    const data_dir = std.fs.path.dirname(args.data) orelse ".";
    const dataset_name = if (args.name.len > 0) args.name else std.fs.path.basename(data_dir);

    // create traces/<dataset>/ base dir
    var traces_base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const traces_base = try std.fmt.bufPrint(&traces_base_buf, "traces/{s}", .{dataset_name});
    cwd.createDir(init.io, "traces", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    cwd.createDirPath(init.io, traces_base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // log execution times per run
    const run_dir = traces_base;

    var times_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const times_path = try std.fmt.bufPrint(&times_path_buf, "{s}/execution_times.txt", .{run_dir});
    const times_file = try cwd.createFile(init.io, times_path, .{});
    var times_buf: [256]u8 = undefined;
    var times_writer = times_file.writer(init.io, &times_buf);
    const times_w = &times_writer.interface;

    // Paths for binary traces inside the run dir
    var action_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const action_bin = try std.fmt.bufPrint(&action_bin_buf, "{s}/{s}", .{ run_dir, action_name });
    var session_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const session_bin = try std.fmt.bufPrint(&session_bin_buf, "{s}/{s}", .{ run_dir, session_name });
    var create_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const create_bin = try std.fmt.bufPrint(&create_bin_buf, "{s}/{s}", .{ run_dir, create_name });
    var prop_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prop_bin = try std.fmt.bufPrint(&prop_bin_buf, "{s}/{s}", .{ run_dir, propagation_name });

    var action_buffer: [64 * 1024]u8 = undefined;
    var session_buffer: [64 * 1024]u8 = undefined;
    var create_buffer: [64 * 1024]u8 = undefined;
    var propagation_buffer: [64 * 1024]u8 = undefined;

    const action_file = try cwd.createFile(init.io, action_bin, .{});
    var action_file_writer = action_file.writer(init.io, &action_buffer);
    const action_writer = &action_file_writer.interface;

    const session_file = try cwd.createFile(init.io, session_bin, .{});
    var session_file_writer = session_file.writer(init.io, &session_buffer);
    const session_writer = &session_file_writer.interface;

    const create_file = try cwd.createFile(init.io, create_bin, .{});
    var create_file_writer = create_file.writer(init.io, &create_buffer);
    const create_writer = &create_file_writer.interface;

    const prop_file = try cwd.createFile(init.io, prop_bin, .{});
    var prop_file_writer = prop_file.writer(init.io, &propagation_buffer);
    const prop_writer = &prop_file_writer.interface;

    const startTime = Io.Timestamp.now(init.io, .real);
    try graph.reset(arena);
    const results = try simulation.simulate(
        gpa,
        arena,
        rng,
        &config,
        &graph,
        action_writer,
        session_writer,
        create_writer,
        prop_writer,
    );
    const elapsedTime = startTime.untilNow(init.io, .real);

    try stdout.print("Run: {d} ms\n", .{elapsedTime.toMilliseconds()});
    try times_w.print("{d} {d} {d}\n", .{ elapsedTimeLoadData.toMilliseconds(), elapsedTimeWireData.toMilliseconds(), elapsedTime.toMilliseconds() });
    try times_w.flush();
    try stdout.print("{f}\n", .{results});
    try stdout.flush();

    // Convert binary traces to JSONL
    try stdout.writeAll("Converting traces into JSONL\n");
    var jsonl_buf: [std.fs.max_path_bytes]u8 = undefined;

    const action_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/action_trace.jsonl", .{run_dir});
    try bytesToJsonl(init.io, entities.TraceAction, action_bin, action_jsonl);

    const session_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/session_trace.jsonl", .{run_dir});
    try bytesToJsonl(init.io, entities.TraceSession, session_bin, session_jsonl);

    const create_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/create_trace.jsonl", .{run_dir});
    try bytesToJsonl(init.io, entities.TraceCreate, create_bin, create_jsonl);

    const prop_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/propagate_trace.jsonl", .{run_dir});
    try bytesToJsonl(init.io, entities.TracePropagation, prop_bin, prop_jsonl);

    try stdout.flush();
}

/// this probably could be much more prettier if I passed the Io.Writer/Io.Reader by parameter, and I
/// could even reuse the buffers... but dunno, at least this is pretty efficient :D
fn bytesToJsonl(io: Io, comptime T: type, read_file: []const u8, write_file: []const u8) !void {
    const n = @sizeOf(T);

    var jsonl_buffer: [4 * 1024]u8 = undefined;
    const jsonl_file = try Io.Dir.cwd().createFile(io, write_file, .{ .read = false });
    var jsonl_file_writer = jsonl_file.writer(io, &jsonl_buffer);
    const writer = &jsonl_file_writer.interface;

    if (Io.Dir.cwd().openFile(io, read_file, .{})) |file| {
        var buf: [4 * 1024]u8 = undefined;
        var reader: Io.File.Reader = file.reader(io, &buf);
        const ri = &reader.interface;

        while (true) {
            const bytes = ri.take(n) catch |err| {
                switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return reader.err.?,
                }
            };

            const event = std.mem.bytesAsValue(T, bytes);
            try std.json.Stringify.value(event, .{}, writer);
            try writer.writeAll("\n");
        }
    } else |err| switch (err) {
        error.FileNotFound, error.AccessDenied => {
            std.debug.print("unable to open file: {}\n", .{err});
        },
        else => |e| return e, // don't continue; rather, bomb out
    }

    try writer.flush();
}
