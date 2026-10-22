//! The host-agnostic value tree and the builder that fills it from a libyaml
//! event stream.
//!
//! The tree is what the WASM core encodes into CBOR or JSON. The native hosts
//! (Erlang, Python) build their own values directly from the event stream and
//! do not use the tree; only the classification rules are shared with them.

const std = @import("std");
const scalars = @import("scalar.zig");
const base64 = @import("base64.zig");

pub const Kind = enum {
    null,
    bool,
    int,
    float,
    str,
    binary,
    seq,
    map,
};

/// A node of the value tree.
///
/// Integers keep their canonical decimal text so that arbitrarily large
/// values survive the round trip; floats are stored as an f64; strings and
/// binary blobs keep their raw bytes.
pub const Value = struct {
    kind: Kind = .null,
    b: bool = false,
    int_text: []const u8 = "",
    f: f64 = 0,
    bytes: []const u8 = "",
    items: []const Value = &.{},
    keys: []const Value = &.{},
    values: []const Value = &.{},

    pub fn isContainer(self: Value) bool {
        return self.kind == .seq or self.kind == .map;
    }
};

pub const Error = error{
    AliasUnknown,
    OddMapping,
    OutOfMemory,
};

const FrameKind = enum { seq, map };

const Frame = struct {
    kind: FrameKind,
    anchor: ?[]const u8 = null,
    items: std.ArrayList(Value) = .empty,
    keys: std.ArrayList(Value) = .empty,
    values: std.ArrayList(Value) = .empty,
    pending_key: ?Value = null,
};

/// Fills a value tree from the libyaml event stream.
///
/// The builder is the `Sink` of `parse.Parser(Builder)`.
pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    stack: std.ArrayList(Frame) = .empty,
    root: ?Value = null,
    anchors: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .anchors = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.anchors.deinit();
        self.arena.deinit();
    }

    /// The first document of the stream, if any.
    pub fn result(self: *const Builder) ?Value {
        return self.root;
    }

    fn alloc(self: *Builder) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn dupe(self: *Builder, bytes: []const u8) ![]const u8 {
        return try self.alloc().dupe(u8, bytes);
    }

    /// Sink: a scalar event.
    pub fn scalar(self: *Builder, value: []const u8, tag: []const u8, anchor: ?[]const u8) !void {
        const v = try self.buildScalar(value, tag);
        if (anchor) |name| try self.bindAnchor(name, v);
        try self.deliver(v);
    }

    /// Sink: a sequence start.
    pub fn seqStart(self: *Builder, anchor: ?[]const u8) !void {
        var frame: Frame = .{ .kind = .seq };
        if (anchor) |name| frame.anchor = try self.dupe(name);
        try self.stack.append(self.alloc(), frame);
    }

    /// Sink: a sequence end.
    pub fn seqEnd(self: *Builder) !void {
        const top = self.stack.pop() orelse return Error.OddMapping;
        const v: Value = .{ .kind = .seq, .items = top.items.items };
        if (top.anchor) |name| try self.bindAnchor(name, v);
        try self.deliver(v);
    }

    /// Sink: a mapping start.
    pub fn mapStart(self: *Builder, anchor: ?[]const u8) !void {
        var frame: Frame = .{ .kind = .map };
        if (anchor) |name| frame.anchor = try self.dupe(name);
        try self.stack.append(self.alloc(), frame);
    }

    /// Sink: a mapping end.
    pub fn mapEnd(self: *Builder) !void {
        const top = self.stack.pop() orelse return Error.OddMapping;
        if (top.pending_key != null) return Error.OddMapping;
        const v: Value = .{ .kind = .map, .keys = top.keys.items, .values = top.values.items };
        if (top.anchor) |name| try self.bindAnchor(name, v);
        try self.deliver(v);
    }

    /// Sink: an alias event.
    pub fn alias(self: *Builder, name: []const u8) !void {
        const found = self.anchors.get(name) orelse return Error.AliasUnknown;
        try self.deliver(found);
    }

    fn bindAnchor(self: *Builder, name: []const u8, v: Value) !void {
        const key = try self.dupe(name);
        try self.anchors.put(key, v);
    }

    fn buildScalar(self: *Builder, value: []const u8, tag: []const u8) !Value {
        if (scalars.isBinaryTag(tag)) {
            // The value of a binary scalar is base64 encoded.
            const decoded = base64.decode(self.alloc(), value) catch {
                // Not valid base64: keep the text as it is.
                return .{ .kind = .binary, .bytes = try self.dupe(value) };
            };
            return .{ .kind = .binary, .bytes = decoded };
        }
        return switch (scalars.classify(value, tag)) {
            .null => .{ .kind = .null },
            .bool => .{ .kind = .bool, .b = scalars.boolValue(value) },
            .int => blk: {
                const buf = try self.alloc().alloc(u8, value.len + 1);
                const text = scalars.normalizeInt(value, buf) orelse {
                    // Not a number after all: fall back to the raw text.
                    break :blk Value{ .kind = .str, .bytes = try self.dupe(value) };
                };
                break :blk Value{ .kind = .int, .int_text = text };
            },
            .float => blk: {
                const f = scalars.parseF64(value) orelse {
                    break :blk Value{ .kind = .str, .bytes = try self.dupe(value) };
                };
                break :blk Value{ .kind = .float, .f = f };
            },
            .str => .{ .kind = .str, .bytes = try self.dupe(value) },
        };
    }

    fn deliver(self: *Builder, v: Value) !void {
        if (self.stack.items.len == 0) {
            if (self.root == null) self.root = v;
            return;
        }
        const top = &self.stack.items[self.stack.items.len - 1];
        switch (top.kind) {
            .seq => try top.items.append(self.alloc(), v),
            .map => {
                if (top.pending_key == null) {
                    top.pending_key = v;
                } else {
                    const k = top.pending_key.?;
                    top.pending_key = null;
                    try top.keys.append(self.alloc(), k);
                    try top.values.append(self.alloc(), v);
                }
            },
        }
    }
};

