// MD4X: Markdown parser for C
// (http://github.com/unjs/md4x)
//
// Copyright (c) 2026 Pooya Parsa <pooya@pi0.io>
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//
// Zig port of src/renderers/md4x-meta.c — byte-for-byte identical behavior.

const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("md4x.h");
    // <yaml.h> for libyaml (the YAML frontmatter parser). We do NOT @cInclude
    // md4x-json.h: its writer helpers are `static`, so @cImport translates them
    // as unresolved external references — under the WASM linker that surfaces as
    // an unresolvable `env` import. Instead the JSON/YAML-to-JSON writers are
    // ported to Zig below, faithfully mirroring md4x-json.h for byte parity, and
    // call libyaml (whose symbols are external and link fine).
    @cInclude("yaml.h");
    @cInclude("md4x-heal.h");
    @cInclude("entity.h");
});

const c_allocator = std.heap.c_allocator;

// Renderer flags (mirrors md4x-meta.h). Heal flag value is shared (0x0100).
const MD_META_FLAG_DEBUG: c_uint = 0x0001;
const MD_META_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_META_FLAG_HEAL: c_uint = 0x0100;

const ProcessOutputFn = ?*const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) callconv(.c) void;

// *****************************
// ***  Internal data types  ***
// *****************************

const META_HEADING = struct {
    level: c_uint,
    text: ?[*]u8,
    text_size: c.MD_SIZE,
};

const META_CTX = struct {
    // Frontmatter raw text.
    fm_text: ?[*]u8 = null,
    fm_size: c.MD_SIZE = 0,
    fm_cap: c.MD_SIZE = 0,
    in_frontmatter: c_int = 0,

    // Headings array.
    headings: ?[*]META_HEADING = null,
    heading_count: c_int = 0,
    heading_cap: c_int = 0,

    // Current heading accumulator.
    in_heading: c_int = 0,
    heading_level: c_uint = 0,
    heading_buf: ?[*]u8 = null,
    heading_buf_size: c.MD_SIZE = 0,
    heading_buf_cap: c.MD_SIZE = 0,

    // Component nesting depth (to ignore component frontmatter).
    comp_depth: c_int = 0,

    err: c_int = 0,
};

// **********************************
// ***  Text accumulation helpers ***
// **********************************

// Mirrors the C realloc-based growable buffer. `buf` may be NULL initially
// (realloc(NULL, ...) == malloc). The current capacity is tracked separately so
// the Zig allocator can free/realloc the correct slice length.
fn meta_buf_append(
    buf: *?[*]u8,
    size: *c.MD_SIZE,
    cap: *c.MD_SIZE,
    text: [*]const u8,
    text_size: c.MD_SIZE,
) c_int {
    if (size.* + text_size > cap.*) {
        const new_cap: c.MD_SIZE = cap.* + cap.* / 2 + text_size + 64;
        if (buf.*) |old| {
            const p = c_allocator.realloc(old[0..cap.*], new_cap) catch return -1;
            buf.* = p.ptr;
        } else {
            const p = c_allocator.alloc(u8, new_cap) catch return -1;
            buf.* = p.ptr;
        }
        cap.* = new_cap;
    }
    @memcpy(buf.*.?[size.* .. size.* + text_size], text[0..text_size]);
    size.* += text_size;
    return 0;
}

fn hex_val(ch: u8) c_uint {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return 0;
}

