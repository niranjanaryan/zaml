//! JSON encoding of the value tree.
//!
//! This is the format the Wasmer command prints and the format the
//! JavaScript package exposes through `parseToJSON()`.
//!
//! Integers are written as their canonical decimal text, so arbitrarily large
//! values survive. Floats are written in the shortest form that round-trips;
//! a float that happens to be integral keeps a `.0` suffix so that it stays
//! distinguishable from an integer. Binary values are rendered as base64
//! strings and mapping keys that are not strings are rendered as their JSON
//! text, quoted.

const std = @import("std");
const emit = @import("emit.zig");
const value = @import("value.zig");
const base64 = @import("base64.zig");

const Writer = emit.Writer;

pub const Error = std.mem.Allocator.Error || error{NoSpaceLeft};

/// Encode `v` into `out` as JSON.
pub fn encode(allocator: std.mem.Allocator, v: value.Value, out: *std.ArrayList(u8)) Error!void {
    const w: Writer = .{ .out = out, .allocator = allocator };
    try encodeValue(w, v);
}

fn encodeValue(w: Writer, v: value.Value) Error!void {
    switch (v.kind) {
        .null => try w.slice("null"),
        .bool => try w.slice(if (v.b) "true" else "false"),
        .int => try w.slice(v.int_text),
        .float => try writeFloat(w, v.f),
        .str => try writeString(w, v.bytes),
        .binary => {
            const encoded = try base64.encode(w.allocator, v.bytes);
            defer w.allocator.free(encoded);
            try writeString(w, encoded);
        },
        .seq => {
            try w.byte('[');
            for (v.items, 0..) |item, i| {
                if (i > 0) try w.byte(',');
                try encodeValue(w, item);
            }
            try w.byte(']');
        },
        .map => {
            try w.byte('{');
            for (v.keys, v.values, 0..) |k, val, i| {
                if (i > 0) try w.byte(',');
                try writeKey(w, k);
                try w.byte(':');
                try encodeValue(w, val);
            }
            try w.byte('}');
        },
    }
}

fn writeKey(w: Writer, k: value.Value) Error!void {
    if (k.kind == .str) {
        try writeString(w, k.bytes);
        return;
    }
    // Non-string keys are rendered as their JSON text, quoted.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(w.allocator);
    try encodeValue(.{ .out = &text, .allocator = w.allocator }, k);
    try writeString(w, text.items);
}

fn writeFloat(w: Writer, f: f64) Error!void {
    var buf: [64]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{d}", .{f})) |text| {
        if (text.len <= 24 and roundTrips(text, f)) {
            try w.slice(text);
            if (std.mem.indexOfAny(u8, text, ".eE") == null) try w.slice(".0");
            return;
        }
    } else |_| {}

    var sci: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&sci, "{e}", .{f});
    try w.slice(text);
}

fn roundTrips(text: []const u8, f: f64) bool {
    const parsed = std.fmt.parseFloat(f64, text) catch return false;
    return @as(u64, @bitCast(parsed)) == @as(u64, @bitCast(f));
}

/// Write a JSON string literal. Invalid UTF-8 is replaced with U+FFFD.
fn writeString(w: Writer, bytes: []const u8) Error!void {
    try w.byte('"');
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        switch (c) {
            0x00...0x1f => {
                switch (c) {
                    '\n' => try w.slice("\\n"),
                    '\r' => try w.slice("\\r"),
                    '\t' => try w.slice("\\t"),
                    0x08 => try w.slice("\\b"),
                    0x0c => try w.slice("\\f"),
                    else => {
                        var esc: [6]u8 = undefined;
                        const text = try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c});
                        try w.slice(text);
                    },
                }
                i += 1;
            },
            0x20...0x7f => {
                if (c == '"' or c == '\\') {
                    try w.byte('\\');
                }
                try w.byte(c);
                i += 1;
            },
            else => {
                const len = std.unicode.utf8ByteSequenceLength(c) catch {
                    try w.slice("\xef\xbf\xbd");
                    i += 1;
                    continue;
                };
                if (i + len > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
                    try w.slice("\xef\xbf\xbd");
                    i += 1;
                    continue;
                }
                try w.slice(bytes[i .. i + len]);
                i += len;
            },
        }
    }
    try w.byte('"');
}

const testing = std.testing;

fn encodeToSlice(allocator: std.mem.Allocator, v: value.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try encode(allocator, v, &out);
    return out.toOwnedSlice(allocator);
}

test "scalars" {
    const allocator = testing.allocator;
    const cases = [_]struct { v: value.Value, expected: []const u8 }{
        .{ .v = .{ .kind = .null }, .expected = "null" },
        .{ .v = .{ .kind = .bool, .b = true }, .expected = "true" },
        .{ .v = .{ .kind = .bool, .b = false }, .expected = "false" },
        .{ .v = .{ .kind = .int, .int_text = "42" }, .expected = "42" },
        .{ .v = .{ .kind = .int, .int_text = "123456789012345678901234567890" }, .expected = "123456789012345678901234567890" },
        .{ .v = .{ .kind = .float, .f = 1.5 }, .expected = "1.5" },
        .{ .v = .{ .kind = .float, .f = 1.0 }, .expected = "1.0" },
        .{ .v = .{ .kind = .str, .bytes = "hi" }, .expected = "\"hi\"" },
        .{ .v = .{ .kind = .str, .bytes = "a\"b\\c\nd" }, .expected = "\"a\\\"b\\\\c\\nd\"" },
        .{ .v = .{ .kind = .binary, .bytes = "foobar" }, .expected = "\"Zm9vYmFy\"" },
    };
    for (cases) |case| {
        const encoded = try encodeToSlice(allocator, case.v);
        defer allocator.free(encoded);
        try testing.expectEqualStrings(case.expected, encoded);
    }
}

test "containers" {
    const allocator = testing.allocator;
    const v: value.Value = .{
        .kind = .map,
        .keys = &.{ .{ .kind = .str, .bytes = "a" }, .{ .kind = .int, .int_text = "7" } },
        .values = &.{ .{ .kind = .int, .int_text = "1" }, .{ .kind = .seq, .items = &.{.{ .kind = .bool, .b = true }} } },
    };
    const encoded = try encodeToSlice(allocator, v);
    defer allocator.free(encoded);
    try testing.expectEqualStrings("{\"a\":1,\"7\":[true]}", encoded);
}

test "invalid utf8 becomes the replacement character" {
    const allocator = testing.allocator;
    const v: value.Value = .{ .kind = .str, .bytes = &.{ 0xff, 'a' } };
    const encoded = try encodeToSlice(allocator, v);
    defer allocator.free(encoded);
    try testing.expectEqualStrings("\"\xef\xbf\xbda\"", encoded);
}
