// MD4X: Markdown parser for C
// (http://github.com/unjs/md4x)
//
// Copyright (c) 2016-2024 Martin Mitáš
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
// Zig port of src/renderers/md4x-html.c — byte-for-byte identical behavior.

const std = @import("std");

// MD_* types + entity + md_parse/md_heal decls now come from the Zig-native
// abi module (replacing md4x.h / entity.h / md4x-heal.h); only genuinely
// external C headers stay in a @cImport, bound as `sys`.
const c = @import("abi");
const sys = @cImport({
    @cInclude("stdio.h");
    @cInclude("yaml.h");
});

const c_allocator = std.heap.c_allocator;

// --- Renderer flags (mirror md4x-html.h) ---
const MD_HTML_FLAG_DEBUG: c_uint = 0x0001;
const MD_HTML_FLAG_VERBATIM_ENTITIES: c_uint = 0x0002;
const MD_HTML_FLAG_SKIP_UTF8_BOM: c_uint = 0x0004;
const MD_HTML_FLAG_FULL_HTML: c_uint = 0x0008;
const MD_HTML_FLAG_CODE_META: c_uint = 0x0010;
const MD_HTML_FLAG_HEAL: c_uint = 0x0100;

const NEED_HTML_ESC_FLAG: u8 = 0x1;
const NEED_URL_ESC_FLAG: u8 = 0x2;

// Map of characters which need escaping. Input-independent, so computed once at
// comptime. Reproduces exactly the previous per-call runtime construction
// (including strchr's C semantics where strchr(set, 0) matches the NUL byte).
const ESCAPE_MAP: [256]u8 = blk: {
    @setEvalBranchQuota(10000);
    var map = [_]u8{0} ** 256;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const ch: u8 = @intCast(i);
        if (strchr("\"&<>", ch))
            map[i] |= NEED_HTML_ESC_FLAG;
        if (!ISALNUM(ch) and !strchr("~-_.+!*(),%#@?=;:/,+$", ch))
            map[i] |= NEED_URL_ESC_FLAG;
    }
    break :blk map;
};

// MD_HTML_OPTS must match the C struct layout exactly.
const MD_HTML_OPTS = extern struct {
    title: ?[*:0]const u8,
    css_url: ?[*:0]const u8,
};

const ProcessOutputFn = ?*const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) callconv(.c) void;

// AppendFn mirrors `void (*fn_append)(MD_HTML*, const MD_CHAR*, MD_SIZE)`.
const AppendFn = *const fn (*MD_HTML, [*]const u8, c.MD_SIZE) void;

// Code block metadata entry (heap-allocated when MD_HTML_FLAG_CODE_META is set).
const MD_HTML_CODE_META = struct {
    start: c.MD_SIZE = 0,
    end: c.MD_SIZE = 0,
    lang: [64]u8 = undefined,
    lang_size: c.MD_SIZE = 0,
    filename: [256]u8 = undefined,
    filename_size: c.MD_SIZE = 0,
    highlights: ?[*]c_uint = null,
    highlight_count: c_uint = 0,
};

const MD_HTML = struct {
    process_output: ProcessOutputFn = null,
    userdata: ?*anyopaque = null,
    flags: c_uint = 0,
    image_nesting_level: c_int = 0,

    // Frontmatter suppression state.
    in_frontmatter: c_int = 0,
    component_nesting: c_int = 0,

    // Component frontmatter: deferred open tag.
    comp_fm_pending: c_int = 0,
    comp_fm_capturing: c_int = 0,
    comp_fm_tag: ?[*]u8 = null,
    comp_fm_tag_size: c.MD_SIZE = 0,
    comp_fm_tag_cap: c.MD_SIZE = 0,
    comp_fm_text: ?[*]u8 = null,
    comp_fm_text_size: c.MD_SIZE = 0,
    comp_fm_text_cap: c.MD_SIZE = 0,

    // Full-HTML mode state.
    opts: ?*const MD_HTML_OPTS = null,
    head_emitted: c_int = 0,

    // Frontmatter YAML capture buffer (allocated only when FULL_HTML).
    fm_text: ?[*]u8 = null,
    fm_size: c.MD_SIZE = 0,
    fm_cap: c.MD_SIZE = 0,

    // Code block metadata tracking.
    output_offset: c.MD_SIZE = 0,
    in_code_block: c_int = 0,
    code_blocks: ?[*]MD_HTML_CODE_META = null,
    n_code_blocks: c_int = 0,
    code_blocks_cap: c_int = 0,

    // Internal output buffer: batches render_verbatim appends into a single
    // process_output callback to reduce per-call overhead. `real_process_output`
    // holds the caller's original callback; `process_output` may be temporarily
    // swapped (e.g. to comp_fm_tag_capture) — buffering is bypassed while swapped.
    real_process_output: ProcessOutputFn = null,
    out_buf: ?[*]u8 = null,
    out_size: c.MD_SIZE = 0,
    out_cap: c.MD_SIZE = 0,
};

// Flush threshold: when the internal buffer reaches this size, emit it.
const OUT_BUF_THRESHOLD: c.MD_SIZE = 8 * 1024;

// Append bytes to the internal output buffer, flushing to real_process_output
// when the threshold is exceeded. Falls back to a direct call on OOM so output
// is never silently dropped.
fn out_buf_append(r: *MD_HTML, text: [*]const u8, size: c.MD_SIZE) void {
    if (r.out_size + size > r.out_cap) {
        const new_cap: c.MD_SIZE = r.out_cap + r.out_cap / 2 + size + OUT_BUF_THRESHOLD;
        const p = buf_realloc(r.out_buf, r.out_cap, new_cap);
        if (p == null) {
            // OOM: flush what we have, then emit directly (no buffering).
            flush_output(r);
            r.real_process_output.?(@ptrCast(text), size, r.userdata);
            return;
        }
        r.out_buf = p;
        r.out_cap = new_cap;
    }
    @memcpy(r.out_buf.?[r.out_size .. r.out_size + size], text[0..size]);
    r.out_size += size;
    if (r.out_size >= OUT_BUF_THRESHOLD)
        flush_output(r);
}

// Emit any buffered bytes via the real callback and reset the buffer.
fn flush_output(r: *MD_HTML) void {
    if (r.out_size > 0) {
        r.real_process_output.?(@ptrCast(r.out_buf.?), r.out_size, r.userdata);
        r.out_size = 0;
    }
}

// Flush the internal buffer, then emit bytes directly via the real callback.
// Used by direct-output paths (comp_fm_flush_tag, render_code_meta_json) so
// their output lands in the correct position relative to buffered body content.
fn emit(r: *MD_HTML, text: [*]const u8, size: c.MD_SIZE) void {
    flush_output(r);
    r.real_process_output.?(@ptrCast(text), size, r.userdata);
}

// *****************************************
// ***  Shared component property parser ***
// *****************************************
//
// The component property parser lives in the shared md4x-props.zig module
// (previously reimplemented inline here). Local aliases preserve the original
// call-site names used below.

