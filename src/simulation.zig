const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Random = std.Random;
const Io = std.Io;
const Order = std.math.Order;

const DaryHeap = @import("ds").DaryHeap;

const dist = @import("distributions");

const config = @import("config.zig");
const entities = @import("entities.zig");
const topo = @import("topology.zig");
const gen = @import("events.zig");

const Topology = topo.Topology;
const SimState = topo.SimState;

const ds_pkg = @import("ds");
const SMAList = ds_pkg.SegmentedMultiArrayList;
const PagedBitSet = ds_pkg.PagedBitSet;

const SimResults = config.SimResults;
const SimConfig = config.SimConfig;

const Precision = config.Precision;

const Event = entities.Event;
const Action = entities.Action;
const Session = entities.Session;
const User = entities.User;
const Post = entities.Post;
const TraceAction = entities.TraceAction;
const TraceSession = entities.TraceSession;
const TraceCreate = entities.TraceCreate;
const TracePropagation = entities.TracePropagation;

const TimelineEvent = entities.TimelineEvent;
const compareTimelineEvent = entities.compareTimelineEvent;
const Index = entities.Index;

const EventQueue: type = DaryHeap(Event, 8, void, entities.compareEvent);

pub const SimMetrics = struct {
    processed_events: u64 = 0,
    generated_events: u64 = 0,
    dropped_events: u64 = 0,

    post_count: u32 = 0,

    impressions: u64 = 0,
    reposts: u64 = 0,
    likes: u64 = 0,
    ignored: u64 = 0,

    total_sessions: u64 = 0,
    total_online_time: f64 = 0.0,
    empty_timeline_ends: u64 = 0,
    max_duration_ends: u64 = 0,
};

const Unif = dist.Uniform(Precision);

fn propagatePost(gpa: Allocator, topology: *const Topology, state: *SimState, t_clock: f64, user_id: u32, post_id: Index) !void {
    const start_idx = topology.start[user_id];
    const end_idx = if (user_id + 1 < state.users.len)
        topology.start[user_id + 1]
    else
        @as(u32, @intCast(topology.start[user_id]));
    const count = end_idx - start_idx;
    const followers = topology.csr[start_idx .. start_idx + count];

    const tl_event = TimelineEvent{
        .time = t_clock,
        .post_id = post_id,
    };

    for (followers) |fid| {
        // Skip if follower already interacted with this post (liked/reposted).
        // This avoids useless heap insertions for posts that would be skipped later.
        if (state.user_interact_post.isSet(fid, post_id)) continue;
        try state.timelines[fid].add(gpa, tl_event);
    }
}

