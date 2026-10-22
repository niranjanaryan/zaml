//! Host-agnostic scalar and tag classification shared by every zaml host:
//! the Erlang NIF, the CPython extension and the WASM core.
//!
//! These rules are the single source of truth for how an untagged or
//! explicitly tagged YAML scalar maps onto a value. Every host used to carry
//! its own copy of these predicates; they must stay in sync, so they live here.

const std = @import("std");

/// The value kind a scalar resolves to.
pub const Kind = enum {
    str,
    int,
    float,
    bool,
    null,
};

/// True for the scalar spellings that resolve to `true`.
pub fn isBoolTrue(s: []const u8) bool {
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "True") or std.mem.eql(u8, s, "TRUE") or
        std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "Yes") or std.mem.eql(u8, s, "YES") or
        std.mem.eql(u8, s, "on") or std.mem.eql(u8, s, "On") or std.mem.eql(u8, s, "ON");
}

/// True for the scalar spellings that resolve to `false`.
pub fn isBoolFalse(s: []const u8) bool {
    return std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "False") or std.mem.eql(u8, s, "FALSE") or
        std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "No") or std.mem.eql(u8, s, "NO") or
        std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "Off") or std.mem.eql(u8, s, "OFF");
}

/// True for the scalar spellings that resolve to null.
pub fn isNull(s: []const u8) bool {
    return std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "Null") or std.mem.eql(u8, s, "NULL") or
        std.mem.eql(u8, s, "~") or s.len == 0;
}

/// True for scalars that look like a decimal integer.
pub fn isIntStr(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '+' or s[0] == '-') {
        if (s.len == 1) return false;
        i = 1;
    }
    var has_digit = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '_') continue;
        if (c < '0' or c > '9') return false;
        has_digit = true;
    }
    return has_digit;
}

/// True for scalars that look like a decimal float.
pub fn isFloatStr(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '+' or s[0] == '-') {
        if (s.len == 1) return false;
        i = 1;
    }
    var has_digit = false;
    var has_dot = false;
    var has_e = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '_') continue;
        if (c == '.') {
            if (has_dot or has_e) return false;
            has_dot = true;
        } else if (c == 'e' or c == 'E') {
            if (has_e or !has_digit) return false;
            has_e = true;
            if (i + 1 < s.len and (s[i + 1] == '+' or s[i + 1] == '-')) i += 1;
        } else if (c < '0' or c > '9') {
            return false;
        } else {
            has_digit = true;
        }
    }
    return (has_dot or has_e) and has_digit;
}

/// Classify a scalar, honouring an explicit tag when one is present.
///
/// Tags arrive in their expanded form (`tag:yaml.org,2002:int`), so the
/// suffix is what carries the meaning.
pub fn classify(value: []const u8, tag: []const u8) Kind {
    if (tag.len > 0) {
        if (std.mem.endsWith(u8, tag, ":str")) return .str;
        if (std.mem.endsWith(u8, tag, ":int")) return .int;
        if (std.mem.endsWith(u8, tag, ":float")) return .float;
        if (std.mem.endsWith(u8, tag, ":bool")) return .bool;
        if (std.mem.endsWith(u8, tag, ":null")) return .null;
    }
    if (isBoolTrue(value)) return .bool;
    if (isBoolFalse(value)) return .bool;
    if (isNull(value)) return .null;
    if (isIntStr(value)) return .int;
    if (isFloatStr(value)) return .float;
    return .str;
}

/// The boolean value of a scalar classified as `.bool`.
pub fn boolValue(s: []const u8) bool {
    return !isBoolFalse(s);
}

/// True when the tag marks the scalar as base64-encoded binary data.
pub fn isBinaryTag(tag: []const u8) bool {
    return tag.len > 0 and std.mem.endsWith(u8, tag, ":binary");
}

