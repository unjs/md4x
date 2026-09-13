// MD4X: Markdown parser for C
// (https://github.com/unjs/md4x)
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

// MD_* types now come from the Zig-native
// abi module (replacing md4x.h / entity.h / md4x-heal.h); this renderer needs
// no external C header of its own — the debug sink's stderr write lives in the
// shared md4x-diag.zig.
const c = @import("abi");
// Sibling units are imported directly (one Zig module per artifact), not
// resolved through link-time C-ABI symbols. `abi` holds types only.
const md4x = @import("../md4x.zig");
const entity = @import("../entity.zig");
const heal = @import("md4x-heal.zig");
const diag = @import("md4x-diag.zig");

const c_allocator = std.heap.c_allocator;

// Renderer flags (mirrors md4x-markdown.h). Heal flag value is shared (0x0100).
const MD_MARKDOWN_FLAG_DEBUG: c_uint = 0x0001;
const MD_MARKDOWN_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_MARKDOWN_FLAG_HEAL: c_uint = 0x0100;

// Non-optional — see the note on `md4x-json.zig`'s ProcessOutputFn.
const ProcessOutputFn = *const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void;

const MD_MARKDOWN = struct {
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    flags: c_uint,
    image_nesting_level: c_int,
    quote_depth: c_int,
    list_depth: c_int,
    ol_counter: c_int,
    in_code_block: bool,
    in_code_span: bool,
    need_newline: bool,
    need_indent: bool,
    li_opened: bool,
    in_frontmatter: bool,
    in_heading: bool,

    // Escaping state. `at_line_start` means nothing but block prefixes ("> ",
    // "- ", the list indent) has been emitted on the current output line, so a
    // block opener would still be recognized there; `line_digits` narrows that
    // to "only ASCII digits since the line start", which is what makes a "." or
    // ")" an ordered-list marker. `last_ch` is the last text byte emitted (0
    // after a newline or after renderer-emitted markup), used for the
    // intra-word test that `_`, `$` and `~` are gated on.
    at_line_start: bool,
    line_digits: bool,
    last_ch: u8,

    // Code-span content is buffered because the fence has to be longer than the
    // longest backtick run inside it, which is only known once the span ends.
    code_buf: ?[*]u8,
    code_size: c_uint,
    code_cap: c_uint,

    // Table state
    in_table: bool,
    in_thead: bool,
    thead_done: bool,
    current_col: c_int,
    col_count: c_int,
    col_aligns: [128]c.Align,

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
    r.process_output(@ptrCast(text), size, r.userdata);
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
    r.at_line_start = true;
    r.line_digits = false;
    r.last_ch = 0;
}

// ***********************************
// ***  Markdown escaping         ***
// ***********************************
//
// This renderer's contract is that its output re-parses to the same document,
// so every text byte that would otherwise be read back as markup is emitted
// with a backslash escape. The rules are split three ways:
//
//   * unconditional  -- `\`, `` ` ``, `*`, `[`, `]` and `<` open inline markup
//     from any position, with no flanking rule to fall back on;
//   * flanking-gated -- `_`, `$` and `~` only become marks when they are not
//     surrounded by word characters on both sides (see the mark collector in
//     `parser/inlines.zig`), so intra-word ones are left alone; `&` is escaped
//     only when what follows is shaped like an entity;
//   * run-gated      -- a `=` is markup only as part of a run of two (`==x==`),
//     and that run is whitespace-flanked, not word-flanked, so an intra-word
//     `a==b==c` highlights too. Every `=` adjacent to another `=` is therefore
//     escaped; a lone `=` mid-line can never open a highlight and is left
//     alone. Escaping only the first of a run would not be enough: `\===`
//     re-parses with a live `==` at offset 2;
//   * position-gated -- `#`, `-`, `+`, `>`, `=`, `:` and `|` are block openers
//     only at the start of a line, and `.` / `)` are ordered-list markers only
//     after leading digits.
//
// Anything else (`!`, `{`, `}`, `(`, `)`, `"`, `'`) cannot start markup on its
// own in md4x's dialect -- `![`, `[text]{...}` and `:name[...]` all need a `[`,
// which is always escaped -- so escaping them would only add noise.

fn is_ascii_word(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or ((ch | 0x20) >= 'a' and (ch | 0x20) <= 'z');
}

