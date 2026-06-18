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
// Zig port of src/renderers/md4x-markdown.c — byte-for-byte identical behavior.

const std = @import("std");

// MD_* types + entity + md_parse/md_heal decls now come from the Zig-native
// abi module (replacing md4x.h / entity.h / md4x-heal.h); only genuinely
// external C headers stay in a @cImport, bound as `sys`.
const c = @import("abi");
const sys = @cImport({
    @cInclude("stdio.h");
});

const c_allocator = std.heap.c_allocator;

// Renderer flags (mirrors md4x-markdown.h). Heal flag value is shared (0x0100).
const MD_MARKDOWN_FLAG_DEBUG: c_uint = 0x0001;
const MD_MARKDOWN_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_MARKDOWN_FLAG_HEAL: c_uint = 0x0100;

const ProcessOutputFn = ?*const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) callconv(.c) void;

const MD_MARKDOWN = struct {
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    flags: c_uint,
    image_nesting_level: c_int,
    quote_depth: c_int,
    list_depth: c_int,
    ol_counter: c_int,
    in_code_block: c_int,
    in_code_span: c_int,
    need_newline: c_int,
    need_indent: c_int,
    li_opened: c_int,
    in_frontmatter: c_int,

    // Table state
    in_table: c_int,
    in_thead: c_int,
    thead_done: c_int,
    current_col: c_int,
    col_count: c_int,
    col_aligns: [128]c.MD_ALIGN,

    // Code block fence
    fence_char: c.MD_CHAR,
    fence_len: c_int,
};

// AppendFn mirrors the C `void (*fn_append)(MD_MARKDOWN*, const MD_CHAR*, MD_SIZE)`.
const AppendFn = *const fn (*MD_MARKDOWN, [*]const u8, c.MD_SIZE) void;

// *********************************************
// ***  Markdown rendering helper functions  ***
// *********************************************

fn render_verbatim(r: *MD_MARKDOWN, text: [*]const u8, size: c.MD_SIZE) void {
    r.process_output.?(@ptrCast(text), size, r.userdata);
}

fn render_verbatim_lit(r: *MD_MARKDOWN, comptime lit: []const u8) void {
    render_verbatim(r, lit.ptr, @intCast(lit.len));
}

fn render_indent(r: *MD_MARKDOWN) void {
    var i: c_int = 0;
    while (i < r.quote_depth) : (i += 1) {
        render_verbatim_lit(r, "> ");
    }
    i = 0;
    while (i < r.list_depth) : (i += 1) {
        render_verbatim_lit(r, "  ");
    }
}

