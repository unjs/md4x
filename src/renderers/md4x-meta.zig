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
    // The JSON writer and YAML-to-JSON conversion (which use libyaml) now live in
    // the shared md4x-json.zig module, so this renderer no longer needs <yaml.h>.
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
// The streaming JSON writer and the libyaml-backed YAML-to-JSON conversion live
// in the shared md4x-json.zig module (previously reimplemented inline here).
// Local aliases preserve the original call-site names used below. Note that the
// meta renderer's `json_write_str` historically took a NUL-terminated pointer,
// which maps to the shared module's `json_write_strz`.

const json = @import("md4x-json.zig");

const JSON_WRITER = json.JsonWriter;
const json_write = json.json_write;
const json_write_str = json.json_write_strz;
const json_write_string = json.json_write_string;
const json_write_yaml_props = json.json_write_yaml_props;

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