/// Copy `s` into `buf` with the YAML `_` digit separators removed.
///
/// Returns null when the result does not fit in `buf`.
pub fn stripUnderscores(s: []const u8, buf: []u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// Canonical decimal text of an integer scalar: `_` separators removed, an
/// explicit `+` dropped, leading zeros removed and `-0` normalised to `0`.
///
/// The result is written into `buf` and is always a valid JSON number.
pub fn normalizeInt(s: []const u8, buf: []u8) ?[]const u8 {
    const stripped = stripUnderscores(s, buf) orelse return null;

    var neg = false;
    var start: usize = 0;
    if (stripped.len > 0 and (stripped[0] == '-' or stripped[0] == '+')) {
        neg = stripped[0] == '-';
        start = 1;
    }

    // Drop leading zeros, keeping at least one digit.
    var digits = start;
    while (digits + 1 < stripped.len and stripped[digits] == '0') digits += 1;
    const digit_count = stripped.len - digits;

    // `-0` is zero.
    if (neg and digit_count == 1 and stripped[digits] == '0') {
        buf[0] = '0';
        return buf[0..1];
    }

    // Move the significant digits to the front of the buffer.
    if (digits != 0) {
        std.mem.copyForwards(u8, buf[0..digit_count], buf[digits .. digits + digit_count]);
    }
    if (!neg) return buf[0..digit_count];

    // Prepend the sign.
    std.mem.copyBackwards(u8, buf[1 .. 1 + digit_count], buf[0..digit_count]);
    buf[0] = '-';
    return buf[0 .. 1 + digit_count];
}

/// Parse an integer scalar that fits into an i64.
pub fn parseI64(s: []const u8) ?i64 {
    var buf: [128]u8 = undefined;
    const normalized = normalizeInt(s, &buf) orelse return null;
    return std.fmt.parseInt(i64, normalized, 10) catch null;
}

/// Parse a float scalar.
pub fn parseF64(s: []const u8) ?f64 {
    var buf: [128]u8 = undefined;
    if (s.len > buf.len) return null;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        buf[n] = c;
        n += 1;
    }
    return std.fmt.parseFloat(f64, buf[0..n]) catch null;
}

const testing = std.testing;

test "boolean spellings" {
    try testing.expect(isBoolTrue("true"));
    try testing.expect(isBoolTrue("True"));
    try testing.expect(isBoolTrue("TRUE"));
    try testing.expect(isBoolTrue("yes"));
    try testing.expect(isBoolTrue("Yes"));
    try testing.expect(isBoolTrue("YES"));
    try testing.expect(isBoolTrue("on"));
    try testing.expect(isBoolTrue("On"));
    try testing.expect(isBoolTrue("ON"));
    try testing.expect(!isBoolTrue("false"));
    try testing.expect(isBoolTrue("no") == false);
    try testing.expect(!isBoolTrue("off"));
    try testing.expect(!isBoolTrue("truthy"));
}

test "false spellings" {
    try testing.expect(isBoolFalse("false"));
    try testing.expect(isBoolFalse("False"));
    try testing.expect(isBoolFalse("FALSE"));
    try testing.expect(isBoolFalse("no"));
    try testing.expect(isBoolFalse("No"));
    try testing.expect(isBoolFalse("NO"));
    try testing.expect(isBoolFalse("off"));
    try testing.expect(isBoolFalse("Off"));
    try testing.expect(isBoolFalse("OFF"));
    try testing.expect(!isBoolFalse("true"));
    try testing.expect(!isBoolFalse("nope"));
}

test "null spellings" {
    try testing.expect(isNull("null"));
    try testing.expect(isNull("Null"));
    try testing.expect(isNull("NULL"));
    try testing.expect(isNull("~"));
    try testing.expect(isNull(""));
    try testing.expect(!isNull("nul"));
}

test "integer spellings" {
    try testing.expect(isIntStr("0"));
    try testing.expect(isIntStr("-1"));
    try testing.expect(isIntStr("+1"));
    try testing.expect(isIntStr("1_000"));
    try testing.expect(isIntStr("007"));
    try testing.expect(!isIntStr(""));
    try testing.expect(!isIntStr("-"));
    try testing.expect(!isIntStr("1.0"));
    try testing.expect(!isIntStr("0x1f"));
    try testing.expect(!isIntStr("1a"));
}