fn stageOne(
    gpa: Allocator,
    arena: Allocator,
    rng: Random,
    simconf: *const SimConfig,
    topology: *const Topology,
    state: *SimState,
    queue: *EventQueue,
    metrics: *SimMetrics,
    t_clock: *f64,
    create_trace: *Io.Writer,
    propagate_trace: *Io.Writer,
) !void {

    // We create an event per user to kickstart the user posts.
    try state.user_seen_post.ensureItemCapacity(arena, state.users.len);
    try state.user_interact_post.ensureItemCapacity(arena, state.users.len);
    for (0..state.users.len) |uid| {
        // we create a creation event
        const create_post = gen.eventCreateWarmup(rng, simconf, @intCast(uid), metrics.generated_events);
        try queue.add(gpa, create_post);
        metrics.generated_events += 1;
    }

    while (t_clock.* <= simconf.warmup_time and queue.items.len > 0) {
        const current_event = queue.remove();
        t_clock.* = current_event.time;

        const current_uid = current_event.user_id;
        const gen_id = current_event.id;

        switch (current_event.type) {
            .create => {
                const new_post_id = metrics.post_count;

                try state.posts.append(arena, .{ .id = new_post_id, .author = current_uid });
                try state.user_seen_post.ensureItemCapacity(arena, new_post_id);
                try state.user_interact_post.ensureItemCapacity(arena, new_post_id);
                // creator has seen and implicitly interacted with their own post
                state.user_seen_post.set(current_uid, new_post_id);
                state.user_interact_post.set(current_uid, new_post_id);

                const propagate = gen.eventPropagate(rng, simconf, t_clock.*, current_uid, new_post_id, metrics.generated_events);
                try queue.add(gpa, propagate);
                metrics.generated_events += 1;

                const c = TraceCreate{ .time = t_clock.*, .user_id = current_uid, .post_id = metrics.post_count, .event_id = metrics.processed_events, .gen_id = gen_id };
                const bytes = std.mem.asBytes(&c);
                try create_trace.writeAll(bytes);

                metrics.post_count += 1;

                const new_post = gen.eventCreatePost(rng, simconf, &state.users, t_clock.*, current_uid, state.users.items(.session_gen)[current_uid], metrics.generated_events);
                try queue.add(gpa, new_post);
                metrics.generated_events += 1;
            },
            .propagate => |post_id| {
                try propagatePost(gpa, topology, state, t_clock.*, current_uid, post_id);
                const p = TracePropagation{ .time = t_clock.*, .type = post_id, .user_id = current_uid, .event_id = metrics.processed_events, .gen_id = gen_id };
                const bytes = std.mem.asBytes(&p);
                try propagate_trace.writeAll(bytes);
            },
            else => unreachable,
        }
        metrics.processed_events += 1; // an event is always processed, there is no continues
    }
}

pub fn initSessions(
    gpa: Allocator,
    rng: Random,
    simconf: *const SimConfig,
    state: *SimState,
    queue: *EventQueue,
    metrics: *SimMetrics,
    t_clock: f64,
    session_trace: *Io.Writer,
) !void {
    const unif: Unif = .init(0, 1, dist.Interval.cc);

    for (0..state.users.len) |uid| {
        // this is to avoid potential problems :)
        // graph.timelines[uid].clearRetainingCapacity();

        const r = unif.sample(rng);
        if (r < simconf.offline_startup_ratio) { // user starts offline
            state.users.items(.is_online)[uid] = false;

            const event_start = gen.eventSessionStart(rng, &state.users, t_clock, @intCast(uid), 0, metrics.generated_events);
            try queue.add(gpa, event_start);
            metrics.generated_events += 1;
        } else { // users starts online
            state.users.items(.is_online)[uid] = true;
            state.users.items(.session_start_time)[uid] = t_clock;
            metrics.total_sessions += 1;

            // as user starts online, we log this into the session trace, it's both a generation and a processed event
            const s = TraceSession{ .time = t_clock, .type = .start, .user_id = @intCast(uid), .event_id = metrics.processed_events, .gen_id = metrics.generated_events, .backlog = 0 };
            const bytes = std.mem.asBytes(&s);
            try session_trace.writeAll(bytes);
            metrics.*.generated_events += 1;
            metrics.*.processed_events += 1;

            const event_end = gen.eventSessionEnd(rng, &state.users, t_clock, @intCast(uid), 0, metrics.generated_events);
            try queue.add(gpa, event_end);
            metrics.*.generated_events += 1;
        }
    }
}