// True when the `&` at `off` starts something shaped like an entity reference,
// i.e. when leaving it bare would let the re-parse fold it (plus whatever text
// follows) into a single character. When the chunk ends before the shape can be
// ruled out the answer is "yes": the very next chunk may complete it, which is
// exactly what happens for a source `&amp;amp;` (entity `&amp;` resolved to a
// lone `&`, immediately followed by the literal text `amp;`).
fn looks_like_entity(text: [*]const u8, off: c.MD_SIZE, size: c.MD_SIZE) bool {
    var i: c.MD_SIZE = off + 1;
    if (i < size and text[i] == '#') {
        i += 1;
        if (i < size and (text[i] == 'x' or text[i] == 'X')) i += 1;
    }
    const beg = i;
    while (i < size) : (i += 1) {
        if (text[i] == ';') return i > beg;
        if (!is_ascii_word(text[i])) return false;
        // Longer than any entity name md4x knows -- it cannot be one.
        if (i - off > 32) return false;
    }
    return true;
}

fn needs_escape(r: *MD_MARKDOWN, text: [*]const u8, off: c.MD_SIZE, size: c.MD_SIZE) bool {
    const ch = text[off];
    const next: u8 = if (off + 1 < size) text[off + 1] else 0;

    if (r.at_line_start) switch (ch) {
        // Block openers: ATX heading / `#slot`, bullet lists, setext
        // underlines, thematic breaks, block quotes, `::component`, and the
        // leading pipe of a table row (which is also what disarms a delimiter
        // row, and with it the whole table).
        '#', '-', '+', '>', '=', ':', '|' => return true,
        else => {},
    };

    // "1." / "1)" -- only a list marker when nothing but digits precedes it.
    if (r.line_digits and (ch == '.' or ch == ')')) return true;

    return switch (ch) {
        '\\', '`', '*', '[', ']', '<' => true,
        '_', '$', '~' => !(is_ascii_word(r.last_ch) and is_ascii_word(next)),
        '=' => next == '=' or r.last_ch == '=',
        '&' => looks_like_entity(text, off, size),
        // GFM only treats a pipe as a cell boundary inside a table.
        '|' => r.in_table,
        // A trailing `#` run closes an ATX heading, so inside one every `#`
        // that could start such a run is escaped.
        '#' => r.in_heading and (r.last_ch == ' ' or r.last_ch == 0),
        else => false,
    };
}

// An `&` cannot be neutralized by a backslash alone in every position, and
// `&amp;` is both shorter to reason about and what the source most likely said
// in the first place, so that is the spelling used for it.
fn render_escape_of(r: *MD_MARKDOWN, ch: u8) void {
    if (ch == '&')
        render_verbatim_lit(r, "&amp;")
    else
        render_verbatim_lit(r, "\\");
}

fn render_markdown_escaped(r: *MD_MARKDOWN, text: [*]const u8, size: c.MD_SIZE) void {
    var beg: c.MD_SIZE = 0;
    var off: c.MD_SIZE = 0;
    while (off < size) : (off += 1) {
        if (needs_escape(r, text, off, size)) {
            if (off > beg)
                render_verbatim(r, text + beg, off - beg);
            render_escape_of(r, text[off]);
            // `&amp;` already carries the `&`; a backslash does not carry the
            // byte it escapes, so that one is re-emitted with the next run.
            beg = if (text[off] == '&') off + 1 else off;
        }
        const ch = text[off];
        r.line_digits = (r.at_line_start or r.line_digits) and ('0' <= ch and ch <= '9');
        r.at_line_start = false;
        r.last_ch = ch;
    }
    if (size > beg)
        render_verbatim(r, text + beg, size - beg);
}

// Backslash-escape a fixed set of bytes, plus any `&` that could be read back
// as an entity. Used for the link/image attributes, where the escape set
// depends on the delimiter rather than on the position in the line.
fn render_escaped_set(r: *MD_MARKDOWN, text: [*]const u8, size: c.MD_SIZE, comptime set: []const u8) void {
    var beg: c.MD_SIZE = 0;
    var off: c.MD_SIZE = 0;
    while (off < size) : (off += 1) {
        const ch = text[off];
        if (std.mem.indexOfScalar(u8, set, ch) != null or
            (ch == '&' and looks_like_entity(text, off, size)))
        {
            if (off > beg)
                render_verbatim(r, text + beg, off - beg);
            render_escape_of(r, ch);
            beg = if (ch == '&') off + 1 else off;
        }
    }
    if (size > beg)
        render_verbatim(r, text + beg, size - beg);
}

