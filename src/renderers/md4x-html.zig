// MD4X: Markdown parser for C
// (https://github.com/unjs/md4x)
//
// Copyright (c) 2016-2026 Martin Mitáš
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
const scan = @import("../scan.zig");

// MD_* types now come from the Zig-native
// abi module (replacing md4x.h / entity.h / md4x-heal.h).
const c = @import("abi");
// Sibling units are imported directly (one Zig module per artifact), not
// resolved through link-time C-ABI symbols. `abi` holds types only.
const md4x = @import("../md4x.zig");
const entity = @import("../entity.zig");
const heal = @import("md4x-heal.zig");
// No @cImport here any more: the last C dependency was libyaml, and the YAML
// frontmatter helpers below now go through the pure-Zig port in src/yaml/.
const yaml = @import("../yaml/yaml.zig");
const diag = @import("md4x-diag.zig");

const c_allocator = std.heap.c_allocator;

// --- Renderer flags (mirror md4x-html.h) ---
const MD_HTML_FLAG_DEBUG: c_uint = 0x0001;
const MD_HTML_FLAG_VERBATIM_ENTITIES: c_uint = 0x0002;
const MD_HTML_FLAG_SKIP_UTF8_BOM: c_uint = 0x0004;
const MD_HTML_FLAG_FULL_HTML: c_uint = 0x0008;
const MD_HTML_FLAG_CODE_META: c_uint = 0x0010;
const MD_HTML_FLAG_HEAL: c_uint = 0x0100;

const NEED_URL_ESC_FLAG: u8 = 0x2;

// Map of characters which need escaping. Input-independent, so computed once at
// comptime. Reproduces exactly the previous per-call runtime construction
// (including strchr's C semantics where strchr(set, 0) matches the NUL byte).
//
// Only the URL-escape bit survives. The HTML-escape bit (0x1, over `" & < >`)
// is gone because nothing reads it any more: `next_html_esc` recognizes those
// four bytes directly so the scan can be vectorized, and a table lookup cannot
// be. The bit value 0x2 is kept as-is rather than renumbered to 0x1, purely so
// this stays a deletion and not a silent change to what the map holds.
const ESCAPE_MAP: [256]u8 = blk: {
    @setEvalBranchQuota(10000);
    var map = [_]u8{0} ** 256;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const ch: u8 = @intCast(i);
        if (!ISALNUM(ch) and !strchr("~-_.+!*(),%#@?=;:/,+$", ch))
            map[i] |= NEED_URL_ESC_FLAG;
    }
    break :blk map;
};

/// Options for `md_html_ex` (full-document mode). Re-exported by lib.zig.
pub const MD_HTML_OPTS = extern struct {
    title: ?[*:0]const u8 = null,
    css_url: ?[*:0]const u8 = null,
};

// Non-optional — see the note on `md4x-json.zig`'s ProcessOutputFn. Every sink
// call below is unconditional, so a null callback was a null-function-pointer
// call rather than a no-op; `MD_HTML` therefore carries no default for the two
// sink fields, making an unset one a compile error at the construction site.
const ProcessOutputFn = *const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void;

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
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque = null,
    flags: c_uint = 0,
    image_nesting_level: c_int = 0,

    // Frontmatter suppression state.
    in_frontmatter: bool = false,
    component_nesting: c_int = 0,

    // Component frontmatter: deferred open tag.
    comp_fm_pending: bool = false,
    comp_fm_capturing: bool = false,
    comp_fm_tag: ?[*]u8 = null,
    comp_fm_tag_size: c.MD_SIZE = 0,
    comp_fm_tag_cap: c.MD_SIZE = 0,
    comp_fm_text: ?[*]u8 = null,
    comp_fm_text_size: c.MD_SIZE = 0,
    comp_fm_text_cap: c.MD_SIZE = 0,

    // Full-HTML mode state.
    opts: ?*const MD_HTML_OPTS = null,
    head_emitted: bool = false,

    // Frontmatter YAML capture buffer (allocated only when FULL_HTML).
    fm_text: ?[*]u8 = null,
    fm_size: c.MD_SIZE = 0,
    fm_cap: c.MD_SIZE = 0,

    // Code block metadata tracking.
    output_offset: c.MD_SIZE = 0,
    in_code_block: bool = false,
    code_blocks: ?[*]MD_HTML_CODE_META = null,
    n_code_blocks: c_int = 0,
    code_blocks_cap: c_int = 0,

    // Internal output buffer: batches render_verbatim appends into a single
    // process_output callback to reduce per-call overhead. `real_process_output`
    // holds the caller's original callback; `process_output` may be temporarily
    // swapped (e.g. to comp_fm_tag_capture) — buffering is bypassed while swapped.
    real_process_output: ProcessOutputFn,
    out_buf: ?[*]u8 = null,
    out_size: c.MD_SIZE = 0,
    out_cap: c.MD_SIZE = 0,
};

// Flush threshold: when the internal buffer reaches this size, emit it.
const OUT_BUF_THRESHOLD: c.MD_SIZE = 8 * 1024;

// ***  `output_offset` invariant  ***
//
// `output_offset` is the number of BODY bytes committed to the caller's output
// stream so far; MD_HTML_CODE_META.start/.end are snapshots of it. Every byte
// must be counted EXACTLY ONCE, at the moment it is committed to the
// caller-bound stream — that is, in `out_buf_append` (buffered or the direct
// OOM fallback) and in `emit` (direct). Consequently:
//
//   * `flush_output` does NOT count: it only drains bytes `out_buf_append`
//     already counted.
//   * `render_verbatim` does NOT count: when it is not diverted it delegates to
//     `out_buf_append`, and when `process_output` HAS been swapped to a capture
//     callback the bytes are going into `comp_fm_tag`, not to the caller — they
//     are counted when that buffer is later handed to `emit`. Counting there
//     too would count them twice.
//   * `render_code_meta_json` deliberately bypasses both helpers. It is the
//     trailer emitted after the body, once every recorded offset is final.
//
// Counting used to live in `render_verbatim` alone, which missed the bytes
// `render_open_block_component` appends straight into `comp_fm_tag` ("<", the
// tag name, ` title="` and `"`) — so every code block after a block component
// reported offsets short by those bytes, cumulatively.

