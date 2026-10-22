//! The zaml command, built for `wasm32-wasi`.
//!
//! It reads YAML from stdin and writes the result to stdout:
//!
//!   wasmer run niranjanaryan/zaml -- --format json < file.yaml
//!
//! JSON is the default, CBOR is the alternative.
//!
//! The command talks to the runtime through the WASI calls directly. The
//! higher level helpers of the standard library walk the preopened
//! directories of the runtime, and not every runtime reports them the
//! same way.

const std = @import("std");
const wasi = std.os.wasi;
const core = @import("core");
const alloc = @import("alloc.zig");

const event = core.event;
const parse = core.parse_c;
const cbor = core.cbor;
const json = core.json;

const Format = enum {
    json,
    cbor,
};

/// The largest document the command reads.
const max_input = 512 * 1024 * 1024;

const usage =
    \\usage: zaml [--format json|cbor]
    \\
    \\Reads YAML from stdin and writes the result to stdout.
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    const heap = std.heap.c_allocator;

    var format: Format = .json;
    var args = init.args.iterateAllocator(heap) catch return fail("out of memory");
    defer args.deinit();
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--format")) {
            const name = args.next() orelse return fail("missing value for --format");
            format = std.meta.stringToEnum(Format, name) orelse
                return failf(heap, "unknown format: {s}", .{name});
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            const name = arg["--format=".len..];
            format = std.meta.stringToEnum(Format, name) orelse
                return failf(heap, "unknown format: {s}", .{name});
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeAll(1, usage) catch {};
            return;
        } else {
            return failf(heap, "unknown argument: {s}", .{arg});
        }
    }

    const input = readAll(heap, 0) catch |err| {
        return failf(heap, "cannot read stdin: {s}", .{@errorName(err)});
    };
    defer heap.free(input);

    var problem: event.Problem = .{};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(heap);

    switch (format) {
        .json => {
            var encoder = json.Encoder.init(heap);
            defer encoder.deinit();
            parse.parse(json.Encoder, input, &encoder, &problem) catch {
                return fail(describe(&problem));
            };
            encoder.finish() catch return fail("out of memory");
            try out.appendSlice(heap, encoder.bytes());
            // A line of JSON ends with a newline; CBOR is binary and does
            // not.
            try out.append(heap, '\n');
        },
        .cbor => {
            var encoder = cbor.Encoder.init(heap);
            defer encoder.deinit();
            parse.parse(cbor.Encoder, input, &encoder, &problem) catch {
                return fail(describe(&problem));
            };
            encoder.finish() catch return fail("out of memory");
            try out.appendSlice(heap, encoder.bytes());
        },
    }

    writeAll(1, out.items) catch return fail("cannot write stdout");
}

/// Read a file descriptor until the end.
fn readAll(heap: std.mem.Allocator, fd: wasi.fd_t) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(heap);

    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const iovec = wasi.iovec_t{ .base = &buffer, .len = buffer.len };
        var read: usize = 0;
        switch (wasi.fd_read(fd, @ptrCast(&iovec), 1, &read)) {
            .SUCCESS => {},
            else => return error.ReadFailed,
        }
        if (read == 0) break;
        if (out.items.len + read > max_input) return error.InputTooLarge;
        try out.appendSlice(heap, buffer[0..read]);
    }

    return out.toOwnedSlice(heap);
}

/// Write a buffer to a file descriptor.
fn writeAll(fd: wasi.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const iovec = wasi.iovec_t{ .base = @constCast(bytes[written..].ptr), .len = bytes.len - written };
        var count: usize = 0;
        switch (wasi.fd_write(fd, @ptrCast(&iovec), 1, &count)) {
            .SUCCESS => {},
            else => return error.WriteFailed,
        }
        if (count == 0) return error.WriteFailed;
        written += count;
    }
}

fn describe(problem: *const event.Problem) []const u8 {
    var buf: [512]u8 = undefined;
    const text = problem.problem();
    if (text.len == 0) return "invalid YAML";

    return std.fmt.bufPrint(buf[0..], "line {d}, column {d}: {s}", .{
        problem.line,
        problem.column,
        text,
    }) catch buf[0..0];
}

fn failf(heap: std.mem.Allocator, comptime format: []const u8, args: anytype) noreturn {
    const message = std.fmt.allocPrint(heap, format, args) catch "out of memory";
    fail(message);
}

fn fail(message: []const u8) noreturn {
    writeAll(2, "zaml: ") catch {};
    writeAll(2, message) catch {};
    writeAll(2, "\n") catch {};
    std.process.exit(1);
}
