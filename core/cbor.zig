//! CBOR encoding of the event stream.
//!
//! The encoder writes the document while the events arrive: nothing is
//! buffered as a tree of values, so a document costs about its own size
//! in memory instead of the size of every value in it.
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
const scalars = @import("scalar.zig");
const base64 = @import("base64.zig");
const stream = @import("stream.zig");

const Writer = emit.Writer;

pub const Error = std.mem.Allocator.Error || error{
    AliasUnknown,
    OddMapping,
};

/// A container that is being written.
const Frame = struct {
    /// Whether the container is a mapping. A sequence is the other case.
    map: bool,
    /// The number of items written into the container. In a mapping this
    /// counts the keys and the values, so the number of pairs is half.
    items: usize = 0,
    /// The offset in the output where the body of the container starts.
    /// The head of the container is put in front of it when it closes.
    body_start: usize = 0,
    /// The anchor of the container, if it has one. The name is copied,
    /// because the buffer of the event does not outlive the event.
    anchor: ?[]u8 = null,
};

/// Writes a document as CBOR while the events of the parse arrive.
///
/// The encoder is the `Sink` of `parse.parse(Encoder, ...)`.
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Frame) = .empty,
    anchors: stream.Anchors,
    /// The offset where the first document ends. A stream may hold more
    /// than one document, and only the first one is written out.
    root_end: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{
            .allocator = allocator,
            .anchors = stream.Anchors.init(allocator),
        };
    }

    pub fn deinit(self: *Encoder) void {
        for (self.stack.items) |frame| {
            if (frame.anchor) |name| self.allocator.free(name);
        }
        self.out.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.anchors.deinit();
    }

    /// The bytes of the document.
    pub fn bytes(self: *const Encoder) []const u8 {
        return self.out.items;
    }

    /// Write the null of an empty document, and drop the documents that
    /// follow the first one.
    pub fn finish(self: *Encoder) !void {
        if (self.root_end) |end| {
            self.out.shrinkRetainingCapacity(end);
            return;
        }
        const w: Writer = .{ .out = &self.out, .allocator = self.allocator };
        try w.byte(0xf6);
    }

    /// Sink: a scalar event.
    pub fn scalar(self: *Encoder, value: []const u8, tag: []const u8, anchor: ?[]const u8) !void {
        const kind = try self.writeScalar(value, tag);
        try self.countItem();
        if (anchor) |name| {
            try self.anchors.bindScalar(name, kind, value, tag);
        }
    }

    /// Sink: a sequence start.
    pub fn seqStart(self: *Encoder, anchor: ?[]const u8) !void {
        const name = try self.copyAnchor(anchor);
        errdefer if (name) |owned| self.allocator.free(owned);
        try self.stack.append(self.allocator, .{
            .map = false,
            .body_start = self.out.items.len,
            .anchor = name,
        });
    }

    /// Sink: a sequence end.
    pub fn seqEnd(self: *Encoder) !void {
        const frame = self.stack.pop() orelse return Error.OddMapping;
        defer if (frame.anchor) |name| self.allocator.free(name);
        try self.closeContainer(frame, .seq);
    }

    /// Sink: a mapping start.
    pub fn mapStart(self: *Encoder, anchor: ?[]const u8) !void {
        const name = try self.copyAnchor(anchor);
        errdefer if (name) |owned| self.allocator.free(owned);
        try self.stack.append(self.allocator, .{
            .map = true,
            .body_start = self.out.items.len,
            .anchor = name,
        });
    }

    /// Sink: a mapping end.
    pub fn mapEnd(self: *Encoder) !void {
        const frame = self.stack.pop() orelse return Error.OddMapping;
        defer if (frame.anchor) |name| self.allocator.free(name);
        if (frame.items % 2 != 0) return Error.OddMapping;
        try self.closeContainer(frame, .map);
    }

    /// Copy an anchor name, because the buffer of the event that carries
    /// it does not outlive the event.
    fn copyAnchor(self: *Encoder, anchor: ?[]const u8) !?[]u8 {
        const name = anchor orelse return null;
        return try self.allocator.dupe(u8, name);
    }

    /// Sink: an alias event.
    pub fn alias(self: *Encoder, name: []const u8) !void {
        const anchor = self.anchors.get(name) orelse return Error.AliasUnknown;
        switch (anchor.kind) {
            .seq, .map => try self.out.appendSlice(self.allocator, anchor.bytes),
            else => _ = try self.writeScalar(anchor.text, anchor.tag),
        }
        try self.countItem();
    }

    /// Count the item that was just written in the open container.
    fn countItem(self: *Encoder) !void {
        if (self.stack.items.len == 0) {
            if (self.root_end == null) self.root_end = self.out.items.len;
            return;
        }
        self.stack.items[self.stack.items.len - 1].items += 1;
    }

    /// Close a container: put its head in front of its body.
    fn closeContainer(self: *Encoder, frame: Frame, kind: stream.Kind) !void {
        const count: u64 = if (frame.map) @intCast(frame.items / 2) else @intCast(frame.items);
        var head_buf: [9]u8 = undefined;
        const head = writeHead(&head_buf, if (frame.map) 5 else 4, count);

        try self.out.insertSlice(self.allocator, frame.body_start, head);

        if (frame.anchor) |name| {
            try self.anchors.bindCollection(name, kind, self.out.items[frame.body_start..]);
        }
        try self.countItem();
    }

    /// Write a scalar, and tell what kind of value it is.
    fn writeScalar(self: *Encoder, value: []const u8, tag: []const u8) !stream.Kind {
        const w: Writer = .{ .out = &self.out, .allocator = self.allocator };

        if (scalars.isBinaryTag(tag)) {
            const decoded = base64.decode(self.allocator, value) catch {
                // Not valid base64: keep the text as it is.
                try w.head(2, value.len);
                try w.slice(value);
                return .binary;
            };
            defer self.allocator.free(decoded);
            try w.head(2, decoded.len);
            try w.slice(decoded);
            return .binary;
        }

        switch (scalars.classify(value, tag)) {
            .null => {
                try w.byte(0xf6);
                return .null;
            },
            .bool => {
                try w.byte(if (scalars.boolValue(value)) 0xf5 else 0xf4);
                return .bool;
            },
            .int => {
                var stack_buf: [128]u8 = undefined;
                var heap_buf: ?[]u8 = null;
                defer if (heap_buf) |buf| self.allocator.free(buf);
                const buf = if (value.len + 1 <= stack_buf.len) stack_buf[0..] else blk: {
                    heap_buf = try self.allocator.alloc(u8, value.len + 1);
                    break :blk heap_buf.?;
                };
                const text = scalars.normalizeInt(value, buf) orelse {
                    // Not a number after all: fall back to the raw text.
                    try w.head(3, value.len);
                    try w.slice(value);
                    return .str;
                };
                try writeInt(w, self.allocator, text);
                return .int;
            },
            .float => {
                const f = scalars.parseF64(value) orelse {
                    // Not a number after all: fall back to the raw text.
                    try w.head(3, value.len);
                    try w.slice(value);
                    return .str;
                };
                try w.byte(0xfb);
                try w.u64be(@bitCast(f));
                return .float;
            },
            .str => {
                try w.head(3, value.len);
                try w.slice(value);
                return .str;
            },
        }
    }
};