// Append bytes to the internal output buffer, flushing to real_process_output
// when the threshold is exceeded. Falls back to a direct call on OOM so output
// is never silently dropped.
fn out_buf_append(r: *MD_HTML, text: [*]const u8, size: c.MD_SIZE) void {
    if (r.flags & MD_HTML_FLAG_CODE_META != 0)
        r.output_offset += size;
    if (r.out_size + size > r.out_cap) {
        const new_cap: c.MD_SIZE = r.out_cap + r.out_cap / 2 + size + OUT_BUF_THRESHOLD;
        const p = buf_realloc(r.out_buf, r.out_cap, new_cap);
        if (p == null) {
            // OOM: flush what we have, then emit directly (no buffering).
            flush_output(r);
            r.real_process_output(@ptrCast(text), size, r.userdata);
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
        r.real_process_output(@ptrCast(r.out_buf.?), r.out_size, r.userdata);
        r.out_size = 0;
    }
}

// Flush the internal buffer, then emit bytes directly via the real callback.
// Used by direct-output paths (comp_fm_flush_tag) so their output lands in the
// correct position relative to buffered body content. Counts towards
// `output_offset` — see the invariant above.
fn emit(r: *MD_HTML, text: [*]const u8, size: c.MD_SIZE) void {
    flush_output(r);
    if (r.flags & MD_HTML_FLAG_CODE_META != 0)
        r.output_offset += size;
    r.real_process_output(@ptrCast(text), size, r.userdata);
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
    //
    // Note this function does NOT touch `output_offset`: the buffered branch is
    // counted by out_buf_append, and the swapped branch is not reaching the
    // caller at all (it is counted when the capture buffer is emit()-ed).
    if (r.process_output == r.real_process_output) {
        out_buf_append(r, text, size);
    } else {
        r.process_output(@ptrCast(text), size, r.userdata);
    }
}

fn render_verbatim_lit(r: *MD_HTML, comptime lit: []const u8) void {
    render_verbatim(r, lit.ptr, @intCast(lit.len));
}

// Find the next offset >= `start` whose byte needs HTML-escaping (one of
// `" & < >`), or `size` if none — the same four bytes `render_html_escaped`
// switches on just below, which is the one place they are now spelled out.
//
// This was previously a hand-written `@Vector(16, u8)` loop with no fallback,
// which was a pessimization on the WASM build: with no `simd128` feature LLVM
// scalarizes such a loop into 16 unconditional compares and the early exit is
// lost. `scan.indexOfAnyPos` gates the vector body on the target actually
// having a vector unit. See src/scan.zig.
fn next_html_esc(data: [*]const u8, start: c.MD_OFFSET, size: c.MD_SIZE) c.MD_OFFSET {
    return @intCast(scan.indexOfAnyPos("&<>\"", null, data, start, size));
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

// Emit `data` as an HTML attribute NAME.
//
// `render_html_escaped` neutralizes the bytes that break out of an attribute
// *value* (`& < > "`). An attribute *name* ends at a different set entirely:
// per the HTML tokenizer's attribute-name state, whitespace (TAB LF FF CR SP),
// `/`, `=` and `>` all terminate it. So a name emitted with value escaping only
// is not guaranteed to stay ONE attribute — a component key of
// `x onload=alert(1)//` tokenizes into `x` plus a live `onload` handler the
// document never wrote.
//
// Both name-emitting sites (a YAML component-frontmatter key, a `{props}` key)
// mean the key to be exactly one inert attribute name, so make that structural:
// percent-encode every byte that is not inert inside a name, and hand the rest
// to `render_html_escaped` so `& < > "` keep their existing entity spelling.
// The encoded set is `ch <= 0x20` (every C0 control plus SP, which covers all
// five HTML whitespace terminators), DEL, `/` and `=`; `>` is already an entity
// by the time a browser sees it. Bytes >= 0x80 pass through untouched, so a
// non-ASCII key such as `título` is unaffected.
//
// Percent-encoding rather than dropping the pair keeps this renderer in
// agreement with the AST renderer about which keys are *acceptable* — both
// still emit every key the YAML/props parser produced, one as an inert
// attribute name and one as a JSON string. See the commit that added this.
fn render_html_attr_name(r: *MD_HTML, data: [*]const u8, size: c.MD_SIZE) void {
    const hex_chars = "0123456789ABCDEF";
    var beg: c.MD_OFFSET = 0;
    var off: c.MD_OFFSET = 0;

    while (off < size) : (off += 1) {
        const ch = data[off];
        if (!(ch <= 0x20 or ch == 0x7f or ch == '/' or ch == '='))
            continue;

        if (off > beg)
            render_html_escaped(r, data + beg, off - beg);

        const esc = [3]u8{ '%', hex_chars[ch >> 4], hex_chars[ch & 0xf] };
        render_verbatim(r, &esc, 3);
        beg = off + 1;
    }

    if (off > beg)
        render_html_escaped(r, data + beg, off - beg);
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

    // Surrogates (U+D800..U+DFFF) are not Unicode scalar values, so encoding
    // them as an ordinary 3-byte sequence yields malformed UTF-8. CommonMark
    // requires them -- like U+0000 -- to be rendered as U+FFFD.
    if (0 < codepoint and codepoint <= 0x10ffff and
        (codepoint < 0xd800 or codepoint > 0xdfff))
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

fn render_attribute(r: *MD_HTML, attr: *const c.Attribute, fn_append: AppendFn) void {
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

fn render_open_ol_block(r: *MD_HTML, det: *const c.BlockOlDetail) void {
    if (det.start == 1) {
        render_verbatim_lit(r, "<ol>\n");
        return;
    }

    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "<ol start=\"{d}\">\n", .{det.start}) catch unreachable;
    render_verbatim(r, s.ptr, @intCast(s.len));
}

// `[^1]` -> `<sup><a href="#fn-1" id="fnref-1-1">1</a></sup>`. The span is
// self-contained (no text callbacks between enter and leave), so the whole
// markup is emitted here and leave_span is a no-op. md4c a8b0d3e.
fn render_open_footnote_ref_span(r: *MD_HTML, det: *const c.SpanFootnoteRefDetail) void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "<sup><a href=\"#fn-{d}\" id=\"fnref-{d}-{d}\">{d}</a></sup>", .{ det.id, det.id, det.ref_id, det.id }) catch unreachable;
    render_verbatim(r, s.ptr, @intCast(s.len));
}

fn render_open_footnote_def_block(r: *MD_HTML, det: *const c.BlockFootnoteDefDetail) void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "<li id=\"fn-{d}\">\n", .{det.id}) catch unreachable;
    render_verbatim(r, s.ptr, @intCast(s.len));
}

