const std = @import("std");
const yaml = @cImport({
    @cInclude("yaml.h");
});
const erl_nif = @cImport({
    @cInclude("erl_nif.h");
});

// The rules that decide what a scalar is. They live in the core so that
// every host of zaml agrees on them; the module is passed in by the
// build, because the NIF is built from the `native/` directory and cannot
// reach `core/` on its own.
const scalars = @import("core").scalars;

const yaml_alloc = std.heap.c_allocator;

const FrameKind = enum { map, list };

const Frame = struct {
    kind: FrameKind,
    // Anchor name attached to this collection (from `&name`), owned by the
    // anchor arena. Bound to the finished term when the collection closes.
    anchor: ?[]const u8 = null,
    list_buf: std.ArrayList(erl_nif.ERL_NIF_TERM) = std.ArrayList(erl_nif.ERL_NIF_TERM).empty,
    pending_key: ?erl_nif.ERL_NIF_TERM = null,
    // Accumulated key/value pairs for the current map, flushed with a
    // single enif_make_map_from_arrays call when the map closes. This avoids
    // the O(n^2) rehashing of per-pair enif_make_map_put calls.
    keys: std.ArrayList(erl_nif.ERL_NIF_TERM) = std.ArrayList(erl_nif.ERL_NIF_TERM).empty,
    vals: std.ArrayList(erl_nif.ERL_NIF_TERM) = std.ArrayList(erl_nif.ERL_NIF_TERM).empty,
};

export fn zaml_load_nif(env: *erl_nif.ErlNifEnv, argc: c_int, argv: [*]const erl_nif.ERL_NIF_TERM) callconv(.c) erl_nif.ERL_NIF_TERM {
    _ = argc;
    const input_term = argv[0];

    var bin: erl_nif.ErlNifBinary = undefined;
    if (erl_nif.enif_inspect_binary(env, input_term, &bin) == 0) {
        return erl_nif.enif_make_atom(env, "error");
    }
    const data: [*]const u8 = @ptrCast(bin.data);
    const input = data[0..bin.size];

    return parse_yaml(env, input_term, input) catch {
        return erl_nif.enif_make_atom(env, "parse_error");
    };
}

fn make_string_sub(env: *erl_nif.ErlNifEnv, input_term: erl_nif.ERL_NIF_TERM, input: []const u8, value: []const u8) erl_nif.ERL_NIF_TERM {
    // libyaml processes plain scalars in place within the input buffer, so we
    // can sub-binary them with zero copy. For quoted/block/folded scalars
    // libyaml 0.2.x also reuses the input buffer, but to stay correct across
    // libyaml versions we only sub-binary when the pointer provably lies
    // inside `input`; otherwise we fall back to a fresh binary + copy.
    const base = @intFromPtr(input.ptr);
    const p = @intFromPtr(value.ptr);
    if (p >= base and p + value.len <= base + input.len) {
        const offset: usize = @intCast(p - base);
        return erl_nif.enif_make_sub_binary(env, input_term, offset, value.len);
    }
    var term: erl_nif.ERL_NIF_TERM = 0;
    const data = erl_nif.enif_make_new_binary(env, @intCast(value.len), &term);
    const dst: [*]u8 = @ptrCast(data);
    @memcpy(dst[0..value.len], value);
    return term;
}

fn parse_yaml(env: *erl_nif.ErlNifEnv, input_term: erl_nif.ERL_NIF_TERM, input: []const u8) !erl_nif.ERL_NIF_TERM {
    var parser: yaml.yaml_parser_t = undefined;
    if (yaml.yaml_parser_initialize(&parser) == 0) return error.NoParser;
    defer yaml.yaml_parser_delete(&parser);

    yaml.yaml_parser_set_input_string(&parser, input.ptr, @intCast(input.len));

    var stack = std.ArrayList(Frame).empty;
    defer {
        for (stack.items) |*f| {
            f.list_buf.deinit(yaml_alloc);
            f.keys.deinit(yaml_alloc);
            f.vals.deinit(yaml_alloc);
        }
        stack.deinit(yaml_alloc);
    }

    // Anchor names come from libyaml event buffers that are freed after every
    // event, so they must be copied into memory that outlives the event. The
    // arena keeps every name alive for the whole parse and frees them at once.
    var anchor_arena = std.heap.ArenaAllocator.init(yaml_alloc);
    defer anchor_arena.deinit();
    const anchor_alloc = anchor_arena.allocator();

    var anchors = std.StringHashMap(erl_nif.ERL_NIF_TERM).init(anchor_alloc);
    defer anchors.deinit();

    var first_doc: ?erl_nif.ERL_NIF_TERM = null;
    var event: yaml.yaml_event_t = undefined;
    var stream_done = false;

    while (!stream_done) {
        if (yaml.yaml_parser_parse(&parser, &event) == 0) return error.ParseError;
        defer yaml.yaml_event_delete(&event);

        switch (event.type) {
            yaml.YAML_NO_EVENT => continue,

            yaml.YAML_STREAM_START_EVENT => {},
            yaml.YAML_STREAM_END_EVENT => stream_done = true,
            yaml.YAML_DOCUMENT_START_EVENT => {},
            yaml.YAML_DOCUMENT_END_EVENT => {},

            yaml.YAML_ALIAS_EVENT => {
                const a = std.mem.span(event.data.alias.anchor);
                const v = anchors.get(a) orelse return error.AliasUnknown;
                try deliver_value(&stack, &first_doc, v);
            },

            yaml.YAML_SCALAR_EVENT => {
                const value = std.mem.span(event.data.scalar.value);
                const tag = if (event.data.scalar.tag) |t| std.mem.span(t) else "";
                const term = try scalar_term(env, input_term, input, value, tag);

                if (event.data.scalar.anchor) |a| {
                    try anchors.put(try anchor_alloc.dupe(u8, std.mem.span(a)), term);
                }
                try deliver_value(&stack, &first_doc, term);
            },

            yaml.YAML_SEQUENCE_START_EVENT => {
                var frame = Frame{ .kind = .list };
                if (event.data.sequence_start.anchor) |a| {
                    frame.anchor = try anchor_alloc.dupe(u8, std.mem.span(a));
                }
                try stack.append(yaml_alloc, frame);
            },
            yaml.YAML_SEQUENCE_END_EVENT => {
                const top = stack.pop() orelse return error.UnexpectedEvent;
                const term = erl_nif.enif_make_list_from_array(env, top.list_buf.items.ptr, @intCast(top.list_buf.items.len));
                if (top.anchor) |name| try anchors.put(name, term);
                try deliver_value(&stack, &first_doc, term);
            },

            yaml.YAML_MAPPING_START_EVENT => {
                var frame = Frame{ .kind = .map };
                if (event.data.mapping_start.anchor) |a| {
                    frame.anchor = try anchor_alloc.dupe(u8, std.mem.span(a));
                }
                try stack.append(yaml_alloc, frame);
            },
            yaml.YAML_MAPPING_END_EVENT => {
                const top = stack.pop() orelse return error.UnexpectedEvent;
                const term = try make_map(env, top.keys, top.vals);
                if (top.anchor) |name| try anchors.put(name, term);
                try deliver_value(&stack, &first_doc, term);
            },

            else => return error.UnknownEvent,
        }
    }

    return first_doc orelse erl_nif.enif_make_atom(env, "nil");
}