const props = @import("md4x-props.zig");

const MD_PARSED_PROPS = props.MD_PARSED_PROPS;
const md_parse_props = props.md_parse_props;

// *****************************************
// ***  HTML rendering helper functions  ***
// *****************************************

inline fn ISDIGIT(ch: u8) bool {
    return '0' <= ch and ch <= '9';
}
inline fn ISLOWER(ch: u8) bool {
    return 'a' <= ch and ch <= 'z';
}
inline fn ISUPPER(ch: u8) bool {
    return 'A' <= ch and ch <= 'Z';
}
inline fn ISALNUM(ch: u8) bool {
    return ISLOWER(ch) or ISUPPER(ch) or ISDIGIT(ch);
}

fn render_verbatim(r: *MD_HTML, text: [*]const u8, size: c.MD_SIZE) void {
    // When process_output has been temporarily swapped away from the caller's
    // original callback (e.g. component-frontmatter capture), bypass the
    // internal buffer and call the swapped callback directly. Otherwise batch
    // into out_buf.
    if (r.process_output == r.real_process_output) {
        out_buf_append(r, text, size);
    } else {
        r.process_output.?(@ptrCast(text), size, r.userdata);
    }
    if (r.flags & MD_HTML_FLAG_CODE_META != 0)
        r.output_offset += size;
}

fn render_verbatim_lit(r: *MD_HTML, comptime lit: []const u8) void {
    render_verbatim(r, lit.ptr, @intCast(lit.len));
}

// Find the next offset >= `start` whose byte needs HTML-escaping (one of
// `" & < >`), or `size` if none. Vectorized: the common case is long plain
// runs, so we scan 16 bytes at a time. Byte-identical to the scalar predicate
// `(ESCAPE_MAP[ch] & NEED_HTML_ESC_FLAG) != 0` — only the scan is widened.
fn next_html_esc(data: [*]const u8, start: c.MD_OFFSET, size: c.MD_SIZE) c.MD_OFFSET {
    const V = 16;
    const Vec = @Vector(V, u8);
    const amp: Vec = @splat('&');
    const lt: Vec = @splat('<');
    const gt: Vec = @splat('>');
    const quot: Vec = @splat('"');

    var off = start;
    while (off + V <= size) : (off += V) {
        const chunk: Vec = @as(*const [V]u8, @ptrCast(data + off)).*;
        const hit = (chunk == amp) | (chunk == lt) | (chunk == gt) | (chunk == quot);
        if (@reduce(.Or, hit)) {
            inline for (0..V) |j| {
                if (hit[j]) return off + @as(c.MD_OFFSET, j);
            }
        }
    }
    // Scalar tail (< 16 bytes remaining).
    while (off < size and (ESCAPE_MAP[data[off]] & NEED_HTML_ESC_FLAG) == 0)
        off += 1;
    return off;
}

fn render_html_escaped(r: *MD_HTML, data: [*]const u8, size: c.MD_SIZE) void {
    var beg: c.MD_OFFSET = 0;
    var off: c.MD_OFFSET = 0;

    while (true) {
        off = next_html_esc(data, off, size);

        if (off > beg)
            render_verbatim(r, data + beg, off - beg);

        if (off < size) {
            switch (data[off]) {
                '&' => render_verbatim_lit(r, "&amp;"),
                '<' => render_verbatim_lit(r, "&lt;"),
                '>' => render_verbatim_lit(r, "&gt;"),
                '"' => render_verbatim_lit(r, "&quot;"),
                else => {},
            }
            off += 1;
        } else {
            break;
        }
        beg = off;
    }
}

