// CPython extension module for `zaml`: a fast YAML parser backed by libyaml,
// built entirely with the Zig toolchain (no clang / setuptools C glue).
//
// https://github.com/niranjanaryan/zaml-elixir
const std = @import("std");

const py = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

const yaml = @cImport({
    @cInclude("yaml.h");
});

const alloc = std.heap.c_allocator;

const FrameKind = enum { map, list };

const Frame = struct {
    kind: FrameKind,
    obj: *py.PyObject,
    pending_key: ?*py.PyObject = null,
};

fn new_none() *py.PyObject {
    return py.Py_BuildValue("");
}

fn scalar_obj(value: []const u8, tag: []const u8) !*py.PyObject {
    if (tag.len > 0) {
        if (std.mem.endsWith(u8, tag, ":str")) return new_str(value);
        if (std.mem.endsWith(u8, tag, ":int")) return make_int(value) orelse new_str(value);
        if (std.mem.endsWith(u8, tag, ":float")) return make_float(value) orelse new_str(value);
        if (std.mem.endsWith(u8, tag, ":bool")) return make_bool(value);
        if (std.mem.endsWith(u8, tag, ":null")) return new_none();
    }
    if (is_bool_true(value)) return py.PyBool_FromLong(1);
    if (is_bool_false(value)) return py.PyBool_FromLong(0);
    if (is_null(value)) return new_none();
    if (is_int_str(value)) return make_int(value) orelse new_str(value);
    if (is_float_str(value)) return make_float(value) orelse new_str(value);
    return new_str(value);
}

fn new_str(value: []const u8) *py.PyObject {
    return py.PyUnicode_FromStringAndSize(@ptrCast(value.ptr), @intCast(value.len));
}

fn make_int(s: []const u8) ?*py.PyObject {
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n + 1 >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    buf[n] = 0;
    // PyLong_FromString handles arbitrary precision (and the sign).
    return py.PyLong_FromString(@ptrCast(&buf[0]), null, 10);
}

fn make_float(s: []const u8) ?*py.PyObject {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    const f = std.fmt.parseFloat(f64, buf[0..n]) catch return null;
    return py.PyFloat_FromDouble(f);
}

fn make_bool(s: []const u8) *py.PyObject {
    if (is_bool_false(s)) return py.PyBool_FromLong(0);
    return py.PyBool_FromLong(1);
}

fn is_bool_true(s: []const u8) bool {
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "True") or std.mem.eql(u8, s, "TRUE") or
        std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "Yes") or std.mem.eql(u8, s, "YES") or
        std.mem.eql(u8, s, "on") or std.mem.eql(u8, s, "On") or std.mem.eql(u8, s, "ON");
}

fn is_bool_false(s: []const u8) bool {
    return std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "False") or std.mem.eql(u8, s, "FALSE") or
        std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "No") or std.mem.eql(u8, s, "NO") or
        std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "Off") or std.mem.eql(u8, s, "OFF");
}

fn is_null(s: []const u8) bool {
    return std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "Null") or std.mem.eql(u8, s, "NULL") or
        std.mem.eql(u8, s, "~") or s.len == 0;
}