// One back-reference anchor per reference, so every `[^1]` occurrence in the
// document has a link back to it.
fn render_close_footnote_def_block(r: *MD_HTML, det: *const c.BlockFootnoteDefDetail) void {
    var buf: [128]u8 = undefined;
    var ref_index: c_uint = 1;
    while (ref_index <= det.ref_count) : (ref_index += 1) {
        if (ref_index > 1) render_verbatim_lit(r, " ");
        const s = std.fmt.bufPrint(&buf, "<a href=\"#fnref-{d}-{d}\" class=\"footnote-backref\">&#8617;</a>", .{ det.id, ref_index }) catch unreachable;
        render_verbatim(r, s.ptr, @intCast(s.len));
    }
    render_verbatim_lit(r, "\n</li>\n");
}

fn render_open_li_block(r: *MD_HTML, det: *const c.BlockLiDetail) void {
    if (det.is_task) {
        render_verbatim_lit(r, "<li class=\"task-list-item\">" ++
            "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled");
        if (det.task_mark == 'x' or det.task_mark == 'X')
            render_verbatim_lit(r, " checked");
        render_verbatim_lit(r, ">");
    } else {
        render_verbatim_lit(r, "<li>");
    }
}

fn render_open_code_block(r: *MD_HTML, det: *const c.BlockCodeDetail) void {
    render_verbatim_lit(r, "<pre><code");

    // If known, output the HTML 5 attribute class="language-LANGNAME".
    if (det.lang.text.len > 0) {
        render_verbatim_lit(r, " class=\"");
        // Do not repeat the prefix if the info string already carries it.
        if (!std.mem.startsWith(u8, det.lang.text, "language-"))
            render_verbatim_lit(r, "language-");
        render_attribute(r, &det.lang, render_html_escaped);
        render_verbatim_lit(r, "\"");
    }

    render_verbatim_lit(r, ">");
}

fn render_open_td_block(r: *MD_HTML, comptime cell_type: []const u8, det: *const c.BlockTdDetail) void {
    render_verbatim_lit(r, "<");
    render_verbatim_lit(r, cell_type);

    switch (det.@"align") {
        c.Align.left => render_verbatim_lit(r, " align=\"left\">"),
        c.Align.center => render_verbatim_lit(r, " align=\"center\">"),
        c.Align.right => render_verbatim_lit(r, " align=\"right\">"),
        else => render_verbatim_lit(r, ">"),
    }
}

fn render_open_a_span(r: *MD_HTML, det: *const c.SpanADetail) void {
    render_verbatim_lit(r, "<a href=\"");
    render_attribute(r, &det.href, render_url_escaped);

    if (det.title.text.len > 0) {
        render_verbatim_lit(r, "\" title=\"");
        render_attribute(r, &det.title, render_html_escaped);
    }

    render_verbatim_lit(r, "\"");
    if (det.raw_attrs.len > 0)
        render_html_component_props(r, det.raw_attrs.ptr, @intCast(det.raw_attrs.len));
    render_verbatim_lit(r, ">");
}

fn render_open_img_span(r: *MD_HTML, det: *const c.SpanImgDetail) void {
    render_verbatim_lit(r, "<img src=\"");
    render_attribute(r, &det.src, render_url_escaped);

    render_verbatim_lit(r, "\" alt=\"");
}

fn render_close_img_span(r: *MD_HTML, det: *const c.SpanImgDetail) void {
    if (det.title.text.len > 0) {
        render_verbatim_lit(r, "\" title=\"");
        render_attribute(r, &det.title, render_html_escaped);
    }

    render_verbatim_lit(r, "\"");
    if (det.raw_attrs.len > 0)
        render_html_component_props(r, det.raw_attrs.ptr, @intCast(det.raw_attrs.len));
    render_verbatim_lit(r, ">");
}