fn render_url_escaped(r: *MD_HTML, data: [*]const u8, size: c.MD_SIZE) void {
    const hex_chars = "0123456789ABCDEF";
    var beg: c.MD_OFFSET = 0;
    var off: c.MD_OFFSET = 0;

    const NEED_URL_ESC = struct {
        inline fn f(ch: u8) bool {
            return (ESCAPE_MAP[ch] & NEED_URL_ESC_FLAG) != 0;
        }
    }.f;

    while (true) {
        while (off < size and !NEED_URL_ESC(data[off]))
            off += 1;
        if (off > beg)
            render_verbatim(r, data + beg, off - beg);

        if (off < size) {
            var hex: [3]u8 = undefined;

            switch (data[off]) {
                '&' => render_verbatim_lit(r, "&amp;"),
                else => {
                    hex[0] = '%';
                    hex[1] = hex_chars[(@as(c_uint, data[off]) >> 4) & 0xf];
                    hex[2] = hex_chars[(@as(c_uint, data[off]) >> 0) & 0xf];
                    render_verbatim(r, &hex, 3);
                },
            }
            off += 1;
        } else {
            break;
        }

        beg = off;
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

fn render_utf8_codepoint(r: *MD_HTML, codepoint: c_uint, fn_append: AppendFn) void {
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

// Translate entity to its UTF-8 equivalent, or output the verbatim one
// if such entity is unknown (or if the translation is disabled).
fn render_entity(r: *MD_HTML, text: [*]const u8, size: c.MD_SIZE, fn_append: AppendFn) void {
    if (r.flags & MD_HTML_FLAG_VERBATIM_ENTITIES != 0) {
        render_verbatim(r, text, size);
        return;
    }

    // We assume UTF-8 output is what is desired.
    if (size > 3 and text[1] == '#') {
        var codepoint: c_uint = 0;

        if (text[2] == 'x' or text[2] == 'X') {
            // Hexadecimal entity.
            var i: c.MD_SIZE = 3;
            while (i < size - 1) : (i += 1)
                codepoint = 16 *% codepoint +% hex_val(text[i]);
        } else {
            // Decimal entity.
            var i: c.MD_SIZE = 2;
            while (i < size - 1) : (i += 1)
                codepoint = 10 *% codepoint +% (text[i] - '0');
        }

        render_utf8_codepoint(r, codepoint, fn_append);
        return;
    } else {
        // Named entity.
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

fn render_attribute(r: *MD_HTML, attr: *const c.MD_ATTRIBUTE, fn_append: AppendFn) void {
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

fn render_open_ol_block(r: *MD_HTML, det: *const c.MD_BLOCK_OL_DETAIL) void {
    if (det.start == 1) {
        render_verbatim_lit(r, "<ol>\n");
        return;
    }

    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "<ol start=\"{d}\">\n", .{det.start}) catch unreachable;
    render_verbatim(r, s.ptr, @intCast(s.len));
}

fn render_open_li_block(r: *MD_HTML, det: *const c.MD_BLOCK_LI_DETAIL) void {
    if (det.is_task != 0) {
        render_verbatim_lit(r, "<li class=\"task-list-item\">" ++
            "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled");
        if (det.task_mark == 'x' or det.task_mark == 'X')
            render_verbatim_lit(r, " checked");
        render_verbatim_lit(r, ">");
    } else {
        render_verbatim_lit(r, "<li>");
    }
}

fn render_open_code_block(r: *MD_HTML, det: *const c.MD_BLOCK_CODE_DETAIL) void {
    render_verbatim_lit(r, "<pre><code");

    // If known, output the HTML 5 attribute class="language-LANGNAME".
    if (det.lang.text != null) {
        render_verbatim_lit(r, " class=\"language-");
        render_attribute(r, &det.lang, render_html_escaped);
        render_verbatim_lit(r, "\"");
    }

    render_verbatim_lit(r, ">");
}

fn render_open_td_block(r: *MD_HTML, comptime cell_type: []const u8, det: *const c.MD_BLOCK_TD_DETAIL) void {
    render_verbatim_lit(r, "<");
    render_verbatim_lit(r, cell_type);

    switch (det.@"align") {
        c.MD_ALIGN_LEFT => render_verbatim_lit(r, " align=\"left\">"),
        c.MD_ALIGN_CENTER => render_verbatim_lit(r, " align=\"center\">"),
        c.MD_ALIGN_RIGHT => render_verbatim_lit(r, " align=\"right\">"),
        else => render_verbatim_lit(r, ">"),
    }
}

fn render_open_a_span(r: *MD_HTML, det: *const c.MD_SPAN_A_DETAIL) void {
    render_verbatim_lit(r, "<a href=\"");
    render_attribute(r, &det.href, render_url_escaped);

    if (det.title.text != null) {
        render_verbatim_lit(r, "\" title=\"");
        render_attribute(r, &det.title, render_html_escaped);
    }

    render_verbatim_lit(r, "\"");
    if (det.raw_attrs != null and det.raw_attrs_size > 0)
        render_html_component_props(r, @ptrCast(det.raw_attrs), det.raw_attrs_size);
    render_verbatim_lit(r, ">");
}

fn render_open_img_span(r: *MD_HTML, det: *const c.MD_SPAN_IMG_DETAIL) void {
    render_verbatim_lit(r, "<img src=\"");
    render_attribute(r, &det.src, render_url_escaped);

    render_verbatim_lit(r, "\" alt=\"");
}

fn render_close_img_span(r: *MD_HTML, det: *const c.MD_SPAN_IMG_DETAIL) void {
    if (det.title.text != null) {
        render_verbatim_lit(r, "\" title=\"");
        render_attribute(r, &det.title, render_html_escaped);
    }

    render_verbatim_lit(r, "\"");
    if (det.raw_attrs != null and det.raw_attrs_size > 0)
        render_html_component_props(r, @ptrCast(det.raw_attrs), det.raw_attrs_size);
    render_verbatim_lit(r, ">");
}

fn render_open_wikilink_span(r: *MD_HTML, det: *const c.MD_SPAN_WIKILINK_DETAIL) void {
    render_verbatim_lit(r, "<x-wikilink data-target=\"");
    render_attribute(r, &det.target, render_html_escaped);

    render_verbatim_lit(r, "\">");
}

// Render parsed component props as HTML attributes.
fn render_html_component_props(r: *MD_HTML, raw: [*]const u8, size: c.MD_SIZE) void {
    var parsed: MD_PARSED_PROPS = undefined;

    md_parse_props(raw, size, &parsed);

    // Write #id.
    if (parsed.id != null and parsed.id_size > 0) {
        render_verbatim_lit(r, " id=\"");
        render_html_escaped(r, parsed.id.?, parsed.id_size);
        render_verbatim_lit(r, "\"");
    }

    // Write regular props.
    var i: usize = 0;
    while (i < @as(usize, @intCast(parsed.n_props))) : (i += 1) {
        const p = &parsed.props[i];

        render_verbatim_lit(r, " ");
        render_html_escaped(r, p.key, p.key_size);

        switch (p.type) {
            .string, .bind => {
                render_verbatim_lit(r, "=\"");
                render_html_escaped(r, p.value.?, p.value_size);
                render_verbatim_lit(r, "\"");
            },
            .boolean => {
                // Bare attribute (no value).
            },
        }
    }

    // Write merged class.
    if (parsed.class_len > 0) {
        render_verbatim_lit(r, " class=\"");
        render_html_escaped(r, &parsed.class_buf, parsed.class_len);
        render_verbatim_lit(r, "\"");
    }
}

// Render opening tag for a simple span with optional trailing attrs.
fn render_open_tag_with_attrs(r: *MD_HTML, comptime tag: []const u8, det: ?*const c.MD_SPAN_ATTRS_DETAIL) void {
    render_verbatim_lit(r, "<");
    render_verbatim_lit(r, tag);
    if (det != null and det.?.raw_attrs != null and det.?.raw_attrs_size > 0)
        render_html_component_props(r, @ptrCast(det.?.raw_attrs), det.?.raw_attrs_size);
    render_verbatim_lit(r, ">");
}

// Render opening tag for [text]{attrs} span.
fn render_open_span_span(r: *MD_HTML, det: ?*const c.MD_SPAN_SPAN_DETAIL) void {
    render_verbatim_lit(r, "<span");
    if (det != null and det.?.raw_attrs != null and det.?.raw_attrs_size > 0)
        render_html_component_props(r, @ptrCast(det.?.raw_attrs), det.?.raw_attrs_size);
    render_verbatim_lit(r, ">");
}

fn render_open_component_span(r: *MD_HTML, det: *const c.MD_SPAN_COMPONENT_DETAIL) void {
    render_verbatim_lit(r, "<");
    render_attribute(r, &det.tag_name, render_html_escaped);
    if (det.raw_props != null and det.raw_props_size > 0)
        render_html_component_props(r, @ptrCast(det.raw_props), det.raw_props_size);
    render_verbatim_lit(r, ">");
}

fn render_close_component_span(r: *MD_HTML, det: *const c.MD_SPAN_COMPONENT_DETAIL) void {
    render_verbatim_lit(r, "</");
    render_attribute(r, &det.tag_name, render_html_escaped);
    render_verbatim_lit(r, ">");
}

// Append to the component frontmatter tag buffer.
fn comp_fm_tag_append(r: *MD_HTML, text: [*]const u8, size: c.MD_SIZE) c_int {
    if (r.comp_fm_tag_size + size > r.comp_fm_tag_cap) {
        const new_cap: c.MD_SIZE = r.comp_fm_tag_cap + r.comp_fm_tag_cap / 2 + size + 64;
        const p = buf_realloc(r.comp_fm_tag, r.comp_fm_tag_cap, new_cap) orelse return -1;
        r.comp_fm_tag = p;
        r.comp_fm_tag_cap = new_cap;
    }
    @memcpy(r.comp_fm_tag.?[r.comp_fm_tag_size .. r.comp_fm_tag_size + size], text[0..size]);
    r.comp_fm_tag_size += size;
    return 0;
}

// Append to the component frontmatter text buffer.
fn comp_fm_text_append(r: *MD_HTML, text: [*]const u8, size: c.MD_SIZE) c_int {
    if (r.comp_fm_text_size + size > r.comp_fm_text_cap) {
        const new_cap: c.MD_SIZE = r.comp_fm_text_cap + r.comp_fm_text_cap / 2 + size + 64;
        const p = buf_realloc(r.comp_fm_text, r.comp_fm_text_cap, new_cap) orelse return -1;
        r.comp_fm_text = p;
        r.comp_fm_text_cap = new_cap;
    }
    @memcpy(r.comp_fm_text.?[r.comp_fm_text_size .. r.comp_fm_text_size + size], text[0..size]);
    r.comp_fm_text_size += size;
    return 0;
}

// process_output callback wrapper for capturing into comp_fm_tag buffer.
fn comp_fm_tag_capture(text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) void {
    _ = comp_fm_tag_append(@ptrCast(@alignCast(userdata.?)), @ptrCast(text), size);
}

// Flush the buffered component open tag. If YAML text was captured,
// parse it and emit as HTML attributes before closing ">".
fn comp_fm_flush_tag(r: *MD_HTML) void {
    if (r.comp_fm_tag == null or r.comp_fm_tag_size == 0)
        return;

    // Emit the buffered tag prefix (e.g. "<card ...props").
    emit(r, r.comp_fm_tag.?, r.comp_fm_tag_size);

    // If we captured YAML, parse and emit as attributes.
    if (r.comp_fm_text != null and r.comp_fm_text_size > 0) {
        var yp: sys.yaml_parser_t = undefined;
        var event: sys.yaml_event_t = undefined;

        if (sys.yaml_parser_initialize(&yp) != 0) {
            sys.yaml_parser_set_input_string(&yp, @ptrCast(r.comp_fm_text.?), r.comp_fm_text_size);

            // STREAM_START
            if (sys.yaml_parser_parse(&yp, &event) != 0 and event.type == sys.YAML_STREAM_START_EVENT) {
                sys.yaml_event_delete(&event);
                // DOCUMENT_START
                if (sys.yaml_parser_parse(&yp, &event) != 0 and event.type == sys.YAML_DOCUMENT_START_EVENT) {
                    sys.yaml_event_delete(&event);
                    // MAPPING_START
                    if (sys.yaml_parser_parse(&yp, &event) != 0 and event.type == sys.YAML_MAPPING_START_EVENT) {
                        sys.yaml_event_delete(&event);
                        // Iterate key-value pairs.
                        while (sys.yaml_parser_parse(&yp, &event) != 0) {
                            var key_buf: [256]u8 = undefined;
                            if (event.type == sys.YAML_MAPPING_END_EVENT) {
                                sys.yaml_event_delete(&event);
                                break;
                            }
                            if (event.type != sys.YAML_SCALAR_EVENT) {
                                sys.yaml_event_delete(&event);
                                break;
                            }
                            var key_len: usize = event.data.scalar.length;
                            if (key_len >= key_buf.len) key_len = key_buf.len - 1;
                            @memcpy(key_buf[0..key_len], event.data.scalar.value[0..key_len]);
                            key_buf[key_len] = 0;
                            sys.yaml_event_delete(&event);

                            // Read value.
                            if (sys.yaml_parser_parse(&yp, &event) == 0) break;
                            if (event.type == sys.YAML_SCALAR_EVENT) {
                                render_verbatim_lit(r, " ");
                                render_html_escaped(r, &key_buf, @intCast(key_len));
                                render_verbatim_lit(r, "=\"");
                                render_html_escaped(r, @ptrCast(event.data.scalar.value), @intCast(event.data.scalar.length));
                                render_verbatim_lit(r, "\"");
                            } else if (event.type == sys.YAML_MAPPING_START_EVENT or event.type == sys.YAML_SEQUENCE_START_EVENT) {
                                // Skip nested structures.
                                var depth: c_int = 1;
                                sys.yaml_event_delete(&event);
                                while (depth > 0 and sys.yaml_parser_parse(&yp, &event) != 0) {
                                    if (event.type == sys.YAML_MAPPING_START_EVENT or event.type == sys.YAML_SEQUENCE_START_EVENT)
                                        depth += 1
                                    else if (event.type == sys.YAML_MAPPING_END_EVENT or event.type == sys.YAML_SEQUENCE_END_EVENT)
                                        depth -= 1;
                                    sys.yaml_event_delete(&event);
                                }
                                continue;
                            }
                            sys.yaml_event_delete(&event);
                        }
                    } else {
                        sys.yaml_event_delete(&event);
                    }
                } else {
                    sys.yaml_event_delete(&event);
                }
            } else {
                sys.yaml_event_delete(&event);
            }
            sys.yaml_parser_delete(&yp);
        }
    }

    render_verbatim_lit(r, ">\n");

    // Reset buffers.
    r.comp_fm_tag_size = 0;
    r.comp_fm_text_size = 0;
    r.comp_fm_pending = 0;
    r.comp_fm_capturing = 0;
}

fn render_open_block_component(r: *MD_HTML, det: *const c.MD_BLOCK_COMPONENT_DETAIL) void {
    // Buffer the open tag (without closing ">") so we can append
    // frontmatter YAML attributes if a frontmatter block follows.
    r.comp_fm_tag_size = 0;
    r.comp_fm_text_size = 0;
    _ = comp_fm_tag_append(r, "<", 1);

    // Append tag name.
    {
        const attr = &det.tag_name;
        var i: usize = 0;
        while (attr.substr_offsets != null and attr.substr_offsets[i] < attr.size) : (i += 1) {
            const off = attr.substr_offsets[i];
            const next = if (attr.substr_offsets[i + 1] < attr.size) attr.substr_offsets[i + 1] else attr.size;
            const len = next - off;
            _ = comp_fm_tag_append(r, @ptrCast(attr.text + off), len);
        }
    }

    // Append title as attribute if present.
    if (det.title != null and det.title_size > 0) {
        _ = comp_fm_tag_append(r, " title=\"", 8);
        {
            const saved_output = r.process_output;
            const saved_ud = r.userdata;
            r.process_output = comp_fm_tag_capture;
            r.userdata = r;
            render_html_escaped(r, @ptrCast(det.title), det.title_size);
            r.process_output = saved_output;
            r.userdata = saved_ud;
        }
        _ = comp_fm_tag_append(r, "\"", 1);
    }

    // Append {props} if present.
    if (det.raw_props != null and det.raw_props_size > 0) {
        // Render props to a temp buffer by capturing output.
        const saved_output = r.process_output;
        const saved_ud = r.userdata;
        r.process_output = comp_fm_tag_capture;
        r.userdata = r;
        render_html_component_props(r, @ptrCast(det.raw_props), det.raw_props_size);
        r.process_output = saved_output;
        r.userdata = saved_ud;
    }

    r.comp_fm_pending = 1;
}

fn render_close_block_component(r: *MD_HTML, det: *const c.MD_BLOCK_COMPONENT_DETAIL) void {
    // Flush pending open tag if it was never flushed (empty component).
    if (r.comp_fm_pending != 0)
        comp_fm_flush_tag(r);
    render_verbatim_lit(r, "</");
    render_attribute(r, &det.tag_name, render_html_escaped);
    render_verbatim_lit(r, ">\n");
}

// *****************************************
// ***  Code block metadata tracking     ***
// *****************************************

fn code_meta_push(r: *MD_HTML) ?*MD_HTML_CODE_META {
    if (r.code_blocks == null) {
        const p = c_allocator.alloc(MD_HTML_CODE_META, 8) catch return null;
        r.code_blocks = p.ptr;
        r.code_blocks_cap = 8;
    } else if (r.n_code_blocks >= r.code_blocks_cap) {
        const new_cap: usize = @intCast(r.code_blocks_cap * 2);
        const old = r.code_blocks.?[0..@intCast(r.code_blocks_cap)];
        const p = c_allocator.realloc(old, new_cap) catch return null;
        r.code_blocks = p.ptr;
        r.code_blocks_cap = @intCast(new_cap);
    }
    const idx: usize = @intCast(r.n_code_blocks);
    r.code_blocks.?[idx] = .{};
    return &r.code_blocks.?[idx];
}

fn code_meta_cleanup(r: *MD_HTML) void {
    if (r.code_blocks) |blocks| {
        // Free committed entries + the in-progress entry if parse was aborted.
        const count: usize = @intCast(r.n_code_blocks + (if (r.in_code_block != 0) @as(c_int, 1) else 0));
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (blocks[i].highlights) |h|
                c_allocator.free(h[0..blocks[i].highlight_count]);
        }
        c_allocator.free(blocks[0..@intCast(r.code_blocks_cap)]);
    }
}

const RawOutFn = ?*const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) callconv(.c) void;

fn emit_json_str(out: RawOutFn, ud: ?*anyopaque, str: [*]const u8, size: c.MD_SIZE) void {
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
            } else {
                // Other control chars: \u00XX
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

fn render_code_meta_json(r: *MD_HTML) void {
    // Flush buffered body content so the code-meta JSON (and the NUL byte that
    // precedes it) lands after the body in the final byte stream.
    flush_output(r);
    const out = r.real_process_output;
    const ud = r.userdata;
    var buf: [64]u8 = undefined;

    out.?("\x00", 1, ud);
    out.?("[", 1, ud);
    var i: usize = 0;
    while (i < @as(usize, @intCast(r.n_code_blocks))) : (i += 1) {
        const m = &r.code_blocks.?[i];
        if (i > 0) out.?(",", 1, ud);

        var s = std.fmt.bufPrint(&buf, "{{\"s\":{d},\"e\":{d}", .{ m.start, m.end }) catch unreachable;
        out.?(s.ptr, @intCast(s.len), ud);

        if (m.lang_size > 0) {
            out.?(",\"l\":", 5, ud);
            emit_json_str(out, ud, &m.lang, m.lang_size);
        }
        if (m.filename_size > 0) {
            out.?(",\"f\":", 5, ud);
            emit_json_str(out, ud, &m.filename, m.filename_size);
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
        out.?("}", 1, ud);
    }
    out.?("]", 1, ud);
}

fn render_open_alert_block(r: *MD_HTML, det: *const c.MD_BLOCK_ALERT_DETAIL) void {
    render_verbatim_lit(r, "<blockquote class=\"alert alert-");
    // Lowercase the type name for the CSS class.
    if (det.type_name.text != null) {
        var i: c.MD_SIZE = 0;
        while (i < det.type_name.size) : (i += 1) {
            var ch: u8 = @bitCast(det.type_name.text[i]);
            if (ch >= 'A' and ch <= 'Z')
                ch += 32;
            render_verbatim(r, @ptrCast(&ch), 1);
        }
    }
    render_verbatim_lit(r, "\">\n");
}

// *********************************************
// ***  Full-HTML frontmatter YAML helpers  ***
// *********************************************

fn fm_append(r: *MD_HTML, text: [*]const u8, size: c.MD_SIZE) c_int {
    if (r.fm_size + size > r.fm_cap) {
        const new_cap: c.MD_SIZE = r.fm_cap + r.fm_cap / 2 + size + 64;
        const p = buf_realloc(r.fm_text, r.fm_cap, new_cap) orelse return -1;
        r.fm_text = p;
        r.fm_cap = new_cap;
    }
    @memcpy(r.fm_text.?[r.fm_size .. r.fm_size + size], text[0..size]);
    r.fm_size += size;
    return 0;
}

// Parse YAML frontmatter and extract title/description.
// Caller must free *out_title and *out_description if non-NULL.
fn parse_frontmatter_meta(text: [*]const u8, size: c.MD_SIZE, out_title: *?[*:0]u8, out_description: *?[*:0]u8) void {
    var yp: sys.yaml_parser_t = undefined;
    var event: sys.yaml_event_t = undefined;

    out_title.* = null;
    out_description.* = null;

    if (sys.yaml_parser_initialize(&yp) == 0)
        return;

    sys.yaml_parser_set_input_string(&yp, @ptrCast(text), size);

    // Consume STREAM_START.
    if (sys.yaml_parser_parse(&yp, &event) == 0) {
        sys.yaml_parser_delete(&yp);
        return;
    }
    if (event.type != sys.YAML_STREAM_START_EVENT) {
        sys.yaml_event_delete(&event);
        sys.yaml_parser_delete(&yp);
        return;
    }
    sys.yaml_event_delete(&event);

    // Consume DOCUMENT_START.
    if (sys.yaml_parser_parse(&yp, &event) == 0) {
        sys.yaml_parser_delete(&yp);
        return;
    }
    if (event.type != sys.YAML_DOCUMENT_START_EVENT) {
        sys.yaml_event_delete(&event);
        sys.yaml_parser_delete(&yp);
        return;
    }
    sys.yaml_event_delete(&event);

    // Expect top-level MAPPING_START.
    if (sys.yaml_parser_parse(&yp, &event) == 0) {
        sys.yaml_parser_delete(&yp);
        return;
    }
    if (event.type != sys.YAML_MAPPING_START_EVENT) {
        sys.yaml_event_delete(&event);
        sys.yaml_parser_delete(&yp);
        return;
    }
    sys.yaml_event_delete(&event);

    // Iterate top-level key-value pairs.
    while (true) {
        var target: ?*?[*:0]u8 = null;

        if (sys.yaml_parser_parse(&yp, &event) == 0) {
            sys.yaml_parser_delete(&yp);
            return;
        }
        if (event.type == sys.YAML_MAPPING_END_EVENT) {
            sys.yaml_event_delete(&event);
            break;
        }
        if (event.type != sys.YAML_SCALAR_EVENT) {
            sys.yaml_event_delete(&event);
            sys.yaml_parser_delete(&yp);
            return;
        }

        // Check if key is "title" or "description".
        if (event.data.scalar.length == 5 and std.mem.eql(u8, event.data.scalar.value[0..5], "title")) {
            target = out_title;
        } else if (event.data.scalar.length == 11 and std.mem.eql(u8, event.data.scalar.value[0..11], "description")) {
            target = out_description;
        }
        sys.yaml_event_delete(&event);

        // Read the value.
        if (sys.yaml_parser_parse(&yp, &event) == 0) {
            sys.yaml_parser_delete(&yp);
            return;
        }

        if (target != null and event.type == sys.YAML_SCALAR_EVENT and event.data.scalar.length > 0) {
            const len: usize = event.data.scalar.length;
            const s = c_allocator.allocSentinel(u8, len, 0) catch null;
            if (s) |buf| {
                @memcpy(buf[0..len], event.data.scalar.value[0..len]);
                if (target.?.*) |old| c_allocator.free(std.mem.span(old));
                target.?.* = buf.ptr;
            }
        } else if (event.type == sys.YAML_MAPPING_START_EVENT or event.type == sys.YAML_SEQUENCE_START_EVENT) {
            // Skip nested structures.
            var depth: c_int = 1;
            sys.yaml_event_delete(&event);
            while (depth > 0) {
                if (sys.yaml_parser_parse(&yp, &event) == 0) {
                    sys.yaml_parser_delete(&yp);
                    return;
                }
                if (event.type == sys.YAML_MAPPING_START_EVENT or event.type == sys.YAML_SEQUENCE_START_EVENT)
                    depth += 1
                else if (event.type == sys.YAML_MAPPING_END_EVENT or event.type == sys.YAML_SEQUENCE_END_EVENT)
                    depth -= 1;
                sys.yaml_event_delete(&event);
            }
            continue;
        }
        sys.yaml_event_delete(&event);
    }

    sys.yaml_parser_delete(&yp);
}

// Emit the <!DOCTYPE html><html><head>...<body> preamble.
// Called lazily before the first body content in full-HTML mode.
fn ensure_head_emitted(r: *MD_HTML) void {
    var yaml_title: ?[*:0]u8 = null;
    var yaml_desc: ?[*:0]u8 = null;

    if (r.head_emitted != 0)
        return;
    r.head_emitted = 1;

    // Parse YAML frontmatter for title/description.
    if (r.fm_text != null and r.fm_size > 0)
        parse_frontmatter_meta(r.fm_text.?, r.fm_size, &yaml_title, &yaml_desc);

    // Explicit opts->title overrides YAML title.
    const title: ?[*:0]const u8 = if (r.opts != null and r.opts.?.title != null) r.opts.?.title else yaml_title;

    render_verbatim_lit(r, "<!DOCTYPE html>\n<html>\n<head>\n");

    render_verbatim_lit(r, "<title>");
    if (title) |t|
        render_html_escaped(r, t, @intCast(std.mem.len(t)));
    render_verbatim_lit(r, "</title>\n");

    render_verbatim_lit(r, "<meta name=\"generator\" content=\"md4x\">\n");

    // UTF-8 mode (default build): emit charset meta.
    render_verbatim_lit(r, "<meta charset=\"UTF-8\">\n");

    if (yaml_desc) |d| {
        render_verbatim_lit(r, "<meta name=\"description\" content=\"");
        render_html_escaped(r, d, @intCast(std.mem.len(d)));
        render_verbatim_lit(r, "\">\n");
    }

    if (r.opts != null and r.opts.?.css_url != null) {
        const css = r.opts.?.css_url.?;
        render_verbatim_lit(r, "<link rel=\"stylesheet\" href=\"");
        render_html_escaped(r, css, @intCast(std.mem.len(css)));
        render_verbatim_lit(r, "\">\n");
    }

    render_verbatim_lit(r, "</head>\n<body>\n");

    if (yaml_title) |t| c_allocator.free(std.mem.span(t));
    if (yaml_desc) |d| c_allocator.free(std.mem.span(d));
}

// **************************************
// ***  HTML renderer implementation  ***
// **************************************

fn enter_block_callback(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const head = [_][]const u8{ "<h1>", "<h2>", "<h3>", "<h4>", "<h5>", "<h6>" };
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));

    // Frontmatter: always suppress, capture text for full-HTML or component props.
    if (block_type == c.MD_BLOCK_FRONTMATTER) {
        r.in_frontmatter = 1;
        if (r.comp_fm_pending != 0) {
            r.comp_fm_capturing = 1;
        }
        return 0;
    }

    // If a component tag is pending and the next block is not frontmatter,
    // flush the buffered tag immediately.
    if (r.comp_fm_pending != 0 and block_type != c.MD_BLOCK_FRONTMATTER) {
        comp_fm_flush_tag(r);
    }

    // In full-HTML mode, emit <head> before first body content.
    if ((r.flags & MD_HTML_FLAG_FULL_HTML != 0) and block_type != c.MD_BLOCK_DOC)
        ensure_head_emitted(r);

    switch (block_type) {
        c.MD_BLOCK_DOC => {}, // noop
        c.MD_BLOCK_QUOTE => render_verbatim_lit(r, "<blockquote>\n"),
        c.MD_BLOCK_UL => render_verbatim_lit(r, "<ul>\n"),
        c.MD_BLOCK_OL => render_open_ol_block(r, @ptrCast(@alignCast(detail.?))),
        c.MD_BLOCK_LI => render_open_li_block(r, @ptrCast(@alignCast(detail.?))),
        c.MD_BLOCK_HR => render_verbatim_lit(r, "<hr>\n"),
        c.MD_BLOCK_H => {
            const det: *const c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail.?));
            render_verbatim_lit_runtime(r, head[det.level - 1]);
        },
        c.MD_BLOCK_CODE => {
            const det: *const c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(detail.?));
            render_open_code_block(r, det);
            if (r.flags & MD_HTML_FLAG_CODE_META != 0) {
                const meta = code_meta_push(r);
                if (meta != null) {
                    const m = meta.?;
                    m.start = r.output_offset;
                    if (det.lang.text != null and det.lang.size > 0) {
                        const sz: c.MD_SIZE = if (det.lang.size < m.lang.len) det.lang.size else @intCast(m.lang.len - 1);
                        @memcpy(m.lang[0..sz], @as([*]const u8, @ptrCast(det.lang.text))[0..sz]);
                        m.lang_size = sz;
                    }
                    if (det.filename.text != null and det.filename.size > 0) {
                        const sz: c.MD_SIZE = if (det.filename.size < m.filename.len) det.filename.size else @intCast(m.filename.len - 1);
                        @memcpy(m.filename[0..sz], @as([*]const u8, @ptrCast(det.filename.text))[0..sz]);
                        m.filename_size = sz;
                    }
                    if (det.highlights != null and det.highlight_count > 0) {
                        const h = c_allocator.alloc(c_uint, det.highlight_count) catch null;
                        if (h) |hp| {
                            @memcpy(hp[0..det.highlight_count], det.highlights[0..det.highlight_count]);
                            m.highlights = hp.ptr;
                            m.highlight_count = det.highlight_count;
                        }
                    }
                    r.in_code_block = 1;
                }
            }
        },
        c.MD_BLOCK_HTML => {}, // noop
        c.MD_BLOCK_P => render_verbatim_lit(r, "<p>"),
        c.MD_BLOCK_TABLE => render_verbatim_lit(r, "<table>\n"),
        c.MD_BLOCK_THEAD => render_verbatim_lit(r, "<thead>\n"),
        c.MD_BLOCK_TBODY => render_verbatim_lit(r, "<tbody>\n"),
        c.MD_BLOCK_TR => render_verbatim_lit(r, "<tr>\n"),
        c.MD_BLOCK_TH => render_open_td_block(r, "th", @ptrCast(@alignCast(detail.?))),
        c.MD_BLOCK_TD => render_open_td_block(r, "td", @ptrCast(@alignCast(detail.?))),
        c.MD_BLOCK_COMPONENT => {
            r.component_nesting += 1;
            render_open_block_component(r, @ptrCast(@alignCast(detail.?)));
        },
        c.MD_BLOCK_ALERT => render_open_alert_block(r, @ptrCast(@alignCast(detail.?))),
        c.MD_BLOCK_TEMPLATE => {
            const det: *const c.MD_BLOCK_TEMPLATE_DETAIL = @ptrCast(@alignCast(detail.?));
            render_verbatim_lit(r, "<template name=\"");
            render_attribute(r, &det.name, render_html_escaped);
            render_verbatim_lit(r, "\">\n");
        },
        else => {},
    }

    return 0;
}

