//! The zaml core: the parts of the parser that do not depend on the host.
//!
//! The native hosts (Erlang, Python) use these modules directly. The
//! WASM builds reach them through this file, because a module can only
//! import files from its own directory.

pub const base64 = @import("base64.zig");
pub const cbor = @import("cbor.zig");
pub const emit = @import("emit.zig");
pub const event = @import("event.zig");
pub const json = @import("json.zig");
pub const parse_c = @import("parse_c.zig");
pub const scalars = @import("scalar.zig");
pub const stream = @import("stream.zig");