pub fn simulate(gpa: Allocator, arena: Allocator, rng: Random, simconf: *const SimConfig, topology: *const Topology, state: *SimState, action_trace: *Io.Writer, session_trace: *Io.Writer, create_trace: *Io.Writer, propagate_trace: *Io.Writer) !SimResults {
    var t_clock: f64 = 0.0;

    var metrics = SimMetrics{};

    var queue: EventQueue = .empty;
    try queue.ensureTotalCapacity(gpa, 4 * topology.csr.len);
    defer queue.deinit(gpa);

    // Pgraphost generation on init
    try stageOne(gpa, arena, rng, simconf, topology, state, &queue, &metrics, &t_clock, create_trace, propagate_trace);
    // queue.clearRetainingCapacity();

    // decide which users start online or not
    try initSessions(gpa, rng, simconf, state, &queue, &metrics, t_clock, session_trace);

    // combine this with the initSessions, it's dumb to iterate twice xd
    // set online users first action
    for (0..state.users.len) |uid| {
        if (state.users.items(.is_online)[uid]) {
            const first_action = gen.eventAction(rng, simconf, t_clock, @intCast(uid), 0, metrics.generated_events);
            try queue.add(gpa, first_action);
            metrics.generated_events += 1;

            // const new_post = eventCreatePost(rng, simconf, t_clock, @intCast(uid), 0, graph.users.items(.session_gen)[uid], metrics.generated_events);
            // try queue.add(gpa, new_post);
            // metrics.generated_events += 1;
        }
    }

    const t_end = @min(simconf.warmup_time + simconf.duration, simconf.horizon);
    while (t_clock <= t_end and queue.items.len > 0) {
        const current_event = queue.remove();
        const current_uid: Index = current_event.user_id;
        const gen_id = current_event.id;
        std.debug.assert(current_event.time >= t_clock);
        t_clock = current_event.time;

        switch (current_event.type) {
            .create => {
                const is_event_stale: bool = current_event.session_gen != state.users.items(.session_gen)[current_uid];
                const is_user_online: bool = state.users.items(.is_online)[current_uid];
                // Note: if an event is stale the user cannot be online. it's just a double check
                if (is_event_stale or !is_user_online) {
                    metrics.dropped_events += 1;
                    continue;
                }
                const new_post_id = metrics.post_count;

                state.users.items(.num_posts)[current_uid] += 1;
                try state.user_seen_post.ensureItemCapacity(arena, new_post_id);
                try state.user_interact_post.ensureItemCapacity(arena, new_post_id);
                // creator has seen and implicitly interacted with their own post
                state.user_seen_post.set(current_uid, new_post_id);
                state.user_interact_post.set(current_uid, new_post_id);

                const propagate = gen.eventPropagate(rng, simconf, t_clock, current_uid, new_post_id, metrics.generated_events);
                try queue.add(gpa, propagate);
                metrics.generated_events += 1;

                const c = TraceCreate{ .time = t_clock, .user_id = current_uid, .post_id = new_post_id, .event_id = metrics.processed_events, .gen_id = gen_id };
                const bytes = std.mem.asBytes(&c);
                try create_trace.writeAll(bytes);
                metrics.post_count += 1;
                metrics.processed_events += 1;

                const new_post = gen.eventCreatePost(rng, simconf, &state.users, t_clock, current_uid, state.users.items(.session_gen)[current_uid], metrics.generated_events);
                try queue.add(gpa, new_post);
                metrics.generated_events += 1;
            },

            .session => |ssn| {
                // a session can be stale due to the catch up mechanic.
                const is_event_stale: bool = current_event.session_gen != state.users.items(.session_gen)[current_uid];
                if (ssn == .end and (!state.users.items(.is_online)[current_uid] or is_event_stale)) {
                    metrics.dropped_events += 1;
                    continue;
                }

                const backlog: u32 = if (ssn == .end) @intCast(state.timelines[current_uid].items.len) else 0;
                const s = TraceSession{ .time = t_clock, .type = ssn, .user_id = current_uid, .event_id = metrics.processed_events, .gen_id = gen_id, .backlog = backlog };
                const bytes = std.mem.asBytes(&s);
                try session_trace.writeAll(bytes);

                switch (ssn) {
                    .start => {
                        state.users.items(.is_online)[current_uid] = true;
                        state.users.items(.session_gen)[current_uid] += 1;

                        state.users.items(.session_start_time)[current_uid] = t_clock; // Record start time
                        metrics.total_sessions += 1;

                        const first_action = gen.eventAction(rng, simconf, t_clock, current_uid, state.users.items(.session_gen)[current_uid], metrics.generated_events);
                        try queue.add(gpa, first_action);
                        metrics.generated_events += 1;

                        const new_post = gen.eventCreatePost(rng, simconf, &state.users, t_clock, current_uid, state.users.items(.session_gen)[current_uid], metrics.generated_events);
                        try queue.add(gpa, new_post);
                        metrics.generated_events += 1;

                        const end_session = gen.eventSessionEnd(rng, &state.users, t_clock, current_uid, state.users.items(.session_gen)[current_uid], metrics.generated_events);
                        try queue.add(gpa, end_session);
                        metrics.generated_events += 1;
                    },
                    .end => {
                        // schedule users wake up time
                        state.users.items(.is_online)[current_uid] = false;
                        // metrics
                        metrics.total_online_time += (t_clock - state.users.items(.session_start_time)[current_uid]);
                        metrics.max_duration_ends += 1;

                        const start_session = gen.eventSessionStart(rng, &state.users, t_clock, current_uid, state.users.items(.session_gen)[current_uid], metrics.generated_events);
                        try queue.add(gpa, start_session);
                        metrics.generated_events += 1;

                        // post non seen when session finished will get nuked
                        state.timelines[current_uid].clearRetainingCapacity();
                    },
                }
                metrics.processed_events += 1; // both .end and .start do not skip the loop, so its okay to put it here:
            },

            .action => |act| {
                const is_event_stale: bool = current_event.session_gen != state.users.items(.session_gen)[current_uid];
                const is_user_online: bool = state.users.items(.is_online)[current_uid];

                if (is_event_stale or !is_user_online) {
                    metrics.dropped_events += 1;
                    continue;
                }

                if (state.timelines[current_uid].items.len != 0) {
                    // Drain already-interacted posts inline to avoid bouncing
                    // through the global event queue for each skipped post.
                    var post_id: ?Index = null;
                    while (state.timelines[current_uid].items.len != 0) {
                        const p = state.timelines[current_uid].remove();
                        if (!state.user_interact_post.isSet(current_uid, p.post_id)) {
                            post_id = p.post_id;
                            break;
                        }
                    }

                    if (post_id) |pid| {
                        const a = TraceAction{ .time = t_clock, .type = act, .user_id = current_uid, .post_id = pid, .event_id = metrics.processed_events, .gen_id = gen_id };
                        const bytes = std.mem.asBytes(&a);
                        try action_trace.writeAll(bytes);

                        // Always mark as seen (diagnostic: counts every exposure)
                        state.user_seen_post.set(current_uid, pid);
                        metrics.impressions += 1;

                        switch (act) {
                            .repost => {
                                // desensitized: user propagated, can't interact with this post again
                                state.user_interact_post.set(current_uid, pid);

                                const propagate = gen.eventPropagate(rng, simconf, t_clock, current_uid, pid, metrics.generated_events);
                                try queue.add(gpa, propagate);
                                metrics.generated_events += 1;
                                metrics.reposts += 1;
                            },
                            .like => {
                                // desensitized: user consumed and acknowledged (platform prevents double-liking)
                                state.user_interact_post.set(current_uid, pid);
                                metrics.likes += 1;
                            },
                            .ignore => {
                                // NOT desensitized: user can be re-exposed to this post via another propagation
                                // (aligned with Independent Cascade model: exposure ≠ adoption)
                                metrics.ignored += 1;
                            },
                        }
                        metrics.processed_events += 1;

                        const event = gen.eventAction(rng, simconf, t_clock, current_uid, state.users.items(.session_gen)[current_uid], metrics.generated_events);
                        try queue.add(gpa, event);
                        metrics.generated_events += 1;
                    }
                } else {
                    state.users.items(.is_online)[current_uid] = false;

                    metrics.total_online_time += (t_clock - state.users.items(.session_start_time)[current_uid]);
                    metrics.empty_timeline_ends += 1;
                    state.users.items(.session_gen)[current_uid] += 1;

                    const s = TraceSession{ .time = t_clock, .type = .end, .user_id = current_uid, .event_id = metrics.processed_events, .gen_id = gen_id, .backlog = 0 };
                    const bytes = std.mem.asBytes(&s);
                    try session_trace.writeAll(bytes);

                    const bored_start = gen.eventSessionStart(rng, &state.users, t_clock, current_uid, state.users.items(.session_gen)[current_uid], metrics.generated_events);
                    try queue.add(gpa, bored_start);
                    metrics.generated_events += 1;
                    metrics.processed_events += 1;
                    // no need to nuke the timeline, it's already empty
                }
            },

            .propagate => |post_id| {
                try propagatePost(gpa, topology, state, t_clock, current_uid, post_id);
                const p = TracePropagation{ .time = t_clock, .type = post_id, .user_id = current_uid, .event_id = metrics.processed_events, .gen_id = gen_id };
                const bytes = std.mem.asBytes(&p);
                try propagate_trace.writeAll(bytes);
                metrics.processed_events += 1;
            },
        }
    }

    try action_trace.flush();
    try session_trace.flush();
    try create_trace.flush();
    try propagate_trace.flush();

    var total_backlog: usize = 0;
    for (state.timelines) |*timeline| {
        const v = timeline.items.len;
        total_backlog += v;
    }

    const mean: f64 = @as(f64, @floatFromInt(total_backlog)) / @as(f64, @floatFromInt(state.users.len));

    var sum_sq_diff: f64 = 0.0;
    for (state.timelines) |*timeline| {
        const v: f64 = @floatFromInt(timeline.items.len);
        const diff = v - mean;
        sum_sq_diff += diff * diff;
    }

    const backlog_variance = sum_sq_diff / @as(f64, @floatFromInt(state.users.len - 1));
    const std_dev = std.math.sqrt(backlog_variance);

    const margin_error = 1.96 * (std_dev / std.math.sqrt(@as(f64, @floatFromInt(state.users.len))));
    const interactions = metrics.likes + metrics.reposts;

    const result = SimResults{
        .processed_events = metrics.processed_events,
        .generated_events = metrics.generated_events,
        .dropped_events = metrics.dropped_events,
        .duration = t_clock,
        .total_likes = metrics.likes,
        .total_reposts = metrics.reposts,
        .total_interactions = interactions,
        .total_ignored = metrics.ignored,
        .total_impressions = metrics.impressions,
        .avg_impressions_per_user = @as(f64, @floatFromInt(metrics.impressions)) / @as(f64, @floatFromInt(state.users.len)),
        .engagement_rate = @as(f64, @floatFromInt(interactions)) / @as(f64, @floatFromInt(metrics.impressions)),
        .avg_backlog = mean,
        .variance_backlog = backlog_variance,
        .ci_backlog = margin_error,
        .total_sessions = metrics.total_sessions,
        .avg_session_length = metrics.total_online_time / @as(f64, @floatFromInt(metrics.total_sessions)),
        .avg_post_per_session = @as(f64, @floatFromInt(metrics.impressions)) / @as(f64, @floatFromInt(metrics.total_sessions)),
        .timeline_drain_ratio = @as(f64, @floatFromInt(metrics.empty_timeline_ends)) / @as(f64, @floatFromInt(metrics.total_sessions)),
        .posts_at_warmup = @as(f64, @floatFromInt(metrics.post_count)) / @as(f64, @floatFromInt(state.user_interact_post.len)),
    };

    return result;
}

fn writeToTrace(comptime T: type, writer: *Io.Writer, event: T) !void {
    switch (T) {
        TraceAction, TraceSession, TraceCreate, TracePropagation => {},
        else => @compileError("Unsupported trace type passed"),
    }

    try std.json.Stringify.value(event, .{}, writer);
    try writer.writeAll("\n");
}
