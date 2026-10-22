//! The zaml WebAssembly core.
//!
//! The module is compiled for `wasm32-freestanding`, so it runs without a
//! libc: the handful of C functions libyaml needs are implemented here and
//! exported to the vendored C sources.
//!
//! The JavaScript package drives the module through a small C ABI:
//!
//!   zaml_alloc(len)            -> the address of a buffer of `len` bytes
//!   zaml_free(ptr, len)        -> release a buffer from zaml_alloc
//!   zaml_parse(ptr, len, fmt)  -> 0 on success, negative on failure
//!   zaml_result_ptr/len        -> the encoded result of the last parse
//!   zaml_error_ptr/len         -> the message of the last failure
//!
//! The result buffer belongs to the module and is released by the next
//! parse, so the caller copies it out before parsing again.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("core");
const alloc = @import("alloc.zig");

const event = core.event;
const parse = core.parse_c;
const cbor = core.cbor;
const json = core.json;

// Pull in the C entry points libyaml needs: without a libc the module
// has to provide them itself.
comptime {
    _ = @import("c_abi.zig");
}

/// The heap the module uses.
///
/// The freestanding build has no libc, so it grows the WebAssembly memory
/// itself; the WASI build uses the C library of the runtime.
const heap = alloc.allocator;

/// The wire format of a parse result.
pub const Format = enum(u32) {
    cbor = 0,
    json = 1,
};

/// Error codes returned by `zaml_parse`.
pub const ErrorCode = enum(i32) {
    ok = 0,
    parse_error = -1,
    out_of_memory = -2,
    bad_format = -3,
};

/// The encoded result of the last parse; owned by the module.
var result_buf: []u8 = &.{};
/// The message of the last failure; owned by the module.
var error_buf: []u8 = &.{};

/// Copy `bytes` into a fresh module owned buffer.
fn store(bytes: []const u8) ![]u8 {
    const buf = try heap.alloc(u8, bytes.len);
    @memcpy(buf, bytes);
    return buf;
}

fn releaseResult() void {
    if (result_buf.len > 0) {
        heap.free(result_buf);
        result_buf = &.{};
    }
}

fn releaseError() void {
    if (error_buf.len > 0) {
        heap.free(error_buf);
        error_buf = &.{};
    }
}

/// Allocate a buffer the host can write the YAML text into.
export fn zaml_alloc(len: u32) u32 {
    const buf = heap.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(buf.ptr));
}

/// Release a buffer handed out by `zaml_alloc`.
export fn zaml_free(ptr: u32, len: u32) void {
    if (ptr == 0 or len == 0) return;
    const bytes: [*]u8 = @ptrFromInt(ptr);
    heap.free(bytes[0..len]);
}

/// Parse the YAML text at `ptr` and encode the result.
///
/// Returns 0 on success. On failure the error message is available
/// through `zaml_error_ptr` and `zaml_error_len`.
export fn zaml_parse(ptr: u32, len: u32, format: u32) i32 {
    releaseResult();
    releaseError();

    const fmt: Format = switch (format) {
        0 => .cbor,
        1 => .json,
        else => {
            setError("unknown output format");
            return @intFromEnum(ErrorCode.bad_format);
        },
    };

    // A host that has nothing to parse passes a null address. The pointer
    // is only made for a buffer that exists, so the module never works
    // with a null one.
    var input: []const u8 = &.{};
    if (ptr != 0 and len != 0) {
        const bytes: [*]const u8 = @ptrFromInt(ptr);
        input = bytes[0..len];
    }

    var problem: event.Problem = .{};
    const encoded = switch (fmt) {
        .cbor => encode(cbor.Encoder, input, &problem) catch |err| {
            setError(describe(&problem));
            return switch (err) {
                error.OutOfMemory => @intFromEnum(ErrorCode.out_of_memory),
                else => @intFromEnum(ErrorCode.parse_error),
            };
        },
        .json => encode(json.Encoder, input, &problem) catch |err| {
            setError(describe(&problem));
            return switch (err) {
                error.OutOfMemory => @intFromEnum(ErrorCode.out_of_memory),
                else => @intFromEnum(ErrorCode.parse_error),
            };
        },
    };

    result_buf = encoded;

    return @intFromEnum(ErrorCode.ok);
}

/// Parse `input` and write it with the encoder.
///
/// The encoder writes the document while the events of the parse arrive,
/// so the document is never held as a tree of values. The bytes are
/// copied out of the encoder into a buffer the module owns.
fn encode(comptime Encoder: type, input: []const u8, problem: *event.Problem) ![]u8 {
    var encoder = Encoder.init(heap);
    defer encoder.deinit();

    try parse.parse(Encoder, input, &encoder, problem);
    try encoder.finish();

    return try heap.dupe(u8, encoder.bytes());
}

/// The address of the encoded result of the last parse.
export fn zaml_result_ptr() u32 {
    if (result_buf.len == 0) return 0;
    return @intCast(@intFromPtr(result_buf.ptr));
}

/// The length of the encoded result of the last parse.
export fn zaml_result_len() u32 {
    return @intCast(result_buf.len);
}

/// The address of the message of the last failure.
export fn zaml_error_ptr() u32 {
    if (error_buf.len == 0) return 0;
    return @intCast(@intFromPtr(error_buf.ptr));
}

/// The length of the message of the last failure.
export fn zaml_error_len() u32 {
    return @intCast(error_buf.len);
}

fn setError(message: []const u8) void {
    error_buf = store(message) catch &.{};
}

/// A human readable description of a parse failure.
fn describe(problem: *const event.Problem) []const u8 {
    var buf: [512]u8 = undefined;
    const text = problem.problem();
    const context = problem.context();

    if (text.len == 0) {
        return std.fmt.bufPrint(buf[0..], "invalid YAML", .{}) catch buf[0..0];
    }

    var out = std.fmt.bufPrint(buf[0..], "line {d}, column {d}: {s}", .{
        problem.line,
        problem.column,
        text,
    }) catch buf[0..0];
    if (context.len > 0) {
        out = std.fmt.bufPrint(out, " ({s})", .{context}) catch out;
    }
    return out;
}