// Encode a Unicode codepoint as UTF-8 into a buffer. Returns bytes written.
fn encode_utf8(codepoint: c_uint, out: [*]u8) c.MD_SIZE {
    if (codepoint <= 0x7f) {
        out[0] = @truncate(codepoint);
        return 1;
    } else if (codepoint <= 0x7ff) {
        out[0] = @intCast(0xc0 | ((codepoint >> 6) & 0x1f));
        out[1] = @intCast(0x80 | (codepoint & 0x3f));
        return 2;
    } else if (codepoint <= 0xffff) {
        out[0] = @intCast(0xe0 | ((codepoint >> 12) & 0xf));
        out[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
        out[2] = @intCast(0x80 | (codepoint & 0x3f));
        return 3;
    } else if (codepoint <= 0x10ffff) {
        out[0] = @intCast(0xf0 | ((codepoint >> 18) & 0x7));
        out[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3f));
        out[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
        out[3] = @intCast(0x80 | (codepoint & 0x3f));
        return 4;
    }
    // U+FFFD replacement character
    out[0] = 0xef;
    out[1] = 0xbf;
    out[2] = 0xbd;
    return 3;
}

// Resolve an HTML entity to UTF-8 and append to the heading buffer.
fn meta_append_entity(ctx: *META_CTX, text: [*]const u8, size: c.MD_SIZE) c_int {
    var utf8: [8]u8 = undefined;
    var n: c.MD_SIZE = undefined;

    if (size > 3 and text[1] == '#') {
        var codepoint: c_uint = 0;
        if (text[2] == 'x' or text[2] == 'X') {
            var i: c.MD_SIZE = 3;
            while (i < size - 1) : (i += 1)
                codepoint = 16 *% codepoint +% hex_val(text[i]);
        } else {
            var i: c.MD_SIZE = 2;
            while (i < size - 1) : (i += 1)
                codepoint = 10 *% codepoint +% (text[i] - '0');
        }
        n = encode_utf8(codepoint, &utf8);
        return meta_buf_append(&ctx.heading_buf, &ctx.heading_buf_size, &ctx.heading_buf_cap, &utf8, n);
    } else {
        const ent = c.entity_lookup(@ptrCast(text), size);
        if (ent != null) {
            const cps = ent.*.codepoints;
            n = encode_utf8(cps[0], &utf8);
            if (meta_buf_append(&ctx.heading_buf, &ctx.heading_buf_size, &ctx.heading_buf_cap, &utf8, n) != 0)
                return -1;
            if (cps[1] != 0) {
                n = encode_utf8(cps[1], &utf8);
                return meta_buf_append(&ctx.heading_buf, &ctx.heading_buf_size, &ctx.heading_buf_cap, &utf8, n);
            }
            return 0;
        }
    }

    // Unknown entity: pass through as-is.
    return meta_buf_append(&ctx.heading_buf, &ctx.heading_buf_size, &ctx.heading_buf_cap, text, size);
}

// **********************************
// ***  md_parse() callbacks       ***
// **********************************

fn meta_enter_block(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const ctx: *META_CTX = @ptrCast(@alignCast(userdata.?));

    if (block_type == c.MD_BLOCK_COMPONENT) {
        ctx.comp_depth += 1;
    } else if (block_type == c.MD_BLOCK_FRONTMATTER) {
        // Only capture document-level frontmatter, not component frontmatter.
        if (ctx.comp_depth == 0)
            ctx.in_frontmatter = 1;
    } else if (block_type == c.MD_BLOCK_H) {
        const d: *const c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail.?));
        ctx.in_heading = 1;
        ctx.heading_level = d.level;
        ctx.heading_buf_size = 0;
    }

    return 0;
}

