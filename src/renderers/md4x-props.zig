// SPDX-License-Identifier: MIT
//
// Shared component property parser for the md4x renderers.
//
// This is the Zig counterpart of the (orphaned) header-only md4x-props.h. The C
// header's md_parse_props() is `static`, so @cImport mistranslates its body
// (array-index post-increment) and cannot link it cleanly. The parser is ported
// to Zig here and shared by the AST, HTML, and ANSI renderers. Behavior is kept
// byte-for-byte identical to the C source.
//
// Imported (not @cImport'd into a clashing symbol) by each renderer lib: Zig
// compiles its own internal copy per importing artifact, so there is no
// exported-symbol collision and no build.zig change is required.

const std = @import("std");

const c = @cImport({
    @cInclude("md4x.h");
});

pub const MD_MAX_PROPS: usize = 32;
pub const MD_CLASS_BUF_SIZE: usize = 512;

// Prop kind. Explicit c_int tag values mirror the C MD_PROP_TYPE enum
// (STRING=0, BOOLEAN=1, BIND=2) so callers may compare against the tags
// directly as well as switch on them.
pub const MD_PROP_TYPE = enum(c_int) {
    string = 0, // key="value", key='value', or key=value
    boolean = 1, // bare word (no value)
    bind = 2, // :key='value' (JSON passthrough)
};

pub const MD_PROP = struct {
    type: MD_PROP_TYPE = .string,
    key: [*]const u8 = undefined,
    key_size: c.MD_SIZE = 0,
    value: ?[*]const u8 = null,
    value_size: c.MD_SIZE = 0,
};

pub const MD_PARSED_PROPS = struct {
    props: [MD_MAX_PROPS]MD_PROP = [_]MD_PROP{.{}} ** MD_MAX_PROPS,
    n_props: c_int = 0,
    class_buf: [MD_CLASS_BUF_SIZE]u8 = [_]u8{0} ** MD_CLASS_BUF_SIZE,
    class_len: c.MD_SIZE = 0,
    id: ?[*]const u8 = null,
    id_size: c.MD_SIZE = 0,
};

// Parse a raw component property string (`key="value" bool #id .class :bind='json'`)
// into the structured MD_PARSED_PROPS form. All key/value pointers are zero-copy
// references into `raw` (not NUL-terminated — use the *_size fields).
pub fn md_parse_props(raw: ?[*]const u8, size: c.MD_SIZE, out: *MD_PARSED_PROPS) void {
    out.* = .{};

    if (raw == null or size == 0)
        return;
    const r = raw.?;

    var i: c.MD_OFFSET = 0;
    while (i < size) {
        // Skip whitespace.
        while (i < size and (r[i] == ' ' or r[i] == '\t'))
            i += 1;
        if (i >= size)
            break;

        if (r[i] == '#') {
            // #id shorthand → store as id (last wins).
            i += 1;
            const start = i;
            while (i < size and r[i] != ' ' and r[i] != '\t' and r[i] != '}')
                i += 1;
            if (i > start) {
                out.id = r + start;
                out.id_size = i - start;
            }
        } else if (r[i] == '.') {
            // .class shorthand → append to merged class buffer.
            i += 1;
            const start = i;
            while (i < size and r[i] != ' ' and r[i] != '\t' and r[i] != '}' and r[i] != '.')
                i += 1;
            if (i > start) {
                const len = i - start;
                if (out.class_len > 0 and out.class_len + 1 < MD_CLASS_BUF_SIZE) {
                    out.class_buf[out.class_len] = ' ';
                    out.class_len += 1;
                }
                if (out.class_len + len < MD_CLASS_BUF_SIZE) {
                    @memcpy(out.class_buf[out.class_len .. out.class_len + len], (r + start)[0..len]);
                    out.class_len += len;
                }
            }
        } else {
            // key="value", key='value', key=value, :key='json', or bare boolean.
            var key_start = i;
            var is_bind = false;

            if (r[i] == ':') {
                is_bind = true;
                i += 1;
                key_start = i;
            }

            while (i < size and r[i] != '=' and r[i] != ' ' and r[i] != '\t' and r[i] != '}')
                i += 1;

            if (i > key_start and i < size and r[i] == '=') {
                // key=...
                const key_end = i;
                i += 1; // skip '='

                if (i < size and (r[i] == '"' or r[i] == '\'')) {
                    // Quoted value.
                    const quote = r[i];
                    i += 1;
                    const val_start = i;
                    while (i < size and r[i] != quote)
                        i += 1;

                    if (out.n_props < MD_MAX_PROPS) {
                        const p = &out.props[@intCast(out.n_props)];
                        out.n_props += 1;
                        p.type = if (is_bind) .bind else .string;
                        p.key = r + key_start;
                        p.key_size = key_end - key_start;
                        p.value = r + val_start;
                        p.value_size = i - val_start;
                    }
                    if (i < size) i += 1; // skip closing quote
                } else {
                    // Unquoted value.
                    const val_start = i;
                    while (i < size and r[i] != ' ' and r[i] != '\t' and r[i] != '}')
                        i += 1;

                    if (out.n_props < MD_MAX_PROPS) {
                        const p = &out.props[@intCast(out.n_props)];
                        out.n_props += 1;
                        p.type = if (is_bind) .bind else .string;
                        p.key = r + key_start;
                        p.key_size = key_end - key_start;
                        p.value = r + val_start;
                        p.value_size = i - val_start;
                    }
                }
            } else if (i > key_start) {
                // Bare word → boolean prop.
                if (out.n_props < MD_MAX_PROPS) {
                    const p = &out.props[@intCast(out.n_props)];
                    out.n_props += 1;
                    p.type = .boolean;
                    p.key = r + key_start;
                    p.key_size = i - key_start;
                    p.value = null;
                    p.value_size = 0;
                }
            } else {
                // Skip unrecognized character to avoid infinite loop.
                i += 1;
            }
        }
    }
}