// Bare link destination: parentheses have to stay balanced and a `<` or `>`
// would flip the re-parse into (or out of) the angle-bracket form.
fn render_dest_escaped(r: *MD_MARKDOWN, text: [*]const u8, size: c.MD_SIZE) void {
    render_escaped_set(r, text, size, "\\<>()");
}

// Angle-bracket link destination: only the delimiters themselves are special.
fn render_dest_angle_escaped(r: *MD_MARKDOWN, text: [*]const u8, size: c.MD_SIZE) void {
    render_escaped_set(r, text, size, "\\<>");
}

// Link/image title, always emitted with `"` delimiters.
fn render_title_escaped(r: *MD_MARKDOWN, text: [*]const u8, size: c.MD_SIZE) void {
    render_escaped_set(r, text, size, "\\\"");
}

// A bare destination ends at the first whitespace byte and cannot carry a
// control byte, and neither can be backslash-escaped -- those are the only
// cases that need the `<…>` form. Everything else a destination can contain
// (`(`, `)`, `<`, `>`, `\`) is handled by `render_dest_escaped`.
//
// The check has to be made on the characters that will actually be emitted, so
// entity substrings are resolved the same way `render_entity` resolves them.
fn substr_needs_angle(ty: c.TextType, text: [*]const u8, size: c.MD_SIZE) bool {
    // A NUL is emitted as U+FFFD, which is safe bare.
    if (ty == c.TextType.nullchar)
        return false;

    // `{{ expr }}` reparses as one destination token, blanks included.
    if (ty == c.TextType.binding)
        return false;

    if (ty == c.TextType.entity) {
        if (entity_codepoints(text, size)) |cps| {
            for (cps) |cp| {
                // Codepoint 0 also comes out as U+FFFD.
                if (cp != 0 and (cp <= ' ' or cp == 0x7f))
                    return true;
            }
            return false;
        }
        // Not a recognized entity: emitted verbatim, so judge its bytes.
    }

    var i: c.MD_SIZE = 0;
    while (i < size) : (i += 1) {
        if (text[i] <= ' ' or text[i] == 0x7f)
            return true;
    }
    return false;
}

fn dest_needs_angle(attr: *const c.Attribute) bool {
    const total = attr.size();
    var i: usize = 0;
    while (i < attr.substr_types.len and attr.substr_offsets[i] < total) : (i += 1) {
        const off = attr.substr_offsets[i];
        if (substr_needs_angle(attr.substr_types[i], attr.text.ptr + off, attr.substr_offsets[i + 1] - off))
            return true;
    }
    return false;
}

fn render_destination(r: *MD_MARKDOWN, attr: *const c.Attribute) void {
    if (dest_needs_angle(attr)) {
        render_verbatim_lit(r, "<");
        render_attribute(r, attr, render_dest_angle_escaped);
        render_verbatim_lit(r, ">");
    } else {
        render_attribute(r, attr, render_dest_escaped);
    }
}

fn render_title(r: *MD_MARKDOWN, attr: *const c.Attribute) void {
    render_verbatim_lit(r, " \"");
    render_attribute(r, attr, render_title_escaped);
    render_verbatim_lit(r, "\"");
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

    // Surrogates (U+D800..U+DFFF) are not Unicode scalar values, so encoding
    // them as an ordinary 3-byte sequence yields malformed UTF-8. CommonMark
    // requires them -- like U+0000 -- to be rendered as U+FFFD.
    if (0 < codepoint and codepoint <= 0x10ffff and
        (codepoint < 0xd800 or codepoint > 0xdfff))
        fn_append(r, &utf8, @intCast(n))
    else
        fn_append(r, &utf8_replacement_char, 3);
}

// Decode an entity reference to the codepoints it stands for. A zero second
// element means the entity is a single codepoint. Null means `text` is not a
// recognized entity and has to be emitted as-is.
fn entity_codepoints(text: [*]const u8, size: c.MD_SIZE) ?[2]c_uint {
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

        return .{ codepoint, 0 };
    }

    return entity.entity_lookup(text[0..size]);
}

fn render_entity(r: *MD_MARKDOWN, text: [*]const u8, size: c.MD_SIZE, fn_append: AppendFn) void {
    if (entity_codepoints(text, size)) |cps| {
        render_utf8_codepoint(r, cps[0], fn_append);
        if (cps[1] != 0)
            render_utf8_codepoint(r, cps[1], fn_append);
        return;
    }

    fn_append(r, text, size);
}

