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
// Zig port of src/renderers/md4x-ansi.c — byte-for-byte identical behavior.

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

// Shared component property parser, from the shared md4x-props.zig module
// (previously reimplemented inline here). The ANSI renderer only consumes the
// string props (to resolve ::alert{type="..."} colors). Local aliases preserve
// the original call-site names used below.

const props = @import("md4x-props.zig");

const MD_PARSED_PROPS = props.MD_PARSED_PROPS;
const md_parse_props = props.md_parse_props;

const c_allocator = std.heap.c_allocator;

// Renderer flags (mirrors md4x-ansi.h). Heal flag value is shared (0x0100).
const MD_ANSI_FLAG_DEBUG: c_uint = 0x0001;
const MD_ANSI_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_ANSI_FLAG_NO_COLOR: c_uint = 0x0004;
const MD_ANSI_FLAG_CODE_META: c_uint = 0x0008;
const MD_ANSI_FLAG_SHOW_URLS: c_uint = 0x0010;
const MD_ANSI_FLAG_SHOW_FRONTMATTER: c_uint = 0x0020;
const MD_ANSI_FLAG_HEAL: c_uint = 0x0100;

// ANSI escape sequences
const ANSI_RESET = "\x1b[0m";
const ANSI_BOLD = "\x1b[1m";
const ANSI_BOLD_OFF = "\x1b[22m";
const ANSI_DIM = "\x1b[2m";
const ANSI_DIM_OFF = "\x1b[22m";
const ANSI_ITALIC = "\x1b[3m";
const ANSI_ITALIC_OFF = "\x1b[23m";
const ANSI_UNDERLINE = "\x1b[4m";
const ANSI_UNDERLINE_OFF = "\x1b[24m";
const ANSI_STRIKETHROUGH = "\x1b[9m";
const ANSI_STRIKE_OFF = "\x1b[29m";

const ANSI_COLOR_BLUE = "\x1b[34m";
const ANSI_COLOR_CYAN = "\x1b[36m";
const ANSI_COLOR_MAGENTA = "\x1b[35m";
const ANSI_COLOR_YELLOW = "\x1b[33m";
const ANSI_COLOR_GREEN = "\x1b[32m";
const ANSI_COLOR_RED = "\x1b[31m";
const ANSI_COLOR_DEFAULT = "\x1b[39m";

// Compound styles
const ANSI_HEADING = "\x1b[1;35m";
const ANSI_LINK = "\x1b[4;34m";
const ANSI_LINK_URL = "\x1b[2;34m";

// OSC 8 hyperlinks: \033]8;;URL\033\\ to open, \033]8;;\033\\ to close
const ANSI_HYPERLINK_OPEN = "\x1b]8;;";
const ANSI_HYPERLINK_SEP = "\x1b\\";
const ANSI_HYPERLINK_CLOSE = "\x1b]8;;\x1b\\";

// Box-drawing characters (UTF-8)
const HORIZONTAL_RULE = "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" ++
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" ++
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" ++
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" ++
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80";

// Blockquote bar (UTF-8: vertical bar U+2502)
const QUOTE_BAR = "\xe2\x94\x82";

// Alert bar (UTF-8: left half block U+258C ▌)
const ALERT_BAR = "\xe2\x96\x8c";

const ProcessOutputFn = ?*const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void;

// Code block metadata entry (heap-allocated when MD_ANSI_FLAG_CODE_META is set)
const MD_ANSI_CODE_META = struct {
    start: c.MD_SIZE, // Byte offset: start of code block (before ANSI_DIM)
    end: c.MD_SIZE, // Byte offset: end of code block (after ANSI_DIM_OFF)
    lang: [64]u8,
    lang_size: c.MD_SIZE,
    filename: [256]u8,
    filename_size: c.MD_SIZE,
    highlights: ?[*]c_uint,
    highlight_count: c_uint,
    prefix: [256]u8, // Line indent prefix (captured from render_indent + "  ")
    prefix_size: c.MD_SIZE,
};

const MD_ANSI = struct {
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    flags: c_uint,
    image_nesting_level: c_int,
    quote_depth: c_int,
    list_depth: c_int,
    ol_counter: c_int,
    in_code_block: c_int,
    need_newline: c_int, // pending newline before next block
    need_indent: c_int, // emit indent prefix on next code text
    li_opened: c_int, // just opened a list item (bullet already printed)
    in_alert: c_int, // inside an alert block
    alert_color: ?[*:0]const u8, // ANSI color escape for current alert bar
    component_nesting: c_int, // block component nesting depth
    in_comp_frontmatter: c_int, // inside component frontmatter (suppress output)

    // Code block metadata tracking (only active when MD_ANSI_FLAG_CODE_META is set)
    output_offset: c.MD_SIZE,
    code_blocks: ?[*]MD_ANSI_CODE_META,
    n_code_blocks: c_int,
    code_blocks_cap: c_int,
};

