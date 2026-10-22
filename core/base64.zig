//! Base64 encoding and decoding, used for `!!binary` values.

const std = @import("std");

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub const Error = error{InvalidBase64};

/// Encode `bytes` as standard base64 with padding.
pub fn encode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, (bytes.len + 2) / 3 * 4);

    var i: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        const n: u32 = (@as(u32, bytes[i]) << 16) |
            (@as(u32, bytes[i + 1]) << 8) |
            @as(u32, bytes[i + 2]);
        try out.append(allocator, alphabet[(n >> 18) & 0x3f]);
        try out.append(allocator, alphabet[(n >> 12) & 0x3f]);
        try out.append(allocator, alphabet[(n >> 6) & 0x3f]);
        try out.append(allocator, alphabet[n & 0x3f]);
    }

    const rest = bytes.len - i;
    if (rest == 1) {
        const n: u32 = @as(u32, bytes[i]) << 16;
        try out.append(allocator, alphabet[(n >> 18) & 0x3f]);
        try out.append(allocator, alphabet[(n >> 12) & 0x3f]);
        try out.append(allocator, '=');
        try out.append(allocator, '=');
    } else if (rest == 2) {
        const n: u32 = (@as(u32, bytes[i]) << 16) | (@as(u32, bytes[i + 1]) << 8);
        try out.append(allocator, alphabet[(n >> 18) & 0x3f]);
        try out.append(allocator, alphabet[(n >> 12) & 0x3f]);
        try out.append(allocator, alphabet[(n >> 6) & 0x3f]);
        try out.append(allocator, '=');
    }

    return out.toOwnedSlice(allocator);
}

/// Decode standard base64 with padding.
///
/// Whitespace is ignored, so the line breaks YAML allows in a `!!binary`
/// value do not matter.
pub fn decode(allocator: std.mem.Allocator, text: []const u8) (std.mem.Allocator.Error || Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var acc: u32 = 0;
    var bits: u5 = 0;
    for (text) |c| {
        switch (c) {
            ' ', '\t', '\n', '\r' => continue,
            '=' => break,
            else => {},
        }
        const value = decodeChar(c) orelse return Error.InvalidBase64;
        acc = (acc << 6) | value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            try out.append(allocator, @intCast((acc >> bits) & 0xff));
        }
    }

    return out.toOwnedSlice(allocator);
}

/// The value of a base64 character.
fn decodeChar(c: u8) ?u32 {
    return switch (c) {
        'A'...'Z' => c - 'A',
        'a'...'z' => c - 'a' + 26,
        '0'...'9' => c - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

const testing = std.testing;

test "base64 of the RFC 4648 vectors" {
    const allocator = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "", "" },
        .{ "f", "Zg==" },
        .{ "fo", "Zm8=" },
        .{ "foo", "Zm9v" },
        .{ "foob", "Zm9vYg==" },
        .{ "fooba", "Zm9vYmE=" },
        .{ "foobar", "Zm9vYmFy" },
    };
    for (cases) |case| {
        const encoded = try encode(allocator, case[0]);
        defer allocator.free(encoded);
        try testing.expectEqualStrings(case[1], encoded);
    }
}

test "base64 decoding of the RFC 4648 vectors" {
    const allocator = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "", "" },
        .{ "Zg==", "f" },
        .{ "Zm8=", "fo" },
        .{ "Zm9v", "foo" },
        .{ "Zm9vYg==", "foob" },
        .{ "Zm9vYmE=", "fooba" },
        .{ "Zm9vYmFy", "foobar" },
    };
    for (cases) |case| {
        const decoded = try decode(allocator, case[0]);
        defer allocator.free(decoded);
        try testing.expectEqualStrings(case[1], decoded);
    }
}

test "base64 decoding ignores whitespace" {
    const allocator = testing.allocator;
    const decoded = try decode(allocator, "Zm9v\n YmFy");
    defer allocator.free(decoded);
    try testing.expectEqualStrings("foobar", decoded);
}

test "base64 decoding rejects invalid characters" {
    const allocator = testing.allocator;
    try testing.expectError(Error.InvalidBase64, decode(allocator, "not base64!"));
}
