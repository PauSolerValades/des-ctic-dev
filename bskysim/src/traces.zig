const Io = @import("std").Io;
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
