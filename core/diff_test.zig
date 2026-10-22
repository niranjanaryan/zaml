//! A differential test of the streaming encoders.
//!
//! The streaming encoders must write exactly what the value tree wrote, so
//! this test parses every document of the corpus twice: once into a value
//! tree that is encoded the old way, and once straight into a streaming
//! encoder. The two results have to be the same bytes.

const std = @import("std");

const legacy_cbor = @import("legacy_cbor.zig");
const legacy_json = @import("legacy_json.zig");
const parse = @import("parse.zig");
const value = @import("value.zig");
const cbor = @import("cbor.zig");
const json = @import("json.zig");

const testing = std.testing;

const corpus = [_][]const u8{
    "",
    " ",
    "\n",
    "null",
    "~",
    "true",
    "false",
    "yes",
    "no",
    "on",
    "off",
    "42",
    "-42",
    "+42",
    "007",
    "-0",
    "1_000",
    "123456789012345678901234567890",
    "-123456789012345678901234567890",
    "1.5",
    "-1.5e-3",
    "1e5",
    "1e",
    ".5",
    "1.",
    "0x1f",
    "hello",
    "'quoted'",
    "\"double quoted\"",
    "with spaces",
    "a: b",
    "a: 1\nb: 2",
    "a:\n  b: 1\n  c: 2",
    "[1, 2, 3]",
    "[]",
    "{}",
    "{a: 1, b: 2}",
    "[1, [2, [3, [4]]]]",
    "a: [1, 2]\nb: {c: 3}",
    "{1: one, 2: two}",
    "1: a",
    "null: null",
    "true: false",
    "1.5: x",
    "? [a, b]\n: value",
    "? {a: 1}\n: value",
    "?: value",
    "key: |\n  line one\n  line two",
    "key: >\n  folded text",
    "key: !custom value",
    "key: !!str 123",
    "key: !!int 123",
    "key: !!float 123",
    "key: !!bool yes",
    "key: !!null ~",
    "key: !!binary aGVsbG8=",
    "key: !!binary aGVsbG8",
    "key: !!binary \"!!!\"",
    "- &a 1\n- *a",
    "a: &anchor value\nb: *anchor",
    "a: &anchor [1, 2]\nb: *anchor",
    "a: &anchor {x: 1}\nb: *anchor",
    "base: &b\n  x: 1\nuse: *b",
    "seq: &s\n  - 1\n  - 2\ncopy: *s",
    "---\na: 1\n---\nb: 2\n",
    "---\n---\n",
    "a: 1\n---\nb: 2\n",
    "- 1\n- 2\n",
    "list:\n  - a: 1\n    b: 2\n  - c: 3",
    "nested:\n  deep:\n    deeper:\n      - 1\n      - 2",
    "unicode: \xce\xbb",
    "escape: \"a\\\"b\\\\c\\nd\"",
    "control: \"a\\u0001b\"",
    "big: 18446744073709551615",
    "bigger: 18446744073709551616",
    "negative: -9223372036854775808",
    "float: 3.141592653589793",
    "text: |\n  a\n  b\n",
    "empty_str: ''",
    "empty_map: {}",
    "empty_seq: []",
    "key with spaces: value",
    "'key': 'value'",
    "1: 2\n3: 4",
    "a: 1\n---\nb: 2\n",
};

fn legacyCbor(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var builder = value.Builder.init(allocator);
    defer builder.deinit();
    try parse.parse(value.Builder, input, &builder, null);
    const root = builder.result() orelse value.Value{ .kind = .null };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try legacy_cbor.encode(allocator, root, &out);
    return out.toOwnedSlice(allocator);
}

fn legacyJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var builder = value.Builder.init(allocator);
    defer builder.deinit();
    try parse.parse(value.Builder, input, &builder, null);
    const root = builder.result() orelse value.Value{ .kind = .null };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try legacy_json.encode(allocator, root, &out);
    return out.toOwnedSlice(allocator);
}

fn streamedCbor(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var encoder = cbor.Encoder.init(allocator);
    defer encoder.deinit();
    try parse.parse(cbor.Encoder, input, &encoder, null);
    try encoder.finish();
    return allocator.dupe(u8, encoder.bytes());
}

fn streamedJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var encoder = json.Encoder.init(allocator);
    defer encoder.deinit();
    try parse.parse(json.Encoder, input, &encoder, null);
    try encoder.finish();
    return allocator.dupe(u8, encoder.bytes());
}

test "the streaming encoders write what the value tree writes" {
    const allocator = testing.allocator;

    for (corpus, 0..) |input, i| {
        const want_cbor = legacyCbor(allocator, input) catch |err| {
            std.debug.print("cbor of document {d} failed: {s}\n", .{ i, @errorName(err) });
            return err;
        };
        defer allocator.free(want_cbor);
        const got_cbor = streamedCbor(allocator, input) catch |err| {
            std.debug.print("streamed cbor of document {d} failed: {s}\n", .{ i, @errorName(err) });
            return err;
        };
        defer allocator.free(got_cbor);

        if (!std.mem.eql(u8, want_cbor, got_cbor)) {
            std.debug.print("cbor differs for document {d}: {s}\n", .{ i, input });
            std.debug.print("  want: {x}\n", .{want_cbor});
            std.debug.print("  got:  {x}\n", .{got_cbor});
            return error.TestUnexpectedResult;
        }

        const want_json = try legacyJson(allocator, input);
        defer allocator.free(want_json);
        const got_json = try streamedJson(allocator, input);
        defer allocator.free(got_json);

        if (!std.mem.eql(u8, want_json, got_json)) {
            std.debug.print("json differs for document {d}: {s}\n", .{ i, input });
            std.debug.print("  want: {s}\n", .{want_json});
            std.debug.print("  got:  {s}\n", .{got_json});
            return error.TestUnexpectedResult;
        }
    }
}

test "the streaming encoders agree on the benchmark fixture" {
    const allocator = testing.allocator;
    const io = testing.io;

    // The fixture is written by the benchmark scripts. The test is
    // skipped when it is not there.
    const dir = std.Io.Dir.cwd();
    const input = dir.readFileAlloc(io, "benchmark/big.yml", allocator, .unlimited) catch return;
    defer allocator.free(input);

    const want_cbor = try legacyCbor(allocator, input);
    defer allocator.free(want_cbor);
    const got_cbor = try streamedCbor(allocator, input);
    defer allocator.free(got_cbor);
    try testing.expectEqualSlices(u8, want_cbor, got_cbor);

    const want_json = try legacyJson(allocator, input);
    defer allocator.free(want_json);
    const got_json = try streamedJson(allocator, input);
    defer allocator.free(got_json);
    try testing.expectEqualSlices(u8, want_json, got_json);
}