// AppendFn mirrors the C `void (*fn_append)(MD_ANSI*, const MD_CHAR*, MD_SIZE)`.
const AppendFn = *const fn (*MD_ANSI, [*]const u8, c.MD_SIZE) void;

// *********************************************
// ***  ANSI rendering helper functions  ***
// *********************************************

fn render_verbatim(r: *MD_ANSI, text: [*]const u8, size: c.MD_SIZE) void {
    r.process_output.?(@ptrCast(text), size, r.userdata);
    if (r.flags & MD_ANSI_FLAG_CODE_META != 0)
        r.output_offset += size;
}

fn render_verbatim_lit(r: *MD_ANSI, comptime lit: []const u8) void {
    render_verbatim(r, lit.ptr, @intCast(lit.len));
}

fn render_ansi(r: *MD_ANSI, comptime code: []const u8) void {
    if (r.flags & MD_ANSI_FLAG_NO_COLOR == 0)
        render_verbatim_lit(r, code);
}

// Runtime-variant of render_ansi for the alert_color pointer (sentinel string).
fn render_ansi_ptr(r: *MD_ANSI, code: [*:0]const u8) void {
    if (r.flags & MD_ANSI_FLAG_NO_COLOR == 0) {
        const slice = std.mem.span(code);
        render_verbatim(r, slice.ptr, @intCast(slice.len));
    }
}

fn render_indent(r: *MD_ANSI) void {
    var i: c_int = 0;
    while (i < r.quote_depth) : (i += 1) {
        render_ansi(r, ANSI_DIM);
        render_verbatim_lit(r, "  " ++ QUOTE_BAR ++ " ");
        render_ansi(r, ANSI_DIM_OFF);
    }
    if (r.in_alert != 0 and r.alert_color != null) {
        render_ansi_ptr(r, r.alert_color.?);
        render_verbatim_lit(r, ALERT_BAR ++ " ");
        render_ansi(r, ANSI_COLOR_DEFAULT);
    }
    i = 0;
    while (i < r.list_depth) : (i += 1) {
        render_verbatim_lit(r, "  ");
    }
}

fn render_newline(r: *MD_ANSI) void {
    render_verbatim_lit(r, "\n");
}

