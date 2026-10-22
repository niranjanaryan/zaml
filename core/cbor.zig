//! CBOR encoding of the value tree.
//!
//! The mapping is chosen so that nothing is lost on the way to JavaScript:
//!
//!   null              -> 0xf6
//!   true / false      -> 0xf5 / 0xf4
//!   integer           -> major type 0 (unsigned) or 1 (negative)
//!   integer > u64     -> tag 2 / 3 (bignum) with a byte string magnitude
//!   float             -> 0xfb (double)
//!   string            -> major type 3 (text)
//!   binary            -> major type 2 (byte string)
//!   sequence          -> major type 4 (array)
//!   mapping           -> major type 5 (map)
//!
//! Map keys keep their own kind, so a mapping with integer keys stays a
//! mapping with integer keys.

const std = @import("std");
const emit = @import("emit.zig");
const value = @import("value.zig");

const Writer = emit.Writer;

pub const Error = error{OutOfMemory};

/// Encode `v` into `out` as CBOR.
pub fn encode(allocator: std.mem.Allocator, v: value.Value, out: *std.ArrayList(u8)) !void {
    const w: Writer = .{ .out = out, .allocator = allocator };
    try encodeValue(w, v);
}

fn encodeValue(w: Writer, v: value.Value) !void {
    switch (v.kind) {
        .null => try w.byte(0xf6),
        .bool => try w.byte(if (v.b) 0xf5 else 0xf4),
        .int => try encodeInt(w, v.int_text),
        .float => {
            try w.byte(0xfb);
            try w.u64be(@bitCast(v.f));
        },
        .str => {
            try w.head(3, v.bytes.len);
            try w.slice(v.bytes);
        },
        .binary => {
            try w.head(2, v.bytes.len);
            try w.slice(v.bytes);
        },
        .seq => {
            try w.head(4, v.items.len);
            for (v.items) |item| try encodeValue(w, item);
        },
        .map => {
            try w.head(5, v.keys.len);
            for (v.keys, v.values) |k, val| {
                try encodeValue(w, k);
                try encodeValue(w, val);
            }
        },
    }
}

fn encodeInt(w: Writer, text: []const u8) !void {
    if (std.fmt.parseInt(i64, text, 10)) |v| {
        if (v >= 0) {
            try w.head(0, @intCast(v));
        } else {
            // CBOR stores -1 - n, so n = -1 - v.
            const n: u64 = @intCast(-(v + 1));
            try w.head(1, n);
        }
        return;
    } else |_| {}

    if (std.fmt.parseInt(u64, text, 10)) |v| {
        try w.head(0, v);
        return;
    } else |_| {}

    // Too large for 64 bits: a bignum with the magnitude as a byte string.
    const negative = text.len > 0 and text[0] == '-';
    const digits = if (negative) text[1..] else text;
    const magnitude = try decimalToMagnitude(w.allocator, digits);
    defer w.allocator.free(magnitude);

    try w.head(6, if (negative) 3 else 2);
    try w.head(2, magnitude.len);
    try w.slice(magnitude);
}

/// Convert decimal digits into the big-endian magnitude of the number.
fn decimalToMagnitude(allocator: std.mem.Allocator, digits: []const u8) ![]u8 {
    // The work buffer keeps ASCII digits throughout: each pass divides the
    // number by 256 and keeps the remainder.
    const buf = try allocator.dupe(u8, digits);
    defer allocator.free(buf);
    var work: []u8 = buf;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    while (true) {
        // Skip leading zeros of the current value.
        var start: usize = 0;
        while (start + 1 < work.len and work[start] == '0') start += 1;
        if (start > 0) work = work[start..];

        if (work.len == 1 and work[0] == '0') break;

        var rem: u32 = 0;
        for (work) |*c| {
            const cur = rem * 10 + @as(u32, c.* - '0');
            c.* = @as(u8, @intCast('0' + cur / 256));
            rem = cur % 256;
        }
        try out.append(allocator, @intCast(rem));
    }

    // The bytes were produced least significant first; CBOR wants big endian.
    std.mem.reverse(u8, out.items);
    return out.toOwnedSlice(allocator);
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
        .{ .v = .{ .kind = .null }, .expected = "\xf6" },
        .{ .v = .{ .kind = .bool, .b = true }, .expected = "\xf5" },
        .{ .v = .{ .kind = .bool, .b = false }, .expected = "\xf4" },
        .{ .v = .{ .kind = .int, .int_text = "0" }, .expected = "\x00" },
        .{ .v = .{ .kind = .int, .int_text = "1" }, .expected = "\x01" },
        .{ .v = .{ .kind = .int, .int_text = "23" }, .expected = "\x17" },
        .{ .v = .{ .kind = .int, .int_text = "24" }, .expected = "\x18\x18" },
        .{ .v = .{ .kind = .int, .int_text = "256" }, .expected = "\x19\x01\x00" },
        .{ .v = .{ .kind = .int, .int_text = "65536" }, .expected = "\x1a\x00\x01\x00\x00" },
        .{ .v = .{ .kind = .int, .int_text = "4294967296" }, .expected = "\x1b\x00\x00\x00\x01\x00\x00\x00\x00" },
        .{ .v = .{ .kind = .int, .int_text = "-1" }, .expected = "\x20" },
        .{ .v = .{ .kind = .int, .int_text = "-1000" }, .expected = "\x39\x03\xe7" },
        .{ .v = .{ .kind = .str, .bytes = "hi" }, .expected = "\x62\x68\x69" },
        .{ .v = .{ .kind = .binary, .bytes = "\x00\x01" }, .expected = "\x42\x00\x01" },
    };
    for (cases) |case| {
        const encoded = try encodeToSlice(allocator, case.v);
        defer allocator.free(encoded);
        try testing.expectEqualStrings(case.expected, encoded);
    }
}

test "bignum" {
    const allocator = testing.allocator;
    const v: value.Value = .{ .kind = .int, .int_text = "123456789012345678901234567890" };
    const encoded = try encodeToSlice(allocator, v);
    defer allocator.free(encoded);
    // Tag 2 (bignum) wrapping a byte string with the magnitude.
    try testing.expectEqual(@as(u8, 0xc2), encoded[0]);
    try testing.expectEqual(@as(u8, 0x4d), encoded[1]);
    try testing.expectEqual(@as(usize, 15), encoded.len);
    try testing.expectEqualStrings(
        "\x01\x8e\xe9\x0f\xf6\xc3\x73\xe0\xee\x4e\x3f\x0a\xd2",
        encoded[2..],
    );
}

test "containers" {
    const allocator = testing.allocator;
    const v: value.Value = .{
        .kind = .seq,
        .items = &.{ .{ .kind = .int, .int_text = "1" }, .{ .kind = .int, .int_text = "2" } },
    };
    const encoded = try encodeToSlice(allocator, v);
    defer allocator.free(encoded);
    try testing.expectEqualStrings("\x82\x01\x02", encoded);
}

test "float" {
    const allocator = testing.allocator;
    const v: value.Value = .{ .kind = .float, .f = 1.5 };
    const encoded = try encodeToSlice(allocator, v);
    defer allocator.free(encoded);
    try testing.expectEqual(@as(usize, 9), encoded.len);
    try testing.expectEqual(@as(u8, 0xfb), encoded[0]);
}
