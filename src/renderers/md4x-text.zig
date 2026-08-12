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
// Zig port of src/renderers/md4x-text.c — byte-for-byte identical behavior.

const std = @import("std");

// MD_* types now come from the Zig-native
// abi module (replacing md4x.h / entity.h / md4x-heal.h); only genuinely
// external C headers stay in a @cImport, bound as `sys`.
const c = @import("abi");
// Sibling units are imported directly (one Zig module per artifact), not
// resolved through link-time C-ABI symbols. `abi` holds types only.
const md4x = @import("../md4x.zig");
const entity = @import("../entity.zig");
const heal = @import("md4x-heal.zig");
const sys = @cImport({
    @cInclude("stdio.h");
});

const c_allocator = std.heap.c_allocator;

// Renderer flags (mirrors md4x-text.h). Heal flag value is shared (0x0100).
const MD_TEXT_FLAG_DEBUG: c_uint = 0x0001;
const MD_TEXT_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_TEXT_FLAG_HEAL: c_uint = 0x0100;

const ProcessOutputFn = ?*const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void;

const MD_TEXT = struct {
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    flags: c_uint,
    image_nesting_level: c_int,
    quote_depth: c_int,
    list_depth: c_int,
    ol_counter: c_int,
    in_code_block: bool,
    need_newline: bool, // pending newline before next block
    need_indent: bool, // emit indent prefix on next code text
    li_opened: bool, // just opened a list item (bullet already printed)
    in_frontmatter: bool, // skip frontmatter content
};

// AppendFn mirrors the C `void (*fn_append)(MD_TEXT*, const MD_CHAR*, MD_SIZE)`.
const AppendFn = *const fn (*MD_TEXT, [*]const u8, c.MD_SIZE) void;

// *********************************************
// ***  Text rendering helper functions  ***
// *********************************************

fn render_verbatim(r: *MD_TEXT, text: [*]const u8, size: c.MD_SIZE) void {
    r.process_output.?(@ptrCast(text), size, r.userdata);
}

fn render_verbatim_lit(r: *MD_TEXT, comptime lit: []const u8) void {
    render_verbatim(r, lit.ptr, @intCast(lit.len));
}

fn render_indent(r: *MD_TEXT) void {
    var i: c_int = 0;
    while (i < r.quote_depth) : (i += 1) {
        render_verbatim_lit(r, "> ");
    }
    i = 0;
    while (i < r.list_depth) : (i += 1) {
        render_verbatim_lit(r, "  ");
    }
}

fn render_newline(r: *MD_TEXT) void {
    render_verbatim_lit(r, "\n");
}

fn hex_val(ch: u8) c_uint {
    if ('0' <= ch and ch <= '9')
        return ch - '0';
    if ('a' <= ch and ch <= 'f')
        return ch - 'a' + 10;
    if ('A' <= ch and ch <= 'F')
        return ch - 'A' + 10;
    return 0;
}

fn render_utf8_codepoint(r: *MD_TEXT, codepoint: c_uint, fn_append: AppendFn) void {
    const utf8_replacement_char = [_]u8{ 0xef, 0xbf, 0xbd };

    var utf8: [4]u8 = undefined;
    var n: usize = undefined;

    if (codepoint <= 0x7f) {
        n = 1;
        utf8[0] = @truncate(codepoint);
    } else if (codepoint <= 0x7ff) {
        n = 2;
        utf8[0] = @intCast(0xc0 | ((codepoint >> 6) & 0x1f));
        utf8[1] = @intCast(0x80 + ((codepoint >> 0) & 0x3f));
    } else if (codepoint <= 0xffff) {
        n = 3;
        utf8[0] = @intCast(0xe0 | ((codepoint >> 12) & 0xf));
        utf8[1] = @intCast(0x80 + ((codepoint >> 6) & 0x3f));
        utf8[2] = @intCast(0x80 + ((codepoint >> 0) & 0x3f));
    } else {
        n = 4;
        utf8[0] = @intCast(0xf0 | ((codepoint >> 18) & 0x7));
        utf8[1] = @intCast(0x80 + ((codepoint >> 12) & 0x3f));
        utf8[2] = @intCast(0x80 + ((codepoint >> 6) & 0x3f));
        utf8[3] = @intCast(0x80 + ((codepoint >> 0) & 0x3f));
    }

    if (0 < codepoint and codepoint <= 0x10ffff)
        fn_append(r, &utf8, @intCast(n))
    else
        fn_append(r, &utf8_replacement_char, 3);
}