fn render_open_wikilink_span(r: *MD_HTML, det: *const c.SpanWikilinkDetail) void {
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
        render_html_attr_name(r, p.key, p.key_size);

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
fn render_open_tag_with_attrs(r: *MD_HTML, comptime tag: []const u8, det: *const c.SpanAttrsDetail) void {
    render_verbatim_lit(r, "<");
    render_verbatim_lit(r, tag);
    if (det.raw_attrs.len > 0)
        render_html_component_props(r, det.raw_attrs.ptr, @intCast(det.raw_attrs.len));
    render_verbatim_lit(r, ">");
}

// Render opening tag for [text]{attrs} span.
fn render_open_span_span(r: *MD_HTML, det: *const c.SpanSpanDetail) void {
    render_verbatim_lit(r, "<span");
    if (det.raw_attrs.len > 0)
        render_html_component_props(r, det.raw_attrs.ptr, @intCast(det.raw_attrs.len));
    render_verbatim_lit(r, ">");
}

fn render_open_component_span(r: *MD_HTML, det: *const c.SpanComponentDetail) void {
    render_verbatim_lit(r, "<");
    render_attribute(r, &det.tag_name, render_html_escaped);
    if (det.raw_props.len > 0)
        render_html_component_props(r, det.raw_props.ptr, @intCast(det.raw_props.len));
    render_verbatim_lit(r, ">");
}

fn render_close_component_span(r: *MD_HTML, det: *const c.SpanComponentDetail) void {
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
fn comp_fm_tag_capture(text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) void {
    _ = comp_fm_tag_append(@ptrCast(@alignCast(userdata.?)), @ptrCast(text), size);
}

// `yaml_parser_parse(&yp, &event) != 0` in boolean position: the C's status
// return is what the two frontmatter walkers below chain their `and`s over, and
// an `Error!void` cannot be chained that way. Failure leaves `event` erased —
// the port clears it on entry exactly as libyaml's `memset` did — so a caller
// that deletes the event afterwards still deletes nothing.
fn parse_ok(yp: *yaml.Parser, event: *yaml.Event) bool {
    yaml.parse(yp, event) catch return false;
    return true;
}

// Flush the buffered component open tag. If YAML text was captured,
// parse it and emit as HTML attributes before closing ">".
fn comp_fm_flush_tag(r: *MD_HTML) void {
    // Reset the deferred-tag state BEFORE the "nothing buffered" early return.
    // comp_fm_tag_append's -1 (OOM) return is discarded at every call site in
    // render_open_block_component, so a failure on the very first append leaves
    // comp_fm_tag_size at 0. With the resets at the end of this function that
    // early return would latch comp_fm_pending / comp_fm_capturing true for the
    // rest of the document: the component's ">" would never be emitted while
    // render_close_block_component still emits "</name>", and every subsequent
    // frontmatter block would keep accumulating into comp_fm_text.
    const tag = r.comp_fm_tag;
    const tag_size = r.comp_fm_tag_size;
    const text_size = r.comp_fm_text_size;
    r.comp_fm_tag_size = 0;
    r.comp_fm_text_size = 0;
    r.comp_fm_pending = false;
    r.comp_fm_capturing = false;

    if (tag == null or tag_size == 0)
        return;

    // Emit the buffered tag prefix (e.g. "<card ...props").
    emit(r, tag.?, tag_size);

    // If we captured YAML, parse and emit as attributes.
    if (r.comp_fm_text != null and text_size > 0) {
        var event: yaml.Event = .{};

        if (yaml.init(c_allocator)) |init_yp| {
            var yp = init_yp;
            yaml.setInputString(&yp, r.comp_fm_text.?[0..text_size]);

            // STREAM_START
            if (parse_ok(&yp, &event) and event.data == .stream_start) {
                event.deinit(c_allocator);
                // DOCUMENT_START
                if (parse_ok(&yp, &event) and event.data == .document_start) {
                    event.deinit(c_allocator);
                    // MAPPING_START
                    if (parse_ok(&yp, &event) and event.data == .mapping_start) {
                        event.deinit(c_allocator);
                        // Iterate key-value pairs.
                        while (parse_ok(&yp, &event)) {
                            var key_buf: [256]u8 = undefined;
                            if (event.data == .mapping_end) {
                                event.deinit(c_allocator);
                                break;
                            }
                            const key = switch (event.data) {
                                .scalar => |d| d.value,
                                else => {
                                    event.deinit(c_allocator);
                                    break;
                                },
                            };
                            var key_len: usize = key.len;
                            if (key_len >= key_buf.len) key_len = key_buf.len - 1;
                            @memcpy(key_buf[0..key_len], key[0..key_len]);
                            key_buf[key_len] = 0;
                            event.deinit(c_allocator);

                            // Read value.
                            if (!parse_ok(&yp, &event)) break;
                            if (event.data == .scalar) {
                                // An EMPTY key (`"": v`) is the one key HTML has
                                // no spelling for — there is no encoding of a
                                // zero-length attribute name — so drop the pair
                                // rather than emit the malformed ` ="v"`, which
                                // a browser recovers from by inventing an
                                // attribute literally named `="v"`.
                                if (key_len > 0) {
                                    const val = event.data.scalar.value;
                                    render_verbatim_lit(r, " ");
                                    render_html_attr_name(r, &key_buf, @intCast(key_len));
                                    render_verbatim_lit(r, "=\"");
                                    render_html_escaped(r, val.ptr, @intCast(val.len));
                                    render_verbatim_lit(r, "\"");
                                }
                            } else if (event.data == .mapping_start or event.data == .sequence_start) {
                                // Skip nested structures.
                                var depth: c_int = 1;
                                event.deinit(c_allocator);
                                while (depth > 0 and parse_ok(&yp, &event)) {
                                    if (event.data == .mapping_start or event.data == .sequence_start)
                                        depth += 1
                                    else if (event.data == .mapping_end or event.data == .sequence_end)
                                        depth -= 1;
                                    event.deinit(c_allocator);
                                }
                                continue;
                            }
                            event.deinit(c_allocator);
                        }
                    } else {
                        event.deinit(c_allocator);
                    }
                } else {
                    event.deinit(c_allocator);
                }
            } else {
                event.deinit(c_allocator);
            }
            yaml.deinit(&yp);
        } else |_| {}
    }

    render_verbatim_lit(r, ">\n");
}

fn render_open_block_component(r: *MD_HTML, det: *const c.BlockComponentDetail) void {
    // Buffer the open tag (without closing ">") so we can append
    // frontmatter YAML attributes if a frontmatter block follows.
    r.comp_fm_tag_size = 0;
    r.comp_fm_text_size = 0;
    _ = comp_fm_tag_append(r, "<", 1);

    // Append tag name, through render_attribute(..., render_html_escaped) with
    // the capture callback swapped in — the same route the title takes below,
    // and symmetric with render_close_block_component's `</name>`. This site
    // used to memcpy the attribute's raw substring bytes, escaping nothing and
    // decoding no `.entity` substring.
    //
    // Currently that is unreachable rather than exploitable: the parser bounds a
    // component name to `[a-zA-Z][a-zA-Z0-9-]*` (`md_is_block_component_opener`
    // in blocks.zig), so a name carries exactly one `.normal` substring with no
    // `& < > "` in it and both spellings emit identical bytes — verified by
    // scripts/diff-corpus.sh. It is changed defensively because the asymmetry is
    // a trap if that charset ever widens: the opener is the half where a name
    // would break out of the tag it is opening.
    {
        const saved_output = r.process_output;
        const saved_ud = r.userdata;
        r.process_output = comp_fm_tag_capture;
        r.userdata = r;
        render_attribute(r, &det.tag_name, render_html_escaped);
        r.process_output = saved_output;
        r.userdata = saved_ud;
    }

    // Append title as attribute if present.
    if (det.title.len > 0) {
        _ = comp_fm_tag_append(r, " title=\"", 8);
        {
            const saved_output = r.process_output;
            const saved_ud = r.userdata;
            r.process_output = comp_fm_tag_capture;
            r.userdata = r;
            render_html_escaped(r, det.title.ptr, @intCast(det.title.len));
            r.process_output = saved_output;
            r.userdata = saved_ud;
        }
        _ = comp_fm_tag_append(r, "\"", 1);
    }

    // Append {props} if present.
    if (det.raw_props.len > 0) {
        // Render props to a temp buffer by capturing output.
        const saved_output = r.process_output;
        const saved_ud = r.userdata;
        r.process_output = comp_fm_tag_capture;
        r.userdata = r;
        render_html_component_props(r, det.raw_props.ptr, @intCast(det.raw_props.len));
        r.process_output = saved_output;
        r.userdata = saved_ud;
    }

    r.comp_fm_pending = true;
}

fn render_close_block_component(r: *MD_HTML, det: *const c.BlockComponentDetail) void {
    // Flush pending open tag if it was never flushed (empty component).
    if (r.comp_fm_pending)
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
        const count: usize = @intCast(r.n_code_blocks + @as(c_int, @intFromBool(r.in_code_block)));
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (blocks[i].highlights) |h|
                c_allocator.free(h[0..blocks[i].highlight_count]);
        }
        c_allocator.free(blocks[0..@intCast(r.code_blocks_cap)]);
    }
}