// Render a blank separator line with alert bar prefix when inside an alert.
fn render_separator(r: *MD_ANSI) void {
    render_newline(r);
    if (r.in_alert != 0 and r.alert_color != null) {
        render_ansi_ptr(r, r.alert_color.?);
        render_verbatim_lit(r, ALERT_BAR);
        render_ansi(r, ANSI_COLOR_DEFAULT);
        render_newline(r);
    }
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

fn render_utf8_codepoint(r: *MD_ANSI, codepoint: c_uint, fn_append: AppendFn) void {
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

fn render_entity(r: *MD_ANSI, text: [*]const u8, size: c.MD_SIZE, fn_append: AppendFn) void {
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

fn render_attribute(r: *MD_ANSI, attr: *const c.MD_ATTRIBUTE, fn_append: AppendFn) void {
    var i: usize = 0;
    while (attr.substr_offsets[i] < attr.size) : (i += 1) {
        const ttype = attr.substr_types[i];
        const off = attr.substr_offsets[i];
        const size = attr.substr_offsets[i + 1] - off;
        const text: [*]const u8 = @ptrCast(attr.text + off);

        switch (ttype) {
            c.MD_TEXT_NULLCHAR => render_utf8_codepoint(r, 0x0000, render_verbatim),
            c.MD_TEXT_ENTITY => render_entity(r, text, size, fn_append),
            else => fn_append(r, text, size),
        }
    }
}

// Case-insensitive compare for short ASCII strings.
fn ci_eq(a: [*c]const c.MD_CHAR, a_size: c.MD_SIZE, b: []const u8) bool {
    const ap: [*]const u8 = @ptrCast(a);
    var i: c.MD_SIZE = 0;
    while (i < a_size and i < b.len and b[i] != 0) : (i += 1) {
        var ca = ap[i];
        var cb = b[i];
        if (ca >= 'A' and ca <= 'Z') ca += 32;
        if (cb >= 'A' and cb <= 'Z') cb += 32;
        if (ca != cb) return false;
    }
    return (i == a_size and i == b.len);
}

// Map alert/component type name to ANSI color, or null if not an alert name.
fn alert_type_color(name: [*c]const c.MD_CHAR, size: c.MD_SIZE) ?[*:0]const u8 {
    if (size == 0 or name == null)
        return null;

    if (ci_eq(name, size, "note")) return ANSI_COLOR_BLUE;
    if (ci_eq(name, size, "info")) return ANSI_COLOR_BLUE;
    if (ci_eq(name, size, "tip")) return ANSI_COLOR_GREEN;
    if (ci_eq(name, size, "success")) return ANSI_COLOR_GREEN;
    if (ci_eq(name, size, "important")) return ANSI_COLOR_MAGENTA;
    if (ci_eq(name, size, "warning")) return ANSI_COLOR_YELLOW;
    if (ci_eq(name, size, "caution")) return ANSI_COLOR_RED;
    if (ci_eq(name, size, "danger")) return ANSI_COLOR_RED;

    return null;
}

// *****************************************
// ***  Code block metadata tracking     ***
// *****************************************

fn ansi_code_meta_push(r: *MD_ANSI) ?*MD_ANSI_CODE_META {
    if (r.code_blocks == null) {
        const mem = c_allocator.alloc(MD_ANSI_CODE_META, 8) catch return null;
        r.code_blocks = mem.ptr;
        r.code_blocks_cap = 8;
    } else if (r.n_code_blocks >= r.code_blocks_cap) {
        const new_cap: usize = @intCast(r.code_blocks_cap * 2);
        const old = r.code_blocks.?[0..@intCast(r.code_blocks_cap)];
        const mem = c_allocator.realloc(old, new_cap) catch return null;
        r.code_blocks = mem.ptr;
        r.code_blocks_cap = @intCast(new_cap);
    }
    const slot = &r.code_blocks.?[@intCast(r.n_code_blocks)];
    @memset(std.mem.asBytes(slot), 0);
    return slot;
}

fn ansi_code_meta_cleanup(r: *MD_ANSI) void {
    if (r.code_blocks) |blocks| {
        const count: usize = @intCast(r.n_code_blocks + (if (r.in_code_block != 0) @as(c_int, 1) else 0));
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (blocks[i].highlights) |h|
                c_allocator.free(h[0..blocks[i].highlight_count]);
        }
        c_allocator.free(blocks[0..@intCast(r.code_blocks_cap)]);
    }
}

// Capture buffer for redirecting output to capture the indent prefix.
const ANSI_CAPTURE_BUF = struct {
    buf: [*]u8,
    size: c.MD_SIZE,
    cap: c.MD_SIZE,
};

fn ansi_capture_append(text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) void {
    const cap: *ANSI_CAPTURE_BUF = @ptrCast(@alignCast(userdata.?));
    const n: c.MD_SIZE = if (cap.size + size <= cap.cap) size else (cap.cap - cap.size);
    if (n > 0) {
        @memcpy(cap.buf[cap.size .. cap.size + n], @as([*]const u8, @ptrCast(text))[0..n]);
        cap.size += n;
    }
}

fn ansi_emit_json_str(out: ProcessOutputFn, ud: ?*anyopaque, str: [*]const u8, size: c.MD_SIZE) void {
    var i: c.MD_SIZE = 0;
    var beg: c.MD_SIZE = 0;
    out.?("\"", 1, ud);
    while (i < size) : (i += 1) {
        const ch: u8 = str[i];
        if (ch == '"' or ch == '\\' or ch < 0x20) {
            if (i > beg)
                out.?(@ptrCast(str + beg), i - beg, ud);
            if (ch == '"' or ch == '\\') {
                out.?("\\", 1, ud);
                out.?(@ptrCast(str + i), 1, ud);
            } else if (ch == '\n') {
                out.?("\\n", 2, ud);
            } else if (ch == '\r') {
                out.?("\\r", 2, ud);
            } else if (ch == '\t') {
                out.?("\\t", 2, ud);
            } else if (ch == 0x1b) {
                out.?("\\u001b", 6, ud);
            } else {
                const hex = "0123456789abcdef";
                const esc = [_]u8{ '\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 0xf] };
                out.?(&esc, 6, ud);
            }
            beg = i + 1;
        }
    }
    if (i > beg)
        out.?(@ptrCast(str + beg), i - beg, ud);
    out.?("\"", 1, ud);
}

fn render_ansi_code_meta_json(r: *MD_ANSI) void {
    const out = r.process_output;
    const ud = r.userdata;
    var buf: [64]u8 = undefined;

    out.?(&[_]u8{0}, 1, ud);
    out.?("[", 1, ud);
    var i: c_int = 0;
    while (i < r.n_code_blocks) : (i += 1) {
        const m = &r.code_blocks.?[@intCast(i)];
        if (i > 0) out.?(",", 1, ud);

        var s = std.fmt.bufPrint(&buf, "{{\"s\":{d},\"e\":{d}", .{ @as(c_uint, @intCast(m.start)), @as(c_uint, @intCast(m.end)) }) catch unreachable;
        out.?(s.ptr, @intCast(s.len), ud);

        if (m.lang_size > 0) {
            out.?(",\"l\":", 5, ud);
            ansi_emit_json_str(out, ud, &m.lang, m.lang_size);
        }
        if (m.filename_size > 0) {
            out.?(",\"f\":", 5, ud);
            ansi_emit_json_str(out, ud, &m.filename, m.filename_size);
        }
        if (m.highlight_count > 0) {
            out.?(",\"h\":[", 6, ud);
            var j: c_uint = 0;
            while (j < m.highlight_count) : (j += 1) {
                if (j > 0) out.?(",", 1, ud);
                s = std.fmt.bufPrint(&buf, "{d}", .{m.highlights.?[j]}) catch unreachable;
                out.?(s.ptr, @intCast(s.len), ud);
            }
            out.?("]", 1, ud);
        }
        if (m.prefix_size > 0) {
            out.?(",\"i\":", 5, ud);
            ansi_emit_json_str(out, ud, &m.prefix, m.prefix_size);
        }
        out.?("}", 1, ud);
    }
    out.?("]", 1, ud);
}

// **************************************
// ***  ANSI renderer implementation  ***
// **************************************

fn enter_block_callback(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));

    switch (block_type) {
        c.MD_BLOCK_DOC => {},

        c.MD_BLOCK_QUOTE => {
            if (r.need_newline != 0) {
                render_separator(r);
                r.need_newline = 0;
            }
            r.quote_depth += 1;
        },

        c.MD_BLOCK_UL => {
            if (r.need_newline != 0 and r.list_depth == 0) {
                render_separator(r);
                r.need_newline = 0;
            }
        },

        c.MD_BLOCK_OL => {
            if (r.need_newline != 0 and r.list_depth == 0) {
                render_separator(r);
                r.need_newline = 0;
            }
            const ol: *const c.MD_BLOCK_OL_DETAIL = @ptrCast(@alignCast(detail.?));
            r.ol_counter = @intCast(ol.start);
        },

        c.MD_BLOCK_LI => {
            const li: *const c.MD_BLOCK_LI_DETAIL = @ptrCast(@alignCast(detail.?));
            render_indent(r);
            if (li.is_task != 0) {
                if (li.task_mark == 'x' or li.task_mark == 'X') {
                    render_ansi(r, ANSI_COLOR_GREEN);
                    render_verbatim_lit(r, "[x] ");
                    render_ansi(r, ANSI_COLOR_DEFAULT);
                } else {
                    render_verbatim_lit(r, "[ ] ");
                }
            } else {
                // Check parent: is this inside OL or UL? We track via ol_counter.
                if (r.ol_counter > 0) {
                    var buf: [16]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}. ", .{r.ol_counter}) catch unreachable;
                    render_ansi(r, ANSI_DIM);
                    render_verbatim(r, s.ptr, @intCast(s.len));
                    render_ansi(r, ANSI_DIM_OFF);
                    r.ol_counter += 1;
                } else {
                    render_ansi(r, ANSI_DIM);
                    render_verbatim_lit(r, "* ");
                    render_ansi(r, ANSI_DIM_OFF);
                }
            }
            r.list_depth += 1;
            r.li_opened = 1;
        },

        c.MD_BLOCK_HR => {
            if (r.need_newline != 0) {
                render_separator(r);
                r.need_newline = 0;
            }
            render_indent(r);
            render_ansi(r, ANSI_DIM);
            render_verbatim_lit(r, HORIZONTAL_RULE);
            render_ansi(r, ANSI_DIM_OFF);
            render_newline(r);
            r.need_newline = 1;
        },

        c.MD_BLOCK_H => {
            if (r.need_newline != 0) {
                render_separator(r);
                r.need_newline = 0;
            }
            render_indent(r);
            render_ansi(r, ANSI_HEADING);
        },

        c.MD_BLOCK_CODE => {
            if (r.need_newline != 0) {
                render_separator(r);
                r.need_newline = 0;
            }
            r.in_code_block = 1;
            r.need_indent = 1;
            if (r.flags & MD_ANSI_FLAG_CODE_META != 0) {
                const meta_opt = ansi_code_meta_push(r);
                if (meta_opt) |meta| {
                    const det: *const c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(detail.?));
                    meta.start = r.output_offset;
                    if (det.lang.text != null and det.lang.size > 0) {
                        const sz: c.MD_SIZE = if (det.lang.size < meta.lang.len) det.lang.size else meta.lang.len - 1;
                        @memcpy(meta.lang[0..sz], @as([*]const u8, @ptrCast(det.lang.text))[0..sz]);
                        meta.lang_size = sz;
                    }
                    if (det.filename.text != null and det.filename.size > 0) {
                        const sz: c.MD_SIZE = if (det.filename.size < meta.filename.len) det.filename.size else meta.filename.len - 1;
                        @memcpy(meta.filename[0..sz], @as([*]const u8, @ptrCast(det.filename.text))[0..sz]);
                        meta.filename_size = sz;
                    }
                    if (det.highlights != null and det.highlight_count > 0) {
                        const h = c_allocator.alloc(c_uint, det.highlight_count) catch null;
                        if (h) |hl| {
                            @memcpy(hl, det.highlights[0..det.highlight_count]);
                            meta.highlights = hl.ptr;
                            meta.highlight_count = det.highlight_count;
                        }
                    }
                    // Capture the indent prefix by temporarily redirecting output.
                    {
                        var pfx_buf: [256]u8 = undefined;
                        var cap = ANSI_CAPTURE_BUF{ .buf = &pfx_buf, .size = 0, .cap = pfx_buf.len };
                        const saved_out = r.process_output;
                        const saved_ud = r.userdata;
                        r.process_output = ansi_capture_append;
                        r.userdata = &cap;
                        render_indent(r);
                        render_verbatim_lit(r, "  ");
                        r.process_output = saved_out;
                        r.userdata = saved_ud;
                        if (cap.size <= meta.prefix.len) {
                            @memcpy(meta.prefix[0..cap.size], pfx_buf[0..cap.size]);
                            meta.prefix_size = cap.size;
                        }
                    }
                }
            }
            render_ansi(r, ANSI_DIM);
        },

        c.MD_BLOCK_HTML => {},

        c.MD_BLOCK_P => {
            if (r.need_newline != 0 and r.li_opened == 0) {
                render_separator(r);
                r.need_newline = 0;
            }
            if (r.li_opened == 0)
                render_indent(r);
            r.li_opened = 0;
        },

        c.MD_BLOCK_TABLE => {
            if (r.need_newline != 0) {
                render_separator(r);
                r.need_newline = 0;
            }
        },

        c.MD_BLOCK_THEAD => {},

        c.MD_BLOCK_TBODY => {},

        c.MD_BLOCK_TR => {
            render_indent(r);
        },

        c.MD_BLOCK_TH => {
            render_ansi(r, ANSI_BOLD);
        },

        c.MD_BLOCK_TD => {},

        c.MD_BLOCK_FRONTMATTER => {
            if (r.component_nesting > 0) {
                r.in_comp_frontmatter = 1;
            } else if (r.flags & MD_ANSI_FLAG_SHOW_FRONTMATTER != 0) {
                render_ansi(r, ANSI_DIM);
            } else {
                r.in_comp_frontmatter = 1;
            }
        },

        c.MD_BLOCK_COMPONENT => {
            const comp: *const c.MD_BLOCK_COMPONENT_DETAIL = @ptrCast(@alignCast(detail.?));
            var color = alert_type_color(comp.tag_name.text, comp.tag_name.size);
            var title = comp.tag_name.text;
            var title_size = comp.tag_name.size;

            // Use explicit title if provided (e.g. :::danger STOP).
            if (comp.title != null and comp.title_size > 0) {
                title = comp.title;
                title_size = comp.title_size;
            }

            // For ::alert{type="..."}, resolve color from the type prop.
            if (color == null and ci_eq(comp.tag_name.text, comp.tag_name.size, "alert")) {
                var parsed: MD_PARSED_PROPS = undefined;
                md_parse_props(comp.raw_props, comp.raw_props_size, &parsed);
                var pi: c_int = 0;
                while (pi < parsed.n_props) : (pi += 1) {
                    const prop = &parsed.props[@intCast(pi)];
                    if (prop.type == .string and ci_eq(prop.key, prop.key_size, "type")) {
                        color = alert_type_color(prop.value, prop.value_size);
                        if (comp.title == null or comp.title_size == 0) {
                            title = prop.value;
                            title_size = prop.value_size;
                        }
                        break;
                    }
                }
                if (color == null) color = ANSI_COLOR_YELLOW;
            }

            if (r.need_newline != 0) {
                render_separator(r);
                r.need_newline = 0;
            }
            r.component_nesting += 1;
            if (color != null) {
                // Render as alert-style box
                r.alert_color = color;
                render_indent(r);
                render_ansi_ptr(r, color.?);
                render_verbatim_lit(r, ALERT_BAR ++ " ");
                render_ansi(r, ANSI_BOLD);
                render_verbatim(r, @ptrCast(title), title_size);
                render_ansi(r, ANSI_BOLD_OFF);
                render_ansi(r, ANSI_COLOR_DEFAULT);
                render_newline(r);
                r.in_alert = 1;
            } else {
                render_ansi(r, ANSI_COLOR_CYAN);
            }
        },

        c.MD_BLOCK_ALERT => {
            const det: *const c.MD_BLOCK_ALERT_DETAIL = @ptrCast(@alignCast(detail.?));
            var color = alert_type_color(det.type_name.text, det.type_name.size);
            if (color == null) color = ANSI_COLOR_YELLOW;
            if (r.need_newline != 0) {
                render_separator(r);
                r.need_newline = 0;
            }
            r.alert_color = color;
            // Render title line: ▌ TYPE
            render_indent(r);
            render_ansi_ptr(r, color.?);
            render_verbatim_lit(r, ALERT_BAR ++ " ");
            render_ansi(r, ANSI_BOLD);
            if (det.type_name.text != null and det.type_name.size > 0)
                render_verbatim(r, @ptrCast(det.type_name.text), det.type_name.size);
            render_ansi(r, ANSI_BOLD_OFF);
            render_ansi(r, ANSI_COLOR_DEFAULT);
            render_newline(r);
            // Set in_alert after title so render_indent doesn't double-bar
            r.in_alert = 1;
        },

        c.MD_BLOCK_TEMPLATE => {
            // Transparent — content renders normally within parent component.
        },

        else => {},
    }

    return 0;
}

