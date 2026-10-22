//! The libyaml event source for the WASM builds.
//!
//! The browser module is compiled without a libc, so `@cImport` is not
//! available and the libyaml structures cannot be described in Zig. The
//! `wasm/shim/zaml_events.c` bridge walks the libyaml event stream and
//! hands out small, stable event records instead.

const std = @import("std");
const event = @import("event.zig");

pub const Error = error{
    NoParser,
    ParseError,
};

/// The details of a failed parse.
pub const Problem = event.Problem;

const EventType = c_int;

const EVENT_NOOP: EventType = 0;
const EVENT_SCALAR: EventType = 1;
const EVENT_SEQ_START: EventType = 2;
const EVENT_SEQ_END: EventType = 3;
const EVENT_MAP_START: EventType = 4;
const EVENT_MAP_END: EventType = 5;
const EVENT_ALIAS: EventType = 6;

/// The C record the bridge fills in.
///
/// The layout must match `zaml_event` in `wasm/shim/zaml_events.h`.
const RawEvent = extern struct {
    type: EventType,
    value: ?[*:0]const u8,
    value_len: usize,
    tag: ?[*:0]const u8,
    tag_len: usize,
    anchor: ?[*:0]const u8,
    anchor_len: usize,
};

extern fn zaml_parser_new(input: [*]const u8, len: usize) ?*anyopaque;
extern fn zaml_parser_next(parser: *anyopaque, ev: *RawEvent) c_int;
extern fn zaml_parser_problem(parser: *const anyopaque, buf: [*]u8, cap: usize, out_len: *usize, line: *u32, column: *u32) void;
extern fn zaml_parser_free(parser: *anyopaque) void;

/// A source that pulls events out of the C bridge.
pub const Source = struct {
    parser: *anyopaque,
    problem: Problem = .{},

    pub fn init(self: *Source, input: []const u8) Error!void {
        self.parser = zaml_parser_new(input.ptr, input.len) orelse return Error.NoParser;
    }

    pub fn deinit(self: *Source) void {
        zaml_parser_free(self.parser);
        self.parser = undefined;
    }

    /// The next event of the stream, or null at the end of it.
    pub fn next(self: *Source) Error!?event.Event {
        var raw: RawEvent = undefined;
        const rc = zaml_parser_next(self.parser, &raw);
        if (rc < 0) {
            self.fillProblem();
            return Error.ParseError;
        }
        if (rc == 0) return null;

        const anchor: ?[]const u8 = if (raw.anchor) |a| a[0..raw.anchor_len] else null;
        return switch (raw.type) {
            EVENT_NOOP => event.Event{ .type = .noop },
            EVENT_SCALAR => event.Event{
                .type = .scalar,
                .value = if (raw.value) |v| v[0..raw.value_len] else "",
                .tag = if (raw.tag) |t| t[0..raw.tag_len] else "",
                .anchor = anchor,
            },
            EVENT_SEQ_START => event.Event{ .type = .seq_start, .anchor = anchor },
            EVENT_SEQ_END => event.Event{ .type = .seq_end },
            EVENT_MAP_START => event.Event{ .type = .map_start, .anchor = anchor },
            EVENT_MAP_END => event.Event{ .type = .map_end },
            EVENT_ALIAS => event.Event{
                .type = .alias,
                .value = if (raw.value) |v| v[0..raw.value_len] else "",
            },
            else => event.Event{ .type = .noop },
        };    }

    /// The details of the last error.
    pub fn takeProblem(self: *Source) Problem {
        return self.problem;
    }

    fn fillProblem(self: *Source) void {
        var len: usize = 0;
        var line: u32 = 0;
        var column: u32 = 0;
        zaml_parser_problem(
            self.parser,
            &self.problem.problem_buf,
            self.problem.problem_buf.len,
            &len,
            &line,
            &column,
        );
        self.problem.problem_len = len;
        self.problem.line = line;
        self.problem.column = column;
    }
};

/// Parse `input`, driving `sink` with the libyaml event stream.
pub fn parse(comptime Sink: type, input: []const u8, sink: *Sink, problem: ?*Problem) !void {
    var source: Source = .{ .parser = undefined };
    try source.init(input);
    defer source.deinit();
    try event.run(Source, &source, Sink, sink, problem);
}
