//! The libyaml event stream shared by every zaml host.
//!
//! A source turns YAML text into a sequence of events; a sink turns those
//! events into values. The dispatch loop in this file is the only place
//! that knows how an event maps onto a sink call, so every host sees
//! exactly the same event stream.
//!
//! The loop deliberately does not resolve anchors. Each host keeps its own
//! anchor table, exactly as it did before, and looks aliases up by name.

const std = @import("std");

/// The kind of event in the stream.
pub const Type = enum {
    /// An event the core does not care about (stream and document markers).
    noop,
    scalar,
    seq_start,
    seq_end,
    map_start,
    map_end,
    alias,
};

/// One event of the stream.
///
/// The slices point into buffers owned by the source and are only valid
/// until the next event is requested.
pub const Event = struct {
    type: Type,
    /// The scalar text, or the alias name.
    value: []const u8 = "",
    /// The expanded tag of a scalar, empty when it has none.
    tag: []const u8 = "",
    /// The anchor name, null when there is none.
    anchor: ?[]const u8 = null,
};

/// Details of a failed parse.
pub const Problem = struct {
    context_buf: [192]u8 = undefined,
    context_len: usize = 0,
    problem_buf: [256]u8 = undefined,
    problem_len: usize = 0,
    /// 1-based line of the error.
    line: u32 = 0,
    /// 1-based column of the error.
    column: u32 = 0,

    pub fn context(self: *const Problem) []const u8 {
        return self.context_buf[0..self.context_len];
    }

    pub fn problem(self: *const Problem) []const u8 {
        return self.problem_buf[0..self.problem_len];
    }
};

/// The sink interface every host implements.
///
///   scalar(value, tag, anchor) - a scalar event
///   seqStart(anchor)           - a sequence start (anchor may be null)
///   seqEnd()                   - a sequence end
///   mapStart(anchor)           - a mapping start (anchor may be null)
///   mapEnd()                   - a mapping end
///   alias(anchor)              - an alias event
///
/// A source implements:
///
///   next(self) - the next event, or null at the end of the stream
///   takeProblem(self) - the details of the last error
pub fn dispatch(comptime Source: type, source: *Source, comptime Sink: type, sink: *Sink) anyerror!void {
    while (true) {
        const ev = (try source.next()) orelse return;
        switch (ev.type) {
            .noop => {},
            .scalar => try sink.scalar(ev.value, ev.tag, ev.anchor),
            .seq_start => try sink.seqStart(ev.anchor),
            .seq_end => try sink.seqEnd(),
            .map_start => try sink.mapStart(ev.anchor),
            .map_end => try sink.mapEnd(),
            .alias => try sink.alias(ev.value),
        }
    }
}

/// Run `source` into `sink`, recording the failure details in `problem`.
pub fn run(comptime Source: type, source: *Source, comptime Sink: type, sink: *Sink, problem: ?*Problem) anyerror!void {
    dispatch(Source, source, Sink, sink) catch |err| {
        if (problem) |p| p.* = source.takeProblem();
        return err;
    };
}