fn render_newline(r: *MD_MARKDOWN) void {
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

fn render_utf8_codepoint(r: *MD_MARKDOWN, codepoint: c_uint, fn_append: AppendFn) void {
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

fn render_entity(r: *MD_MARKDOWN, text: [*]const u8, size: c.MD_SIZE, fn_append: AppendFn) void {
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
        const ent = c.entity_lookup(@ptrCast(text), size);
        if (ent != null) {
            const cps = ent.*.codepoints;
            render_utf8_codepoint(r, cps[0], fn_append);
            if (cps[1] != 0)
                render_utf8_codepoint(r, cps[1], fn_append);
            return;
        }
    }

    fn_append(r, text, size);
}

fn render_attribute(r: *MD_MARKDOWN, attr: *const c.MD_ATTRIBUTE, fn_append: AppendFn) void {
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

fn render_table_separator(r: *MD_MARKDOWN) void {
    render_indent(r);
    render_verbatim_lit(r, "|");
    var i: c_int = 0;
    while (i < r.col_count) : (i += 1) {
        switch (r.col_aligns[@intCast(i)]) {
            c.MD_ALIGN_LEFT => render_verbatim_lit(r, " :--- |"),
            c.MD_ALIGN_CENTER => render_verbatim_lit(r, " :---: |"),
            c.MD_ALIGN_RIGHT => render_verbatim_lit(r, " ---: |"),
            else => render_verbatim_lit(r, " --- |"),
        }
    }
    render_newline(r);
}

// ******************************************
// ***  Markdown renderer implementation  ***
// ******************************************

fn enter_block_callback(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));

    switch (block_type) {
        c.MD_BLOCK_DOC => {},

        c.MD_BLOCK_QUOTE => {
            if (r.need_newline != 0) {
                render_newline(r);
                r.need_newline = 0;
            }
            r.quote_depth += 1;
        },

        c.MD_BLOCK_UL => {
            if (r.need_newline != 0 and r.list_depth == 0) {
                render_newline(r);
                r.need_newline = 0;
            }
            r.ol_counter = 0;
        },

        c.MD_BLOCK_OL => {
            if (r.need_newline != 0 and r.list_depth == 0) {
                render_newline(r);
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
                    render_verbatim_lit(r, "- [x] ");
                } else {
                    render_verbatim_lit(r, "- [ ] ");
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
            r.li_opened = 1;
        },

        c.MD_BLOCK_HR => {
            if (r.need_newline != 0) {
                render_newline(r);
                r.need_newline = 0;
            }
            render_indent(r);
            render_verbatim_lit(r, "---");
            render_newline(r);
            r.need_newline = 1;
        },

        c.MD_BLOCK_H => {
            const h: *const c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail.?));
            const level = h.level;
            if (r.need_newline != 0) {
                render_newline(r);
                r.need_newline = 0;
            }
            render_indent(r);
            var i: c_uint = 0;
            while (i < level and i < 6) : (i += 1)
                render_verbatim_lit(r, "#");
            render_verbatim_lit(r, " ");
        },

        c.MD_BLOCK_CODE => {
            const code: *const c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(detail.?));
            if (r.need_newline != 0) {
                render_newline(r);
                r.need_newline = 0;
            }
            render_indent(r);
            r.fence_char = code.fence_char;
            if (code.fence_char == '~') {
                render_verbatim_lit(r, "~~~");
                r.fence_len = 3;
            } else {
                render_verbatim_lit(r, "```");
                r.fence_len = 3;
            }
            if (code.info.text != null and code.info.size > 0) {
                render_attribute(r, &code.info, render_verbatim);
            }
            render_newline(r);
            r.in_code_block = 1;
            r.need_indent = 1;
        },

        c.MD_BLOCK_HTML => {
            // Strip raw HTML blocks
        },

        c.MD_BLOCK_P => {
            if (r.need_newline != 0 and r.li_opened == 0) {
                render_newline(r);
                r.need_newline = 0;
            }
            if (r.li_opened == 0)
                render_indent(r);
            r.li_opened = 0;
        },

        c.MD_BLOCK_TABLE => {
            const tbl: *const c.MD_BLOCK_TABLE_DETAIL = @ptrCast(@alignCast(detail.?));
            if (r.need_newline != 0) {
                render_newline(r);
                r.need_newline = 0;
            }
            r.in_table = 1;
            r.col_count = @intCast(tbl.col_count);
            if (r.col_count > 128)
                r.col_count = 128;
            @memset(&r.col_aligns, 0);
        },

        c.MD_BLOCK_THEAD => {
            r.in_thead = 1;
            r.thead_done = 0;
        },

        c.MD_BLOCK_TBODY => {},

        c.MD_BLOCK_TR => {
            render_indent(r);
            render_verbatim_lit(r, "|");
            r.current_col = 0;
        },

        c.MD_BLOCK_TH => {
            const td: *const c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail.?));
            render_verbatim_lit(r, " ");
            if (r.current_col < 128)
                r.col_aligns[@intCast(r.current_col)] = td.@"align";
        },

        c.MD_BLOCK_TD => {
            render_verbatim_lit(r, " ");
        },

        c.MD_BLOCK_FRONTMATTER => {
            r.in_frontmatter = 1;
        },

        c.MD_BLOCK_COMPONENT => {
            const comp: *const c.MD_BLOCK_COMPONENT_DETAIL = @ptrCast(@alignCast(detail.?));
            if (r.need_newline != 0) {
                render_newline(r);
                r.need_newline = 0;
            }
            render_indent(r);
            render_verbatim_lit(r, "<");
            if (comp.tag_name.text != null and comp.tag_name.size > 0)
                render_attribute(r, &comp.tag_name, render_verbatim);
            if (comp.title != null and comp.title_size > 0) {
                render_verbatim_lit(r, " title=\"");
                render_verbatim(r, @ptrCast(comp.title), comp.title_size);
                render_verbatim_lit(r, "\"");
            }
            render_verbatim_lit(r, ">");
            render_newline(r);
            render_newline(r);
        },

        c.MD_BLOCK_ALERT => {
            const det: *const c.MD_BLOCK_ALERT_DETAIL = @ptrCast(@alignCast(detail.?));
            if (r.need_newline != 0) {
                render_newline(r);
                r.need_newline = 0;
            }
            r.quote_depth += 1;
            render_indent(r);
            render_verbatim_lit(r, "[!");
            if (det.type_name.text != null and det.type_name.size > 0)
                render_attribute(r, &det.type_name, render_verbatim);
            render_verbatim_lit(r, "]");
            render_newline(r);
        },

        c.MD_BLOCK_TEMPLATE => {
            // Transparent — render children normally
        },

        else => {},
    }

    return 0;
}