fn make_map(env: *erl_nif.ErlNifEnv, keys: std.ArrayList(erl_nif.ERL_NIF_TERM), vals: std.ArrayList(erl_nif.ERL_NIF_TERM)) !erl_nif.ERL_NIF_TERM {
    if (keys.items.len == 0) return erl_nif.enif_make_new_map(env);
    var out: erl_nif.ERL_NIF_TERM = 0;
    if (erl_nif.enif_make_map_from_arrays(env, keys.items.ptr, vals.items.ptr, @intCast(keys.items.len), &out) == 0) {
        return error.DuplicateKeys;
    }
    return out;
}

fn deliver_value(stack: *std.ArrayList(Frame), first_doc: *?erl_nif.ERL_NIF_TERM, value: erl_nif.ERL_NIF_TERM) !void {
    if (stack.items.len == 0) {
        if (first_doc.* == null) first_doc.* = value;
        return;
    }
    const top = &stack.items[stack.items.len - 1];
    switch (top.kind) {
        .list => try top.list_buf.append(yaml_alloc, value),
        .map => {
            if (top.pending_key == null) {
                top.pending_key = value;
            } else {
                const k = top.pending_key.?;
                top.pending_key = null;
                try top.keys.append(yaml_alloc, k);
                try top.vals.append(yaml_alloc, value);
            }
        },
    }
}

fn scalar_term(env: *erl_nif.ErlNifEnv, input_term: erl_nif.ERL_NIF_TERM, input: []const u8, value: []const u8, tag: []const u8) !erl_nif.ERL_NIF_TERM {
    switch (scalars.classify(value, tag)) {
        .str => return make_string_sub(env, input_term, input, value),
        .int => return make_int_term(env, value) catch return make_string_sub(env, input_term, input, value),
        .float => return make_float_term(env, value) catch return make_string_sub(env, input_term, input, value),
        .bool => return make_bool_term(env, value),
        .null => return erl_nif.enif_make_atom(env, "nil"),
    }
}

fn make_int_term(env: *erl_nif.ErlNifEnv, s: []const u8) !erl_nif.ERL_NIF_TERM {
    const v = scalars.parseI64(s) orelse return error.IntParseFailed;
    return erl_nif.enif_make_int64(env, v);
}

fn make_float_term(env: *erl_nif.ErlNifEnv, s: []const u8) !erl_nif.ERL_NIF_TERM {
    const f = scalars.parseF64(s) orelse return error.FloatParseFailed;
    return erl_nif.enif_make_double(env, f);
}

fn make_bool_term(env: *erl_nif.ErlNifEnv, s: []const u8) erl_nif.ERL_NIF_TERM {
    return erl_nif.enif_make_atom(env, if (scalars.boolValue(s)) "true" else "false");
}

var nif_funcs = [_]erl_nif.ErlNifFunc{
    .{
        .name = @as([*]const u8, @ptrCast("load")),
        .arity = 1,
        .fptr = @ptrCast(&zaml_load_nif),
        .flags = 0,
    },
};

var nif_entry = erl_nif.ErlNifEntry{
    .major = erl_nif.ERL_NIF_MAJOR_VERSION,
    .minor = erl_nif.ERL_NIF_MINOR_VERSION,
    .name = @as([*]const u8, @ptrCast("Elixir.Zaml")),
    .num_of_funcs = nif_funcs.len,
    .funcs = @as([*]erl_nif.ErlNifFunc, &nif_funcs),
    .load = null,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = @as([*]const u8, @ptrCast(erl_nif.ERL_NIF_VM_VARIANT)),
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = @sizeOf(erl_nif.ErlNifResourceTypeInit),
    .min_erts = null,
};

export fn nif_init() callconv(.c) [*c]erl_nif.ErlNifEntry {
    return &nif_entry;
}