fn emit_json_str(out: ProcessOutputFn, ud: ?*anyopaque, str: [*]const u8, size: c.MD_SIZE) void {
    var i: c.MD_SIZE = 0;
    var beg: c.MD_SIZE = 0;
    out("\"", 1, ud);
    while (i < size) : (i += 1) {
        const ch: u8 = str[i];
        if (ch == '"' or ch == '\\' or ch < 0x20) {
            if (i > beg)
                out(@ptrCast(str + beg), i - beg, ud);
            if (ch == '"' or ch == '\\') {
                out("\\", 1, ud);
                out(@ptrCast(str + i), 1, ud);
            } else if (ch == '\n') {
                out("\\n", 2, ud);
            } else if (ch == '\r') {
                out("\\r", 2, ud);
            } else if (ch == '\t') {
                out("\\t", 2, ud);
            } else {
                // Other control chars: \u00XX
                const hex = "0123456789abcdef";
                const esc = [_]u8{ '\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 0xf] };
                out(&esc, 6, ud);
            }
            beg = i + 1;
        }
    }
    if (i > beg)
        out(@ptrCast(str + beg), i - beg, ud);
    out("\"", 1, ud);
}

fn render_code_meta_json(r: *MD_HTML) void {
    // Flush buffered body content so the code-meta JSON (and the NUL byte that
    // precedes it) lands after the body in the final byte stream.
    flush_output(r);
    const out = r.real_process_output;
    const ud = r.userdata;
    var buf: [64]u8 = undefined;

    out("\x00", 1, ud);
    out("[", 1, ud);
    var i: usize = 0;
    while (i < @as(usize, @intCast(r.n_code_blocks))) : (i += 1) {
        const m = &r.code_blocks.?[i];
        if (i > 0) out(",", 1, ud);

        var s = std.fmt.bufPrint(&buf, "{{\"s\":{d},\"e\":{d}", .{ m.start, m.end }) catch unreachable;
        out(s.ptr, @intCast(s.len), ud);

        if (m.lang_size > 0) {
            out(",\"l\":", 5, ud);
            emit_json_str(out, ud, &m.lang, m.lang_size);
        }
        if (m.filename_size > 0) {
            out(",\"f\":", 5, ud);
            emit_json_str(out, ud, &m.filename, m.filename_size);
        }
        if (m.highlight_count > 0) {
            out(",\"h\":[", 6, ud);
            var j: c_uint = 0;
            while (j < m.highlight_count) : (j += 1) {
                if (j > 0) out(",", 1, ud);
                s = std.fmt.bufPrint(&buf, "{d}", .{m.highlights.?[j]}) catch unreachable;
                out(s.ptr, @intCast(s.len), ud);
            }
            out("]", 1, ud);
        }
        out("}", 1, ud);
    }
    out("]", 1, ud);
}

fn render_open_alert_block(r: *MD_HTML, det: *const c.BlockAlertDetail) void {
    render_verbatim_lit(r, "<blockquote class=\"alert alert-");
    // Lowercase the type name for the CSS class.
    //
    // Emitted in chunks, not byte by byte: every single-byte render_verbatim
    // ran a full out_buf_append (capacity check, 1-byte @memcpy, flush-threshold
    // check) for one character. The parser puts NO length cap on the `[!TYPE]`
    // name (blocks.zig accepts `[a-zA-Z0-9_-]*` up to the `]`), so this loops
    // over the buffer rather than assuming the name fits in it — a longer name
    // takes several chunks and is never truncated.
    //
    // The total byte count is unchanged, which is what `output_offset` (see the
    // invariant above) counts: N one-byte appends and ceil(N/64) chunked ones
    // both commit exactly N bytes.
    const name = det.type_name.text;
    var i: usize = 0;
    while (i < name.len) {
        var chunk: [64]u8 = undefined;
        const n = @min(chunk.len, name.len - i);
        for (name[i..][0..n], chunk[0..n]) |src, *dst| {
            dst.* = if (src >= 'A' and src <= 'Z') src + 32 else src;
        }
        render_verbatim(r, &chunk, @intCast(n));
        i += n;
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
    var event: yaml.Event = .{};

    out_title.* = null;
    out_description.* = null;

    // An allocation failure is the C's `yaml_parser_initialize` returning 0:
    // both outputs stay null and the caller falls back to its defaults.
    var yp = yaml.init(c_allocator) catch
        return;

    yaml.setInputString(&yp, text[0..size]);

    // Consume STREAM_START.
    yaml.parse(&yp, &event) catch {
        yaml.deinit(&yp);
        return;
    };
    if (event.data != .stream_start) {
        event.deinit(c_allocator);
        yaml.deinit(&yp);
        return;
    }
    event.deinit(c_allocator);

    // Consume DOCUMENT_START.
    yaml.parse(&yp, &event) catch {
        yaml.deinit(&yp);
        return;
    };
    if (event.data != .document_start) {
        event.deinit(c_allocator);
        yaml.deinit(&yp);
        return;
    }
    event.deinit(c_allocator);

    // Expect top-level MAPPING_START.
    yaml.parse(&yp, &event) catch {
        yaml.deinit(&yp);
        return;
    };
    if (event.data != .mapping_start) {
        event.deinit(c_allocator);
        yaml.deinit(&yp);
        return;
    }
    event.deinit(c_allocator);

    // Iterate top-level key-value pairs.
    while (true) {
        var target: ?*?[*:0]u8 = null;

        yaml.parse(&yp, &event) catch {
            yaml.deinit(&yp);
            return;
        };
        if (event.data == .mapping_end) {
            event.deinit(c_allocator);
            break;
        }
        const key = switch (event.data) {
            .scalar => |d| d.value,
            else => {
                event.deinit(c_allocator);
                yaml.deinit(&yp);
                return;
            },
        };

        // Check if key is "title" or "description".
        if (std.mem.eql(u8, key, "title")) {
            target = out_title;
        } else if (std.mem.eql(u8, key, "description")) {
            target = out_description;
        }
        event.deinit(c_allocator);

        // Read the value.
        yaml.parse(&yp, &event) catch {
            yaml.deinit(&yp);
            return;
        };

        if (target != null and event.data == .scalar and event.data.scalar.value.len > 0) {
            const val = event.data.scalar.value;
            const len: usize = val.len;
            const s = c_allocator.allocSentinel(u8, len, 0) catch null;
            if (s) |buf| {
                @memcpy(buf[0..len], val[0..len]);
                if (target.?.*) |old| c_allocator.free(std.mem.span(old));
                target.?.* = buf.ptr;
            }
        } else if (event.data == .mapping_start or event.data == .sequence_start) {
            // Skip nested structures.
            var depth: c_int = 1;
            event.deinit(c_allocator);
            while (depth > 0) {
                yaml.parse(&yp, &event) catch {
                    yaml.deinit(&yp);
                    return;
                };
                if (event.data == .mapping_start or event.data == .sequence_start)
                    depth += 1
                else if (event.data == .mapping_end or event.data == .sequence_end)
                    depth -= 1;
                event.deinit(c_allocator);
            }
            continue;
        }
        event.deinit(c_allocator);
    }

    yaml.deinit(&yp);
}

// Emit the <!DOCTYPE html><html><head>...<body> preamble.
// Called lazily before the first body content in full-HTML mode.
fn ensure_head_emitted(r: *MD_HTML) void {
    var yaml_title: ?[*:0]u8 = null;
    var yaml_desc: ?[*:0]u8 = null;

    if (r.head_emitted)
        return;
    r.head_emitted = true;

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

fn enter_block_callback(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const head = [_][]const u8{ "<h1>", "<h2>", "<h3>", "<h4>", "<h5>", "<h6>" };
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));
    const block_type = std.meta.activeTag(detail.*);

    // Frontmatter: always suppress, capture text for full-HTML or component props.
    if (block_type == c.BlockType.frontmatter) {
        r.in_frontmatter = true;
        if (r.comp_fm_pending) {
            r.comp_fm_capturing = true;
        }
        return 0;
    }

    // If a component tag is pending and the next block is not frontmatter,
    // flush the buffered tag immediately.
    if (r.comp_fm_pending and block_type != c.BlockType.frontmatter) {
        comp_fm_flush_tag(r);
    }

    // In full-HTML mode, emit <head> before first body content.
    if ((r.flags & MD_HTML_FLAG_FULL_HTML != 0) and block_type != c.BlockType.doc)
        ensure_head_emitted(r);

    switch (detail.*) {
        .doc => {}, // noop
        .quote => render_verbatim_lit(r, "<blockquote>\n"),
        .ul => render_verbatim_lit(r, "<ul>\n"),
        .ol => |*d| render_open_ol_block(r, d),
        .li => |*d| render_open_li_block(r, d),
        .hr => render_verbatim_lit(r, "<hr>\n"),
        .h => |*d| {
            render_verbatim_lit_runtime(r, head[d.level - 1]);
        },
        .code => |*det| {
            render_open_code_block(r, det);
            if (r.flags & MD_HTML_FLAG_CODE_META != 0) {
                const meta = code_meta_push(r);
                if (meta != null) {
                    const m = meta.?;
                    m.start = r.output_offset;
                    if (det.lang.text.len > 0) {
                        const lang_size = det.lang.size();
                        const sz: c.MD_SIZE = if (lang_size < m.lang.len) lang_size else @intCast(m.lang.len - 1);
                        @memcpy(m.lang[0..sz], det.lang.text[0..sz]);
                        m.lang_size = sz;
                    }
                    if (det.filename.text.len > 0) {
                        const fn_size = det.filename.size();
                        const sz: c.MD_SIZE = if (fn_size < m.filename.len) fn_size else @intCast(m.filename.len - 1);
                        @memcpy(m.filename[0..sz], det.filename.text[0..sz]);
                        m.filename_size = sz;
                    }
                    if (det.highlights.len > 0) {
                        const h = c_allocator.alloc(c_uint, det.highlights.len) catch null;
                        if (h) |hp| {
                            @memcpy(hp, det.highlights);
                            m.highlights = hp.ptr;
                            m.highlight_count = @intCast(det.highlights.len);
                        }
                    }
                    r.in_code_block = true;
                }
            }
        },
        .html => {}, // noop
        .p => render_verbatim_lit(r, "<p>"),
        .table => render_verbatim_lit(r, "<table>\n"),
        .thead => render_verbatim_lit(r, "<thead>\n"),
        .tbody => render_verbatim_lit(r, "<tbody>\n"),
        .tr => render_verbatim_lit(r, "<tr>\n"),
        .th => |*d| render_open_td_block(r, "th", d),
        .td => |*d| render_open_td_block(r, "td", d),
        .component => |*d| {
            r.component_nesting += 1;
            render_open_block_component(r, d);
        },
        .alert => |*d| render_open_alert_block(r, d),
        .template => |*d| {
            render_verbatim_lit(r, "<template name=\"");
            render_attribute(r, &d.name, render_html_escaped);
            render_verbatim_lit(r, "\">\n");
        },
        .frontmatter => {},
        .footnote_def_section => render_verbatim_lit(r, "<section class=\"footnotes\">\n<ol>\n"),
        .footnote_def => |*d| render_open_footnote_def_block(r, d),
    }

    return 0;
}

// Runtime-string variant of render_verbatim_lit (for head[] table entries).
fn render_verbatim_lit_runtime(r: *MD_HTML, lit: []const u8) void {
    render_verbatim(r, lit.ptr, @intCast(lit.len));
}

fn leave_block_callback(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const head = [_][]const u8{ "</h1>\n", "</h2>\n", "</h3>\n", "</h4>\n", "</h5>\n", "</h6>\n" };
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));
    const block_type = std.meta.activeTag(detail.*);

    // Frontmatter: always suppress.
    if (block_type == c.BlockType.frontmatter) {
        r.in_frontmatter = false;
        if (r.comp_fm_capturing) {
            // Component frontmatter done — flush the buffered tag with YAML attrs.
            comp_fm_flush_tag(r);
        }
        return 0;
    }

    switch (detail.*) {
        .doc => {
            if (r.flags & MD_HTML_FLAG_FULL_HTML != 0) {
                ensure_head_emitted(r);
                render_verbatim_lit(r, "</body>\n</html>\n");
            }
        },
        .quote => render_verbatim_lit(r, "</blockquote>\n"),
        .ul => render_verbatim_lit(r, "</ul>\n"),
        .ol => render_verbatim_lit(r, "</ol>\n"),
        .li => render_verbatim_lit(r, "</li>\n"),
        .hr => {}, // noop
        .h => |*d| {
            render_verbatim_lit_runtime(r, head[d.level - 1]);
        },
        .code => {
            if ((r.flags & MD_HTML_FLAG_CODE_META != 0) and r.in_code_block) {
                r.code_blocks.?[@intCast(r.n_code_blocks)].end = r.output_offset;
                r.n_code_blocks += 1;
                r.in_code_block = false;
            }
            render_verbatim_lit(r, "</code></pre>\n");
        },
        .html => {}, // noop
        .p => render_verbatim_lit(r, "</p>\n"),
        .table => render_verbatim_lit(r, "</table>\n"),
        .thead => render_verbatim_lit(r, "</thead>\n"),
        .tbody => render_verbatim_lit(r, "</tbody>\n"),
        .tr => render_verbatim_lit(r, "</tr>\n"),
        .th => render_verbatim_lit(r, "</th>\n"),
        .td => render_verbatim_lit(r, "</td>\n"),
        .component => |*d| {
            r.component_nesting -= 1;
            render_close_block_component(r, d);
        },
        .alert => render_verbatim_lit(r, "</blockquote>\n"),
        .template => render_verbatim_lit(r, "</template>\n"),
        .frontmatter => {},
        .footnote_def_section => render_verbatim_lit(r, "</ol>\n</section>\n"),
        .footnote_def => |*d| render_close_footnote_def_block(r, d),
    }

    return 0;
}