fn render_attribute(r: *MD_MARKDOWN, attr: *const c.Attribute, fn_append: AppendFn) void {
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

// ***********************************
// ***  Code-span buffering        ***
// ***********************************

// Shared realloc helper that tracks the old capacity (the c_allocator needs a
// correctly sized slice back). Returns null on OOM, leaving the old block
// intact.
fn buf_realloc(old_ptr: ?[*]u8, old_cap: c_uint, new_cap: c_uint) ?[*]u8 {
    if (old_ptr) |old| {
        const p = c_allocator.realloc(old[0..old_cap], new_cap) catch return null;
        return p.ptr;
    }
    const p = c_allocator.alloc(u8, new_cap) catch return null;
    return p.ptr;
}

fn code_buf_append(r: *MD_MARKDOWN, text: [*]const u8, size: c.MD_SIZE) bool {
    if (r.code_size + size > r.code_cap) {
        const new_cap: c_uint = r.code_cap + r.code_cap / 2 + size + 64;
        const p = buf_realloc(r.code_buf, r.code_cap, new_cap) orelse return false;
        r.code_buf = p;
        r.code_cap = new_cap;
    }
    @memcpy(r.code_buf.?[r.code_size .. r.code_size + size], text[0..size]);
    r.code_size += size;
    return true;
}

// Emit the buffered code-span content with a fence long enough to survive it.
// Backslash escapes do not exist inside a code span, so the only lever is the
// fence length plus CommonMark's one-space padding rule.
fn render_code_span(r: *MD_MARKDOWN) void {
    const buf: []const u8 = if (r.code_buf) |p| p[0..r.code_size] else &.{};

    // The fence must be longer than the longest backtick run in the content.
    var fence: usize = 1;
    var run: usize = 0;
    var all_spaces = buf.len > 0;
    for (buf) |ch| {
        if (ch == '`') {
            run += 1;
            if (run >= fence) fence = run + 1;
        } else {
            run = 0;
            if (ch != ' ') all_spaces = false;
        }
    }

    // A leading or trailing backtick would merge into the fence, and a content
    // that both starts and ends with a space would lose one space at each end
    // to the stripping rule -- unless it is nothing but spaces, which the rule
    // exempts. One space of padding fixes all three.
    const pad = buf.len > 0 and !all_spaces and
        (buf[0] == '`' or buf[buf.len - 1] == '`' or
            (buf[0] == ' ' and buf[buf.len - 1] == ' '));

    var i: usize = 0;
    while (i < fence) : (i += 1)
        render_verbatim_lit(r, "`");
    if (pad) render_verbatim_lit(r, " ");
    if (buf.len > 0) render_verbatim(r, buf.ptr, @intCast(buf.len));
    if (pad) render_verbatim_lit(r, " ");
    i = 0;
    while (i < fence) : (i += 1)
        render_verbatim_lit(r, "`");

    r.at_line_start = false;
    r.line_digits = false;
    r.last_ch = 0;
}

fn render_table_separator(r: *MD_MARKDOWN) void {
    render_indent(r);
    render_verbatim_lit(r, "|");
    var i: c_int = 0;
    while (i < r.col_count) : (i += 1) {
        switch (r.col_aligns[@intCast(i)]) {
            c.Align.left => render_verbatim_lit(r, " :--- |"),
            c.Align.center => render_verbatim_lit(r, " :---: |"),
            c.Align.right => render_verbatim_lit(r, " ---: |"),
            else => render_verbatim_lit(r, " --- |"),
        }
    }
    render_newline(r);
}

// ******************************************
// ***  Markdown renderer implementation  ***
// ******************************************

fn enter_block_callback(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));

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
            r.ol_counter = 0;
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

        .h => |*h| {
            const level = h.level;
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
            render_indent(r);
            var i: c_uint = 0;
            while (i < level and i < 6) : (i += 1)
                render_verbatim_lit(r, "#");
            render_verbatim_lit(r, " ");
            // Everything past the opening sequence is heading content; no block
            // opener is recognized there, so only the ATX closing sequence
            // (handled by `in_heading`) still needs escaping.
            r.at_line_start = false;
            r.in_heading = true;
        },

        .code => |*code| {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
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
            if (code.info.text.len > 0) {
                render_attribute(r, &code.info, render_verbatim);
            }
            render_newline(r);
            r.in_code_block = true;
            r.need_indent = true;
        },

        .html => {
            // Strip raw HTML blocks
        },

        .p => {
            if (r.need_newline and !r.li_opened) {
                render_newline(r);
                r.need_newline = false;
            }
            if (!r.li_opened)
                render_indent(r);
            r.li_opened = false;
        },

        .table => |*tbl| {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
            r.in_table = true;
            r.col_count = @intCast(tbl.col_count);
            if (r.col_count > 128)
                r.col_count = 128;
            @memset(&r.col_aligns, .default);
        },

        .thead => {
            r.in_thead = true;
            r.thead_done = false;
        },

        .tbody => {},

        .tr => {
            render_indent(r);
            render_verbatim_lit(r, "|");
            r.current_col = 0;
        },

        .th => |*td| {
            render_verbatim_lit(r, " ");
            r.at_line_start = false;
            if (r.current_col < 128)
                r.col_aligns[@intCast(r.current_col)] = td.@"align";
        },

        .td => {
            render_verbatim_lit(r, " ");
            r.at_line_start = false;
        },

        .frontmatter => {
            r.in_frontmatter = true;
        },

        .component => |*comp| {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
            render_indent(r);
            render_verbatim_lit(r, "<");
            if (comp.tag_name.text.len > 0)
                render_attribute(r, &comp.tag_name, render_verbatim);
            if (comp.title.len > 0) {
                render_verbatim_lit(r, " title=\"");
                render_verbatim(r, comp.title.ptr, @intCast(comp.title.len));
                render_verbatim_lit(r, "\"");
            }
            render_verbatim_lit(r, ">");
            render_newline(r);
            render_newline(r);
        },

        .alert => |*det| {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
            r.quote_depth += 1;
            render_indent(r);
            render_verbatim_lit(r, "[!");
            if (det.type_name.text.len > 0)
                render_attribute(r, &det.type_name, render_verbatim);
            render_verbatim_lit(r, "]");
            render_newline(r);
        },

        .template => {
            // Transparent — render children normally
        },

        // Definitions are re-emitted here, at the END of the document, not at
        // their original position. That is a textual move, not a semantic one:
        // a footnote definition may sit anywhere in the source and resolves the
        // same either way, and the parser only ever hands them over deferred.
        .footnote_def_section => {},

        .footnote_def => |*d| {
            if (r.need_newline) {
                render_newline(r);
                r.need_newline = false;
            }
            render_indent(r);
            render_verbatim_lit(r, "[^");
            if (d.label.text.len > 0)
                render_attribute(r, &d.label, render_verbatim);
            render_verbatim_lit(r, "]: ");
            r.at_line_start = false;
        },
    }

    return 0;
}