/// Write a CBOR head into `buf` and return the part of it that was used.
fn writeHead(buf: []u8, major: u8, arg: u64) []const u8 {
    const mt: u8 = major << 5;
    if (arg < 24) {
        buf[0] = mt | @as(u8, @intCast(arg));
        return buf[0..1];
    }
    if (arg <= 0xff) {
        buf[0] = mt | 24;
        buf[1] = @intCast(arg);
        return buf[0..2];
    }
    if (arg <= 0xffff) {
        buf[0] = mt | 25;
        std.mem.writeInt(u16, buf[1..3], @intCast(arg), .big);
        return buf[0..3];
    }
    if (arg <= 0xffffffff) {
        buf[0] = mt | 26;
        std.mem.writeInt(u32, buf[1..5], @intCast(arg), .big);
        return buf[0..5];
    }
    buf[0] = mt | 27;
    std.mem.writeInt(u64, buf[1..9], arg, .big);
    return buf[0..9];
}

/// Write an integer in its shortest form.
fn writeInt(w: Writer, allocator: std.mem.Allocator, text: []const u8) !void {
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
    const magnitude = try decimalToMagnitude(allocator, digits);
    defer allocator.free(magnitude);

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

test "the scalars of a document" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.scalar("42", "", null);
    try encoder.scalar("text", "", null);
    try encoder.scalar("true", "", null);
    try encoder.scalar("null", "", null);
    try encoder.scalar("1.5", "", null);

    try testing.expectEqualStrings(
        "\x18\x2a\x64text\xf5\xf6\xfb\x3f\xf8\x00\x00\x00\x00\x00\x00",
        encoder.bytes(),
    );
}

test "a mapping keeps the order of its pairs" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.mapStart(null);
    try encoder.scalar("a", "", null);
    try encoder.scalar("1", "", null);
    try encoder.scalar("b", "", null);
    try encoder.scalar("2", "", null);
    try encoder.mapEnd();

    try testing.expectEqualStrings("\xa2\x61a\x01\x61b\x02", encoder.bytes());
}

test "a nested sequence" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.seqStart(null);
    try encoder.scalar("1", "", null);
    try encoder.seqStart(null);
    try encoder.scalar("2", "", null);
    try encoder.seqEnd();
    try encoder.seqEnd();

    try testing.expectEqualStrings("\x82\x01\x81\x02", encoder.bytes());
}

test "an empty document is null" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.finish();
    try testing.expectEqualStrings("\xf6", encoder.bytes());
}

test "an alias writes the node again" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.mapStart(null);
    try encoder.scalar("a", "", null);
    try encoder.scalar("1", "", "x");
    try encoder.scalar("b", "", null);
    try encoder.alias("x");
    try encoder.mapEnd();

    try testing.expectEqualStrings("\xa2\x61a\x01\x61b\x01", encoder.bytes());
}

test "an alias of a collection writes it again" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.seqStart("x");
    try encoder.scalar("1", "", null);
    try encoder.seqEnd();
    try encoder.alias("x");

    try testing.expectEqualStrings("\x81\x01\x81\x01", encoder.bytes());
}

test "an unknown alias is an error" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try testing.expectError(Error.AliasUnknown, encoder.alias("nope"));
}

test "a bignum" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.scalar("123456789012345678901234567890", "", null);

    const encoded = encoder.bytes();
    try testing.expectEqual(@as(u8, 0xc2), encoded[0]);
    try testing.expectEqual(@as(u8, 0x4d), encoded[1]);
    try testing.expectEqual(@as(usize, 15), encoded.len);
}

test "a binary value" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.scalar("aGVsbG8=", "tag:yaml.org,2002:binary", null);

    try testing.expectEqualStrings("\x45hello", encoder.bytes());
}
