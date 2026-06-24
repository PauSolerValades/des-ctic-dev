const std = @import("std");
const Io = std.Io;

const e = @import("entities.zig");

/// Auxiliar struct for trace writing. Contains all
/// the entities that need to be written on the trace
pub const TraceAction = struct {
    time: f64,
    event_id: u64,
    gen_id: u64,
    user_id: u32,
    post_id: u32,
    type: e.Action,
};

pub const TraceCreate = struct {
    time: f64,
    event_id: u64,
    gen_id: u64,
    user_id: u32,
    post_id: u32,
};

pub const TraceSession = struct {
    time: f64,
    event_id: u64,
    gen_id: u64,
    user_id: u32,
    type: e.Session,
    backlog: u32,
};

pub const TracePropagation = struct {
    time: f64,
    event_id: u64,
    gen_id: u64,
    user_id: u32,
    type: u32,
};

/// Bundles the four trace writers into a single struct so they can be passed
/// as one parameter instead of four. Each field is a pointer to an Io.Writer.
pub const TraceWriters = struct {
    action: *Io.Writer,
    session: *Io.Writer,
    create: *Io.Writer,
    propagate: *Io.Writer,
};

/// converts the json to traces
pub fn bytesToJsonl(io: Io, comptime T: type, read_file: []const u8, write_file: []const u8) !void {
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
        else => return err,
    }

    try writer.flush();
}