fn leave_block_callback(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));

    switch (detail.*) {
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
            r.in_heading = false;
            render_newline(r);
            r.need_newline = true;
        },

        .code => {
            render_indent(r);
            if (r.fence_char == '~') {
                render_verbatim_lit(r, "~~~");
            } else {
                render_verbatim_lit(r, "```");
            }
            render_newline(r);
            r.in_code_block = false;
            r.need_newline = true;
        },

        .html => {},

        .p => {
            render_newline(r);
            r.need_newline = true;
        },

        .table => {
            r.in_table = false;
            r.need_newline = true;
        },

        .thead => {
            r.in_thead = false;
        },

        .tbody => {},

        .tr => {
            render_newline(r);
            if (r.in_thead and !r.thead_done) {
                render_table_separator(r);
                r.thead_done = true;
            }
        },

        .th => {
            render_verbatim_lit(r, " |");
            r.current_col += 1;
        },

        .td => {
            render_verbatim_lit(r, " |");
            r.current_col += 1;
        },

        .frontmatter => {
            r.in_frontmatter = false;
        },

        .component => |*comp| {
            render_indent(r);
            render_verbatim_lit(r, "</");
            if (comp.tag_name.text.len > 0)
                render_attribute(r, &comp.tag_name, render_verbatim);
            render_verbatim_lit(r, ">");
            render_newline(r);
            r.need_newline = true;
        },

        .alert => {
            r.quote_depth -= 1;
            r.need_newline = true;
        },

        .template => {},

        .footnote_def_section => {
            r.need_newline = true;
        },

        .footnote_def => {
            render_newline(r);
            r.need_newline = true;
        },
    }

    return 0;
}

