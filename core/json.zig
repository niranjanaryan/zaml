//! JSON encoding of the event stream.
//!
//! The encoder writes the document while the events arrive: nothing is
//! buffered as a tree of values, so a document costs about its own size
//! in memory instead of the size of every value in it.
//!
//! This is the format the Wasmer command prints and the format the
//! JavaScript package exposes through `parseJson()`.
//!
//! Integers are written as their canonical decimal text, so arbitrarily large
//! values survive. Floats are written in the shortest form that round-trips;
//! a float that happens to be integral keeps a `.0` suffix so that it stays
//! distinguishable from an integer. Binary values are rendered as base64
//! strings and mapping keys that are not strings are rendered as their JSON
//! text, quoted.

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
    /// Whether the container is a key of a mapping. A key that is not a
    /// string is written as its JSON text, quoted.
    is_key: bool = false,
};

/// Writes a document as JSON while the events of the parse arrive.
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
        try self.writeScalarText("null", "");
    }

    /// Sink: a scalar event.
    pub fn scalar(self: *Encoder, value: []const u8, tag: []const u8, anchor: ?[]const u8) !void {
        const in_map = self.inMap();
        const is_key = in_map and self.nextIsKey();

        var kind: stream.Kind = .null;
        if (is_key) {
            try self.writeSeparator();
            kind = try self.writeKeyText(value, tag);
            try self.writeByte(':');
        } else {
            // A value of a mapping follows the colon its key wrote; an
            // item of a sequence is separated from the one before it.
            if (!in_map) try self.writeSeparator();
            kind = try self.writeScalar(.{ .out = &self.out, .allocator = self.allocator }, value, tag);
        }
        try self.countItem();

        if (anchor) |name| {
            try self.anchors.bindScalar(name, kind, value, tag);
        }
    }

    /// Sink: a sequence start.
    pub fn seqStart(self: *Encoder, anchor: ?[]const u8) !void {
        try self.startContainer(false, anchor);
    }

    /// Sink: a sequence end.
    pub fn seqEnd(self: *Encoder) !void {
        const frame = self.stack.pop() orelse return Error.OddMapping;
        defer if (frame.anchor) |name| self.allocator.free(name);
        try self.closeContainer(frame, .seq);
    }

    /// Sink: a mapping start.
    pub fn mapStart(self: *Encoder, anchor: ?[]const u8) !void {
        try self.startContainer(true, anchor);
    }

    /// Sink: a mapping end.
    pub fn mapEnd(self: *Encoder) !void {
        const frame = self.stack.pop() orelse return Error.OddMapping;
        defer if (frame.anchor) |name| self.allocator.free(name);
        if (frame.items % 2 != 0) return Error.OddMapping;
        try self.closeContainer(frame, .map);
    }

    /// Sink: an alias event.
    pub fn alias(self: *Encoder, name: []const u8) !void {
        const anchor = self.anchors.get(name) orelse return Error.AliasUnknown;
        const in_map = self.inMap();
        const is_key = in_map and self.nextIsKey();

        if (is_key) {
            try self.writeSeparator();
            try self.writeAliasKey(anchor);
            try self.writeByte(':');
        } else {
            if (!in_map) try self.writeSeparator();
            try self.writeAliasValue(anchor);
        }
        try self.countItem();
    }

    /// Open a container.
    fn startContainer(self: *Encoder, map: bool, anchor: ?[]const u8) !void {
        const in_map = self.inMap();
        const is_key = in_map and self.nextIsKey();
        if (is_key or !in_map) try self.writeSeparator();

        // The name of an anchor is copied, because the buffer of the event
        // does not outlive the event.
        const name = if (anchor) |a| try self.allocator.dupe(u8, a) else null;
        errdefer if (name) |owned| self.allocator.free(owned);

        try self.stack.append(self.allocator, .{
            .map = map,
            .body_start = self.out.items.len,
            .anchor = name,
            .is_key = is_key,
        });
    }

    /// Close a container: put its head in front of its body.
    fn closeContainer(self: *Encoder, frame: Frame, kind: stream.Kind) !void {
        try self.out.insertSlice(self.allocator, frame.body_start, if (frame.map) "{" else "[");
        try self.writeByte(if (frame.map) '}' else ']');

        if (frame.anchor) |name| {
            try self.anchors.bindCollection(name, kind, self.out.items[frame.body_start..]);
        }

        if (frame.is_key) {
            // A key that is not a string is written as its JSON text,
            // quoted.
            try self.quoteRange(frame.body_start);
            try self.writeByte(':');
        }
        try self.countItem();
    }

    /// Replace the bytes of a range with the same text, quoted.
    fn quoteRange(self: *Encoder, start: usize) !void {
        const text = try self.allocator.dupe(u8, self.out.items[start..]);
        defer self.allocator.free(text);

        var quoted: std.ArrayList(u8) = .empty;
        defer quoted.deinit(self.allocator);
        try writeString(.{ .out = &quoted, .allocator = self.allocator }, text);

        self.out.shrinkRetainingCapacity(start);
        try self.out.appendSlice(self.allocator, quoted.items);
    }

    /// Write the JSON text of a scalar.
    fn writeScalarText(self: *Encoder, value: []const u8, tag: []const u8) !void {
        const w: Writer = .{ .out = &self.out, .allocator = self.allocator };
        _ = try self.writeScalar(w, value, tag);
    }

    /// Write the JSON text of a scalar, and tell what kind it is.
    fn writeScalar(self: *Encoder, w: Writer, value: []const u8, tag: []const u8) !stream.Kind {
        if (scalars.isBinaryTag(tag)) {
            const decoded = base64.decode(self.allocator, value) catch {
                // Not valid base64: the text is the binary itself, and it
                // is rendered as base64 like any other binary value.
                const encoded = try base64.encode(self.allocator, value);
                defer self.allocator.free(encoded);
                try writeString(w, encoded);
                return .binary;
            };
            defer self.allocator.free(decoded);
            const encoded = try base64.encode(self.allocator, decoded);
            defer self.allocator.free(encoded);
            try writeString(w, encoded);
            return .binary;
        }

        switch (scalars.classify(value, tag)) {
            .null => {
                try w.slice("null");
                return .null;
            },
            .bool => {
                try w.slice(if (scalars.boolValue(value)) "true" else "false");
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
                    try writeString(w, value);
                    return .str;
                };
                try w.slice(text);
                return .int;
            },
            .float => {
                const f = scalars.parseF64(value) orelse {
                    // Not a number after all: fall back to the raw text.
                    try writeString(w, value);
                    return .str;
                };
                try writeFloat(w, f);
                return .float;
            },
            .str => {
                try writeString(w, value);
                return .str;
            },
        }
    }

    /// The kind a scalar has, without writing it.
    ///
    /// A scalar that looks like a number but is not one is a string, the
    /// same way the value tree treats it.
    fn kindOf(self: *Encoder, value: []const u8, tag: []const u8) !stream.Kind {
        if (scalars.isBinaryTag(tag)) return .binary;
        return switch (scalars.classify(value, tag)) {
            .null => .null,
            .bool => .bool,
            .int => blk: {
                var stack_buf: [128]u8 = undefined;
                var heap_buf: ?[]u8 = null;
                defer if (heap_buf) |buf| self.allocator.free(buf);
                const buf = if (value.len + 1 <= stack_buf.len) stack_buf[0..] else blk2: {
                    heap_buf = try self.allocator.alloc(u8, value.len + 1);
                    break :blk2 heap_buf.?;
                };
                break :blk if (scalars.normalizeInt(value, buf) == null) .str else .int;
            },
            .float => if (scalars.parseF64(value) == null) .str else .float,
            .str => .str,
        };
    }

    /// Write a key of a mapping, and tell what kind it is.
    fn writeKeyText(self: *Encoder, value: []const u8, tag: []const u8) !stream.Kind {
        const kind = try self.kindOf(value, tag);
        if (kind == .str) {
            // A string key is written as a string.
            try self.writeScalarText(value, tag);
            return kind;
        }
        // Any other key is written as its JSON text, quoted.
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        _ = try self.writeScalar(.{ .out = &text, .allocator = self.allocator }, value, tag);
        try writeString(.{ .out = &self.out, .allocator = self.allocator }, text.items);
        return kind;
    }

    /// Write the value an alias names.
    fn writeAliasValue(self: *Encoder, anchor: stream.Anchor) !void {
        switch (anchor.kind) {
            .seq, .map => try self.out.appendSlice(self.allocator, anchor.bytes),
            else => try self.writeScalarText(anchor.text, anchor.tag),
        }
    }

    /// Write a key an alias names.
    fn writeAliasKey(self: *Encoder, anchor: stream.Anchor) !void {
        if (anchor.kind == .str) {
            try self.writeAliasValue(anchor);
            return;
        }
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        switch (anchor.kind) {
            .seq, .map => try text.appendSlice(self.allocator, anchor.bytes),
            else => _ = try self.writeScalar(.{ .out = &text, .allocator = self.allocator }, anchor.text, anchor.tag),
        }
        try writeString(.{ .out = &self.out, .allocator = self.allocator }, text.items);
    }

    /// Whether the open container is a mapping.
    fn inMap(self: *const Encoder) bool {
        if (self.stack.items.len == 0) return false;
        return self.stack.items[self.stack.items.len - 1].map;
    }

    /// Whether the next item of the open mapping is a key.
    fn nextIsKey(self: *const Encoder) bool {
        if (self.stack.items.len == 0) return false;
        const top = &self.stack.items[self.stack.items.len - 1];
        return top.items % 2 == 0;
    }

    /// Write the comma between two items, if there is one.
    fn writeSeparator(self: *Encoder) !void {
        if (self.stack.items.len == 0) return;
        const top = &self.stack.items[self.stack.items.len - 1];
        if (top.items == 0) return;
        try self.writeByte(',');
    }

    fn writeByte(self: *Encoder, b: u8) !void {
        try self.out.append(self.allocator, b);
    }

    /// Count the item that was just written in the open container.
    fn countItem(self: *Encoder) !void {
        if (self.stack.items.len == 0) {
            if (self.root_end == null) self.root_end = self.out.items.len;
            return;
        }
        self.stack.items[self.stack.items.len - 1].items += 1;
    }
};

