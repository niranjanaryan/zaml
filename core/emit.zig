//! A tiny byte writer used by the CBOR and JSON encoders.

const std = @import("std");

pub const Writer = struct {
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn byte(self: Writer, b: u8) !void {
        try self.out.append(self.allocator, b);
    }

    pub fn slice(self: Writer, s: []const u8) !void {
        try self.out.appendSlice(self.allocator, s);
    }

    pub fn u16be(self: Writer, v: u16) !void {
        try self.byte(@truncate(v >> 8));
        try self.byte(@truncate(v));
    }

    pub fn u32be(self: Writer, v: u32) !void {
        try self.byte(@truncate(v >> 24));
        try self.byte(@truncate(v >> 16));
        try self.byte(@truncate(v >> 8));
        try self.byte(@truncate(v));
    }

    pub fn u64be(self: Writer, v: u64) !void {
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            try self.byte(@truncate(v >> @intCast(56 - 8 * i)));
        }
    }

    /// Write a CBOR head: the major type in the top three bits and the
    /// argument in the shortest form that can hold it.
    pub fn head(self: Writer, major: u8, arg: u64) !void {
        const mt: u8 = major << 5;
        if (arg < 24) {
            try self.byte(mt | @as(u8, @intCast(arg)));
        } else if (arg <= 0xff) {
            try self.byte(mt | 24);
            try self.byte(@intCast(arg));
        } else if (arg <= 0xffff) {
            try self.byte(mt | 25);
            try self.u16be(@intCast(arg));
        } else if (arg <= 0xffffffff) {
            try self.byte(mt | 26);
            try self.u32be(@intCast(arg));
        } else {
            try self.byte(mt | 27);
            try self.u64be(arg);
        }
    }
};