fn render_entity(r: *MD_TEXT, text: [*]const u8, size: c.MD_SIZE, fn_append: AppendFn) void {
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

        render_utf8_codepoint(r, codepoint, fn_append);
        return;
    } else {
        const ent = entity.entity_lookup(@ptrCast(text), size);
        if (ent != null) {
            const cps = ent.?.codepoints;
            render_utf8_codepoint(r, cps[0], fn_append);
            if (cps[1] != 0)
                render_utf8_codepoint(r, cps[1], fn_append);
            return;
        }
    }

    fn_append(r, text, size);
}

fn render_attribute(r: *MD_TEXT, attr: *const c.Attribute, fn_append: AppendFn) void {
    const total = attr.size();
    var i: usize = 0;
    while (i < attr.substr_types.len and attr.substr_offsets[i] < total) : (i += 1) {
        const ttype = attr.substr_types[i];
        const off = attr.substr_offsets[i];
        const size = attr.substr_offsets[i + 1] - off;
        const text: [*]const u8 = attr.text.ptr + off;

        switch (ttype) {
            c.TextType.nullchar => render_utf8_codepoint(r, 0x0000, render_verbatim),
            c.TextType.entity => render_entity(r, text, size, fn_append),
            else => fn_append(r, text, size),
        }
    }
}

// **************************************
// ***  Text renderer implementation  ***
// **************************************

fn enter_block_callback(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_TEXT = @ptrCast(@alignCast(userdata.?));

    switch (detail.*) {
        .doc => {},

        .quote => {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
            r.quote_depth += 1;
        },

        .ul => {
            if (r.need_newline and r.list_depth == 0) {
                render_newline(r);
                r.need_newline = false;
            }
        },

        .ol => |*ol| {
            if (r.need_newline and r.list_depth == 0) {
                render_newline(r);
                r.need_newline = false;
            }
            r.ol_counter = @intCast(ol.start);
        },

        .li => |*li| {
            render_indent(r);
            if (li.is_task) {
                if (li.task_mark == 'x' or li.task_mark == 'X') {
                    render_verbatim_lit(r, "[x] ");
                } else {
                    render_verbatim_lit(r, "[ ] ");
                }
            } else {
                if (r.ol_counter > 0) {
                    var buf: [16]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}. ", .{r.ol_counter}) catch unreachable;
                    render_verbatim(r, s.ptr, @intCast(s.len));
                    r.ol_counter += 1;
                } else {
                    render_verbatim_lit(r, "- ");
                }
            }
            r.list_depth += 1;
            r.li_opened = true;
        },

        .hr => {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
            render_indent(r);
            render_verbatim_lit(r, "---");
            render_newline(r);
            r.need_newline = true;
        },

        .h => {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
            render_indent(r);
        },

        .code => {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
            r.in_code_block = true;
            r.need_indent = true;
        },

        .html => {},

        .p => {
            if (r.need_newline and !r.li_opened) {
                render_newline(r);
                r.need_newline = false;
            }
            if (!r.li_opened)
                render_indent(r);
            r.li_opened = false;
        },

        .table => {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
        },

        .thead => {},

        .tbody => {},

        .tr => {
            render_indent(r);
        },

        .th => {},

        .td => {},

        .frontmatter => {
            r.in_frontmatter = true;
        },

        .component => {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
        },

        .alert => |*det| {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
            r.quote_depth += 1;
            render_indent(r);
            if (det.type_name.text.len > 0)
                render_attribute(r, &det.type_name, render_verbatim);
            render_newline(r);
        },

        .template => {},
    }

    return 0;
}

fn leave_block_callback(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_TEXT = @ptrCast(@alignCast(userdata.?));

    switch (std.meta.activeTag(detail.*)) {
        .doc => {},

        .quote => {
            r.quote_depth -= 1;
        },

        .ul => {
            r.ol_counter = 0;
            r.need_newline = true;
        },

        .ol => {
            r.ol_counter = 0;
            r.need_newline = true;
        },

        .li => {
            r.list_depth -= 1;
            render_newline(r);
        },

        .hr => {},

        .h => {
            render_newline(r);
            r.need_newline = true;
        },

        .code => {
            r.in_code_block = false;
            r.need_newline = true;
        },

        .html => {},

        .p => {
            render_newline(r);
            r.need_newline = true;
        },

        .table => {
            r.need_newline = true;
        },

        .thead => {},

        .tbody => {},

        .tr => {
            render_newline(r);
        },

        .th => {
            render_verbatim_lit(r, "\t");
        },

        .td => {
            render_verbatim_lit(r, "\t");
        },

        .frontmatter => {
            r.in_frontmatter = false;
        },

        .component => {
            r.need_newline = true;
        },

        .alert => {
            r.quote_depth -= 1;
            r.need_newline = true;
        },

        .template => {},
    }

    return 0;
}