// Runtime-string variant of render_verbatim_lit (for head[] table entries).
fn render_verbatim_lit_runtime(r: *MD_HTML, lit: []const u8) void {
    render_verbatim(r, lit.ptr, @intCast(lit.len));
}

fn leave_block_callback(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const head = [_][]const u8{ "</h1>\n", "</h2>\n", "</h3>\n", "</h4>\n", "</h5>\n", "</h6>\n" };
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));

    // Frontmatter: always suppress.
    if (block_type == c.MD_BLOCK_FRONTMATTER) {
        r.in_frontmatter = 0;
        if (r.comp_fm_capturing != 0) {
            // Component frontmatter done — flush the buffered tag with YAML attrs.
            comp_fm_flush_tag(r);
        }
        return 0;
    }

    switch (block_type) {
        c.MD_BLOCK_DOC => {
            if (r.flags & MD_HTML_FLAG_FULL_HTML != 0) {
                ensure_head_emitted(r);
                render_verbatim_lit(r, "</body>\n</html>\n");
            }
        },
        c.MD_BLOCK_QUOTE => render_verbatim_lit(r, "</blockquote>\n"),
        c.MD_BLOCK_UL => render_verbatim_lit(r, "</ul>\n"),
        c.MD_BLOCK_OL => render_verbatim_lit(r, "</ol>\n"),
        c.MD_BLOCK_LI => render_verbatim_lit(r, "</li>\n"),
        c.MD_BLOCK_HR => {}, // noop
        c.MD_BLOCK_H => {
            const det: *const c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail.?));
            render_verbatim_lit_runtime(r, head[det.level - 1]);
        },
        c.MD_BLOCK_CODE => {
            if ((r.flags & MD_HTML_FLAG_CODE_META != 0) and r.in_code_block != 0) {
                r.code_blocks.?[@intCast(r.n_code_blocks)].end = r.output_offset;
                r.n_code_blocks += 1;
                r.in_code_block = 0;
            }
            render_verbatim_lit(r, "</code></pre>\n");
        },
        c.MD_BLOCK_HTML => {}, // noop
        c.MD_BLOCK_P => render_verbatim_lit(r, "</p>\n"),
        c.MD_BLOCK_TABLE => render_verbatim_lit(r, "</table>\n"),
        c.MD_BLOCK_THEAD => render_verbatim_lit(r, "</thead>\n"),
        c.MD_BLOCK_TBODY => render_verbatim_lit(r, "</tbody>\n"),
        c.MD_BLOCK_TR => render_verbatim_lit(r, "</tr>\n"),
        c.MD_BLOCK_TH => render_verbatim_lit(r, "</th>\n"),
        c.MD_BLOCK_TD => render_verbatim_lit(r, "</td>\n"),
        c.MD_BLOCK_COMPONENT => {
            r.component_nesting -= 1;
            render_close_block_component(r, @ptrCast(@alignCast(detail.?)));
        },
        c.MD_BLOCK_ALERT => render_verbatim_lit(r, "</blockquote>\n"),
        c.MD_BLOCK_TEMPLATE => render_verbatim_lit(r, "</template>\n"),
        else => {},
    }

    return 0;
}