fn meta_leave_block(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const ctx: *META_CTX = @ptrCast(@alignCast(userdata.?));

    _ = detail;

    if (block_type == c.MD_BLOCK_COMPONENT) {
        ctx.comp_depth -= 1;
    } else if (block_type == c.MD_BLOCK_FRONTMATTER) {
        ctx.in_frontmatter = 0;
    } else if (block_type == c.MD_BLOCK_H) {
        // Store the completed heading.
        if (ctx.heading_count >= ctx.heading_cap) {
            const new_cap: c_int = if (ctx.heading_cap == 0) 8 else ctx.heading_cap * 2;
            const new_n: usize = @intCast(new_cap);
            if (ctx.headings) |old| {
                const old_n: usize = @intCast(ctx.heading_cap);
                const p = c_allocator.realloc(old[0..old_n], new_n) catch {
                    ctx.err = 1;
                    return -1;
                };
                ctx.headings = p.ptr;
            } else {
                const p = c_allocator.alloc(META_HEADING, new_n) catch {
                    ctx.err = 1;
                    return -1;
                };
                ctx.headings = p.ptr;
            }
            ctx.heading_cap = new_cap;
        }

        const idx: usize = @intCast(ctx.heading_count);
        ctx.headings.?[idx].level = ctx.heading_level;

        // Copy accumulated text.
        if (ctx.heading_buf_size > 0) {
            const text = c_allocator.alloc(u8, ctx.heading_buf_size + 1) catch {
                ctx.err = 1;
                return -1;
            };
            @memcpy(text[0..ctx.heading_buf_size], ctx.heading_buf.?[0..ctx.heading_buf_size]);
            text[ctx.heading_buf_size] = 0;
            ctx.headings.?[idx].text = text.ptr;
            ctx.headings.?[idx].text_size = ctx.heading_buf_size;
        } else {
            ctx.headings.?[idx].text = null;
            ctx.headings.?[idx].text_size = 0;
        }

        ctx.heading_count += 1;
        ctx.in_heading = 0;
    }

    return 0;
}

fn meta_enter_span(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    _ = span_type;
    _ = detail;
    _ = userdata;
    return 0;
}

fn meta_leave_span(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    _ = span_type;
    _ = detail;
    _ = userdata;
    return 0;
}

fn meta_text(text_type: c.MD_TEXTTYPE, text_in: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) c_int {
    const ctx: *META_CTX = @ptrCast(@alignCast(userdata.?));
    const text: [*]const u8 = @ptrCast(text_in);

    if (ctx.in_frontmatter != 0) {
        if (meta_buf_append(&ctx.fm_text, &ctx.fm_size, &ctx.fm_cap, text, size) != 0) {
            ctx.err = 1;
            return -1;
        }
        return 0;
    }

    if (ctx.in_heading != 0) {
        switch (text_type) {
            c.MD_TEXT_SOFTBR, c.MD_TEXT_BR => {
                if (meta_buf_append(&ctx.heading_buf, &ctx.heading_buf_size, &ctx.heading_buf_cap, " ", 1) != 0) {
                    ctx.err = 1;
                    return -1;
                }
            },

            c.MD_TEXT_NULLCHAR => {
                const buf = [_]u8{ 0xEF, 0xBF, 0xBD };
                if (meta_buf_append(&ctx.heading_buf, &ctx.heading_buf_size, &ctx.heading_buf_cap, &buf, 3) != 0) {
                    ctx.err = 1;
                    return -1;
                }
            },

            c.MD_TEXT_ENTITY => {
                if (meta_append_entity(ctx, text, size) != 0) {
                    ctx.err = 1;
                    return -1;
                }
            },

            else => {
                if (meta_buf_append(&ctx.heading_buf, &ctx.heading_buf_size, &ctx.heading_buf_cap, text, size) != 0) {
                    ctx.err = 1;
                    return -1;
                }
            },
        }
    }

    return 0;
}

fn meta_debug_log(msg: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    _ = c.fprintf(c.stderr, "MD4X: %s\n", msg);
}

// **************************************
// ***  JSON output                   ***
// **************************************
//
// The following is a faithful Zig port of src/renderers/md4x-json.h. The C
// helpers there are `static` (file-local), so they cannot be reused via
// @cImport without becoming unresolved WASM imports — hence the port. Behavior
// is kept byte-for-byte identical, including YAML 1.1 type coercion.

// Streaming JSON writer (mirrors the C JSON_WRITER struct).
const JSON_WRITER = struct {
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
};

fn json_write(w: *JSON_WRITER, data: [*]const u8, size: c.MD_SIZE) void {
    w.process_output.?(@ptrCast(data), size, w.userdata);
}

fn json_write_str(w: *JSON_WRITER, str: [*:0]const u8) void {
    json_write(w, str, @intCast(std.mem.len(str)));
}