fn leave_block_callback(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));

    _ = detail;

    switch (block_type) {
        c.MD_BLOCK_DOC => {},

        c.MD_BLOCK_QUOTE => {
            r.quote_depth -= 1;
        },

        c.MD_BLOCK_UL => {
            r.ol_counter = 0;
            r.li_opened = 0;
            r.need_newline = 1;
        },

        c.MD_BLOCK_OL => {
            r.ol_counter = 0;
            r.li_opened = 0;
            r.need_newline = 1;
        },

        c.MD_BLOCK_LI => {
            r.list_depth -= 1;
            render_newline(r);
        },

        c.MD_BLOCK_HR => {},

        c.MD_BLOCK_H => {
            render_ansi(r, ANSI_RESET);
            render_newline(r);
            r.need_newline = 1;
        },

        c.MD_BLOCK_CODE => {
            render_ansi(r, ANSI_DIM_OFF);
            if (r.flags & MD_ANSI_FLAG_CODE_META != 0 and r.n_code_blocks < r.code_blocks_cap) {
                r.code_blocks.?[@intCast(r.n_code_blocks)].end = r.output_offset;
                r.n_code_blocks += 1;
            }
            r.in_code_block = 0;
            r.need_newline = 1;
        },

        c.MD_BLOCK_HTML => {},

        c.MD_BLOCK_P => {
            render_newline(r);
            r.need_newline = 1;
        },

        c.MD_BLOCK_TABLE => {
            r.need_newline = 1;
        },

        c.MD_BLOCK_THEAD => {
            render_indent(r);
            render_ansi(r, ANSI_DIM);
            render_verbatim_lit(r, HORIZONTAL_RULE);
            render_ansi(r, ANSI_DIM_OFF);
            render_newline(r);
        },

        c.MD_BLOCK_TBODY => {},

        c.MD_BLOCK_TR => {
            render_newline(r);
        },

        c.MD_BLOCK_TH => {
            render_ansi(r, ANSI_BOLD_OFF);
            render_verbatim_lit(r, "\t");
        },

        c.MD_BLOCK_TD => {
            render_verbatim_lit(r, "\t");
        },

        c.MD_BLOCK_FRONTMATTER => {
            if (r.in_comp_frontmatter != 0) {
                r.in_comp_frontmatter = 0;
            } else {
                render_ansi(r, ANSI_DIM_OFF);
                r.need_newline = 1;
            }
        },

        c.MD_BLOCK_COMPONENT => {
            r.component_nesting -= 1;
            if (r.in_alert != 0) {
                r.in_alert = 0;
                r.alert_color = null;
            } else {
                render_ansi(r, ANSI_COLOR_DEFAULT);
            }
            r.need_newline = 1;
        },

        c.MD_BLOCK_ALERT => {
            r.in_alert = 0;
            r.alert_color = null;
            r.need_newline = 1;
        },

        c.MD_BLOCK_TEMPLATE => {
            // Transparent — no output needed.
        },

        else => {},
    }

    return 0;
}