fn enter_span_callback(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_TEXT = @ptrCast(@alignCast(userdata.?));

    if (detail.* == .img)
        r.image_nesting_level += 1;

    return 0;
}

fn leave_span_callback(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_TEXT = @ptrCast(@alignCast(userdata.?));

    if (detail.* == .img)
        r.image_nesting_level -= 1;

    return 0;
}

fn text_callback(text_type: c.TextType, text_slice: []const c.MD_CHAR, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_TEXT = @ptrCast(@alignCast(userdata.?));
    const text: [*]const u8 = text_slice.ptr;
    const size: c.MD_SIZE = @intCast(text_slice.len);

    if (r.in_frontmatter)
        return 0;

    switch (text_type) {
        .nullchar => {
            render_utf8_codepoint(r, 0x0000, render_verbatim);
        },

        .br => {
            render_newline(r);
            render_indent(r);
        },

        .softbr => {
            if (r.image_nesting_level == 0) {
                render_newline(r);
                render_indent(r);
            } else {
                render_verbatim_lit(r, " ");
            }
        },

        .html => {},

        .entity => {
            render_entity(r, text, size, render_verbatim);
        },

        .code => {
            if (r.in_code_block) {
                if (size == 1 and text[0] == '\n') {
                    render_newline(r);
                    r.need_indent = true;
                } else {
                    if (r.need_indent) {
                        render_indent(r);
                        render_verbatim_lit(r, "  ");
                        r.need_indent = false;
                    }
                    render_verbatim(r, text, size);
                }
            } else {
                render_verbatim(r, text, size);
            }
        },

        else => {
            render_verbatim(r, text, size);
        },
    }

    return 0;
}

fn debug_log_callback(msg: []const u8, userdata: ?*anyopaque) void {
    const r: *MD_TEXT = @ptrCast(@alignCast(userdata.?));
    if (r.flags & MD_TEXT_FLAG_DEBUG != 0)
        _ = sys.fprintf(sys.stderr, "MD4X: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
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

fn md4x_heal_buf_append(text: [*c]const u8, size: c_uint, userdata: ?*anyopaque) void {
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

// Run md_heal and return the healed buffer. Caller must free buf.data.
// Returns 0 on success, -1 on error.
fn md4x_heal_input(input: [*c]const c.MD_CHAR, input_size: c.MD_SIZE, buf: *MD4X_HEAL_BUF) c_int {
    buf.data = null;
    buf.size = 0;
    buf.cap = 0;
    buf.err = 0;
    const ret = heal.md_heal(@ptrCast(input), input_size, md4x_heal_buf_append, buf);
    if (buf.err != 0) return -1;
    return ret;
}

fn heal_buf_free(buf: *MD4X_HEAL_BUF) void {
    if (buf.data) |d| {
        // The C version uses free(hbuf.data); the underlying allocation came from
        // realloc/alloc with the c_allocator, so free it as a sized slice.
        c_allocator.free(d[0..buf.cap]);
    }
}

pub fn md_text(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int {
    var input_ptr = input;
    var size = input_size;

    // Heal-before-render: run md_heal first, then render the healed output.
    if (renderer_flags & MD_TEXT_FLAG_HEAL != 0) {
        var hbuf: MD4X_HEAL_BUF = undefined;
        if (md4x_heal_input(input, input_size, &hbuf) != 0) {
            heal_buf_free(&hbuf);
            return -1;
        }
        const ret = md_text(@ptrCast(hbuf.data), hbuf.size, process_output, userdata, parser_flags, renderer_flags & ~MD_TEXT_FLAG_HEAL);
        heal_buf_free(&hbuf);
        return ret;
    }

    const parser: c.Parser = .{
        .flags = parser_flags,
        .enter_block = enter_block_callback,
        .leave_block = leave_block_callback,
        .enter_span = enter_span_callback,
        .leave_span = leave_span_callback,
        .text = text_callback,
        .debug_log = debug_log_callback,
    };

    var render: MD_TEXT = std.mem.zeroes(MD_TEXT);
    render.process_output = process_output;
    render.userdata = userdata;
    render.flags = renderer_flags;

    // Consider skipping UTF-8 byte order mark (BOM).
    if (renderer_flags & MD_TEXT_FLAG_SKIP_UTF8_BOM != 0 and @sizeOf(c.MD_CHAR) == 1) {
        const bom = [_]u8{ 0xef, 0xbb, 0xbf };
        if (size >= bom.len and std.mem.eql(u8, @as([*]const u8, @ptrCast(input_ptr))[0..bom.len], &bom)) {
            input_ptr += bom.len;
            size -= bom.len;
        }
    }

    return md4x.md_parse(@ptrCast(input_ptr), size, &parser, @ptrCast(&render));
}