fn enter_span_callback(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));
    const inside_img = (r.image_nesting_level > 0);

    if (span_type == c.MD_SPAN_IMG)
        r.image_nesting_level += 1;
    if (inside_img)
        return 0;

    switch (span_type) {
        c.MD_SPAN_EM => {
            if (detail != null)
                render_open_tag_with_attrs(r, "em", @ptrCast(@alignCast(detail)))
            else
                render_verbatim_lit(r, "<em>");
        },
        c.MD_SPAN_STRONG => {
            if (detail != null)
                render_open_tag_with_attrs(r, "strong", @ptrCast(@alignCast(detail)))
            else
                render_verbatim_lit(r, "<strong>");
        },
        c.MD_SPAN_U => {
            if (detail != null)
                render_open_tag_with_attrs(r, "u", @ptrCast(@alignCast(detail)))
            else
                render_verbatim_lit(r, "<u>");
        },
        c.MD_SPAN_A => render_open_a_span(r, @ptrCast(@alignCast(detail.?))),
        c.MD_SPAN_IMG => render_open_img_span(r, @ptrCast(@alignCast(detail.?))),
        c.MD_SPAN_CODE => {
            if (detail != null)
                render_open_tag_with_attrs(r, "code", @ptrCast(@alignCast(detail)))
            else
                render_verbatim_lit(r, "<code>");
        },
        c.MD_SPAN_DEL => {
            if (detail != null)
                render_open_tag_with_attrs(r, "del", @ptrCast(@alignCast(detail)))
            else
                render_verbatim_lit(r, "<del>");
        },
        c.MD_SPAN_LATEXMATH => render_verbatim_lit(r, "<x-equation>"),
        c.MD_SPAN_LATEXMATH_DISPLAY => render_verbatim_lit(r, "<x-equation type=\"display\">"),
        c.MD_SPAN_WIKILINK => render_open_wikilink_span(r, @ptrCast(@alignCast(detail.?))),
        c.MD_SPAN_COMPONENT => render_open_component_span(r, @ptrCast(@alignCast(detail.?))),
        c.MD_SPAN_SPAN => render_open_span_span(r, @ptrCast(@alignCast(detail))),
        else => {},
    }

    return 0;
}