fn enter_span_callback(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));

    if (span_type == c.MD_SPAN_IMG)
        r.image_nesting_level += 1;

    if (r.image_nesting_level > 0 and span_type != c.MD_SPAN_IMG)
        return 0;

    switch (span_type) {
        c.MD_SPAN_EM => render_ansi(r, ANSI_ITALIC),
        c.MD_SPAN_STRONG => render_ansi(r, ANSI_BOLD),
        c.MD_SPAN_U => render_ansi(r, ANSI_UNDERLINE),
        c.MD_SPAN_A => {
            const a: *const c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(detail.?));
            // OSC 8 hyperlink: makes text clickable in supported terminals
            if (r.flags & MD_ANSI_FLAG_NO_COLOR == 0 and a.href.size > 0) {
                render_verbatim_lit(r, ANSI_HYPERLINK_OPEN);
                render_attribute(r, &a.href, render_verbatim);
                render_verbatim_lit(r, ANSI_HYPERLINK_SEP);
            }
            render_ansi(r, ANSI_LINK);
        },
        c.MD_SPAN_IMG => {
            // Images are suppressed — alt text is silently skipped via image_nesting_level
        },
        c.MD_SPAN_CODE => render_ansi(r, ANSI_COLOR_CYAN),
        c.MD_SPAN_DEL => render_ansi(r, ANSI_STRIKETHROUGH),
        c.MD_SPAN_LATEXMATH => render_ansi(r, ANSI_COLOR_YELLOW),
        c.MD_SPAN_LATEXMATH_DISPLAY => render_ansi(r, ANSI_COLOR_YELLOW),
        c.MD_SPAN_WIKILINK => render_ansi(r, ANSI_LINK),
        c.MD_SPAN_COMPONENT => render_ansi(r, ANSI_COLOR_CYAN),
        c.MD_SPAN_SPAN => {}, // Transparent: no special styling
        else => {},
    }

    return 0;
}