const testing = std.testing;

fn parseIntoTree(input: []const u8) !Builder {
    var builder = Builder.init(testing.allocator);
    errdefer builder.deinit();
    try ( @import("parse.zig")).parse(Builder, input, &builder, null);
    return builder;
}

test "scalars keep their kind" {
    var b = try parseIntoTree("a: 1\nb: text\nc: true\nd: null\ne: 1.5\n");
    defer b.deinit();
    const root = b.result().?;
    try testing.expectEqual(Kind.map, root.kind);
    try testing.expectEqual(@as(usize, 5), root.keys.len);
    try testing.expectEqual(Kind.int, root.values[0].kind);
    try testing.expectEqualStrings("1", root.values[0].int_text);
    try testing.expectEqual(Kind.str, root.values[1].kind);
    try testing.expectEqual(Kind.bool, root.values[2].kind);
    try testing.expectEqual(Kind.null, root.values[3].kind);
    try testing.expectEqual(Kind.float, root.values[4].kind);
}

test "big integers keep every digit" {
    var b = try parseIntoTree("n: 123456789012345678901234567890\n");
    defer b.deinit();
    const root = b.result().?;
    try testing.expectEqual(Kind.int, root.values[0].kind);
    try testing.expectEqualStrings("123456789012345678901234567890", root.values[0].int_text);
}

test "anchors and aliases" {
    var b = try parseIntoTree("base: &b\n  x: 1\nuse: *b\n");
    defer b.deinit();
    const root = b.result().?;
    try testing.expectEqual(Kind.map, root.kind);
    try testing.expectEqual(Kind.map, root.values[1].kind);
    try testing.expectEqual(@as(usize, 1), root.values[1].keys.len);
}

test "unknown alias is an error" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try testing.expectError(
        Error.AliasUnknown,
        ( @import("parse.zig")).parse(Builder, "x: *nope\n", &builder, null),
    );
}

test "only the first document is kept" {
    var b = try parseIntoTree("a: 1\n---\nb: 2\n");
    defer b.deinit();
    const root = b.result().?;
    try testing.expectEqual(Kind.map, root.kind);
    try testing.expectEqual(@as(usize, 1), root.keys.len);
}

test "empty document" {
    var b = try parseIntoTree("");
    defer b.deinit();
    try testing.expect(b.result() == null);
}
