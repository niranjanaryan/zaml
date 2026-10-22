//! The C entry points the vendored libyaml sources need.
//!
//! The freestanding build has no libc, so `malloc`, `free` and the rest
//! are provided here. They are ordinary exports of the module, which is
//! why they live in their own file: the WASI build gets them from the C
//! library of the runtime and must not define them a second time.

const std = @import("std");
const alloc = @import("alloc.zig");

export fn malloc(size: usize) callconv(.c) ?*anyopaque {
    const buf = alloc.allocator.alloc(u8, size) catch return null;
    return @ptrCast(buf.ptr);
}

export fn free(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    const bytes: [*]u8 = @ptrCast(@alignCast(p));
    alloc.releaseBlock(bytes);
}

export fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const old = ptr orelse return malloc(size);
    const bytes: [*]u8 = @ptrCast(@alignCast(old));
    const old_len = alloc.lengthOf(bytes);

    const buf = alloc.allocator.alloc(u8, size) catch return null;
    @memcpy(buf[0..@min(old_len, size)], bytes[0..@min(old_len, size)]);
    free(old);
    return @ptrCast(buf.ptr);
}

export fn strdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const len = std.mem.len(s);
    const buf = alloc.allocator.alloc(u8, len + 1) catch return null;
    @memcpy(buf[0..len], s[0..len]);
    buf[len] = 0;
    return @ptrCast(buf.ptr);
}

export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    const x = std.mem.span(a);
    const y = std.mem.span(b);
    const n = @min(x.len, y.len);
    for (x[0..n], y[0..n]) |left, right| {
        if (left != right) return @as(c_int, left) - @as(c_int, right);
    }
    if (x.len == y.len) return 0;
    return if (x.len > y.len) 1 else -1;
}

export fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) callconv(.c) c_int {
    const x = std.mem.span(a);
    const y = std.mem.span(b);
    const count = @min(n, @min(x.len, y.len));
    for (x[0..count], y[0..count]) |left, right| {
        if (left != right) return @as(c_int, left) - @as(c_int, right);
    }
    // The first `n` bytes are equal when the compared part was not
    // exhausted by a difference.
    if (n <= @min(x.len, y.len)) return 0;
    if (x.len == y.len) return 0;
    return if (x.len > y.len) 1 else -1;
}

// The file based parts of libyaml are never used: the parser always
// reads from a string. The stubs keep the linker happy.
export fn fread(ptr: ?*anyopaque, size: usize, count: usize, stream: ?*anyopaque) callconv(.c) usize {
    _ = ptr;
    _ = size;
    _ = count;
    _ = stream;
    return 0;
}

export fn fwrite(ptr: ?*anyopaque, size: usize, count: usize, stream: ?*anyopaque) callconv(.c) usize {
    _ = ptr;
    _ = size;
    _ = count;
    _ = stream;
    return 0;
}

export fn ferror(stream: ?*anyopaque) callconv(.c) c_int {
    _ = stream;
    return 1;
}