fn leave_span_callback(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));

    if (span_type == c.MD_SPAN_IMG)
        r.image_nesting_level -= 1;

    if (r.image_nesting_level > 0)
        return 0;

    switch (span_type) {
        c.MD_SPAN_EM => render_ansi(r, ANSI_ITALIC_OFF),
        c.MD_SPAN_STRONG => render_ansi(r, ANSI_BOLD_OFF),
        c.MD_SPAN_U => render_ansi(r, ANSI_UNDERLINE_OFF),
        c.MD_SPAN_A => {
            const a: *const c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(detail.?));
            render_ansi(r, ANSI_RESET);
            // Close OSC 8 hyperlink
            if (r.flags & MD_ANSI_FLAG_NO_COLOR == 0 and a.href.size > 0)
                render_verbatim_lit(r, ANSI_HYPERLINK_CLOSE);
            // Show URL as dim fallback for terminals without OSC 8
            if (r.flags & MD_ANSI_FLAG_SHOW_URLS != 0 and a.href.size > 0 and a.is_autolink == 0) {
                render_ansi(r, ANSI_LINK_URL);
                render_verbatim_lit(r, " (");
                render_attribute(r, &a.href, render_verbatim);
                render_verbatim_lit(r, ")");
                render_ansi(r, ANSI_RESET);
            }
        },
        c.MD_SPAN_IMG => {},
        c.MD_SPAN_CODE => render_ansi(r, ANSI_COLOR_DEFAULT),
        c.MD_SPAN_DEL => render_ansi(r, ANSI_STRIKE_OFF),
        c.MD_SPAN_LATEXMATH => render_ansi(r, ANSI_COLOR_DEFAULT),
        c.MD_SPAN_LATEXMATH_DISPLAY => render_ansi(r, ANSI_COLOR_DEFAULT),
        c.MD_SPAN_WIKILINK => render_ansi(r, ANSI_RESET),
        c.MD_SPAN_COMPONENT => render_ansi(r, ANSI_COLOR_DEFAULT),
        c.MD_SPAN_SPAN => {}, // Transparent: no special styling
        else => {},
    }

    return 0;
}