fn leave_span_callback(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));

    if (span_type == c.MD_SPAN_IMG)
        r.image_nesting_level -= 1;
    if (r.image_nesting_level > 0)
        return 0;

    switch (span_type) {
        c.MD_SPAN_EM => render_verbatim_lit(r, "</em>"),
        c.MD_SPAN_STRONG => render_verbatim_lit(r, "</strong>"),
        c.MD_SPAN_U => render_verbatim_lit(r, "</u>"),
        c.MD_SPAN_A => render_verbatim_lit(r, "</a>"),
        c.MD_SPAN_IMG => render_close_img_span(r, @ptrCast(@alignCast(detail.?))),
        c.MD_SPAN_CODE => render_verbatim_lit(r, "</code>"),
        c.MD_SPAN_DEL => render_verbatim_lit(r, "</del>"),
        c.MD_SPAN_LATEXMATH, c.MD_SPAN_LATEXMATH_DISPLAY => render_verbatim_lit(r, "</x-equation>"),
        c.MD_SPAN_WIKILINK => render_verbatim_lit(r, "</x-wikilink>"),
        c.MD_SPAN_COMPONENT => render_close_component_span(r, @ptrCast(@alignCast(detail.?))),
        c.MD_SPAN_SPAN => render_verbatim_lit(r, "</span>"),
        else => {},
    }

    return 0;
}