fn json_write_escaped(w: *JSON_WRITER, str: [*]const u8, size: c.MD_SIZE) void {
    var i: c.MD_OFFSET = 0;
    var beg: c.MD_OFFSET = 0;
    var esc: [8]u8 = undefined;

    while (i < size) : (i += 1) {
        const ch: u8 = str[i];
        var replacement: ?[*]const u8 = null;
        var esc_len: c_int = 0;

        switch (ch) {
            '"' => replacement = "\\\"",
            '\\' => replacement = "\\\\",
            0x08 => replacement = "\\b", // \b
            0x0c => replacement = "\\f", // \f
            '\n' => replacement = "\\n",
            '\r' => replacement = "\\r",
            '\t' => replacement = "\\t",
            else => {
                if (ch < 0x20) {
                    _ = c.snprintf(&esc, esc.len, "\\u%04x", @as(c_uint, ch));
                    replacement = &esc;
                    esc_len = 6;
                }
            },
        }

        if (replacement) |rep| {
            if (i > beg)
                json_write(w, str + beg, i - beg);
            if (esc_len == 0)
                esc_len = @intCast(std.mem.len(@as([*:0]const u8, @ptrCast(rep))));
            json_write(w, rep, @intCast(esc_len));
            beg = i + 1;
        }
    }

    if (i > beg)
        json_write(w, str + beg, i - beg);
}

fn json_write_string(w: *JSON_WRITER, str: [*]const u8, size: c.MD_SIZE) void {
    json_write(w, "\"", 1);
    json_write_escaped(w, str, size);
    json_write(w, "\"", 1);
}

// Helper: check if a string matches a value (case-insensitive, known length).
fn yaml_streq_ci(s: [*]const u8, len: c.MD_SIZE, lit: [*]const u8, lit_len: c.MD_SIZE) c_int {
    if (len != lit_len) return 0;
    var i: c.MD_SIZE = 0;
    while (i < len) : (i += 1) {
        var ch: u8 = s[i];
        if (ch >= 'A' and ch <= 'Z')
            ch += 32;
        if (ch != lit[i])
            return 0;
    }
    return 1;
}

// Helper: check if a value string looks like a JSON number.
fn yaml_is_number(s: [*]const u8, len: c.MD_SIZE) c_int {
    var i: c.MD_SIZE = 0;
    var has_digit: c_int = 0;
    var has_dot: c_int = 0;

    if (len == 0) return 0;

    // Optional leading sign.
    if (s[0] == '-' or s[0] == '+') {
        i += 1;
        if (i >= len) return 0;
    }

    while (i < len) : (i += 1) {
        if (s[i] >= '0' and s[i] <= '9') {
            has_digit = 1;
        } else if (s[i] == '.' and has_dot == 0) {
            has_dot = 1;
        } else {
            return 0;
        }
    }
    return has_digit;
}

// Write a YAML scalar as a typed JSON value (YAML 1.1 resolution for plain scalars).
fn json_write_yaml_scalar(w: *JSON_WRITER, event: *const c.yaml_event_t) void {
    const val: [*]const u8 = @ptrCast(event.data.scalar.value);
    const len: c.MD_SIZE = @intCast(event.data.scalar.length);
    const style = event.data.scalar.style;

    // Quoted scalars are always strings.
    if (style == c.YAML_SINGLE_QUOTED_SCALAR_STYLE or style == c.YAML_DOUBLE_QUOTED_SCALAR_STYLE) {
        json_write_string(w, val, len);
        return;
    }

    // Plain scalars: apply type coercion.
    if (len == 0) {
        json_write_str(w, "null");
        return;
    }
    if (yaml_streq_ci(val, len, "null", 4) != 0 or (len == 1 and val[0] == '~')) {
        json_write_str(w, "null");
        return;
    }
    if (yaml_streq_ci(val, len, "true", 4) != 0 or yaml_streq_ci(val, len, "yes", 3) != 0 or yaml_streq_ci(val, len, "on", 2) != 0) {
        json_write_str(w, "true");
        return;
    }
    if (yaml_streq_ci(val, len, "false", 5) != 0 or yaml_streq_ci(val, len, "no", 2) != 0 or yaml_streq_ci(val, len, "off", 3) != 0) {
        json_write_str(w, "false");
        return;
    }
    if (yaml_is_number(val, len) != 0) {
        json_write(w, val, len);
        return;
    }

    // Default: string (also covers literal/folded block scalars).
    json_write_string(w, val, len);
}