fn text_callback(text_type: c.MD_TEXTTYPE, text_in: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));
    const text: [*]const u8 = @ptrCast(text_in);

    // Suppress component frontmatter text.
    if (r.in_comp_frontmatter != 0)
        return 0;

    switch (text_type) {
        c.MD_TEXT_NULLCHAR => {
            render_utf8_codepoint(r, 0x0000, render_verbatim);
        },

        c.MD_TEXT_BR => {
            render_newline(r);
            render_indent(r);
        },

        c.MD_TEXT_SOFTBR => {
            if (r.image_nesting_level == 0) {
                render_newline(r);
                render_indent(r);
            } else {
                render_verbatim_lit(r, " ");
            }
        },

        c.MD_TEXT_HTML => {
            // Raw HTML: suppress in terminal output
        },

        c.MD_TEXT_ENTITY => {
            render_entity(r, text, size, render_verbatim);
        },

        c.MD_TEXT_CODE => {
            if (r.in_code_block != 0) {
                // Inside code block: the parser sends each line and its \n
                // as separate callbacks. We use need_indent to track when
                // we need to emit the indent prefix at line start.
                if (size == 1 and text[0] == '\n') {
                    render_newline(r);
                    r.need_indent = 1;
                } else {
                    if (r.need_indent != 0) {
                        render_indent(r);
                        render_verbatim_lit(r, "  ");
                        r.need_indent = 0;
                    }
                    render_verbatim(r, text, size);
                }
            } else {
                // Inline code span
                render_verbatim(r, text, size);
            }
        },

        else => {
            render_verbatim(r, text, size);
        },
    }

    return 0;
}