test "float spellings" {
    try testing.expect(isFloatStr("1.0"));
    try testing.expect(isFloatStr("1."));
    try testing.expect(isFloatStr("1e5"));
    try testing.expect(isFloatStr("1E5"));
    try testing.expect(isFloatStr("-1.5e-3"));
    try testing.expect(isFloatStr("1_0.5"));
    try testing.expect(!isFloatStr("1"));
    try testing.expect(isFloatStr(".5"));
    try testing.expect(!isFloatStr("1.2.3"));
    // "1e" classifies as a float; the float parse then fails and the hosts
    // fall back to the raw string.
    try testing.expect(isFloatStr("1e"));
}

test "classification honours explicit tags" {
    try testing.expectEqual(Kind.str, classify("1", "tag:yaml.org,2002:str"));
    try testing.expectEqual(Kind.int, classify("1", "tag:yaml.org,2002:int"));
    try testing.expectEqual(Kind.float, classify("1", "tag:yaml.org,2002:float"));
    try testing.expectEqual(Kind.bool, classify("1", "tag:yaml.org,2002:bool"));
    try testing.expectEqual(Kind.null, classify("1", "tag:yaml.org,2002:null"));
    try testing.expectEqual(Kind.int, classify("1", ""));
}

test "classification of untagged scalars" {
    try testing.expectEqual(Kind.bool, classify("true", ""));
    try testing.expectEqual(Kind.bool, classify("off", ""));
    try testing.expectEqual(Kind.null, classify("~", ""));
    try testing.expectEqual(Kind.null, classify("", ""));
    try testing.expectEqual(Kind.int, classify("42", ""));
    try testing.expectEqual(Kind.float, classify("4.2", ""));
    try testing.expectEqual(Kind.str, classify("hello", ""));
    try testing.expectEqual(Kind.str, classify("0x1f", ""));
}

test "bool value" {
    try testing.expect(boolValue("true"));
    try testing.expect(!boolValue("false"));
    try testing.expect(boolValue("anything else"));
}

test "strip underscores" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1000", stripUnderscores("1_000", &buf).?);
    try testing.expectEqualStrings("1000", stripUnderscores("1000", &buf).?);
    try testing.expectEqualStrings("-12", stripUnderscores("-1_2", &buf).?);
    var small: [4]u8 = undefined;
    try testing.expect(stripUnderscores("123456", &small) == null);
}

test "normalize integers" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", normalizeInt("0", &buf).?);
    try testing.expectEqualStrings("7", normalizeInt("007", &buf).?);
    try testing.expectEqualStrings("7", normalizeInt("+7", &buf).?);
    try testing.expectEqualStrings("-7", normalizeInt("-007", &buf).?);
    try testing.expectEqualStrings("0", normalizeInt("-0", &buf).?);
    try testing.expectEqualStrings("0", normalizeInt("-000", &buf).?);
    try testing.expectEqualStrings("1000", normalizeInt("1_000", &buf).?);
    try testing.expectEqualStrings("-1000", normalizeInt("-1_000", &buf).?);
    try testing.expectEqualStrings("10", normalizeInt("10", &buf).?);
}

test "parse i64" {
    try testing.expectEqual(@as(?i64, 42), parseI64("42"));
    try testing.expectEqual(@as(?i64, 42), parseI64("0042"));
    try testing.expectEqual(@as(?i64, -42), parseI64("-42"));
    try testing.expectEqual(@as(?i64, null), parseI64("12345678901234567890"));
}

test "parse f64" {
    try testing.expectEqual(@as(?f64, 1.5), parseF64("1.5"));
    try testing.expectEqual(@as(?f64, 150.0), parseF64("1_5e1"));
    try testing.expectEqual(@as(?f64, null), parseF64("abc"));
}
