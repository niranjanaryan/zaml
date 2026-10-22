//! The allocator of the WebAssembly module.
//!
//! The freestanding build has no libc, so the module grows the
//! WebAssembly memory itself. Every block carries a small header with
//! its length, which lets `free` find the right size class without the
//! caller repeating the size: the C sources of libyaml call `free` with
//! nothing but a pointer.
//!
//! The WASI build uses the C library of the runtime instead, so it needs
//! none of this.

const std = @import("std");
const builtin = @import("builtin");

/// True when the module runs without a libc.
pub const freestanding = builtin.os.tag == .freestanding;

/// The allocator the WebAssembly memory is carved up with.
const base = if (freestanding) std.heap.wasm_allocator else std.heap.c_allocator;

/// The header every block of the freestanding heap carries.
///
/// It sits right in front of the payload and is a multiple of 16 bytes,
/// so the payload keeps the alignment of the block.
const Header = struct {
    /// The address of the block the payload lives in.
    block: usize,
    /// The size of that block.
    total: usize,
    /// The length of the payload.
    len: usize,
    /// The alignment the block was allocated with.
    alignment: usize,
};

const header_size = @sizeOf(Header);

/// The allocator the module uses for everything it owns.
pub const allocator: std.mem.Allocator = if (freestanding)
    .{ .ptr = undefined, .vtable = &vtable }
else
    std.heap.c_allocator;

const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = freeBlock,
};

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;

    const wanted = @max(alignment.toByteUnits(), @alignOf(Header));
    const total = len + header_size + wanted;
    const block = base.rawAlloc(total, .fromByteUnits(wanted), @returnAddress()) orelse return null;

    const payload = std.mem.alignForward(usize, @intFromPtr(block) + header_size, wanted);
    const header: *Header = @ptrFromInt(payload - header_size);
    header.* = .{
        .block = @intFromPtr(block),
        .total = total,
        .len = len,
        .alignment = wanted,
    };
    return @ptrFromInt(payload);
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;

    const header = headerOf(memory.ptr);
    if (new_len + header_size > header.total) return false;
    header.len = new_len;
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    if (!resize(ctx, memory, alignment, new_len, ret_addr)) return null;
    return memory.ptr;
}

fn freeBlock(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;

    release(memory.ptr);
}

fn release(block: [*]u8) void {
    const header = headerOf(block);
    const bytes: [*]u8 = @ptrFromInt(header.block);
    base.vtable.free(base.ptr, bytes[0..header.total], .fromByteUnits(header.alignment), 0);
}

/// The header in front of a payload.
pub fn headerOf(ptr: [*]u8) *Header {
    return @ptrFromInt(@intFromPtr(ptr) - header_size);
}

/// The length of a payload handed out by this allocator.
pub fn lengthOf(ptr: [*]u8) usize {
    return headerOf(ptr).len;
}

/// Release a payload handed out by this allocator.
pub fn releaseBlock(ptr: [*]u8) void {
    release(ptr);
}
