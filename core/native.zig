//! The parts of the core the native hosts share.
//!
//! The Erlang NIF and the CPython extension are built outside the build
//! script, from their own directories, and they need the system libyaml
//! rather than the vendored one. They must therefore not reach the whole
//! core: `core/core.zig` pulls in the WebAssembly C bridge, which has no
//! place in a native build.
//!
//! What the native hosts share is the classification of a scalar: how a
//! tag and a plain value turn into a kind. The construction of the value
//! itself stays in the host, because an Erlang term and a Python object
//! are made in very different ways.

pub const scalars = @import("scalar.zig");