fn enter_span_callback(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));
    const inside_img = (r.image_nesting_level > 0);

    if (detail.* == .img)
        r.image_nesting_level += 1;
    if (inside_img)
        return 0;

    switch (detail.*) {
        .em => |*d| render_open_tag_with_attrs(r, "em", d),
        .strong => |*d| render_open_tag_with_attrs(r, "strong", d),
        .a => |*d| render_open_a_span(r, d),
        .img => |*d| render_open_img_span(r, d),
        .code => |*d| render_open_tag_with_attrs(r, "code", d),
        .del => |*d| render_open_tag_with_attrs(r, "del", d),
        .mark => |*d| render_open_tag_with_attrs(r, "mark", d),
        .latexmath => render_verbatim_lit(r, "<x-equation>"),
        .latexmath_display => render_verbatim_lit(r, "<x-equation type=\"display\">"),
        .wikilink => |*d| render_open_wikilink_span(r, d),
        .component => |*d| render_open_component_span(r, d),
        .span => |*d| render_open_span_span(r, d),
        .footnote_ref => |*d| render_open_footnote_ref_span(r, d),
    }

    return 0;
}

fn leave_span_callback(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));

    if (detail.* == .img)
        r.image_nesting_level -= 1;
    if (r.image_nesting_level > 0)
        return 0;

    switch (detail.*) {
        .em => render_verbatim_lit(r, "</em>"),
        .strong => render_verbatim_lit(r, "</strong>"),
        .a => render_verbatim_lit(r, "</a>"),
        .img => |*d| render_close_img_span(r, d),
        .code => render_verbatim_lit(r, "</code>"),
        .del => render_verbatim_lit(r, "</del>"),
        .mark => render_verbatim_lit(r, "</mark>"),
        .latexmath, .latexmath_display => render_verbatim_lit(r, "</x-equation>"),
        .wikilink => render_verbatim_lit(r, "</x-wikilink>"),
        .component => |*d| render_close_component_span(r, d),
        .span => render_verbatim_lit(r, "</span>"),
        // enter_span already emitted the whole `<sup>…</sup>`.
        .footnote_ref => {},
    }

    return 0;
}

