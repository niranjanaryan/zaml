//! The test root of the shared core.
//!
//! The tests of the core need the libyaml source of the native hosts,
//! which reaches libyaml through `@cImport`. The WebAssembly builds use
//! `parse_c.zig` instead and must not pull that header in, so the two
//! entry points are separate files.

pub const base64 = @import("base64.zig");
pub const cbor = @import("cbor.zig");
pub const emit = @import("emit.zig");
pub const event = @import("event.zig");
pub const json = @import("json.zig");
pub const parse = @import("parse.zig");
pub const scalars = @import("scalar.zig");
pub const stream = @import("stream.zig");
pub const value = @import("value.zig");

// The tests of a file are only run when the file is imported from a test
// block, so every file with tests is pulled in here.
test {
    _ = @import("base64.zig");
    _ = @import("cbor.zig");
    _ = @import("diff_test.zig");
    _ = @import("emit.zig");
    _ = @import("event.zig");
    _ = @import("json.zig");
    _ = @import("parse.zig");
    _ = @import("scalar.zig");
    _ = @import("stream.zig");
    _ = @import("value.zig");
}