fn enter_span_callback(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));

    // Renderer-emitted markup is punctuation as far as the re-parse is
    // concerned, so it must not be mistaken for the word character that would
    // exempt a following `_`, `$` or `~` from escaping.
    r.last_ch = 0;

    switch (detail.*) {
        .em => {
            render_verbatim_lit(r, "*");
        },

        .strong => {
            render_verbatim_lit(r, "**");
        },

        .a => {
            render_verbatim_lit(r, "[");
        },

        .img => {
            render_verbatim_lit(r, "![");
            r.image_nesting_level += 1;
        },

        .code => {
            // The fence is emitted in leave_span, once the content is known.
            r.in_code_span = true;
            r.code_size = 0;
        },

        .del => {
            render_verbatim_lit(r, "~~");
        },

        .mark => {
            render_verbatim_lit(r, "==");
        },

        .latexmath => {
            render_verbatim_lit(r, "$");
        },

        .latexmath_display => {
            render_verbatim_lit(r, "$$");
        },

        .component => |*comp| {
            render_verbatim_lit(r, "<");
            if (comp.tag_name.text.len > 0)
                render_attribute(r, &comp.tag_name, render_verbatim);
            render_verbatim_lit(r, ">");
        },

        .span => {
            // Generic span — transparent, just render content
        },

        // Self-contained span: no text callbacks follow, so the whole
        // `[^label]` is written here. The label is verbatim by construction —
        // it cannot contain whitespace, `[` or `]`, which are the only bytes
        // that could end it early on the re-parse.
        .footnote_ref => |*d| {
            render_verbatim_lit(r, "[^");
            if (d.label.text.len > 0)
                render_attribute(r, &d.label, render_verbatim);
            render_verbatim_lit(r, "]");
        },
    }

    return 0;
}

fn leave_span_callback(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));

    // See enter_span_callback.
    r.last_ch = 0;

    switch (detail.*) {
        .em => {
            render_verbatim_lit(r, "*");
        },

        .strong => {
            render_verbatim_lit(r, "**");
        },

        .a => |*a| {
            render_verbatim_lit(r, "](");
            render_destination(r, &a.href);
            if (a.title.text.len > 0)
                render_title(r, &a.title);
            render_verbatim_lit(r, ")");
        },

        .img => |*img| {
            render_verbatim_lit(r, "](");
            render_destination(r, &img.src);
            if (img.title.text.len > 0)
                render_title(r, &img.title);
            render_verbatim_lit(r, ")");
            r.image_nesting_level -= 1;
        },

        .code => {
            render_code_span(r);
            r.in_code_span = false;
        },

        .del => {
            render_verbatim_lit(r, "~~");
        },

        .mark => {
            render_verbatim_lit(r, "==");
        },

        .latexmath => {
            render_verbatim_lit(r, "$");
        },

        .latexmath_display => {
            render_verbatim_lit(r, "$$");
        },

        .component => |*comp| {
            render_verbatim_lit(r, "</");
            if (comp.tag_name.text.len > 0)
                render_attribute(r, &comp.tag_name, render_verbatim);
            render_verbatim_lit(r, ">");
        },

        .span => {},

        .footnote_ref => {}, // enter_span already wrote the whole `[^label]`.
    }

    return 0;
}

