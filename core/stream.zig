//! The scaffolding the streaming encoders share.
//!
//! Both encoders write a document while the events of the parse arrive.
//! Nothing is kept as a tree of values, so the memory an encoder needs is
//! about the size of the document it writes, not the size of the values
//! in it.

const std = @import("std");

/// The kind of a value.
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

/// A node an anchor names.
pub const Anchor = struct {
    /// The kind of the node.
    kind: Kind,
    /// The text of a scalar, with the tag it was written with. Empty for
    /// a collection.
    text: []const u8 = "",
    tag: []const u8 = "",
    /// The encoded bytes of a collection. Empty for a scalar.
    bytes: []u8 = &.{},
};

/// The anchors of a document.
///
/// An alias writes the node its anchor names again, so an anchor holds
/// what is needed to write it: the text of a scalar, or the encoded bytes
/// of a collection. Everything is copied out of the buffers it comes
/// from, because those buffers do not outlive the event.
pub const Anchors = struct {
    map: std.StringHashMap(Anchor),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Anchors {
        return .{
            .map = std.StringHashMap(Anchor).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Anchors) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.text);
            self.allocator.free(entry.value_ptr.tag);
            self.allocator.free(entry.value_ptr.bytes);
        }
        self.map.deinit();
    }

    /// Bind an anchor to a node.
    pub fn bindScalar(self: *Anchors, name: []const u8, kind: Kind, text: []const u8, tag: []const u8) !void {
        const anchor = Anchor{
            .kind = kind,
            .text = try self.allocator.dupe(u8, text),
            .tag = try self.allocator.dupe(u8, tag),
        };
        try self.put(name, anchor);
    }

    /// Bind an anchor to a collection, which is kept as its encoded bytes.
    pub fn bindCollection(self: *Anchors, name: []const u8, kind: Kind, bytes: []const u8) !void {
        const anchor = Anchor{
            .kind = kind,
            .bytes = try self.allocator.dupe(u8, bytes),
        };
        try self.put(name, anchor);
    }

    /// The node an alias names.
    pub fn get(self: *const Anchors, name: []const u8) ?Anchor {
        return self.map.get(name);
    }

    fn put(self: *Anchors, name: []const u8, anchor: Anchor) !void {
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);

        if (self.map.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.text);
            self.allocator.free(old.value.tag);
            self.allocator.free(old.value.bytes);
        }
        try self.map.put(key, anchor);
    }
};

const testing = std.testing;

test "an anchor keeps the node it names" {
    var anchors = Anchors.init(testing.allocator);
    defer anchors.deinit();

    try anchors.bindScalar("a", .int, "42", "");
    const found = anchors.get("a").?;
    try testing.expectEqual(Kind.int, found.kind);
    try testing.expectEqualStrings("42", found.text);

    try anchors.bindCollection("b", .seq, "\x81\x01");
    const collection = anchors.get("b").?;
    try testing.expectEqual(Kind.seq, collection.kind);
    try testing.expectEqualStrings("\x81\x01", collection.bytes);
}

test "an anchor can be bound again" {
    var anchors = Anchors.init(testing.allocator);
    defer anchors.deinit();

    try anchors.bindScalar("a", .int, "1", "");
    try anchors.bindScalar("a", .int, "2", "");
    const found = anchors.get("a").?;
    try testing.expectEqualStrings("2", found.text);
}
