//! The libyaml event source for the native hosts (Erlang, Python).
//!
//! This is the only file that talks to libyaml through `@cImport`, so it
//! is the only one that needs a libc. The WASM builds use
//! `parse_c.zig` instead, which reaches libyaml through a small C
//! shim.

const std = @import("std");
const event = @import("event.zig");

pub const yaml = @cImport({
    @cInclude("yaml.h");
});

pub const Error = error{
    NoParser,
    ParseError,
};

/// The details of a failed parse.
pub const Problem = event.Problem;

/// A source that pulls events straight out of libyaml.
pub const Source = struct {
    parser: yaml.yaml_parser_t = undefined,
    initialized: bool = false,
    /// The event handed out last; libyaml owns its buffers, so it stays
    /// alive until the next event replaces it.
    pending: yaml.yaml_event_t = undefined,
    has_pending: bool = false,
    problem: Problem = .{},

    /// Start parsing `input`.
    ///
    /// The parser keeps a pointer to itself, so the source must not be
    /// moved after this call: create it in place and initialise it.
    pub fn init(self: *Source, input: []const u8) Error!void {
        if (yaml.yaml_parser_initialize(&self.parser) == 0) return Error.NoParser;
        self.initialized = true;
        yaml.yaml_parser_set_input_string(&self.parser, input.ptr, @intCast(input.len));
    }

    pub fn deinit(self: *Source) void {
        if (self.has_pending) {
            yaml.yaml_event_delete(&self.pending);
            self.has_pending = false;
        }
        if (self.initialized) {
            yaml.yaml_parser_delete(&self.parser);
            self.initialized = false;
        }
    }

    /// The next event of the stream, or null at the end of it.
    ///
    /// The slices of the returned event stay valid until the next call.
    pub fn next(self: *Source) Error!?event.Event {
        if (self.has_pending) {
            yaml.yaml_event_delete(&self.pending);
            self.has_pending = false;
        }

        if (yaml.yaml_parser_parse(&self.parser, &self.pending) == 0) {
            self.fillProblem();
            return Error.ParseError;
        }
        self.has_pending = true;
        const ev = &self.pending;

        switch (ev.type) {
            yaml.YAML_NO_EVENT => return event.Event{ .type = .noop },
            yaml.YAML_STREAM_START_EVENT => return event.Event{ .type = .noop },
            yaml.YAML_DOCUMENT_START_EVENT => return event.Event{ .type = .noop },
            yaml.YAML_DOCUMENT_END_EVENT => return event.Event{ .type = .noop },
            yaml.YAML_STREAM_END_EVENT => return null,

            yaml.YAML_ALIAS_EVENT => {
                return event.Event{
                    .type = .alias,
                    .value = std.mem.span(ev.data.alias.anchor),
                };
            },

            yaml.YAML_SCALAR_EVENT => {
                return event.Event{
                    .type = .scalar,
                    .value = std.mem.span(ev.data.scalar.value),
                    .tag = if (ev.data.scalar.tag) |t| std.mem.span(t) else "",
                    .anchor = if (ev.data.scalar.anchor) |a| std.mem.span(a) else null,
                };
            },

            yaml.YAML_SEQUENCE_START_EVENT => {
                return event.Event{
                    .type = .seq_start,
                    .anchor = if (ev.data.sequence_start.anchor) |a| std.mem.span(a) else null,
                };
            },
            yaml.YAML_SEQUENCE_END_EVENT => return event.Event{ .type = .seq_end },

            yaml.YAML_MAPPING_START_EVENT => {
                return event.Event{
                    .type = .map_start,
                    .anchor = if (ev.data.mapping_start.anchor) |a| std.mem.span(a) else null,
                };
            },
            yaml.YAML_MAPPING_END_EVENT => return event.Event{ .type = .map_end },

            else => return event.Event{ .type = .noop },
        }
    }

    /// The details of the last error.
    pub fn takeProblem(self: *Source) Problem {
        return self.problem;
    }

    fn fillProblem(self: *Source) void {
        self.problem.context_len = copyCString(self.problem.context_buf[0..], self.parser.context);
        self.problem.problem_len = copyCString(self.problem.problem_buf[0..], self.parser.problem);
        self.problem.line = @intCast(self.parser.problem_mark.line + 1);
        self.problem.column = @intCast(self.parser.problem_mark.column + 1);
    }
};

/// Copy a NUL-terminated C string into a fixed buffer, truncating if needed.
fn copyCString(dest: []u8, src: ?[*:0]const u8) usize {
    const s = src orelse return 0;
    var n: usize = 0;
    while (n < dest.len and s[n] != 0) : (n += 1) {
        dest[n] = s[n];
    }
    return n;
}

/// Parse `input`, driving `sink` with the libyaml event stream.
pub fn parse(comptime Sink: type, input: []const u8, sink: *Sink, problem: ?*Problem) !void {
    var source: Source = .{};
    try source.init(input);
    defer source.deinit();
    try event.run(Source, &source, Sink, sink, problem);
}