fn is_int_str(s: []const u8) bool {
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

fn is_float_str(s: []const u8) bool {
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

fn deliver(stack: *std.ArrayList(Frame), root: *?*py.PyObject, value: *py.PyObject) !void {
    if (stack.items.len == 0) {
        if (root.* == null) {
            root.* = value;
        } else {
            py.Py_DecRef(value);
        }
        return;
    }
    const top = &stack.items[stack.items.len - 1];
    switch (top.kind) {
        .list => {
            _ = py.PyList_Append(top.obj, value);
            py.Py_DecRef(value);
        },
        .map => {
            if (top.pending_key == null) {
                top.pending_key = value;
            } else {
                const k = top.pending_key.?;
                top.pending_key = null;
                if (py.PyDict_SetItem(top.obj, k, value) != 0) {
                    py.Py_DecRef(k);
                    py.Py_DecRef(value);
                    return error.UnhashableKey;
                }
                py.Py_DecRef(k);
                py.Py_DecRef(value);
            }
        },
    }
}

fn parse(input: []const u8) !*py.PyObject {
    var parser: yaml.yaml_parser_t = undefined;
    if (yaml.yaml_parser_initialize(&parser) == 0) return error.NoParser;
    defer yaml.yaml_parser_delete(&parser);
    yaml.yaml_parser_set_input_string(&parser, input.ptr, @intCast(input.len));

    var stack: std.ArrayList(Frame) = .empty;
    defer {
        // Only reached with frames left over on the error path; the success
        // path drains the stack. Release each partially-built container and
        // any dangling mapping key.
        for (stack.items) |*f| {
            if (f.pending_key) |k| py.Py_DecRef(k);
            py.Py_DecRef(f.obj);
        }
        stack.deinit(alloc);
    }

    const anchors = py.PyDict_New();
    defer py.Py_DecRef(anchors);

    var root: ?*py.PyObject = null;
    var event: yaml.yaml_event_t = undefined;
    var done = false;

    while (!done) {
        if (yaml.yaml_parser_parse(&parser, &event) == 0) return error.ParseError;
        defer yaml.yaml_event_delete(&event);

        switch (event.type) {
            yaml.YAML_NO_EVENT => {},

            yaml.YAML_STREAM_START_EVENT => {},
            yaml.YAML_DOCUMENT_START_EVENT => {},
            yaml.YAML_DOCUMENT_END_EVENT => {},
            yaml.YAML_STREAM_END_EVENT => done = true,

            yaml.YAML_ALIAS_EVENT => {
                const a = std.mem.span(event.data.alias.anchor);
                const v = py.PyDict_GetItemString(anchors, @ptrCast(a.ptr));
                if (v == null) return error.AliasUnknown;
                py.Py_IncRef(v);
                try deliver(&stack, &root, v);
            },

            yaml.YAML_SCALAR_EVENT => {
                const value = std.mem.span(event.data.scalar.value);
                const tag = if (event.data.scalar.tag) |t| std.mem.span(t) else "";
                const obj = try scalar_obj(value, tag);
                if (event.data.scalar.anchor) |a| {
                    const name = std.mem.span(a);
                    _ = py.PyDict_SetItemString(anchors, @ptrCast(name.ptr), obj);
                }
                try deliver(&stack, &root, obj);
            },

            yaml.YAML_SEQUENCE_START_EVENT => {
                const list = py.PyList_New(0);
                if (event.data.sequence_start.anchor) |a| {
                    const name = std.mem.span(a);
                    _ = py.PyDict_SetItemString(anchors, @ptrCast(name.ptr), list);
                }
                try stack.append(alloc, .{ .kind = .list, .obj = list });
            },
            yaml.YAML_SEQUENCE_END_EVENT => {
                const top = stack.pop() orelse return error.UnexpectedEvent;
                if (top.pending_key) |k| py.Py_DecRef(k);
                try deliver(&stack, &root, top.obj);
            },

            yaml.YAML_MAPPING_START_EVENT => {
                const map = py.PyDict_New();
                if (event.data.mapping_start.anchor) |a| {
                    const name = std.mem.span(a);
                    _ = py.PyDict_SetItemString(anchors, @ptrCast(name.ptr), map);
                }
                try stack.append(alloc, .{ .kind = .map, .obj = map });
            },
            yaml.YAML_MAPPING_END_EVENT => {
                const top = stack.pop() orelse return error.UnexpectedEvent;
                if (top.pending_key) |k| {
                    py.Py_DecRef(k);
                    return error.OddMapping;
                }
                try deliver(&stack, &root, top.obj);
            },

            else => return error.UnknownEvent,
        }
    }

    return root orelse new_none();
}

fn zaml_load(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.c) [*c]py.PyObject {
    _ = self;
    var buf: [*c]const u8 = undefined;
    var len: py.Py_ssize_t = 0;
    if (py.PyArg_ParseTuple(args, "s#", &buf, &len) == 0) return null;

    const input = buf[0..@intCast(len)];
    const result = parse(input) catch {
        if (py.PyErr_Occurred() == null) {
            py.PyErr_SetString(py.PyExc_ValueError, "invalid YAML");
        }
        return null;
    };
    return @ptrCast(result);
}

var zaml_methods = [_]py.PyMethodDef{
    py.PyMethodDef{
        .ml_name = "load",
        .ml_meth = zaml_load,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "load(yaml: str | bytes) -> object\n\nParse a YAML document and return native Python objects.",
    },
    py.PyMethodDef{
        .ml_name = null,
        .ml_meth = null,
        .ml_flags = 0,
        .ml_doc = null,
    },
};

// CPython <3.12 exposes `PyObject.ob_refcnt` directly; 3.12/3.13 pack it
// into an anonymous union ({ob_refcnt, ob_refcnt_split}) and 3.14 renamed the
// wide member to `ob_refcnt_full`. Set the refcount to 1 whichever layout the
// headers we are compiled against use.
const module_def_base: py.PyModuleDef_Base = blk: {
    var base = std.mem.zeroes(py.PyModuleDef_Base);
    base.ob_base.ob_type = null;
    if (@hasField(py.PyObject, "ob_refcnt")) {
        base.ob_base.ob_refcnt = 1;
    } else if (@hasField(py.PyObject, "unnamed_0")) {
        const Refcnt = @TypeOf(base.ob_base.unnamed_0);
        if (@hasField(Refcnt, "ob_refcnt_full")) {
            base.ob_base.unnamed_0.ob_refcnt_full = 1;
        } else if (@hasField(Refcnt, "ob_refcnt")) {
            base.ob_base.unnamed_0.ob_refcnt = 1;
        } else if (@hasField(Refcnt, "ob_refcnt_split")) {
            base.ob_base.unnamed_0.ob_refcnt_split[0] = 1;
        }
    }
    break :blk base;
};

var zaml_module = py.PyModuleDef{
    .m_base = module_def_base,
    .m_name = "zamlpy",
    .m_doc = "Fast YAML 1.2 parser backed by libyaml, built with Zig.",
    .m_size = -1,
    .m_methods = &zaml_methods,
    .m_slots = null,
    .m_traverse = null,
    .m_clear = null,
    .m_free = null,
};

pub export fn PyInit_zamlpy() [*c]py.PyObject {
    return py.PyModule_Create(&zaml_module);
}