fn text_callback(text_type: c.MD_TEXTTYPE, text_in: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) c_int {
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));
    const text: [*]const u8 = @ptrCast(text_in);

    // Frontmatter text: capture for full-HTML or component frontmatter, always suppress output.
    if (r.in_frontmatter != 0) {
        if (r.comp_fm_capturing != 0)
            _ = comp_fm_text_append(r, text, size)
        else if ((r.flags & MD_HTML_FLAG_FULL_HTML != 0) and r.component_nesting == 0)
            _ = fm_append(r, text, size);
        return 0;
    }

    switch (text_type) {
        c.MD_TEXT_NULLCHAR => render_utf8_codepoint(r, 0x0000, render_verbatim),
        c.MD_TEXT_BR => render_verbatim_lit_runtime(r, if (r.image_nesting_level == 0) "<br>\n" else " "),
        c.MD_TEXT_SOFTBR => render_verbatim_lit_runtime(r, if (r.image_nesting_level == 0) "\n" else " "),
        c.MD_TEXT_HTML => render_verbatim(r, text, size),
        c.MD_TEXT_ENTITY => render_entity(r, text, size, render_html_escaped),
        else => render_html_escaped(r, text, size),
    }

    return 0;
}

fn debug_log_callback(msg: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));
    if (r.flags & MD_HTML_FLAG_DEBUG != 0)
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
        const p = buf_realloc(buf.data, buf.cap, new_cap) orelse {
            buf.err = 1;
            return;
        };
        buf.data = p;
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
    if (buf.data) |d| {
        c_allocator.free(d[0..buf.cap]);
    }
}