fn writeFloat(w: Writer, f: f64) !void {
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
fn writeString(w: Writer, bytes: []const u8) !void {
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

test "the scalars of a document" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.scalar("42", "", null);
    try encoder.scalar("text", "", null);
    try encoder.scalar("true", "", null);
    try encoder.scalar("null", "", null);
    try encoder.scalar("1.5", "", null);

    try testing.expectEqualStrings("42\"text\"truenull1.5", encoder.bytes());
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

    try testing.expectEqualStrings("{\"a\":1,\"b\":2}", encoder.bytes());
}

test "a key that is not a string is quoted" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.mapStart(null);
    try encoder.scalar("7", "", null);
    try encoder.scalar("1", "", null);
    try encoder.mapEnd();

    try testing.expectEqualStrings("{\"7\":1}", encoder.bytes());
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

    try testing.expectEqualStrings("[1,[2]]", encoder.bytes());
}

test "an empty document is null" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.finish();
    try testing.expectEqualStrings("null", encoder.bytes());
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

    try testing.expectEqualStrings("{\"a\":1,\"b\":1}", encoder.bytes());
}

test "an alias of a collection writes it again" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.seqStart("x");
    try encoder.scalar("1", "", null);
    try encoder.seqEnd();
    try encoder.alias("x");

    try testing.expectEqualStrings("[1][1]", encoder.bytes());
}

test "a binary value" {
    const allocator = testing.allocator;
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.scalar("aGVsbG8=", "tag:yaml.org,2002:binary", null);

    try testing.expectEqualStrings("\"aGVsbG8=\"", encoder.bytes());
}