fn leave_block_callback(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));

    switch (block_type) {
        c.MD_BLOCK_DOC => {},

        c.MD_BLOCK_QUOTE => {
            r.quote_depth -= 1;
        },

        c.MD_BLOCK_UL => {
            r.ol_counter = 0;
            r.need_newline = 1;
        },

        c.MD_BLOCK_OL => {
            r.ol_counter = 0;
            r.need_newline = 1;
        },

        c.MD_BLOCK_LI => {
            r.list_depth -= 1;
            render_newline(r);
        },

        c.MD_BLOCK_HR => {},

        c.MD_BLOCK_H => {
            render_newline(r);
            r.need_newline = 1;
        },

        c.MD_BLOCK_CODE => {
            render_indent(r);
            if (r.fence_char == '~') {
                render_verbatim_lit(r, "~~~");
            } else {
                render_verbatim_lit(r, "```");
            }
            render_newline(r);
            r.in_code_block = 0;
            r.need_newline = 1;
        },

        c.MD_BLOCK_HTML => {},

        c.MD_BLOCK_P => {
            render_newline(r);
            r.need_newline = 1;
        },

        c.MD_BLOCK_TABLE => {
            r.in_table = 0;
            r.need_newline = 1;
        },

        c.MD_BLOCK_THEAD => {
            r.in_thead = 0;
        },

        c.MD_BLOCK_TBODY => {},

        c.MD_BLOCK_TR => {
            render_newline(r);
            if (r.in_thead != 0 and r.thead_done == 0) {
                render_table_separator(r);
                r.thead_done = 1;
            }
        },

        c.MD_BLOCK_TH => {
            render_verbatim_lit(r, " |");
            r.current_col += 1;
        },

        c.MD_BLOCK_TD => {
            render_verbatim_lit(r, " |");
            r.current_col += 1;
        },

        c.MD_BLOCK_FRONTMATTER => {
            r.in_frontmatter = 0;
        },

        c.MD_BLOCK_COMPONENT => {
            const comp: *const c.MD_BLOCK_COMPONENT_DETAIL = @ptrCast(@alignCast(detail.?));
            render_indent(r);
            render_verbatim_lit(r, "</");
            if (comp.tag_name.text != null and comp.tag_name.size > 0)
                render_attribute(r, &comp.tag_name, render_verbatim);
            render_verbatim_lit(r, ">");
            render_newline(r);
            r.need_newline = 1;
        },

        c.MD_BLOCK_ALERT => {
            r.quote_depth -= 1;
            r.need_newline = 1;
        },

        c.MD_BLOCK_TEMPLATE => {},

        else => {},
    }

    return 0;
}

fn enter_span_callback(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));

    switch (span_type) {
        c.MD_SPAN_EM => {
            render_verbatim_lit(r, "*");
        },

        c.MD_SPAN_STRONG => {
            render_verbatim_lit(r, "**");
        },

        c.MD_SPAN_A => {
            render_verbatim_lit(r, "[");
        },

        c.MD_SPAN_IMG => {
            render_verbatim_lit(r, "![");
            r.image_nesting_level += 1;
        },

        c.MD_SPAN_CODE => {
            render_verbatim_lit(r, "`");
            r.in_code_span = 1;
        },

        c.MD_SPAN_DEL => {
            render_verbatim_lit(r, "~~");
        },

        c.MD_SPAN_LATEXMATH => {
            render_verbatim_lit(r, "$");
        },

        c.MD_SPAN_LATEXMATH_DISPLAY => {
            render_verbatim_lit(r, "$$");
        },

        c.MD_SPAN_WIKILINK => {
            // Convert wiki link to regular link: [target](
            render_verbatim_lit(r, "[");
        },

        c.MD_SPAN_U => {
            // Underline has no standard markdown — use HTML tag
            render_verbatim_lit(r, "<u>");
        },

        c.MD_SPAN_COMPONENT => {
            const comp: *const c.MD_SPAN_COMPONENT_DETAIL = @ptrCast(@alignCast(detail.?));
            render_verbatim_lit(r, "<");
            if (comp.tag_name.text != null and comp.tag_name.size > 0)
                render_attribute(r, &comp.tag_name, render_verbatim);
            render_verbatim_lit(r, ">");
        },

        c.MD_SPAN_SPAN => {
            // Generic span — transparent, just render content
        },

        else => {},
    }

    return 0;
}