// Shared realloc helper that tracks the old capacity (the c_allocator needs a
// sized slice). Returns null on OOM, leaving the original allocation intact.
fn buf_realloc(old_ptr: ?[*]u8, old_cap: c_uint, new_cap: c_uint) ?[*]u8 {
    if (old_ptr) |old| {
        const p = c_allocator.realloc(old[0..old_cap], new_cap) catch return null;
        return p.ptr;
    } else {
        const p = c_allocator.alloc(u8, new_cap) catch return null;
        return p.ptr;
    }
}

export fn md_html_ex(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
    opts: ?*const MD_HTML_OPTS,
) callconv(.c) c_int {
    var input_ptr = input;
    var size = input_size;

    // Heal-before-render: run md_heal first, then render the healed output.
    if (renderer_flags & MD_HTML_FLAG_HEAL != 0) {
        var hbuf: MD4X_HEAL_BUF = undefined;
        if (md4x_heal_input(input, input_size, &hbuf) != 0) {
            heal_buf_free(&hbuf);
            return -1;
        }
        const ret = md_html_ex(@ptrCast(hbuf.data), hbuf.size, process_output, userdata, parser_flags, renderer_flags & ~MD_HTML_FLAG_HEAL, opts);
        heal_buf_free(&hbuf);
        return ret;
    }

    var render: MD_HTML = .{};
    render.process_output = process_output;
    render.real_process_output = process_output;
    render.userdata = userdata;
    render.flags = renderer_flags;
    render.opts = opts;

    var parser: c.MD_PARSER = std.mem.zeroes(c.MD_PARSER);
    parser.flags = parser_flags;
    parser.enter_block = enter_block_callback;
    parser.leave_block = leave_block_callback;
    parser.enter_span = enter_span_callback;
    parser.leave_span = leave_span_callback;
    parser.text = text_callback;
    parser.debug_log = debug_log_callback;

    // Consider skipping UTF-8 byte order mark (BOM).
    if (renderer_flags & MD_HTML_FLAG_SKIP_UTF8_BOM != 0 and @sizeOf(c.MD_CHAR) == 1) {
        const bom = [_]u8{ 0xef, 0xbb, 0xbf };
        if (size >= bom.len and std.mem.eql(u8, @as([*]const u8, @ptrCast(input_ptr))[0..bom.len], &bom)) {
            input_ptr += bom.len;
            size -= bom.len;
        }
    }

    const ret = c.md_parse(@ptrCast(input_ptr), size, &parser, @ptrCast(&render));

    if (renderer_flags & MD_HTML_FLAG_CODE_META != 0) {
        if (ret == 0)
            render_code_meta_json(&render); // flushes out_buf internally before JSON
        code_meta_cleanup(&render);
    }

    // Flush any remaining buffered body bytes (render_code_meta_json already
    // flushed the body before appending JSON when CODE_META is set).
    flush_output(&render);
    if (render.out_buf) |p| c_allocator.free(p[0..render.out_cap]);

    if (render.fm_text) |p| c_allocator.free(p[0..render.fm_cap]);
    if (render.comp_fm_tag) |p| c_allocator.free(p[0..render.comp_fm_tag_cap]);
    if (render.comp_fm_text) |p| c_allocator.free(p[0..render.comp_fm_text_cap]);

    return ret;
}

export fn md_html(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) callconv(.c) c_int {
    return md_html_ex(input, input_size, process_output, userdata, parser_flags, renderer_flags, null);
}

// strchr equivalent matching C semantics: C's strchr() also matches the
// terminating NUL, so strchr(set, 0) returns non-NULL → true here.
fn strchr(comptime set: []const u8, ch: u8) bool {
    if (ch == 0) return true;
    for (set) |s| {
        if (s == ch) return true;
    }
    return false;
}