fn text_callback(text_type: c.TextType, text_slice: []const c.MD_CHAR, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));
    const text: [*]const u8 = text_slice.ptr;
    const size: c.MD_SIZE = @intCast(text_slice.len);

    // Frontmatter text: capture for full-HTML or component frontmatter, always suppress output.
    if (r.in_frontmatter) {
        if (r.comp_fm_capturing)
            _ = comp_fm_text_append(r, text, size)
        else if ((r.flags & MD_HTML_FLAG_FULL_HTML != 0) and r.component_nesting == 0)
            _ = fm_append(r, text, size);
        return 0;
    }

    switch (text_type) {
        c.TextType.nullchar => render_utf8_codepoint(r, 0x0000, render_verbatim),
        c.TextType.br => render_verbatim_lit_runtime(r, if (r.image_nesting_level == 0) "<br>\n" else " "),
        c.TextType.softbr => render_verbatim_lit_runtime(r, if (r.image_nesting_level == 0) "\n" else " "),
        // When inside a Markdown image label, the text falls into the alt="..."
        // attribute opened by render_open_img_span(). Raw HTML must be escaped
        // there, exactly like normal text, otherwise it breaks out of the
        // attribute. Compare the image_nesting_level handling in enter_span_callback().
        c.TextType.html => if (r.image_nesting_level == 0)
            render_verbatim(r, text, size)
        else
            render_html_escaped(r, text, size),
        c.TextType.entity => render_entity(r, text, size, render_html_escaped),
        else => render_html_escaped(r, text, size),
    }

    return 0;
}