fn text_callback(text_type: c.TextType, text_slice: []const c.MD_CHAR, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));
    const text: [*]const u8 = text_slice.ptr;
    const size: c.MD_SIZE = @intCast(text_slice.len);

    if (r.in_frontmatter)
        return 0;

    switch (text_type) {
        .nullchar => {
            // A NUL inside a code span is part of its content, so it has to go
            // into the buffer rather than ahead of the fence.
            if (r.in_code_span) {
                const replacement = [_]u8{ 0xef, 0xbf, 0xbd };
                if (!code_buf_append(r, &replacement, replacement.len))
                    return -1;
            } else {
                render_utf8_codepoint(r, 0xFFFD, render_markdown_escaped);
            }
        },

        .br => {
            render_verbatim_lit(r, "\\");
            render_newline(r);
            render_indent(r);
        },

        .softbr => {
            render_newline(r);
            render_indent(r);
        },

        .html => {
            // Strip all raw HTML (comments, custom tags, etc.)
        },

        .entity => {
            // The entity is resolved to its characters, which then need the
            // same escaping as any other text: `&amp;amp;` must not come back
            // out as a bare `&amp;`.
            render_entity(r, text, size, render_markdown_escaped);
        },

        .code => {
            if (r.in_code_block) {
                if (size == 1 and text[0] == '\n') {
                    render_newline(r);
                    r.need_indent = true;
                } else {
                    if (r.need_indent) {
                        render_indent(r);
                        r.need_indent = false;
                    }
                    render_verbatim(r, text, size);
                }
            } else if (r.in_code_span) {
                if (!code_buf_append(r, text, size))
                    return -1;
            } else {
                render_verbatim(r, text, size);
            }
        },

        // LaTeX math is verbatim by definition -- a backslash escape inside
        // `$…$` is math, not an escape.
        .latexmath => {
            render_verbatim(r, text, size);
        },

        .normal => {
            render_markdown_escaped(r, text, size);
        },

        // `{{ expr }}` round-trips as its source bytes: escaping anything
        // inside would change the expression, and the bytes reparse as the
        // same run. A newline inside it is re-emitted through the renderer
        // so a continuation line keeps the container's indentation.
        // Inside a table cell the parser already unescaped `\|`, so the pipe
        // goes back out escaped or it would split the cell on reparse.
        .binding => {
            var beg: c.MD_SIZE = 0;
            var off: c.MD_SIZE = 0;
            while (off < size) : (off += 1) {
                const ch = text[off];
                if (ch == '\n') {
                    if (off > beg) render_verbatim(r, text + beg, off - beg);
                    render_newline(r);
                    render_indent(r);
                    beg = off + 1;
                } else if (ch == '|' and r.in_table) {
                    if (off > beg) render_verbatim(r, text + beg, off - beg);
                    render_verbatim_lit(r, "\\|");
                    beg = off + 1;
                }
            }
            if (size > beg) render_verbatim(r, text + beg, size - beg);
        },
    }

    return 0;
}

fn debug_log_callback(msg: []const u8, userdata: ?*anyopaque) void {
    const r: *MD_MARKDOWN = @ptrCast(@alignCast(userdata.?));
    if (r.flags & MD_MARKDOWN_FLAG_DEBUG != 0)
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

pub fn md_markdown(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    renderer_flags: c_uint,
) c_int {
    var input_ptr = input;
    var size = input_size;

    // Heal-before-render: run md_heal first, then render the healed output.
    if (renderer_flags & MD_MARKDOWN_FLAG_HEAL != 0) {
        var hbuf: MD4X_HEAL_BUF = undefined;
        if (md4x_heal_input(input, input_size, &hbuf) != 0) {
            heal_buf_free(&hbuf);
            return -1;
        }
        const ret = md_markdown(@ptrCast(hbuf.data), hbuf.size, process_output, userdata, renderer_flags & ~MD_MARKDOWN_FLAG_HEAL);
        heal_buf_free(&hbuf);
        return ret;
    }

    const parser: c.Parser = .{
        .enter_block = enter_block_callback,
        .leave_block = leave_block_callback,
        .enter_span = enter_span_callback,
        .leave_span = leave_span_callback,
        .text = text_callback,
        .debug_log = debug_log_callback,
    };

    // zeroInit rather than zeroes: `process_output` is a non-optional function
    // pointer, which has no zero value.
    var render: MD_MARKDOWN = std.mem.zeroInit(MD_MARKDOWN, .{ .process_output = process_output });
    render.userdata = userdata;
    render.flags = renderer_flags;
    // Nothing has been emitted yet, so the first byte out is at a line start.
    render.at_line_start = true;
    defer if (render.code_buf) |p| c_allocator.free(p[0..render.code_cap]);

    // Consider skipping UTF-8 byte order mark (BOM).
    if (renderer_flags & MD_MARKDOWN_FLAG_SKIP_UTF8_BOM != 0 and @sizeOf(c.MD_CHAR) == 1) {
        const bom = [_]u8{ 0xef, 0xbb, 0xbf };
        if (size >= bom.len and std.mem.eql(u8, @as([*]const u8, @ptrCast(input_ptr))[0..bom.len], &bom)) {
            input_ptr += bom.len;
            size -= bom.len;
        }
    }

    return md4x.md_parse(@ptrCast(input_ptr), size, &parser, @ptrCast(&render));
}