// Write a YAML mapping as JSON object key-value pairs (without outer braces).
// Assumes MAPPING_START consumed. Returns number of pairs, or -1 on error.
fn json_write_yaml_mapping(w: *JSON_WRITER, yp: *c.yaml_parser_t) c_int {
    var event: c.yaml_event_t = undefined;
    var n: c_int = 0;

    while (true) {
        if (c.yaml_parser_parse(yp, &event) == 0)
            return -1;

        if (event.type == c.YAML_MAPPING_END_EVENT) {
            c.yaml_event_delete(&event);
            break;
        }

        if (event.type != c.YAML_SCALAR_EVENT) {
            c.yaml_event_delete(&event);
            return -1;
        }

        if (n > 0)
            json_write(w, ",", 1);

        // Write key.
        json_write(w, "\"", 1);
        json_write_escaped(w, @ptrCast(event.data.scalar.value), @intCast(event.data.scalar.length));
        json_write_str(w, "\":");
        c.yaml_event_delete(&event);

        // Write value (recursive).
        if (json_write_yaml_value(w, yp) < 0)
            return -1;

        n += 1;
    }
    return n;
}

// Write a YAML sequence as a JSON array.
// Assumes SEQUENCE_START consumed. Returns 0 on success, -1 on error.
fn json_write_yaml_sequence(w: *JSON_WRITER, yp: *c.yaml_parser_t) c_int {
    var event: c.yaml_event_t = undefined;
    var n: c_int = 0;

    json_write(w, "[", 1);

    while (true) {
        if (c.yaml_parser_parse(yp, &event) == 0)
            return -1;

        if (event.type == c.YAML_SEQUENCE_END_EVENT) {
            c.yaml_event_delete(&event);
            break;
        }

        if (n > 0)
            json_write(w, ",", 1);

        if (event.type == c.YAML_SCALAR_EVENT) {
            json_write_yaml_scalar(w, &event);
            c.yaml_event_delete(&event);
        } else if (event.type == c.YAML_MAPPING_START_EVENT) {
            c.yaml_event_delete(&event);
            json_write(w, "{", 1);
            if (json_write_yaml_mapping(w, yp) < 0)
                return -1;
            json_write(w, "}", 1);
        } else if (event.type == c.YAML_SEQUENCE_START_EVENT) {
            c.yaml_event_delete(&event);
            if (json_write_yaml_sequence(w, yp) < 0)
                return -1;
        } else {
            c.yaml_event_delete(&event);
            return -1;
        }

        n += 1;
    }

    json_write(w, "]", 1);
    return 0;
}

// Write the next YAML value (scalar, mapping, or sequence) as JSON.
// Returns 0 on success, -1 on error.
fn json_write_yaml_value(w: *JSON_WRITER, yp: *c.yaml_parser_t) c_int {
    var event: c.yaml_event_t = undefined;

    if (c.yaml_parser_parse(yp, &event) == 0)
        return -1;

    if (event.type == c.YAML_SCALAR_EVENT) {
        json_write_yaml_scalar(w, &event);
        c.yaml_event_delete(&event);
        return 0;
    }
    if (event.type == c.YAML_MAPPING_START_EVENT) {
        c.yaml_event_delete(&event);
        json_write(w, "{", 1);
        if (json_write_yaml_mapping(w, yp) < 0)
            return -1;
        json_write(w, "}", 1);
        return 0;
    }
    if (event.type == c.YAML_SEQUENCE_START_EVENT) {
        c.yaml_event_delete(&event);
        return json_write_yaml_sequence(w, yp);
    }
    if (event.type == c.YAML_ALIAS_EVENT) {
        c.yaml_event_delete(&event);
        json_write_str(w, "null");
        return 0;
    }

    c.yaml_event_delete(&event);
    return -1;
}