fn debug_log_callback(msg: []const u8, userdata: ?*anyopaque) void {
    const r: *MD_HTML = @ptrCast(@alignCast(userdata.?));
    if (r.flags & MD_HTML_FLAG_DEBUG != 0)
        diag.logMessage(msg);
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
    const ret = heal.md_heal(@ptrCast(input), input_size, md4x_heal_buf_append, buf);
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

pub fn md_html_ex(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
    opts: ?*const MD_HTML_OPTS,
) c_int {
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

    var render: MD_HTML = .{
        .process_output = process_output,
        .real_process_output = process_output,
    };
    render.userdata = userdata;
    render.flags = renderer_flags;
    render.opts = opts;

    const parser: c.Parser = .{
        .flags = parser_flags,
        .enter_block = enter_block_callback,
        .leave_block = leave_block_callback,
        .enter_span = enter_span_callback,
        .leave_span = leave_span_callback,
        .text = text_callback,
        .debug_log = debug_log_callback,
    };

    // Consider skipping UTF-8 byte order mark (BOM).
    if (renderer_flags & MD_HTML_FLAG_SKIP_UTF8_BOM != 0 and @sizeOf(c.MD_CHAR) == 1) {
        const bom = [_]u8{ 0xef, 0xbb, 0xbf };
        if (size >= bom.len and std.mem.eql(u8, @as([*]const u8, @ptrCast(input_ptr))[0..bom.len], &bom)) {
            input_ptr += bom.len;
            size -= bom.len;
        }
    }

    const ret = md4x.md_parse(@ptrCast(input_ptr), size, &parser, @ptrCast(&render));

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

pub fn md_html(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int {
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