fn leave_span_callback(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));

    switch (span_type) {
        c.MD_SPAN_EM => {
            render_verbatim_lit(r, "*");
        },

        c.MD_SPAN_STRONG => {
            render_verbatim_lit(r, "**");
        },

        c.MD_SPAN_A => {
            const a: *const c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(detail.?));
            render_verbatim_lit(r, "](");
            render_attribute(r, &a.href, render_verbatim);
            if (a.title.text != null and a.title.size > 0) {
                render_verbatim_lit(r, " \"");
                render_attribute(r, &a.title, render_verbatim);
                render_verbatim_lit(r, "\"");
            }
            render_verbatim_lit(r, ")");
        },

        c.MD_SPAN_IMG => {
            const img: *const c.MD_SPAN_IMG_DETAIL = @ptrCast(@alignCast(detail.?));
            render_verbatim_lit(r, "](");
            render_attribute(r, &img.src, render_verbatim);
            if (img.title.text != null and img.title.size > 0) {
                render_verbatim_lit(r, " \"");
                render_attribute(r, &img.title, render_verbatim);
                render_verbatim_lit(r, "\"");
            }
            render_verbatim_lit(r, ")");
            r.image_nesting_level -= 1;
        },

        c.MD_SPAN_CODE => {
            render_verbatim_lit(r, "`");
            r.in_code_span = 0;
        },

        c.MD_SPAN_DEL => {
            render_verbatim_lit(r, "~~");
        },

        c.MD_SPAN_LATEXMATH => {
            render_verbatim_lit(r, "$");
        },

        c.MD_SPAN_LATEXMATH_DISPLAY => {
            render_verbatim_lit(r, "$$");
        },

        c.MD_SPAN_WIKILINK => {
            const wl: *const c.MD_SPAN_WIKILINK_DETAIL = @ptrCast(@alignCast(detail.?));
            render_verbatim_lit(r, "](");
            render_attribute(r, &wl.target, render_verbatim);
            render_verbatim_lit(r, ")");
        },

        c.MD_SPAN_U => {
            render_verbatim_lit(r, "</u>");
        },

        c.MD_SPAN_COMPONENT => {
            const comp: *const c.MD_SPAN_COMPONENT_DETAIL = @ptrCast(@alignCast(detail.?));
            render_verbatim_lit(r, "</");
            if (comp.tag_name.text != null and comp.tag_name.size > 0)
                render_attribute(r, &comp.tag_name, render_verbatim);
            render_verbatim_lit(r, ">");
        },

        c.MD_SPAN_SPAN => {},

        else => {},
    }

    return 0;
}

fn text_callback(text_type: c.MD_TEXTTYPE, text_in: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));
    const text: [*]const u8 = @ptrCast(text_in);

    if (r.in_frontmatter != 0)
        return 0;

    switch (text_type) {
        c.MD_TEXT_NULLCHAR => {
            render_utf8_codepoint(r, 0xFFFD, render_verbatim);
        },

        c.MD_TEXT_BR => {
            render_verbatim_lit(r, "\\");
            render_newline(r);
            render_indent(r);
        },

        c.MD_TEXT_SOFTBR => {
            render_newline(r);
            render_indent(r);
        },

        c.MD_TEXT_HTML => {
            // Strip all raw HTML (comments, custom tags, etc.)
        },

        c.MD_TEXT_ENTITY => {
            render_entity(r, text, size, render_verbatim);
        },

        c.MD_TEXT_CODE => {
            if (r.in_code_block != 0) {
                if (size == 1 and text[0] == '\n') {
                    render_newline(r);
                    r.need_indent = 1;
                } else {
                    if (r.need_indent != 0) {
                        render_indent(r);
                        r.need_indent = 0;
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

fn debug_log_callback(msg: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));
    if (r.flags & MD_MARKDOWN_FLAG_DEBUG != 0)
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

// Run md_heal and return the healed buffer. Caller must free buf.data.
// Returns 0 on success, -1 on error.
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
    if (buf.data) |d| {
        // The C version uses free(hbuf.data); the underlying allocation came from
        // realloc/alloc with the c_allocator, so free it as a sized slice.
        c_allocator.free(d[0..buf.cap]);
    }
}

export fn md_markdown(
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
    if (renderer_flags & MD_MARKDOWN_FLAG_HEAL != 0) {
        var hbuf: MD4X_HEAL_BUF = undefined;
        if (md4x_heal_input(input, input_size, &hbuf) != 0) {
            heal_buf_free(&hbuf);
            return -1;
        }
        const ret = md_markdown(@ptrCast(hbuf.data), hbuf.size, process_output, userdata, parser_flags, renderer_flags & ~MD_MARKDOWN_FLAG_HEAL);
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

    var render: MD_MARKDOWN = std.mem.zeroes(MD_MARKDOWN);
    render.process_output = process_output;
    render.userdata = userdata;
    render.flags = renderer_flags;

    // Consider skipping UTF-8 byte order mark (BOM).
    if (renderer_flags & MD_MARKDOWN_FLAG_SKIP_UTF8_BOM != 0 and @sizeOf(c.MD_CHAR) == 1) {
        const bom = [_]u8{ 0xef, 0xbb, 0xbf };
        if (size >= bom.len and std.mem.eql(u8, @as([*]const u8, @ptrCast(input_ptr))[0..bom.len], &bom)) {
            input_ptr += bom.len;
            size -= bom.len;
        }
    }

    return c.md_parse(@ptrCast(input_ptr), size, &parser, @ptrCast(&render));
}