// Write parsed YAML frontmatter as JSON props using libyaml.
// Returns number of top-level props written.
fn json_write_yaml_props(w: *JSON_WRITER, text: [*]const u8, size: c.MD_SIZE) c_int {
    var yp: c.yaml_parser_t = undefined;
    var event: c.yaml_event_t = undefined;
    var n_written: c_int = 0;

    if (c.yaml_parser_initialize(&yp) == 0)
        return 0;

    c.yaml_parser_set_input_string(&yp, @ptrCast(text), size);

    // Consume STREAM_START.
    if (c.yaml_parser_parse(&yp, &event) == 0) {
        c.yaml_parser_delete(&yp);
        return n_written;
    }
    if (event.type != c.YAML_STREAM_START_EVENT) {
        c.yaml_event_delete(&event);
        c.yaml_parser_delete(&yp);
        return n_written;
    }
    c.yaml_event_delete(&event);

    // Consume DOCUMENT_START.
    if (c.yaml_parser_parse(&yp, &event) == 0) {
        c.yaml_parser_delete(&yp);
        return n_written;
    }
    if (event.type != c.YAML_DOCUMENT_START_EVENT) {
        c.yaml_event_delete(&event);
        c.yaml_parser_delete(&yp);
        return n_written;
    }
    c.yaml_event_delete(&event);

    // Expect top-level MAPPING_START.
    if (c.yaml_parser_parse(&yp, &event) == 0) {
        c.yaml_parser_delete(&yp);
        return n_written;
    }
    if (event.type != c.YAML_MAPPING_START_EVENT) {
        c.yaml_event_delete(&event);
        c.yaml_parser_delete(&yp);
        return n_written;
    }
    c.yaml_event_delete(&event);

    n_written = json_write_yaml_mapping(w, &yp);
    if (n_written < 0)
        n_written = 0;

    c.yaml_parser_delete(&yp);
    return n_written;
}

fn meta_serialize(w: *JSON_WRITER, ctx: *META_CTX) void {
    var has_prop: c_int = 0;

    json_write(w, "{", 1);

    // Write frontmatter YAML as top-level JSON props.
    if (ctx.fm_text != null and ctx.fm_size > 0) {
        has_prop = @intFromBool(json_write_yaml_props(w, ctx.fm_text.?, ctx.fm_size) > 0);
    }

    // Write headings array.
    if (has_prop != 0) json_write(w, ",", 1);
    json_write_str(w, "\"headings\":[");

    var i: c_int = 0;
    while (i < ctx.heading_count) : (i += 1) {
        var buf: [16]u8 = undefined;
        const idx: usize = @intCast(i);

        if (i > 0) json_write(w, ",", 1);

        json_write_str(w, "{\"level\":");
        _ = c.snprintf(&buf, buf.len, "%u", ctx.headings.?[idx].level);
        json_write_str(w, @ptrCast(&buf));

        json_write_str(w, ",\"text\":");
        if (ctx.headings.?[idx].text) |t| {
            json_write_string(w, t, ctx.headings.?[idx].text_size);
        } else {
            json_write_str(w, "\"\"");
        }

        json_write(w, "}", 1);
    }

    json_write_str(w, "]}\n");
}

fn meta_free(ctx: *META_CTX) void {
    if (ctx.fm_text) |p| c_allocator.free(p[0..ctx.fm_cap]);
    if (ctx.heading_buf) |p| c_allocator.free(p[0..ctx.heading_buf_cap]);

    if (ctx.headings) |hs| {
        var i: c_int = 0;
        while (i < ctx.heading_count) : (i += 1) {
            const idx: usize = @intCast(i);
            if (hs[idx].text) |t| c_allocator.free(t[0 .. hs[idx].text_size + 1]);
        }
        const n: usize = @intCast(ctx.heading_cap);
        c_allocator.free(hs[0..n]);
    }
}