fn debug_log_callback(msg: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));
    if (r.flags & MD_ANSI_FLAG_DEBUG != 0)
        _ = sys.fprintf(sys.stderr, "MD4X: %s\n", msg);
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
        c_allocator.free(d[0..buf.cap]);
    }
}

pub fn md_ansi(
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
    if (renderer_flags & MD_ANSI_FLAG_HEAL != 0) {
        var hbuf: MD4X_HEAL_BUF = undefined;
        if (md4x_heal_input(input, input_size, &hbuf) != 0) {
            heal_buf_free(&hbuf);
            return -1;
        }
        const ret = md_ansi(@ptrCast(hbuf.data), hbuf.size, process_output, userdata, parser_flags, renderer_flags & ~MD_ANSI_FLAG_HEAL);
        heal_buf_free(&hbuf);
        return ret;
    }

    var parser: c.MD_PARSER = std.mem.zeroes(c.MD_PARSER);
    parser.flags = parser_flags;
    parser.enter_block = enter_block_callback;
    parser.leave_block = leave_block_callback;
    parser.enter_span = enter_span_callback;
    parser.leave_span = leave_span_callback;
    parser.text = text_callback;
    parser.debug_log = debug_log_callback;

    var render: MD_ANSI = std.mem.zeroes(MD_ANSI);
    render.process_output = process_output;
    render.userdata = userdata;
    render.flags = renderer_flags;

    // Consider skipping UTF-8 byte order mark (BOM).
    if (renderer_flags & MD_ANSI_FLAG_SKIP_UTF8_BOM != 0 and @sizeOf(c.MD_CHAR) == 1) {
        const bom = [_]u8{ 0xef, 0xbb, 0xbf };
        if (size >= bom.len and std.mem.eql(u8, @as([*]const u8, @ptrCast(input_ptr))[0..bom.len], &bom)) {
            input_ptr += bom.len;
            size -= bom.len;
        }
    }

    const ret = md4x.md_parse(@ptrCast(input_ptr), size, &parser, @ptrCast(&render));

    if (renderer_flags & MD_ANSI_FLAG_CODE_META != 0) {
        if (ret == 0)
            render_ansi_code_meta_json(&render);
        ansi_code_meta_cleanup(&render);
    }

    return ret;
}
