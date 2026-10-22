//! The build script of zaml.
//!
//! The native hosts (the Erlang NIF and the CPython extension) are built
//! by the Makefile and by `builder.py`, because they need the headers of
//! the Erlang and Python installations. This build script covers the
//! WebAssembly targets, which need nothing but the Zig toolchain:
//!
//!   zig build wasm        - the browser/Node module (wasm32-freestanding)
//!   zig build wasm-wasi   - the Wasmer command (wasm32-wasi-musl)
//!   zig build test        - the unit tests of the shared core
//!
//! Both WebAssembly targets are built from the same sources: the shared
//! core in `core/`, the vendored libyaml in `vendor/libyaml/` and the
//! event bridge in `wasm/shim/`.

const std = @import("std");

/// The C sources of libyaml that a parser needs. The emitter and the
/// writer are not part of it: zaml only reads YAML.
const libyaml_sources = [_][]const u8{
    "vendor/libyaml/api.c",
    "vendor/libyaml/loader.c",
    "vendor/libyaml/parser.c",
    "vendor/libyaml/reader.c",
    "vendor/libyaml/scanner.c",
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // The shared core, reachable from every target.
    const core_module = b.addModule("core", .{
        .root_source_file = b.path("core/core.zig"),
    });

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasi_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    // The browser module: no libc, no imports, a plain WebAssembly
    // module the JavaScript package instantiates.
    const browser_module = b.createModule(.{
        .root_source_file = b.path("wasm/main.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .link_libc = false,
    });
    browser_module.addImport("core", core_module);
    browser_module.export_symbol_names = &.{
        "zaml_alloc",
        "zaml_free",
        "zaml_parse",
        "zaml_result_ptr",
        "zaml_result_len",
        "zaml_error_ptr",
        "zaml_error_len",
    };
    browser_module.addIncludePath(b.path("vendor/libyaml"));
    browser_module.addIncludePath(b.path("wasm/shim/include"));
    browser_module.addIncludePath(b.path("wasm/shim"));
    browser_module.addCSourceFiles(.{
        .files = &libyaml_sources,
        .flags = &.{"-DHAVE_CONFIG_H=1"},
    });
    browser_module.addCSourceFiles(.{
        .files = &.{"wasm/shim/zaml_events.c"},
        .flags = &.{"-DHAVE_CONFIG_H=1"},
    });

    const browser = b.addExecutable(.{
        .name = "zaml",
        .root_module = browser_module,
    });
    browser.entry = .disabled;
    const browser_install = b.addInstallArtifact(browser, .{
        .dest_dir = .{ .override = .{ .custom = "dist/wasm" } },
    });
    const browser_step = b.step("wasm", "Build the browser WebAssembly module");
    browser_step.dependOn(&browser_install.step);

    // The Wasmer command: reads YAML on stdin, writes the result to
    // stdout.
    const wasi_module = b.createModule(.{
        .root_source_file = b.path("wasm/wasi_main.zig"),
        .target = wasi_target,
        .optimize = optimize,
        .link_libc = true,
    });
    wasi_module.addImport("core", core_module);
    wasi_module.addIncludePath(b.path("vendor/libyaml"));
    wasi_module.addCSourceFiles(.{
        .files = &libyaml_sources,
        .flags = &.{"-DHAVE_CONFIG_H=1"},
    });
    wasi_module.addCSourceFiles(.{
        .files = &.{"wasm/shim/zaml_events.c"},
        .flags = &.{"-DHAVE_CONFIG_H=1"},
    });

    const wasi = b.addExecutable(.{
        .name = "zaml",
        .root_module = wasi_module,
    });
    // The two targets produce different modules, so they get different
    // names: `zaml.wasm` is the browser module, `zaml.wasi.wasm` the
    // Wasmer command. Sharing a name would let one overwrite the other.
    const wasi_install = b.addInstallFile(wasi.getEmittedBin(), "dist/wasm/zaml.wasi.wasm");
    const wasi_step = b.step("wasm-wasi", "Build the Wasmer command");
    wasi_step.dependOn(&wasi_install.step);

    // The unit tests of the shared core. They use the vendored libyaml
    // sources, so they test exactly what the WebAssembly builds ship.
    const test_module = b.createModule(.{
        .root_source_file = b.path("core/test_all.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addIncludePath(b.path("vendor/libyaml"));
    test_module.addCSourceFiles(.{
        .files = &libyaml_sources,
        .flags = &.{"-DHAVE_CONFIG_H=1"},
    });
    const core_tests = b.addTest(.{ .root_module = test_module });
    const run_core_tests = b.addRunArtifact(core_tests);
    const test_step = b.step("test", "Run the unit tests of the shared core");
    test_step.dependOn(&run_core_tests.step);
}
