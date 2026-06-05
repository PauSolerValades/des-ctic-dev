const std = @import("std");
const Random = std.Random;
const Io = std.Io;

const argz = @import("eazy_args");

const structs = @import("config-generic.zig");
const simulation = @import("simulation.zig");
const loader = @import("topology_loading.zig");
const entities = @import("entities.zig");
const topo = @import("topology.zig");

const SimConfig = structs.SimConfig;

const Topology = topo.Topology;
const SimState = topo.SimState;

const Arg = argz.Argument;
const Opt = argz.Option;
const Flag = argz.Flag;

const ParseErrors = argz.ParseErrors;

const def = .{
    .name = "bsky-generic",
    .description = "Bskysim with runtime JSON config",
    .required = .{
        Arg([]const u8, "data", "Data file containing the network definition"),
        Arg([]const u8, "config", "Configuration filepath to run"),
    },
    .options = .{
        Opt([]const u8, "output", "o", "./traces", "Dataset name for trace folder"),
        Opt(usize, "runs", "n", 1, "Runs to execute the simulation"),
        Opt(usize, "workers", "w", 1, "Units of parallelism"),
    },
    .flags = .{
        Flag("clean", "c", "Delete the .bin output"),
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

    const parsed_config = loader.loadJson(arena, init.io, args.config, SimConfig) catch |err| {
        try stderr.print("Error parsing config JSON file: {any}", .{err});
        try stderr.flush();
        std.process.exit(0);
    };
    const config = parsed_config.value;
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

    const startTimeWireData = Io.Timestamp.now(init.io, .real);

    var topology: Topology = try .create(arena, sampled_topology);
    defer topology.delete(arena);
    const elapsedTimeWireData = startTimeWireData.untilNow(init.io, .real);

    var samp_top_var = sampled_topology;
    samp_top_var.delete(data_alloc);
    arena_json.deinit();

    try stdout.print("Time Elapsed wiring topology: {d} ms\n", .{elapsedTimeWireData.toMilliseconds()});
    try stdout.flush();

    const data_dir = std.fs.path.dirname(args.data) orelse ".";
    const dataset_name = if (args.output.len > 0) args.output else std.fs.path.basename(data_dir);

    var traces_base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const traces_base = try std.fmt.bufPrint(&traces_base_buf, "{s}", .{dataset_name});
    cwd.createDir(init.io, "traces", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    cwd.createDirPath(init.io, traces_base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const run_dir = traces_base;

    var times_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const times_path = try std.fmt.bufPrint(&times_path_buf, "{s}/execution_times.ssv", .{run_dir});
    const times_file = try Io.Dir.cwd().createFile(init.io, times_path, .{ .truncate = true });
    defer times_file.close(init.io);

    var times_buf: [64]u8 = undefined;
    var times_writer = times_file.writerStreaming(init.io, &times_buf);
    const times_w = &times_writer.interface;
    try times_w.writeAll("batch run time_ms\n");
    try times_w.flush();

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const tio = threaded.io();

    var mutex_times: Io.Mutex = .init;

    var futures = try gpa.alloc(@TypeOf(try tio.concurrent(simulationBatch, undefined)), args.workers);
    defer gpa.free(futures);

    const runs_per_worker = args.runs / args.workers;
    const total_runs = args.runs;

    for (0..args.workers) |i| {
        const start_idx = i * runs_per_worker;
        const runs = if (i == args.workers - 1)
            total_runs - start_idx
        else
            runs_per_worker;

        const batch_args = .{
            &mutex_times,
            times_file,
            &topology,
            &config,
            seed,
            runs,
            start_idx,
            run_dir,
            i,
        };
        futures[i] = try tio.concurrent(simulationBatch, batch_args);
        try stdout.print("Spawned batch {d} with {d} runs\n", .{ i, runs });
    }
    try stdout.flush();

    for (0..args.workers) |i| {
        try futures[i].await(tio);
    }
}

fn simulationBatch(
    mutex_times: *Io.Mutex,
    times_file: Io.File,
    topology: *const Topology,
    config: *const SimConfig,
    seed: u64,
    runs: usize,
    start_idx: usize,
    run_dir: []const u8,
    worker_id: usize,
) !void {
    var aa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    var general: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const deinit_status = general.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }
    const gpa = general.allocator();

    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &buffer);
    const stdout = &stdout_writer.interface;

    var prng: Random.DefaultPrng = .init(seed);

    var state: SimState = try .create(io, arena, gpa, prng.random(), topology);
    defer state.delete(arena, gpa);

    var times_buf: [256]u8 = undefined;
    var times_writer = times_file.writerStreaming(io, &times_buf);
    const times_w = &times_writer.interface;

    // Discarding writer — reused across runs when tracing is off.
    // The underlying buffer is empty: no buffering, everything drains to /dev/null.
    var discarding = Io.Writer.Discarding.init(&.{});
    const discarding_writer: *Io.Writer = &discarding.writer;

    const action_name = "action_trace.bin";
    const session_name = "session_trace.bin";
    const create_name = "create_trace.bin";
    const propagation_name = "propagation_trace.bin";

    for (0..runs) |i| {
        const run_idx = start_idx + i;

        const run_seed = seed +% std.hash.Wyhash.hash(0, std.mem.asBytes(&run_idx));
        prng.seed(run_seed);

        const rng = prng.random();

        // Two clear code paths, chosen at runtime:
        //   trace=true  → open real files, write traces, convert to jsonl
        //   trace=false → discarding writers, no file I/O at all
        if (config.trace_to_file) {
            var action_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
            const action_bin = try std.fmt.bufPrint(&action_bin_buf, "{s}/{d}-{s}", .{ run_dir, run_idx, action_name });
            var session_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
            const session_bin = try std.fmt.bufPrint(&session_bin_buf, "{s}/{d}-{s}", .{ run_dir, run_idx, session_name });
            var create_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
            const create_bin = try std.fmt.bufPrint(&create_bin_buf, "{s}/{d}-{s}", .{ run_dir, run_idx, create_name });
            var prop_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
            const prop_bin = try std.fmt.bufPrint(&prop_bin_buf, "{s}/{d}-{s}", .{ run_dir, run_idx, propagation_name });

            var action_buffer: [64 * 1024]u8 = undefined;
            var session_buffer: [64 * 1024]u8 = undefined;
            var create_buffer: [64 * 1024]u8 = undefined;
            var propagation_buffer: [64 * 1024]u8 = undefined;

            const cwd = Io.Dir.cwd();
            const action_file = try cwd.createFile(io, action_bin, .{});
            defer action_file.close(io);
            var action_file_writer = action_file.writer(io, &action_buffer);
            const action_writer = &action_file_writer.interface;

            const session_file = try cwd.createFile(io, session_bin, .{});
            defer session_file.close(io);
            var session_file_writer = session_file.writer(io, &session_buffer);
            const session_writer = &session_file_writer.interface;

            const create_file = try cwd.createFile(io, create_bin, .{});
            defer create_file.close(io);
            var create_file_writer = create_file.writer(io, &create_buffer);
            const create_writer = &create_file_writer.interface;

            const prop_file = try cwd.createFile(io, prop_bin, .{});
            defer prop_file.close(io);
            var prop_file_writer = prop_file.writer(io, &propagation_buffer);
            const prop_writer = &prop_file_writer.interface;

            const startTime = Io.Timestamp.now(io, .cpu_thread);
            _ = try simulation.simulate(
                gpa,
                arena,
                rng,
                config,
                topology,
                &state,
                action_writer,
                session_writer,
                create_writer,
                prop_writer,
            );
            const elapsedTime = startTime.untilNow(io, .cpu_thread);

            try mutex_times.lock(io);
            try times_w.print("{d} {d} {d}\n", .{ worker_id, run_idx, elapsedTime.toMilliseconds() });
            try times_w.flush();
            mutex_times.unlock(io);

            // JSONL conversion
            var jsonl_buf: [std.fs.max_path_bytes]u8 = undefined;

            const action_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/{d}-action_trace.jsonl", .{ run_dir, i });
            try bytesToJsonl(io, entities.TraceAction, action_bin, action_jsonl);

            const session_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/{d}-session_trace.jsonl", .{ run_dir, i });
            try bytesToJsonl(io, entities.TraceSession, session_bin, session_jsonl);

            const create_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/{d}-create_trace.jsonl", .{ run_dir, i });
            try bytesToJsonl(io, entities.TraceCreate, create_bin, create_jsonl);

            const prop_jsonl = try std.fmt.bufPrint(&jsonl_buf, "{s}/{d}-propagate_trace.jsonl", .{ run_dir, i });
            try bytesToJsonl(io, entities.TracePropagation, prop_bin, prop_jsonl);

            try stdout.print("[Batch {d} - {d}] - Execution time: {d} ms\n", .{ worker_id, run_idx, elapsedTime.toMilliseconds() });
            try stdout.flush();
        } else {
            const startTime = Io.Timestamp.now(io, .cpu_thread);
            _ = try simulation.simulate(
                gpa,
                arena,
                rng,
                config,
                topology,
                &state,
                discarding_writer,
                discarding_writer,
                discarding_writer,
                discarding_writer,
            );
            const elapsedTime = startTime.untilNow(io, .cpu_thread);

            try mutex_times.lock(io);
            try times_w.print("{d} {d} {d}\n", .{ worker_id, run_idx, elapsedTime.toMilliseconds() });
            try times_w.flush();
            mutex_times.unlock(io);

            try stdout.print("[Batch {d} - {d}] - Execution time: {d} ms\n", .{ worker_id, run_idx, elapsedTime.toMilliseconds() });
            try stdout.flush();
        }

        state.reset();
    }

    return;
}

fn bytesToJsonl(io: Io, comptime T: type, read_file: []const u8, write_file: []const u8) !void {
    const n = @sizeOf(T);

    var jsonl_buffer: [4 * 1024]u8 = undefined;
    const jsonl_file = try Io.Dir.cwd().createFile(io, write_file, .{ .read = false });
    defer jsonl_file.close(io);
    var jsonl_file_writer = jsonl_file.writer(io, &jsonl_buffer);
    const writer = &jsonl_file_writer.interface;

    if (Io.Dir.cwd().openFile(io, read_file, .{})) |file| {
        defer file.close(io);

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
        else => |e| return e,
    }

    try writer.flush();
}