// **************************************
// ***  Heal-before-render wrapper    ***
// **************************************

const MD4X_HEAL_BUF = struct {
    data: ?[*]u8,
    size: c_uint,
    cap: c_uint,
    err: c_int,
};

fn md4x_heal_buf_append(text: [*c]const u8, size: c_uint, userdata: ?*anyopaque) callconv(.c) void {
    const buf: *MD4X_HEAL_BUF = @ptrCast(@alignCast(userdata.?));
    if (buf.err != 0) return;
    if (buf.size + size > buf.cap) {
        const new_cap: c_uint = buf.cap + buf.cap / 2 + size + 256;
        if (buf.data) |old| {
            const p = c_allocator.realloc(old[0..buf.cap], new_cap) catch {
                buf.err = 1;
                return;
            };
            buf.data = p.ptr;
        } else {
            const p = c_allocator.alloc(u8, new_cap) catch {
                buf.err = 1;
                return;
            };
            buf.data = p.ptr;
        }
        buf.cap = new_cap;
    }
    @memcpy(buf.data.?[buf.size .. buf.size + size], @as([*]const u8, @ptrCast(text))[0..size]);
    buf.size += size;
}

fn md4x_heal_input(input: [*c]const c.MD_CHAR, input_size: c.MD_SIZE, buf: *MD4X_HEAL_BUF) c_int {
    buf.data = null;
    buf.size = 0;
    buf.cap = 0;
    buf.err = 0;
    const ret = c.md_heal(@ptrCast(input), input_size, md4x_heal_buf_append, buf);
    if (buf.err != 0) return -1;
    return ret;
}

fn heal_buf_free(buf: *MD4X_HEAL_BUF) void {
    if (buf.data) |d| c_allocator.free(d[0..buf.cap]);
}

// **************************************
// ***  Public API                    ***
// **************************************

export fn md_meta(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) callconv(.c) c_int {
    var input_ptr = input;
    var size = input_size;

    // Heal-before-render: run md_heal first, then render the healed output.
    if (renderer_flags & MD_META_FLAG_HEAL != 0) {
        var hbuf: MD4X_HEAL_BUF = undefined;
        if (md4x_heal_input(input, input_size, &hbuf) != 0) {
            heal_buf_free(&hbuf);
            return -1;
        }
        const ret = md_meta(@ptrCast(hbuf.data), hbuf.size, process_output, userdata, parser_flags, renderer_flags & ~MD_META_FLAG_HEAL);
        heal_buf_free(&hbuf);
        return ret;
    }

    var parser: c.MD_PARSER = std.mem.zeroes(c.MD_PARSER);
    parser.flags = parser_flags;
    parser.enter_block = meta_enter_block;
    parser.leave_block = meta_leave_block;
    parser.enter_span = meta_enter_span;
    parser.leave_span = meta_leave_span;
    parser.text = meta_text;
    parser.debug_log = if (renderer_flags & MD_META_FLAG_DEBUG != 0) meta_debug_log else null;

    var ctx: META_CTX = .{};

    // Skip UTF-8 BOM. (MD4X_USE_ASCII is never defined for this build.)
    if (renderer_flags & MD_META_FLAG_SKIP_UTF8_BOM != 0 and @sizeOf(c.MD_CHAR) == 1) {
        const bom = [_]u8{ 0xEF, 0xBB, 0xBF };
        if (size >= bom.len and std.mem.eql(u8, @as([*]const u8, @ptrCast(input_ptr))[0..bom.len], &bom)) {
            input_ptr += bom.len;
            size -= bom.len;
        }
    }

    const ret = c.md_parse(@ptrCast(input_ptr), size, &parser, @ptrCast(&ctx));

    if (ret != 0 or ctx.err != 0) {
        meta_free(&ctx);
        return -1;
    }

    // Serialize metadata to JSON via the output callback.
    var writer: JSON_WRITER = undefined;
    writer.process_output = process_output;
    writer.userdata = userdata;
    meta_serialize(&writer, &ctx);

    meta_free(&ctx);
    return 0;
}
