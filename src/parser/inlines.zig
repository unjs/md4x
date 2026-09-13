// MD4X parser — inline mark-resolution engine + raw-HTML recognizers module.
//
// Raw-HTML recognizers (md_is_html_*), the mark collector/analyzers, the mod-3
// emphasis machinery, link resolution, inline analysis, and the span/text
// emission layer. Extracted verbatim from the monolithic src/md4x.zig (pure
// refactor — no logic change). See AGENTS.md.

const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const refdefs = @import("refdefs.zig");
const build_config = @import("build_config");

/// Emoji shortcode table, or a stub that matches nothing.
///
/// The stub is the DEFAULT (`-Demoji=false`, see build.zig) and is the ONLY way
/// to keep the generated 1913-entry table out of the artifact: with the real
/// table imported, every `:name:` probe references `EMOJI_MAP` and the ~110 KB
/// of table data is linked in regardless of any runtime flag. The stub's
/// `MAX_NAME_LEN = 0` also collapses the recognizer's name scan, so the whole
/// feature folds away instead of merely never matching — `:wave:` then reaches
/// the output verbatim.
pub const emoji = if (build_config.emoji) @import("../emoji.zig") else struct {
    pub const MAX_NAME_LEN: OFF = 0;
    pub fn emoji_lookup(_: []const u8) ?[]const u8 {
        return null;
    }
};

const c = types.c;
const CHAR = types.CHAR;
const SZ = types.SZ;
const OFF = types.OFF;
const OFF_MAX = types.OFF_MAX;
const MD_SIZE = types.MD_SIZE;
const MD_CTX = types.MD_CTX;
const MD_LINE = types.MD_LINE;
const MD_MARK = types.MD_MARK;
const MD_MARKSTACK = types.MD_MARKSTACK;
const MD_INLINE_ATTR_INFO = types.MD_INLINE_ATTR_INFO;
const c_allocator = types.c_allocator;
const CODESPAN_MARK_MAXLEN = types.CODESPAN_MARK_MAXLEN;
const MarkFlags = types.MarkFlags;

const ISANYOF_ = util.ISANYOF_;
const ISALPHA_ = util.ISALPHA_;
const ISALNUM_ = util.ISALNUM_;
const ISBLANK_ = util.ISBLANK_;
const ISCNTRL_ = util.ISCNTRL_;
const ISWHITESPACE_ = util.ISWHITESPACE_;
const MD_ATTRIBUTE_BUILD = util.MD_ATTRIBUTE_BUILD;
const MD_BUILD_ATTR_NO_ESCAPES = util.MD_BUILD_ATTR_NO_ESCAPES;
const md_ascii_eq = util.md_ascii_eq;
const md_build_attribute = util.md_build_attribute;
const md_free_attribute = util.md_free_attribute;
const md_is_entity = util.md_is_entity;
const md_lookup_line = util.md_lookup_line;
const md_temp_buffer = util.md_temp_buffer;

const MD_LINK_ATTR = refdefs.MD_LINK_ATTR;
const md_is_autolink = refdefs.md_is_autolink;
const md_is_inline_link_spec = refdefs.md_is_inline_link_spec;
const md_is_link_reference = refdefs.md_is_link_reference;
const md_lookup_footnote_def = refdefs.md_lookup_footnote_def;

// ============================================================================
//  Pass C — Raw HTML recognizers (needed by md_collect_marks). These are
//  shared with Pass D block analysis (HTML block type 7) but only depend on
//  char helpers + md_ascii_eq + md_lookup_line, so they live here.
// ============================================================================

// Faithful port of md_is_html_tag (md4x.c ~1131). n_lines == 0 => whole tag
// must be on one line (block-start probe).
//
// Three JSX extensions over CommonMark's tag grammar, so an Astro / MDX
// component passes through as raw HTML instead of being escaped as text:
// a `.` inside a capitalized tag name (`<Card.Item>`), a brace-balanced
// attribute value (`n={1 + 2}`, `style={{color: "red"}}`) where CommonMark
// would stop the unquoted value at the blank, and a `{...spread}` where an
// attribute name is expected. The value's closer comes from the document's
// precomputed brace pairs (md_match_brace) — O(log n) per query, so a line
// of `<a b={` stays linear — which means quotes inside the value are not
// understood: a `}` inside a string ends the value early. A value that does
// not balance, does not end the attribute, or crosses a line the tag may
// not, falls back to the CommonMark reading, so `<a b={x>` and `<a b={x}}>`
// are the tags they always were.
pub fn md_is_html_tag(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) bool {
    var attr_state: c_int = undefined;
    var off: OFF = beg;
    var line_end: OFF = if (lines.len > 0) lines[0].end else ctx.size;
    var line_index: MD_SIZE = 0;

    if (off + 1 >= line_end) return false;
    off += 1;

    attr_state = 0;

    if (ctx.ch(off) == '/') {
        attr_state = -1;
        off += 1;
    }

    // Tag name.
    if (off >= line_end or !ctx.isAlpha(off)) return false;
    // A member-expression name (`Card.Item`) only when capitalized: CommonMark
    // (spec example 606) and GitHub keep `<foo.bar.baz>` as text, and Astro
    // requires a component name to start with an uppercase letter anyway.
    const dotted_name = ctx.ch(off) >= 'A' and ctx.ch(off) <= 'Z';
    off += 1;
    while (off < line_end and (ctx.isAlnum(off) or ctx.ch(off) == '-' or
        (dotted_name and ctx.ch(off) == '.' and off + 1 < line_end and ctx.isAlpha(off + 1)))) off += 1;

    while (true) {
        while (off < line_end and !ctx.isNewline(off)) {
            // JSX: `={expr}` value, or `{...spread}` in attribute position.
            if (ctx.ch(off) == '{' and (attr_state == 3 or
                ((attr_state == 1 or attr_state == 2) and off + 3 < line_end and
                    ctx.ch(off + 1) == '.' and ctx.ch(off + 2) == '.' and ctx.ch(off + 3) == '.')))
            {
                if (md_jsx_value_end(ctx, lines, off, max_end, &line_index, &line_end)) |value_end| {
                    off = value_end;
                    attr_state = 0;
                    continue;
                }
                if (attr_state != 3) return false;
                // Unbalanced, not closing the attribute, or crossing a
                // line: CommonMark's unquoted value below.
            }

            if (attr_state > 40) {
                if (attr_state == 41 and (ctx.isBlank(off) or ctx.isAnyOf(off, "\"'=<>`"))) {
                    attr_state = 0;
                    off -= 1; // Put the char back for re-inspection.
                } else if (attr_state == 42 and ctx.ch(off) == '\'') {
                    attr_state = 0;
                } else if (attr_state == 43 and ctx.ch(off) == '"') {
                    attr_state = 0;
                }
                off += 1;
            } else if (ctx.isWhitespace(off)) {
                if (attr_state == 0) attr_state = 1;
                off += 1;
            } else if (attr_state <= 2 and ctx.ch(off) == '>') {
                // End.
                if (off >= max_end) return false;
                p_end.* = off + 1;
                return true;
            } else if (attr_state <= 2 and ctx.ch(off) == '/' and off + 1 < line_end and ctx.ch(off + 1) == '>') {
                // End with digraph '/>'.
                off += 1;
                if (off >= max_end) return false;
                p_end.* = off + 1;
                return true;
            } else if ((attr_state == 1 or attr_state == 2) and (ctx.isAlpha(off) or ctx.ch(off) == '_' or ctx.ch(off) == ':')) {
                off += 1;
                while (off < line_end and (ctx.isAlnum(off) or ctx.isAnyOf(off, "_.:-"))) off += 1;
                attr_state = 2;
            } else if (attr_state == 2 and ctx.ch(off) == '=') {
                off += 1;
                attr_state = 3;
            } else if (attr_state == 3) {
                if (ctx.ch(off) == '"') {
                    attr_state = 43;
                } else if (ctx.ch(off) == '\'') {
                    attr_state = 42;
                } else if (!ctx.isAnyOf(off, "\"'=<>`") and !ctx.isNewline(off)) {
                    attr_state = 41;
                } else {
                    return false;
                }
                off += 1;
            } else {
                return false;
            }
        }

        // Must be on a single line (HTML block start cond. type 7).
        if (lines.len == 0) return false;

        line_index += 1;
        if (line_index >= lines.len) return false;

        off = lines[line_index].beg;
        line_end = lines[line_index].end;

        if (attr_state == 0 or attr_state == 41) attr_state = 1;

        if (off >= max_end) return false;
    }
}

// The offset just past the `}` matching the `{` at `off`, when that run can
// be a JSX attribute value of the tag being scanned: the closer is before
// `max_end`, on a line of the tag (any line of `lines`; the same line when
// `lines` is empty — the block-start probe, where the tag must fit on one
// line), and is followed by a blank, `>`, `/` or the line end, as a quoted
// value must be. `p_line_index` / `p_line_end` are moved to the closer's
// line. Null falls back to CommonMark's unquoted-value reading.
fn md_jsx_value_end(ctx: *MD_CTX, lines: []const MD_LINE, off: OFF, max_end: OFF, p_line_index: *MD_SIZE, p_line_end: *OFF) ?OFF {
    const close = (md_match_brace(ctx, off) catch return null) orelse return null;
    if (close >= max_end) return null;

    var line_end: OFF = p_line_end.*;
    if (lines.len == 0) {
        // The probe has no line table: a `}` past the newline is not ours.
        var i: OFF = off;
        while (i < close) : (i += 1) {
            if (ctx.isNewline(i)) return null;
        }
    } else if (close > lines[p_line_index.*].end) {
        var li: MD_SIZE = p_line_index.*;
        const line = md_lookup_line(close, lines, &li);
        if (close < line.beg or close > line.end) return null;
        p_line_index.* = li;
        line_end = line.end;
    }

    const value_end = close + 1;
    if (value_end < line_end and !ctx.isWhitespace(value_end) and !ctx.isAnyOf(value_end, ">/")) return null;
    p_line_end.* = line_end;
    return value_end;
}

// Faithful port of md_scan_for_html_closer (md4x.c ~1249).
pub fn md_scan_for_html_closer(ctx: *MD_CTX, str: [*c]const CHAR, len: MD_SIZE, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF, p_scan_horizon: *OFF) bool {
    var off: OFF = beg;
    var line_index: MD_SIZE = 0;

    if (off < p_scan_horizon.* and p_scan_horizon.* >= max_end -% len) {
        return false;
    }

    while (true) {
        while (off + len <= lines[line_index].end and off + len <= max_end) {
            if (md_ascii_eq(ctx.str(off), str, len)) {
                p_end.* = off + len;
                return true;
            }
            off += 1;
        }

        line_index += 1;
        if (off >= max_end or line_index >= lines.len) {
            p_scan_horizon.* = off;
            return false;
        }

        off = lines[line_index].beg;
    }
}

pub fn md_is_html_comment(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) bool {
    var off: OFF = beg;
    if (off + 4 >= lines[0].end) return false;
    if (ctx.ch(off + 1) != '!' or ctx.ch(off + 2) != '-' or ctx.ch(off + 3) != '-') return false;
    off += 2; // Skip only "<!" so we accept "<!-->" or "<!--->".
    return md_scan_for_html_closer(ctx, "-->", 3, lines, off, max_end, p_end, &ctx.html_comment_horizon);
}

pub fn md_is_html_processing_instruction(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) bool {
    var off: OFF = beg;
    if (off + 2 >= lines[0].end) return false;
    if (ctx.ch(off + 1) != '?') return false;
    off += 2;
    return md_scan_for_html_closer(ctx, "?>", 2, lines, off, max_end, p_end, &ctx.html_proc_instr_horizon);
}

pub fn md_is_html_declaration(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) bool {
    var off: OFF = beg;
    if (off + 2 >= lines[0].end) return false;
    if (ctx.ch(off + 1) != '!') return false;
    off += 2;
    if (off >= lines[0].end or !ctx.isAlpha(off)) return false;
    off += 1;
    while (off < lines[0].end and ctx.isAlpha(off)) off += 1;
    return md_scan_for_html_closer(ctx, ">", 1, lines, off, max_end, p_end, &ctx.html_decl_horizon);
}

pub fn md_is_html_cdata(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) bool {
    const open_str = "<![CDATA[";
    const open_size: SZ = open_str.len;
    var off: OFF = beg;
    if (off + open_size >= lines[0].end) return false;
    if (std.mem.eql(u8, @as([*]const u8, @ptrCast(ctx.str(off)))[0..open_size], open_str) == false) return false;
    off += open_size;
    return md_scan_for_html_closer(ctx, "]]>", 3, lines, off, max_end, p_end, &ctx.html_cdata_horizon);
}

pub fn md_is_html_any(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) bool {
    if (md_is_html_tag(ctx, lines, beg, max_end, p_end)) return true;
    if (md_is_html_comment(ctx, lines, beg, max_end, p_end)) return true;
    if (md_is_html_processing_instruction(ctx, lines, beg, max_end, p_end)) return true;
    if (md_is_html_declaration(ctx, lines, beg, max_end, p_end)) return true;
    if (md_is_html_cdata(ctx, lines, beg, max_end, p_end)) return true;
    return false;
}

// ============================================================================
//  Pass C — Inline mark-resolution engine
// ============================================================================

// opener_stacks[] index constants (mirroring the C #defines on MD_CTX).
pub const ASTERISK_OPENERS_oo_mod3_0: usize = 0;
pub const UNDERSCORE_OPENERS_oo_mod3_0: usize = 6;
pub const TILDE_OPENERS_1: usize = 12;
pub const TILDE_OPENERS_2: usize = 13;
pub const BRACKET_OPENERS: usize = 14;
pub const DOLLAR_OPENERS: usize = 15;
pub const EQUAL_OPENERS: usize = 16;

// md4x.c ~2609. Returns the base index into ctx.opener_stacks for the given
// emphasis char + flags (applying the EMPH_OC offset of +3 and the mod3 offset).
pub fn md_emph_stack_index(ch: CHAR, flags: u8) usize {
    var idx: usize = switch (ch) {
        '*' => ASTERISK_OPENERS_oo_mod3_0,
        '_' => UNDERSCORE_OPENERS_oo_mod3_0,
        else => unreachable,
    };

    if (flags & MarkFlags.emph_oc != 0) idx += 3;

    switch (flags & MarkFlags.emph_mod3_mask) {
        MarkFlags.emph_mod3_0 => idx += 0,
        MarkFlags.emph_mod3_1 => idx += 1,
        MarkFlags.emph_mod3_2 => idx += 2,
        else => unreachable,
    }
    return idx;
}

pub inline fn md_emph_stack(ctx: *MD_CTX, ch: CHAR, flags: u8) *MD_MARKSTACK {
    return &ctx.opener_stacks[md_emph_stack_index(ch, flags)];
}

// md4x.c ~2633. Returns the opener stack that owns the given mark.
pub fn md_opener_stack(ctx: *MD_CTX, mark_index: c_int) *MD_MARKSTACK {
    const mark = &ctx.marks.items[@intCast(mark_index)];
    switch (mark.ch) {
        '*', '_' => return md_emph_stack(ctx, mark.ch, mark.flags),
        '~' => return if (mark.end - mark.beg == 1) &ctx.opener_stacks[TILDE_OPENERS_1] else &ctx.opener_stacks[TILDE_OPENERS_2],
        '!', '[' => return &ctx.opener_stacks[BRACKET_OPENERS],
        else => unreachable,
    }
}

// md4x.c ~2651. Grow ctx.marks and return a pointer to the new slot, or
// error.OutOfMemory on allocation failure (the returned pointer is never null).
pub fn md_add_mark(ctx: *MD_CTX) error{OutOfMemory}![*c]MD_MARK {
    ctx.marks.ensureUnusedCapacity(ctx.alloc, 1) catch {
        ctx.log("realloc() failed.");
        return error.OutOfMemory;
    };
    const slot = &ctx.marks.items.ptr[ctx.marks.items.len];
    ctx.marks.items.len += 1;
    return slot;
}

// ADD_MARK(ch, beg, end, flags): allocate+init a mark. On OOM returns null so
// the caller can signal abort (set ret=-1 and `goto abort`).
pub inline fn addMark(ctx: *MD_CTX, ch: CHAR, beg: OFF, end: OFF, flags: u8) ?[*c]MD_MARK {
    const mark = md_add_mark(ctx) catch return null;
    mark.*.beg = beg;
    mark.*.end = end;
    mark.*.prev = -1;
    mark.*.next = -1;
    mark.*.ch = ch;
    mark.*.flags = flags;
    return mark;
}

pub inline fn md_mark_stack_push(ctx: *MD_CTX, stack: *MD_MARKSTACK, mark_index: c_int) void {
    ctx.marks.items[@intCast(mark_index)].next = stack.top;
    stack.top = mark_index;
}

pub inline fn md_mark_stack_pop(ctx: *MD_CTX, stack: *MD_MARKSTACK) c_int {
    const top = stack.top;
    if (top >= 0) stack.top = ctx.marks.items[@intCast(top)].next;
    return top;
}

// md_mark_store_ptr/get_ptr (md4x.c ~2712): a void* is memcpy'd over the first
// sizeof(void*) bytes of the mark (beg+end). We replicate by writing the
// pointer's bits into beg/end. Only valid for 'D' dummy marks.
pub inline fn md_mark_store_ptr(ctx: *MD_CTX, mark_index: c_int, ptr: ?*anyopaque) void {
    const mark = &ctx.marks.items[@intCast(mark_index)];
    var p = ptr;
    const dst = @as([*]u8, @ptrCast(mark))[0..@sizeOf(?*anyopaque)];
    const src = @as([*]const u8, @ptrCast(&p))[0..@sizeOf(?*anyopaque)];
    @memcpy(dst, src);
}

pub inline fn md_mark_get_ptr(ctx: *MD_CTX, mark_index: c_int) ?*anyopaque {
    const mark = &ctx.marks.items[@intCast(mark_index)];
    var ptr: ?*anyopaque = undefined;
    const src = @as([*]const u8, @ptrCast(mark))[0..@sizeOf(?*anyopaque)];
    @memcpy(@as([*]u8, @ptrCast(&ptr))[0..@sizeOf(?*anyopaque)], src);
    return ptr;
}

// Free a `ptr_stack` entry at its EXACT allocated length. The stored buffer is
// always an `md_merge_lines_alloc` result (a merged multiline link title), which
// is shrunk to fit, so its allocated length is the size the same dummy mark
// already carries in `prev` — written next to md_mark_store_ptr in
// md_resolve_links and read back verbatim at emission time. Nothing rewrites a
// mark's `prev` after md_resolve_links, so it is still the length here.
pub inline fn md_mark_free_ptr(ctx: *MD_CTX, mark_index: c_int) void {
    const size: SZ = @bitCast(ctx.marks.items[@intCast(mark_index)].prev);
    const ptr: [*c]CHAR = @ptrCast(@alignCast(md_mark_get_ptr(ctx, mark_index)));
    util.free_array_a(CHAR, ctx.alloc, ptr, @intCast(size));
}

pub inline fn md_resolve_range(ctx: *MD_CTX, opener_index: c_int, closer_index: c_int) void {
    const opener = &ctx.marks.items[@intCast(opener_index)];
    const closer = &ctx.marks.items[@intCast(closer_index)];
    opener.next = closer_index;
    closer.prev = opener_index;
    opener.flags |= MarkFlags.opener | MarkFlags.resolved;
    closer.flags |= MarkFlags.closer | MarkFlags.resolved;
}

pub const MD_ROLLBACK_CROSSING: c_int = 0;
pub const MD_ROLLBACK_ALL: c_int = 1;

// md4x.c ~2764.
pub fn md_rollback(ctx: *MD_CTX, opener_index: c_int, closer_index: c_int, how: c_int) void {
    var i: usize = 0;
    while (i < ctx.opener_stacks.len) : (i += 1) {
        const stack = &ctx.opener_stacks[i];
        while (stack.top >= opener_index)
            _ = md_mark_stack_pop(ctx, stack);
    }

    if (how == MD_ROLLBACK_ALL) {
        var j: c_int = opener_index + 1;
        while (j < closer_index) : (j += 1) {
            const mark = &ctx.marks.items[@intCast(j)];

            // Same asymmetry md_disable_marks guards against (md4c 326fe25):
            // a footnote-reference opener inside the rolled-back range may have
            // its `]` closer outside it. Both entry points need the guard —
            // rollback and disable reach overlapping mark ranges.
            if (mark.ch == '[' and (mark.flags & MarkFlags.footnote_ref) != 0 and
                mark.next >= 0 and mark.next >= closer_index)
            {
                const closer = &ctx.marks.items[@intCast(mark.next)];
                closer.ch = 'D';
                closer.flags &= ~MarkFlags.resolved;
            }

            mark.ch = 'D';
            mark.flags = 0;
        }
    }
}

// Turn the marks in [mark_index0, mark_index1) into dummy ('D') marks so no
// later analysis pass can pair them with anything. Unlike MD_ROLLBACK_ALL this
// clears ONLY `resolved`: the remaining flag bits stay readable, and `beg`/
// `end`/`prev`/`next` are untouched so the `ptr_stack` chain and its stored
// title lengths survive.
// md4c 44c90ca (post-fork-point).
pub fn md_disable_marks(ctx: *MD_CTX, mark_index0: c_int, mark_index1: c_int) void {
    var i: c_int = mark_index0;
    while (i < mark_index1) : (i += 1) {
        const mark = &ctx.marks.items[@intCast(i)];

        // A footnote-reference opener's `]` closer may live OUTSIDE the disabled
        // range (it does when the opener is swallowed by a link destination).
        // Leaving it behind is what tripped md4c's assert in #348 — kill it with
        // its opener. md4c 326fe25.
        if (mark.ch == '[' and (mark.flags & MarkFlags.footnote_ref) != 0 and
            mark.next >= 0 and mark.next >= mark_index1)
        {
            const closer = &ctx.marks.items[@intCast(mark.next)];
            closer.ch = 'D';
            closer.flags &= ~MarkFlags.resolved;
        }

        mark.ch = 'D';
        mark.flags &= ~MarkFlags.resolved;
    }
}

// md4x.c ~2783.
pub fn md_build_mark_char_map(ctx: *MD_CTX) void {
    @memset(&ctx.mark_char_map, 0);

    ctx.mark_char_map['\\'] = 1;
    ctx.mark_char_map['*'] = 1;
    ctx.mark_char_map['_'] = 1;
    ctx.mark_char_map['`'] = 1;
    ctx.mark_char_map['&'] = 1;
    ctx.mark_char_map[';'] = 1;
    ctx.mark_char_map['<'] = 1;
    ctx.mark_char_map['>'] = 1;
    ctx.mark_char_map['['] = 1;
    ctx.mark_char_map['!'] = 1;
    ctx.mark_char_map[']'] = 1;
    ctx.mark_char_map[0] = 1;
    ctx.mark_char_map[':'] = 1;
    // md4x has one dialect, so the extension mark chars below are set
    // unconditionally too: strikethrough '~', LaTeX math '$', highlight '=',
    // permissive email autolinks '@', permissive www autolinks '.' and tables
    // '|'. The map is constant — it exists only so the inline scanner can skip
    // uninteresting bytes, not to select a dialect.
    ctx.mark_char_map['~'] = 1;
    ctx.mark_char_map['$'] = 1;
    ctx.mark_char_map['='] = 1;
    ctx.mark_char_map['@'] = 1;
    ctx.mark_char_map['.'] = 1;
    ctx.mark_char_map['|'] = 1;
    // `{{ expr }}` interpolation runs (TextType.binding).
    ctx.mark_char_map['{'] = 1;
}

// md4x.c ~2828. Detect a code span starting at `beg`.
pub fn md_is_code_span(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, opener: *MD_MARK, closer: *MD_MARK, last_potential_closers: *[CODESPAN_MARK_MAXLEN]OFF, p_reached_paragraph_end: *bool) bool {
    const opener_beg: OFF = beg;
    var opener_end: OFF = undefined;
    var closer_beg: OFF = undefined;
    var closer_end: OFF = undefined;
    var mark_len: SZ = undefined;
    var line_end: OFF = undefined;
    var has_space_after_opener: bool = false;
    var has_eol_after_opener: bool = false;
    var has_space_before_closer: bool = false;
    var has_eol_before_closer: bool = false;
    var has_only_space: bool = true;
    var line_index: MD_SIZE = 0;

    line_end = lines[0].end;
    opener_end = opener_beg;
    while (opener_end < line_end and ctx.ch(opener_end) == '`') opener_end += 1;
    has_space_after_opener = opener_end < line_end and ctx.ch(opener_end) == ' ';
    has_eol_after_opener = opener_end == line_end;

    opener.end = opener_end;

    mark_len = opener_end - opener_beg;
    if (mark_len > CODESPAN_MARK_MAXLEN) return false;

    if (last_potential_closers[mark_len - 1] >= lines[lines.len - 1].end or
        (p_reached_paragraph_end.* and last_potential_closers[mark_len - 1] < opener_end))
        return false;

    closer_beg = opener_end;
    closer_end = opener_end;

    while (true) {
        while (closer_beg < line_end and ctx.ch(closer_beg) != '`') {
            if (ctx.ch(closer_beg) != ' ') has_only_space = false;
            closer_beg += 1;
        }
        closer_end = closer_beg;
        while (closer_end < line_end and ctx.ch(closer_end) == '`') closer_end += 1;

        if (closer_end - closer_beg == mark_len) {
            has_space_before_closer = closer_beg > lines[line_index].beg and ctx.ch(closer_beg - 1) == ' ';
            has_eol_before_closer = closer_beg == lines[line_index].beg;
            break;
        }

        if (closer_end - closer_beg > 0) {
            has_only_space = false;
            if (closer_end - closer_beg < CODESPAN_MARK_MAXLEN) {
                const li = closer_end - closer_beg - 1;
                if (closer_beg > last_potential_closers[li]) last_potential_closers[li] = closer_beg;
            }
        }

        if (closer_end >= line_end) {
            line_index += 1;
            if (line_index >= lines.len) {
                p_reached_paragraph_end.* = true;
                return false;
            }
            line_end = lines[line_index].end;
            closer_beg = lines[line_index].beg;
        } else {
            closer_beg = closer_end;
        }
    }

    if (!has_only_space and
        (has_space_after_opener or has_eol_after_opener) and
        (has_space_before_closer or has_eol_before_closer))
    {
        if (has_space_after_opener) {
            opener_end += 1;
        } else {
            opener_end = lines[1].beg;
        }

        if (has_space_before_closer) {
            closer_beg -= 1;
        } else {
            closer_beg = lines[line_index - 1].end;
            while (closer_beg < ctx.size and ctx.isBlank(closer_beg)) closer_beg += 1;
        }
    }

    opener.ch = '`';
    opener.beg = opener_beg;
    opener.end = opener_end;
    opener.flags = MarkFlags.potential_opener;
    closer.ch = '`';
    closer.beg = closer_beg;
    closer.end = closer_end;
    closer.flags = MarkFlags.potential_closer;
    return true;
}

// The byte class github/gemoji's shortcode aliases use (`+1`, `100`, `wave`,
// `non-potable_water`). A pure `CHAR` predicate in the style of util.zig's
// `IS*_` helpers; it lives here because the recognizer below is its only caller.
inline fn ISEMOJINAME_(ch: CHAR) bool {
    const b: u8 = @bitCast(ch);
    return (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_' or b == '+' or b == '-';
}

// Detect an emoji shortcode `:name:` opening at `beg`. `*p_end` receives the
// offset just past the closing colon.
//
// The name scan is bounded by the table's longest name as well as by the line,
// and the first byte after the colon is already outside the class for the
// colons ordinary text is full of (`http://x`, `a:b`, `10:30`, `::component`),
// so a non-shortcode colon is rejected in a byte or two. The table probe — the
// only part that is not O(1) — runs solely once a well-formed `:name:` has been
// spelled out.
pub fn md_is_emoji_shortcode(ctx: *MD_CTX, beg: OFF, line_end: OFF, p_end: *OFF) bool {
    const name_beg: OFF = beg + 1;
    const max_end: OFF = @min(line_end, name_beg +| emoji.MAX_NAME_LEN);
    var off: OFF = name_beg;

    while (off < max_end and ISEMOJINAME_(ctx.ch(off))) off += 1;
    if (off == name_beg or off >= line_end or ctx.ch(off) != ':') return false;

    const name: [*]const u8 = @ptrCast(ctx.str(name_beg));
    if (emoji.emoji_lookup(name[0 .. off - name_beg]) == null) return false;

    p_end.* = off + 1;
    return true;
}

// md4x.c ~3056. Collect all significant marks for the given lines.
pub fn md_collect_marks(ctx: *MD_CTX, lines: []const MD_LINE, table_mode: bool) c_int {
    var line_index: MD_SIZE = 0;
    var ret: c_int = 0;
    var codespan_last_potential_closers = [_]OFF{0} ** CODESPAN_MARK_MAXLEN;
    var codespan_scanned_till_paragraph_end: bool = false;

    const DeferredCompCloser = struct {
        opener_index: c_int,
        closer_beg: OFF,
        closer_end: OFF,
    };
    var deferred_comp_closers: [16]DeferredCompCloser = undefined;
    var n_deferred_comp_closers: c_int = 0;

    const SkipRegion = struct { beg: OFF, end: OFF };
    var skip_regions: [16]SkipRegion = undefined;
    var n_skip_regions: c_int = 0;

    while (line_index < lines.len) : (line_index += 1) {
        var line: [*c]const MD_LINE = @ptrCast(&lines[line_index]);
        var off: OFF = line.*.beg;

        scan: while (true) {
            // IS_MARK_CHAR(off) for 8-bit encodings: mark_char_map[(unsigned char)CH(off)].
            const IS_MARK_CHAR = struct {
                inline fn f(cx: *MD_CTX, o: OFF) bool {
                    return cx.mark_char_map[@as(u8, @bitCast(cx.ch(o)))] != 0;
                }
            }.f;

            // Loop unrolling optimization.
            while (off + 3 < line.*.end and !IS_MARK_CHAR(ctx, off + 0) and !IS_MARK_CHAR(ctx, off + 1) and
                !IS_MARK_CHAR(ctx, off + 2) and !IS_MARK_CHAR(ctx, off + 3)) off += 4;
            while (off < line.*.end and !IS_MARK_CHAR(ctx, off + 0)) off += 1;

            if (off >= line.*.end) break;

            // Skip-region check for component ]{props} areas.
            if (n_skip_regions > 0) {
                var skip_i: c_int = 0;
                var hit = false;
                while (skip_i < n_skip_regions) : (skip_i += 1) {
                    if (off >= skip_regions[@intCast(skip_i)].beg and off < skip_regions[@intCast(skip_i)].end) {
                        off = skip_regions[@intCast(skip_i)].end;
                        hit = true;
                        break;
                    }
                }
                if (hit) continue :scan;
            }

            const ch = ctx.ch(off);

            // Backslash escape.
            if (ch == '\\' and off + 1 < ctx.size and (ctx.isPunct(off + 1) or ctx.isNewline(off + 1))) {
                if (!ctx.isNewline(off + 1) or line_index + 1 < lines.len) {
                    if (addMark(ctx, ch, off, off + 2, MarkFlags.resolved) == null) {
                        ret = -1;
                        return ret;
                    }
                }
                off += 2;
                continue :scan;
            }

            // Potential (strong) emphasis start/end.
            if (ch == '*' or ch == '_') {
                var tmp: OFF = off + 1;
                var left_level: c_int = undefined;
                var right_level: c_int = undefined;

                while (tmp < line.*.end and ctx.ch(tmp) == ch) tmp += 1;

                if (off == line.*.beg or ctx.isUnicodeWhitespaceBefore(off))
                    left_level = 0
                else if (ctx.isUnicodePunctBefore(off))
                    left_level = 1
                else
                    left_level = 2;

                if (tmp == line.*.end or ctx.isUnicodeWhitespace(tmp))
                    right_level = 0
                else if (ctx.isUnicodePunct(tmp))
                    right_level = 1
                else
                    right_level = 2;

                if (ch == '_' and left_level == 2 and right_level == 2) {
                    left_level = 0;
                    right_level = 0;
                }

                if (left_level != 0 or right_level != 0) {
                    var flags: u8 = 0;

                    if (left_level > 0 and left_level >= right_level) flags |= MarkFlags.potential_closer;
                    if (right_level > 0 and right_level >= left_level) flags |= MarkFlags.potential_opener;
                    if (flags == (MarkFlags.potential_opener | MarkFlags.potential_closer)) flags |= MarkFlags.emph_oc;

                    switch ((tmp - off) % 3) {
                        0 => flags |= MarkFlags.emph_mod3_0,
                        1 => flags |= MarkFlags.emph_mod3_1,
                        2 => flags |= MarkFlags.emph_mod3_2,
                        else => {},
                    }

                    if (addMark(ctx, ch, off, tmp, flags) == null) {
                        ret = -1;
                        return ret;
                    }

                    off += 1;
                    while (off < tmp) {
                        if (addMark(ctx, 'D', off, off, 0) == null) {
                            ret = -1;
                            return ret;
                        }
                        off += 1;
                    }
                    continue :scan;
                }

                off = tmp;
                continue :scan;
            }

            // Potential code span.
            if (ch == '`') {
                var opener: MD_MARK = .{};
                var closer: MD_MARK = .{};

                const is_code_span = md_is_code_span(ctx, line[0 .. lines.len - line_index], off, &opener, &closer, &codespan_last_potential_closers, &codespan_scanned_till_paragraph_end);
                if (is_code_span) {
                    if (addMark(ctx, opener.ch, opener.beg, opener.end, opener.flags) == null) {
                        ret = -1;
                        return ret;
                    }
                    if (addMark(ctx, closer.ch, closer.beg, closer.end, closer.flags) == null) {
                        ret = -1;
                        return ret;
                    }
                    md_resolve_range(ctx, ctx.nMarks() - 2, ctx.nMarks() - 1);
                    off = closer.end;
                    if (off > line.*.end) {
                        line = md_lookup_line(off, lines, &line_index);
                    }
                    continue :scan;
                }

                off = opener.end;
                continue :scan;
            }

            // Potential entity start.
            if (ch == '&') {
                if (addMark(ctx, ch, off, off + 1, MarkFlags.potential_opener) == null) {
                    ret = -1;
                    return ret;
                }
                off += 1;
                continue :scan;
            }

            // Potential entity end.
            if (ch == ';') {
                if (ctx.nMarks() > 0 and ctx.marks.items[@intCast(ctx.nMarks() - 1)].ch == '&') {
                    if (addMark(ctx, ch, off, off + 1, MarkFlags.potential_closer) == null) {
                        ret = -1;
                        return ret;
                    }
                }
                off += 1;
                continue :scan;
            }

            // `{{ expr }}` / `{{{ expr }}}` interpolation run, or a JSX-style
            // `{expr}`. Like raw HTML it is one resolved opener/closer pair
            // whose interior collects no marks, so nothing inside it is
            // inline syntax; unlike raw HTML it is emitted as
            // TextType.binding, which only the HTML renderer treats
            // specially. May span lines within the block.
            //
            // A single `{` right after a possible inline-element closer is
            // left to the attribute machinery — `**b**{.cls}`, `[t]{#i}`,
            // `[x](u){a=1}`, `` `c`{.x} ``; anywhere else (`Hello {a*b}`,
            // `{x}` at a line start, `{a}{b}`) it is an expression, and its
            // closer is the document's matched pair (md_match_brace): no
            // quote or escape inside is understood, and the content must be
            // at least one byte (`{}` is text). A block attribute run
            // (`Hello {.cls}`) was cut off the line before inlines ran, so it
            // never gets here.
            if (ch == '{') {
                const block_end = lines[lines.len - 1].end;
                var bind_end: OFF = 0;
                if (off + 1 < block_end and ctx.ch(off + 1) == '{') {
                    // A failed closer search from an earlier `{{` in this
                    // block already proved there is none.
                    if (!(off < ctx.binding_horizon and ctx.binding_horizon >= block_end)) {
                        if (util.md_scan_binding(ctx.str(0)[0..block_end], off, true)) |bind_end_u| {
                            bind_end = @intCast(bind_end_u);
                        } else {
                            ctx.binding_horizon = block_end;
                        }
                    }
                } else if (off == line.*.beg or !ISANYOF_(ctx.ch(off - 1), "*_~=`])")) {
                    if (md_match_brace(ctx, off) catch {
                        ret = -1;
                        return ret;
                    }) |close| {
                        if (close < block_end and close > off + 1) bind_end = close + 1;
                    }
                }
                if (bind_end != 0) {
                    if (addMark(ctx, '{', off, off, MarkFlags.opener | MarkFlags.resolved) == null) {
                        ret = -1;
                        return ret;
                    }
                    if (addMark(ctx, '}', bind_end, bind_end, MarkFlags.closer | MarkFlags.resolved) == null) {
                        ret = -1;
                        return ret;
                    }
                    ctx.marks.items[@intCast(ctx.nMarks() - 2)].next = ctx.nMarks() - 1;
                    ctx.marks.items[@intCast(ctx.nMarks() - 1)].prev = ctx.nMarks() - 2;
                    off = bind_end;
                    if (off > line.*.end) {
                        line = md_lookup_line(off, lines, &line_index);
                    }
                    continue :scan;
                }
                off += 1;
                continue :scan;
            }

            // Potential autolink or raw HTML start/end.
            if (ch == '<') {
                var html_end: OFF = undefined;
                const is_html = md_is_html_any(ctx, line[0 .. lines.len - line_index], off, lines[lines.len - 1].end, &html_end);
                if (is_html) {
                    if (addMark(ctx, '<', off, off, MarkFlags.opener | MarkFlags.resolved) == null) {
                        ret = -1;
                        return ret;
                    }
                    if (addMark(ctx, '>', html_end, html_end, MarkFlags.closer | MarkFlags.resolved) == null) {
                        ret = -1;
                        return ret;
                    }
                    ctx.marks.items[@intCast(ctx.nMarks() - 2)].next = ctx.nMarks() - 1;
                    ctx.marks.items[@intCast(ctx.nMarks() - 1)].prev = ctx.nMarks() - 2;
                    off = html_end;
                    if (off > line.*.end) {
                        line = md_lookup_line(off, lines, &line_index);
                    }
                    continue :scan;
                }

                var autolink_end: OFF = undefined;
                var missing_mailto: bool = undefined;
                const is_autolink = md_is_autolink(ctx, off, lines[lines.len - 1].end, &autolink_end, &missing_mailto);
                if (is_autolink) {
                    var flags: u8 = MarkFlags.resolved | MarkFlags.autolink;
                    if (missing_mailto) flags |= MarkFlags.autolink_missing_mailto;

                    const autolink_opener: c_int = ctx.nMarks();
                    if (addMark(ctx, '<', off, off + 1, MarkFlags.opener | flags) == null) {
                        ret = -1;
                        return ret;
                    }

                    // The autolink's LABEL still resolves entities: `<...&amp;...>`
                    // renders the text as `&`, matching the destination, which
                    // `md_build_attribute()` has always decoded. md4c skips the
                    // interior wholesale here, which decodes the destination but
                    // leaves the label literal — the two halves of one link then
                    // disagree, and the markdown renderer round-trips the autolink
                    // into a plain link whose label and href differ. cmark-gfm (what
                    // GitHub runs) decodes both, and CommonMark's entity section
                    // exempts only code spans and code blocks, so the label is the
                    // half that was wrong. Deliberate divergence from md4c; see
                    // .agents/upstream-sync.md.
                    //
                    // Only whole, valid entities become marks, and they are emitted
                    // pre-resolved in the shape `md_analyze_entity()` would have left
                    // them (opener spanning `&`..`;`, closer on the `;`) — the
                    // analysis phase never revisits a range inside a resolved
                    // autolink. A bare `&` or a stray `;` collects nothing and stays
                    // ordinary text.
                    var ent_off: OFF = off + 1;
                    while (ent_off + 1 < autolink_end - 1) : (ent_off += 1) {
                        if (ctx.ch(ent_off) != '&') continue;

                        var ent_end: OFF = undefined;
                        if (!md_is_entity(ctx, ent_off, autolink_end - 1, &ent_end)) continue;

                        const ent_opener: c_int = ctx.nMarks();
                        if (addMark(ctx, '&', ent_off, ent_end, MarkFlags.opener | MarkFlags.resolved) == null) {
                            ret = -1;
                            return ret;
                        }
                        if (addMark(ctx, ';', ent_end - 1, ent_end, MarkFlags.closer | MarkFlags.resolved) == null) {
                            ret = -1;
                            return ret;
                        }
                        ctx.marks.items[@intCast(ent_opener)].next = ent_opener + 1;
                        ctx.marks.items[@intCast(ent_opener + 1)].prev = ent_opener;

                        // -1 offsets the loop's own increment.
                        ent_off = ent_end - 1;
                    }

                    const autolink_closer: c_int = ctx.nMarks();
                    if (addMark(ctx, '>', autolink_end - 1, autolink_end, MarkFlags.closer | flags) == null) {
                        ret = -1;
                        return ret;
                    }
                    ctx.marks.items[@intCast(autolink_opener)].next = autolink_closer;
                    ctx.marks.items[@intCast(autolink_closer)].prev = autolink_opener;
                    off = autolink_end;
                    continue :scan;
                }

                off += 1;
                continue :scan;
            }

            // A potential footnote reference: `[^label]`. Collected BEFORE the
            // generic `[` arm so the opener swallows the `^` and can never be
            // mistaken for a link / image opener. The opener spans
            // `[^` (end - beg == 2); the `]` is collected by the generic closer
            // arm below and paired by md_analyze_bracket like any other bracket.
            if (ch == '[' and off + 1 < line.*.end and ctx.ch(off + 1) == '^') {
                const tmp: OFF = off + 2;
                if (addMark(ctx, '[', off, tmp, MarkFlags.potential_opener | MarkFlags.footnote_ref) == null) {
                    ret = -1;
                    return ret;
                }
                off = tmp;
                // Two dummies, matching the generic `[` arm's shape so every
                // `opener + 1` / `opener + 2` reader stays in range. Only the
                // first is used: md_resolve_footnote_refs parks the resolved
                // (id, ref_id) pair in its `beg`/`end`.
                if (addMark(ctx, 'D', off, off, 0) == null) {
                    ret = -1;
                    return ret;
                }
                if (addMark(ctx, 'D', off, off, 0) == null) {
                    ret = -1;
                    return ret;
                }
                continue :scan;
            }

            // Potential link or its part.
            if (ch == '[' or (ch == '!' and off + 1 < line.*.end and ctx.ch(off + 1) == '[')) {
                const tmp: OFF = if (ch == '[') off + 1 else off + 2;
                if (addMark(ctx, ch, off, tmp, MarkFlags.potential_opener) == null) {
                    ret = -1;
                    return ret;
                }
                off = tmp;
                if (addMark(ctx, 'D', off, off, 0) == null) {
                    ret = -1;
                    return ret;
                }
                if (addMark(ctx, 'D', off, off, 0) == null) {
                    ret = -1;
                    return ret;
                }
                continue :scan;
            }
            if (ch == ']') {
                if (addMark(ctx, ch, off, off + 1, MarkFlags.potential_closer) == null) {
                    ret = -1;
                    return ret;
                }
                off += 1;
                continue :scan;
            }

            // Potential permissive e-mail autolink.
            if (ch == '@') {
                if (line.*.beg + 1 <= off and ctx.isAlnum(off - 1) and off + 3 < line.*.end and ctx.isAlnum(off + 1)) {
                    if (addMark(ctx, ch, off, off + 1, MarkFlags.potential_opener) == null) {
                        ret = -1;
                        return ret;
                    }
                    if (addMark(ctx, 'D', line.*.beg, line.*.end, 0) == null) {
                        ret = -1;
                        return ret;
                    }
                }
                off += 1;
                continue :scan;
            }

            // Potential emoji shortcode, inline component or permissive URL
            // autolink.
            if (ch == ':') {
                // Emoji shortcodes come first: a shortcode name may itself be
                // component-shaped (`t-rex`, `e-mail`), or hide one in front of
                // an underscore (`non-potable_water` — the component name class
                // stops at `_`, leaving the hyphenated `non-potable` behind),
                // and the component recognizer below would swallow the prefix.
                // Going first cannot shadow a component in return: the name has
                // to be in the table AND be closed by a second colon, which
                // `:icon-star`, `:badge[New]` and `:icon{name=x}` are not.
                {
                    var emoji_end: OFF = undefined;
                    if (md_is_emoji_shortcode(ctx, off, line.*.end, &emoji_end)) {
                        if (addMark(ctx, 'E', off, emoji_end, MarkFlags.resolved) == null) {
                            ret = -1;
                            return ret;
                        }
                        off = emoji_end;
                        continue :scan;
                    }
                }

                comp: {
                    if (off + 1 < line.*.end and ctx.isAlpha(off + 1) and
                        (off == line.*.beg or !ctx.isAlnum(off - 1)))
                    {
                        var name_end: OFF = off + 2;
                        var name_has_hyphen: c_int = 0;
                        while (name_end < line.*.end and (ctx.isAlnum(name_end) or ctx.ch(name_end) == '-')) {
                            if (ctx.ch(name_end) == '-') name_has_hyphen = 1;
                            name_end += 1;
                        }
                        if (name_end > off + 1) {
                            var comp_end: OFF = name_end;
                            var has_content: c_int = 0;
                            var content_beg: OFF = 0;
                            var content_end: OFF = 0;
                            var props_beg: OFF = 0;
                            var props_end: OFF = 0;
                            var opener_end: OFF = undefined;
                            var closer_beg: OFF = undefined;
                            var closer_end: OFF = undefined;

                            // Optional [content].
                            if (comp_end < line.*.end and ctx.ch(comp_end) == '[') {
                                var bracket_depth: c_int = 1;
                                var scan_off: OFF = comp_end + 1;
                                content_beg = scan_off;
                                while (scan_off < line.*.end and bracket_depth > 0) {
                                    if (ctx.ch(scan_off) == '[') bracket_depth += 1 else if (ctx.ch(scan_off) == ']') bracket_depth -= 1;
                                    if (bracket_depth > 0) scan_off += 1;
                                }
                                if (bracket_depth == 0) {
                                    has_content = 1;
                                    content_end = scan_off;
                                    comp_end = scan_off + 1;
                                }
                            }

                            // Optional {props}.
                            if (comp_end < line.*.end and ctx.ch(comp_end) == '{') {
                                var brace_depth: c_int = 1;
                                var scan_off: OFF = comp_end + 1;
                                props_beg = scan_off;
                                while (scan_off < line.*.end and brace_depth > 0) {
                                    if (ctx.ch(scan_off) == '{') brace_depth += 1 else if (ctx.ch(scan_off) == '}') brace_depth -= 1;
                                    if (brace_depth > 0) scan_off += 1;
                                }
                                if (brace_depth == 0) {
                                    props_end = scan_off;
                                    comp_end = scan_off + 1;
                                }
                            }

                            // Standalone components require a hyphen in the name.
                            if (has_content == 0 and props_end == 0 and name_has_hyphen == 0)
                                break :comp;

                            if (has_content != 0) {
                                opener_end = content_beg;
                                closer_beg = content_end;
                                closer_end = comp_end;
                            } else {
                                opener_end = name_end;
                                closer_beg = name_end;
                                closer_end = comp_end;
                            }

                            if (has_content != 0 and n_deferred_comp_closers < 16) {
                                if (addMark(ctx, 'C', off, opener_end, MarkFlags.opener | MarkFlags.resolved) == null) {
                                    ret = -1;
                                    return ret;
                                }
                                const opener_index = ctx.nMarks() - 1;
                                if (addMark(ctx, 'D', props_beg, props_end, 0) == null) {
                                    ret = -1;
                                    return ret;
                                }
                                deferred_comp_closers[@intCast(n_deferred_comp_closers)] = .{
                                    .opener_index = opener_index,
                                    .closer_beg = closer_beg,
                                    .closer_end = closer_end,
                                };
                                n_deferred_comp_closers += 1;
                                if (n_skip_regions < 16) {
                                    skip_regions[@intCast(n_skip_regions)] = .{ .beg = content_end, .end = comp_end };
                                    n_skip_regions += 1;
                                }
                                off = opener_end;
                                continue :scan;
                            } else {
                                if (addMark(ctx, 'C', off, opener_end, MarkFlags.opener | MarkFlags.resolved) == null) {
                                    ret = -1;
                                    return ret;
                                }
                                if (addMark(ctx, 'D', props_beg, props_end, 0) == null) {
                                    ret = -1;
                                    return ret;
                                }
                                if (addMark(ctx, 'C', closer_beg, closer_end, MarkFlags.closer | MarkFlags.resolved) == null) {
                                    ret = -1;
                                    return ret;
                                }
                                ctx.marks.items[@intCast(ctx.nMarks() - 3)].next = ctx.nMarks() - 1;
                                ctx.marks.items[@intCast(ctx.nMarks() - 1)].prev = ctx.nMarks() - 3;
                                off = comp_end;
                                continue :scan;
                            }
                        }
                    }
                }
                // not_component:

                // Potential permissive URL autolink.
                {
                    const SchemeEntry = struct { scheme: [*c]const CHAR, scheme_size: SZ, suffix: [*c]const CHAR, suffix_size: SZ };
                    const scheme_map = [_]SchemeEntry{
                        .{ .scheme = "http", .scheme_size = 4, .suffix = "//", .suffix_size = 2 },
                        .{ .scheme = "https", .scheme_size = 5, .suffix = "//", .suffix_size = 2 },
                        .{ .scheme = "ftp", .scheme_size = 3, .suffix = "//", .suffix_size = 2 },
                    };
                    var scheme_index: usize = 0;
                    while (scheme_index < scheme_map.len) : (scheme_index += 1) {
                        const scheme = scheme_map[scheme_index].scheme;
                        const scheme_size = scheme_map[scheme_index].scheme_size;
                        const suffix = scheme_map[scheme_index].suffix;
                        const suffix_size = scheme_map[scheme_index].suffix_size;

                        if (line.*.beg + scheme_size <= off and md_ascii_eq(ctx.str(off - scheme_size), scheme, scheme_size) and
                            off + 1 + suffix_size < line.*.end and md_ascii_eq(ctx.str(off + 1), suffix, suffix_size))
                        {
                            if (addMark(ctx, ch, off - scheme_size, off + 1 + suffix_size, MarkFlags.potential_opener) == null) {
                                ret = -1;
                                return ret;
                            }
                            if (addMark(ctx, 'D', line.*.beg, line.*.end, 0) == null) {
                                ret = -1;
                                return ret;
                            }
                            off += 1 + suffix_size;
                            break;
                        }
                    }
                }

                off += 1;
                continue :scan;
            }

            // Potential permissive WWW autolink.
            if (ch == '.') {
                if (line.*.beg + 3 <= off and md_ascii_eq(ctx.str(off - 3), "www", 3) and
                    (off - 3 == line.*.beg or ctx.isUnicodeWhitespaceBefore(off - 3) or ctx.isUnicodePunctBefore(off - 3)))
                {
                    if (addMark(ctx, ch, off - 3, off + 1, MarkFlags.potential_opener) == null) {
                        ret = -1;
                        return ret;
                    }
                    if (addMark(ctx, 'D', line.*.beg, line.*.end, 0) == null) {
                        ret = -1;
                        return ret;
                    }
                    off += 1;
                    continue :scan;
                }
                off += 1;
                continue :scan;
            }

            // Potential table cell boundary.
            if (table_mode and ch == '|') {
                if (addMark(ctx, ch, off, off + 1, 0) == null) {
                    ret = -1;
                    return ret;
                }
                off += 1;
                continue :scan;
            }

            // Potential highlight start/end: `==text==`. A lone `=` stays an
            // ordinary character (setext underlines are block-level and never
            // reach the mark collector, and `key=value` in attributes/props
            // uses a single `=`); only a run of exactly two opens a mark.
            if (ch == '=') {
                var tmp: OFF = off + 1;
                while (tmp < line.*.end and ctx.ch(tmp) == '=') tmp += 1;

                // Only a run of exactly two is a delimiter; `===` and longer
                // stay literal.
                if (tmp - off == 2) {
                    var flags: u8 = MarkFlags.potential_opener | MarkFlags.potential_closer;

                    // Cannot open before whitespace; cannot close after it.
                    // (Whitespace-adjacency only — NOT the emphasis flanking
                    // rules, so `a==b==c` highlights, matching md4c.)
                    if (tmp >= line.*.end or ctx.isUnicodeWhitespace(tmp))
                        flags &= ~MarkFlags.potential_opener;
                    if (off == line.*.beg or ctx.isUnicodeWhitespaceBefore(off))
                        flags &= ~MarkFlags.potential_closer;
                    if (flags != 0) {
                        if (addMark(ctx, ch, off, tmp, flags) == null) {
                            ret = -1;
                            return ret;
                        }
                    }
                }

                off = tmp;
                continue :scan;
            }

            // Potential strikethrough/equation start/end.
            if (ch == '$' or ch == '~') {
                var tmp: OFF = off + 1;
                while (tmp < line.*.end and ctx.ch(tmp) == ch) tmp += 1;

                if (tmp - off <= 2) {
                    var flags: u8 = MarkFlags.potential_opener | MarkFlags.potential_closer;
                    if (off > line.*.beg and !ctx.isUnicodeWhitespaceBefore(off) and !ctx.isUnicodePunctBefore(off))
                        flags &= ~MarkFlags.potential_opener;
                    if (tmp < line.*.end and !ctx.isUnicodeWhitespace(tmp) and !ctx.isUnicodePunct(tmp))
                        flags &= ~MarkFlags.potential_closer;
                    if (flags != 0) {
                        if (addMark(ctx, ch, off, tmp, flags) == null) {
                            ret = -1;
                            return ret;
                        }
                    }
                }
                off = tmp;
                continue :scan;
            }

            // Turn non-trivial whitespace into single space.
            if (ISWHITESPACE_(ch)) {
                var tmp: OFF = off + 1;
                while (tmp < line.*.end and ctx.isWhitespace(tmp)) tmp += 1;
                if (tmp - off > 1 or ch != ' ') {
                    if (addMark(ctx, ch, off, tmp, MarkFlags.resolved) == null) {
                        ret = -1;
                        return ret;
                    }
                }
                off = tmp;
                continue :scan;
            }

            // NULL character.
            if (ch == 0) {
                if (addMark(ctx, ch, off, off + 1, MarkFlags.resolved) == null) {
                    ret = -1;
                    return ret;
                }
                off += 1;
                continue :scan;
            }

            off += 1;
        }
    }

    // Insert deferred component closer marks at correct positions (reverse order).
    if (n_deferred_comp_closers > 0) {
        // Insertion sort by closer_beg descending.
        var i: c_int = 1;
        while (i < n_deferred_comp_closers) : (i += 1) {
            const key = deferred_comp_closers[@intCast(i)];
            var j: c_int = i - 1;
            while (j >= 0 and deferred_comp_closers[@intCast(j)].closer_beg < key.closer_beg) {
                deferred_comp_closers[@intCast(j + 1)] = deferred_comp_closers[@intCast(j)];
                j -= 1;
            }
            deferred_comp_closers[@intCast(j + 1)] = key;
        }

        i = 0;
        while (i < n_deferred_comp_closers) : (i += 1) {
            var opener_index = deferred_comp_closers[@intCast(i)].opener_index;
            const cbeg = deferred_comp_closers[@intCast(i)].closer_beg;
            const cend = deferred_comp_closers[@intCast(i)].closer_end;

            var insert_pos: c_int = opener_index + 2;
            while (insert_pos < ctx.nMarks()) : (insert_pos += 1) {
                if (ctx.marks.items[@intCast(insert_pos)].beg >= cbeg) break;
            }

            {
                // Grow ctx.marks by one slot; the returned pointer is unused
                // here (the new slot is populated below via insert_pos).
                _ = md_add_mark(ctx) catch {
                    ret = -1;
                    return ret;
                };
                if (insert_pos < ctx.nMarks() - 1) {
                    const dst = &ctx.marks.items[@intCast(insert_pos + 1)];
                    const srcp = &ctx.marks.items[@intCast(insert_pos)];
                    const count: usize = @intCast(ctx.nMarks() - 1 - insert_pos);
                    std.mem.copyBackwards(MD_MARK, @as([*]MD_MARK, @ptrCast(dst))[0..count], @as([*]const MD_MARK, @ptrCast(srcp))[0..count]);
                }
            }
            ctx.marks.items[@intCast(insert_pos)].beg = cbeg;
            ctx.marks.items[@intCast(insert_pos)].end = cend;
            ctx.marks.items[@intCast(insert_pos)].ch = 'C';
            ctx.marks.items[@intCast(insert_pos)].flags = MarkFlags.closer | MarkFlags.resolved;
            ctx.marks.items[@intCast(insert_pos)].prev = -1;
            ctx.marks.items[@intCast(insert_pos)].next = -1;

            var jj: c_int = 0;
            while (jj < ctx.nMarks()) : (jj += 1) {
                if (jj == insert_pos) continue;
                if (ctx.marks.items[@intCast(jj)].prev >= insert_pos) ctx.marks.items[@intCast(jj)].prev += 1;
                if (ctx.marks.items[@intCast(jj)].next >= insert_pos) ctx.marks.items[@intCast(jj)].next += 1;
            }
            if (opener_index >= insert_pos) opener_index += 1;
            {
                var k: c_int = i + 1;
                while (k < n_deferred_comp_closers) : (k += 1) {
                    if (deferred_comp_closers[@intCast(k)].opener_index >= insert_pos)
                        deferred_comp_closers[@intCast(k)].opener_index += 1;
                }
            }
            ctx.marks.items[@intCast(opener_index)].next = insert_pos;
            ctx.marks.items[@intCast(insert_pos)].prev = opener_index;
        }
    }

    // Add a dummy mark at the end to simplify process_inlines().
    if (addMark(ctx, 127, ctx.size, ctx.size, MarkFlags.resolved) == null) {
        ret = -1;
        return ret;
    }

    return ret;
}

// md4x.c ~3628.
pub fn md_analyze_bracket(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks.items[@intCast(mark_index)];

    if (mark.flags & MarkFlags.potential_opener != 0) {
        if (ctx.opener_stacks[BRACKET_OPENERS].top >= 0)
            ctx.marks.items[@intCast(ctx.opener_stacks[BRACKET_OPENERS].top)].flags |= MarkFlags.has_nested_brackets;
        md_mark_stack_push(ctx, &ctx.opener_stacks[BRACKET_OPENERS], mark_index);
        return;
    }

    if (ctx.opener_stacks[BRACKET_OPENERS].top >= 0) {
        const opener_index = md_mark_stack_pop(ctx, &ctx.opener_stacks[BRACKET_OPENERS]);
        const opener = &ctx.marks.items[@intCast(opener_index)];

        opener.next = mark_index;
        mark.prev = opener_index;

        if (ctx.unresolved_link_tail >= 0)
            ctx.marks.items[@intCast(ctx.unresolved_link_tail)].prev = opener_index
        else
            ctx.unresolved_link_head = opener_index;
        ctx.unresolved_link_tail = opener_index;
        opener.prev = -1;
    }
}

// ---- Document-wide `{`…`}` pairing for the inline-attribute scans ----
//
// Both attribute scans (md_resolve_links' `[text]{attrs}` probe and
// md_resolve_attrs' trailing-`{attrs}` probe) ask the same question of a `{` at
// offset `s`: where is the offset at which the running brace balance returns to
// its value before `s` — i.e. the matching `}` — if anywhere before ctx.size?
//
// Both used to answer it by scanning forward from `s` to ctx.size counting
// depth, per candidate. That is quadratic whenever the scans run long: on
// unbalanced input (`'*a*{' x N`) every candidate re-reads the whole remaining
// document, and on deeply nested input (`'*a*{' x N ++ '}' x N`) so does every
// successful one. PLAN item 9a; both shapes were measured at 4x per doubling.
//
// The matching is a property of the document alone, so it is computed once, in
// one linear right-to-left pass, and then queried by binary search. The answer
// is identical to the old scan's by construction: the depth scan from `s` stops
// at the first `}` that is not consumed by a nearer `{`, which is exactly the
// pair the stack pass forms.

// Build ctx.brace_pairs: every matched `{`…`}` pair in the document, ascending
// by `.open`. Walking right-to-left and popping the nearest pending `}` yields
// the pairs in DESCENDING open order, so the result is reversed at the end.
fn md_build_brace_pairs(ctx: *MD_CTX) error{OutOfMemory}!void {
    errdefer ctx.brace_pairs.clearRetainingCapacity();

    // Pending (not yet matched) `}` offsets, innermost last.
    var closers: std.ArrayListUnmanaged(OFF) = .empty;
    defer closers.deinit(ctx.alloc);

    var off: OFF = ctx.size;
    while (off > 0) {
        off -= 1;
        switch (ctx.ch(off)) {
            '}' => try closers.append(ctx.alloc, off),
            '{' => {
                if (closers.pop()) |close|
                    try ctx.brace_pairs.append(ctx.alloc, .{ .open = off, .close = close });
            },
            else => {},
        }
    }

    std.mem.reverse(types.MD_BRACE_PAIR, ctx.brace_pairs.items);
    ctx.brace_pairs_built = true;
}

// Can the `{` at `off` open an attribute run? `{{` is reserved for
// interpolation (`{{ expr }}`, resolved by the render host — see the data
// binding section of test/spec-comark.txt), so a doubled brace stays literal
// text instead of leaking `{` into the tag as a bare attribute name. This is
// Comark's `comark_inline_props` rule (plugins/attributes.js); its other two
// exclusions — a `{` right after `{` or `$` — are already implied by every
// caller, which only gets here with a span closer or a blank before the brace.
// Component props (`:badge{...}`) are a different production and not gated.
pub fn md_is_attr_opener(ctx: *MD_CTX, off: OFF) bool {
    return !(off + 1 < ctx.size and ctx.ch(off + 1) == '{');
}

// A byte that may appear in an id, a class or an unquoted value — HTML's
// attribute-name rule (anything but blanks, controls and the tag-syntax
// characters) minus the backslash, so `\}` stays the escape it is in every
// other inline context instead of leaking a raw `\` into the tag.
inline fn md_is_attr_name_char(ch: CHAR) bool {
    return !ISBLANK_(ch) and !ISCNTRL_(ch) and !ISANYOF_(ch, "{}\"'=<>/\\");
}

// A byte that may follow the first character of a key — Comark's key grammar
// (`[a-z_][a-z0-9_-]*`, case-insensitive; internal/parse/syntax/props.js), so
// `data-x` and `aria-label` are keys but `props.title` and `fn()` are not.
// Comark drops a non-matching key and keeps the run; md4x's all-or-nothing
// rule instead leaves the run as text, which is what a JSX-style `{expr}`
// wants. A bare identifier (`{title}`) is the one shape left ambiguous with a
// boolean prop; md_is_bare_attr_content settles it by the blank before the
// brace.
inline fn md_is_attr_key_char(ch: CHAR) bool {
    return ISALNUM_(ch) or ch == '_' or ch == '-';
}

// Is `[beg, end)` — the bytes between a matched `{` and `}` — a well-formed
// attribute list? Blank-separated items, each one of
//
//     #id   .class   [:]key   [:]key="v"   [:]key='v'   [:]key=v
//
// where an id/class is one or more name bytes not starting with `.` or `#`
// (`{...props}` is a spread, not three classes), a key starts with an ASCII
// letter or `_` and continues with key bytes, and an unquoted value is one or
// more name bytes. Anything else (`{"}`, `{=b}`, `{a=}`, `{.a {b}}`, `{x.y}`,
// `{f()}`, an unclosed quote, a newline) makes the whole run literal text: an all-or-nothing
// fallback rather than `md_parse_props`'s lenient reading, which leaks `{` or
// `"` into the tag as a bare attribute name. The grammar here is a strict
// subset of what `md_parse_props` accepts, so every run that passes is parsed
// the same way.
//
// An empty or blank-only list is well-formed: `[text]{}` is Comark's bare
// `<span>` and `**b**{}` a no-op. Only the block form refuses it — a trailing
// `{}` on a paragraph carries nothing, so `md_find_block_attrs` leaves it as
// text.
pub fn md_is_attr_content(ctx: *MD_CTX, beg: OFF, end: OFF) bool {
    var i: OFF = beg;

    while (i < end) {
        while (i < end and ISBLANK_(ctx.ch(i))) i += 1;
        if (i >= end) break;

        if (ctx.ch(i) == '#' or ctx.ch(i) == '.') {
            i += 1;
            if (i < end and (ctx.ch(i) == '.' or ctx.ch(i) == '#')) return false;
            const start = i;
            while (i < end and md_is_attr_name_char(ctx.ch(i))) i += 1;
            if (i == start) return false;
        } else {
            if (ctx.ch(i) == ':') i += 1;
            if (i >= end or !(ISALPHA_(ctx.ch(i)) or ctx.ch(i) == '_')) return false;
            i += 1;
            while (i < end and md_is_attr_key_char(ctx.ch(i))) i += 1;

            if (i < end and ctx.ch(i) == '=') {
                i += 1;
                if (i >= end) return false;
                const q = ctx.ch(i);
                if (q == '"' or q == '\'') {
                    i += 1;
                    while (i < end and ctx.ch(i) != q) : (i += 1) {
                        if (ctx.isNewline(i)) return false;
                    }
                    if (i >= end) return false;
                    i += 1;
                } else {
                    const start = i;
                    while (i < end and md_is_attr_name_char(ctx.ch(i))) i += 1;
                    if (i == start) return false;
                }
            }
        }

        // Items are blank-separated: `a"b"`, `a=b"c"` and the like are junk.
        if (i < end and !ISBLANK_(ctx.ch(i))) return false;
    }

    return true;
}

// Is the well-formed attribute list `[beg, end)` nothing but bare keys —
// `{title}`, `{a b}` — with no `#id`, `.class`, `:key` or `key=value` item?
// That is the one shape an attribute run shares with a JSX-style `{expr}`,
// and the blank before the brace is what tells them apart: `**b**{title}`
// binds to the element it touches, `Hello {title}` is an expression in
// running text. `md_find_block_attrs` refuses such a run; Comark reads it as
// a boolean prop on the block (see docs/compatibility.md).
pub fn md_is_bare_attr_content(ctx: *MD_CTX, beg: OFF, end: OFF) bool {
    var i: OFF = beg;
    while (i < end) : (i += 1) {
        const ch = ctx.ch(i);
        if (ISBLANK_(ch)) continue;
        if (!(ISALPHA_(ch) or ch == '_')) return false;
        while (i < end and md_is_attr_key_char(ctx.ch(i))) i += 1;
        if (i < end and !ISBLANK_(ctx.ch(i))) return false;
    }
    return true;
}

// Offset of the `}` matching the `{` at `open_off`, or null when it has none.
fn md_match_brace(ctx: *MD_CTX, open_off: OFF) error{OutOfMemory}!?OFF {
    if (!ctx.brace_pairs_built) try md_build_brace_pairs(ctx);

    const pairs = ctx.brace_pairs.items;
    var lo: usize = 0;
    var hi: usize = pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pairs[mid].open < open_off) lo = mid + 1 else hi = mid;
    }
    if (lo < pairs.len and pairs[lo].open == open_off) return pairs[lo].close;
    return null;
}

// md4x.c ~3677.
pub fn md_resolve_links(ctx: *MD_CTX, lines: []const MD_LINE) c_int {
    var opener_index = ctx.unresolved_link_head;
    var last_link_beg: OFF = 0;
    var last_link_end: OFF = 0;
    var last_img_beg: OFF = 0;
    var last_img_end: OFF = 0;

    while (opener_index >= 0) {
        const opener = &ctx.marks.items[@intCast(opener_index)];
        const closer_index = opener.next;
        const closer = &ctx.marks.items[@intCast(closer_index)];
        var next_index = opener.prev;
        var next_opener: ?*MD_MARK = null;
        var next_closer: ?*MD_MARK = null;
        var attr: MD_LINK_ATTR = .{};
        var is_link: c_int = 0;

        if (opener.ch == 'D') {
            // We could have disabled this in a previous iteration (it fell
            // inside a resolved link URL); processing it would just burn CPU
            // cycles, or worse, resurrect a mark that was deliberately killed.
            opener_index = next_index;
            continue;
        }

        // Footnote-reference openers are never links: md_resolve_footnote_refs
        // resolves them after this pass has finished with the real links.
        if (opener.flags & MarkFlags.footnote_ref != 0) {
            opener_index = next_index;
            continue;
        }

        if (next_index >= 0) {
            next_opener = &ctx.marks.items[@intCast(next_index)];
            next_closer = &ctx.marks.items[@intCast(next_opener.?.next)];
        }

        if ((opener.beg < last_link_beg and closer.end < last_link_end) or
            (opener.beg < last_img_beg and closer.end < last_img_end) or
            (opener.beg < last_link_end and opener.ch == '['))
        {
            opener_index = next_index;
            continue;
        }

        if (next_opener != null and next_opener.?.beg == closer.end) {
            if (next_closer.?.beg > closer.end + 1) {
                // Might be full reference link.
                if (next_opener.?.flags & MarkFlags.has_nested_brackets == 0)
                    is_link = md_is_link_reference(ctx, lines, next_opener.?.beg, next_closer.?.end, &attr);
            } else {
                // Might be shortcut reference link.
                if (opener.flags & MarkFlags.has_nested_brackets == 0)
                    is_link = md_is_link_reference(ctx, lines, opener.beg, closer.end, &attr);
            }

            if (is_link < 0) return -1;

            if (is_link != 0) {
                closer.end = next_closer.?.end;
                next_index = ctx.marks.items[@intCast(next_index)].prev;
            }
        } else {
            if (closer.end < ctx.size and ctx.ch(closer.end) == '(') {
                // Might be inline link.
                var inline_link_end: OFF = OFF_MAX;
                // Hoisted out of the scan below: once the link is confirmed,
                // this is one past the last mark swallowed by the "(...)".
                var following_mark_index: c_int = closer_index + 1;
                is_link = md_is_inline_link_spec(ctx, lines, closer.end, &inline_link_end, &attr);
                if (is_link < 0) return -1;

                if (is_link != 0) {
                    while (following_mark_index < ctx.nMarks()) {
                        const m = &ctx.marks.items[@intCast(following_mark_index)];
                        if (m.beg >= inline_link_end) break;
                        if ((m.flags & (MarkFlags.opener | MarkFlags.resolved)) == (MarkFlags.opener | MarkFlags.resolved)) {
                            if (ctx.marks.items[@intCast(m.next)].beg >= inline_link_end) {
                                // Exact-length free: md_merge_lines_alloc shrank
                                // the merged title to `title_size`.
                                if (attr.title_needs_free) util.free_array_a(CHAR, ctx.alloc, attr.title, @intCast(attr.title_size));
                                is_link = 0;
                                break;
                            }
                            following_mark_index = m.next + 1;
                        } else {
                            following_mark_index += 1;
                        }
                    }
                }

                if (is_link != 0) {
                    // Eat the "(...)".
                    closer.end = inline_link_end;
                    // Everything the URL swallowed must stop being a mark, or an
                    // opener inside the URL pairs with a closer outside it and
                    // emits an unbalanced enter_span/leave_span.
                    md_disable_marks(ctx, closer_index + 1, following_mark_index);
                }
            }

            if (is_link == 0) {
                // Might be collapsed reference link.
                if (opener.flags & MarkFlags.has_nested_brackets == 0)
                    is_link = md_is_link_reference(ctx, lines, opener.beg, closer.end, &attr);
                if (is_link < 0) return -1;
            }

            if (is_link == 0 and opener.ch == '[') {
                // Might be a [text]{attrs} span.
                if (closer.end < ctx.size and ctx.ch(closer.end) == '{' and md_is_attr_opener(ctx, closer.end)) {
                    if (md_match_brace(ctx, closer.end) catch return -1) |brace_end| {
                        if (md_is_attr_content(ctx, closer.end + 1, brace_end)) {
                            is_link = 1;
                            ctx.marks.items[@intCast(opener_index + 1)].ch = 'S';
                            ctx.marks.items[@intCast(opener_index + 1)].beg = closer.end + 1;
                            ctx.marks.items[@intCast(opener_index + 1)].end = brace_end;
                            closer.end = brace_end + 1;
                        }
                    }
                }
            }
        }

        if (is_link != 0) {
            opener.flags |= MarkFlags.opener | MarkFlags.resolved;
            closer.flags |= MarkFlags.closer | MarkFlags.resolved;

            if (ctx.marks.items[@intCast(opener_index + 1)].ch == 'S') {
                md_analyze_link_contents(ctx, lines, opener_index + 1, closer_index);
            } else {
                ctx.marks.items[@intCast(opener_index + 1)].beg = attr.dest_beg;
                ctx.marks.items[@intCast(opener_index + 1)].end = attr.dest_end;

                md_mark_store_ptr(ctx, opener_index + 2, attr.title);
                if (attr.title_needs_free)
                    md_mark_stack_push(ctx, &ctx.ptr_stack, opener_index + 2);
                ctx.marks.items[@intCast(opener_index + 2)].prev = @bitCast(attr.title_size);

                if (opener.ch == '[') {
                    last_link_beg = opener.beg;
                    last_link_end = closer.end;
                } else {
                    last_img_beg = opener.beg;
                    last_img_end = closer.end;
                }

                md_analyze_link_contents(ctx, lines, opener_index + 1, closer_index);

                // If a permissive autolink is the link's entire label, drop it:
                // `[http://example.com](/x)` must not nest an <a> in an <a>.
                var first_nested_i: c_int = opener_index + 1;
                while (ctx.marks.items[@intCast(first_nested_i)].ch == 'D' and first_nested_i < closer_index) first_nested_i += 1;

                // NOTE: the C loop condition tests first_nested->ch (md4c quirk); preserved verbatim.
                var last_nested_i: c_int = closer_index - 1;
                while (ctx.marks.items[@intCast(first_nested_i)].ch == 'D' and last_nested_i > opener_index) last_nested_i -= 1;

                const first_nested = &ctx.marks.items[@intCast(first_nested_i)];
                const last_nested = &ctx.marks.items[@intCast(last_nested_i)];

                if ((first_nested.flags & MarkFlags.resolved != 0) and
                    first_nested.beg == opener.end and
                    ISANYOF_(first_nested.ch, "@:.") and
                    first_nested.next == last_nested_i and
                    last_nested.end == closer.beg)
                {
                    first_nested.ch = 'D';
                    first_nested.flags &= ~MarkFlags.resolved;
                    last_nested.ch = 'D';
                    last_nested.flags &= ~MarkFlags.resolved;
                }
            }
        }

        opener_index = next_index;
    }

    return 0;
}

// Resolve every `[^label]` footnote reference in the current block. Runs after
// md_resolve_links, so all real links are already resolved and any footnote
// opener that a link URL swallowed has been turned into
// a 'D' dummy (which is what the `ch != '['` guard below rejects — md4c
// 54bfec0, since the footnote_ref FLAG survives disabling but the char does not).
//
// An unknown label is simply left unresolved, so it renders as literal text.
// md4c a8b0d3e.
pub fn md_resolve_footnote_refs(ctx: *MD_CTX) void {
    var i: c_int = 0;
    while (i < ctx.nMarks()) : (i += 1) {
        const opener = &ctx.marks.items[@intCast(i)];

        if (opener.ch != '[' or (opener.flags & MarkFlags.footnote_ref) == 0)
            continue;
        if (opener.next < 0)
            continue; // No matching ']' was found.

        const closer = &ctx.marks.items[@intCast(opener.next)];
        if (closer.ch != ']')
            continue; // The closer was disabled; see md_disable_marks.

        // The label is the raw text between the marks: `opener.end` points past
        // `[^`, `closer.beg` at the `]`.
        const label_beg: OFF = opener.end;
        const label_end: OFF = closer.beg;
        if (label_beg >= label_end)
            continue; // Empty label.

        const def = md_lookup_footnote_def(ctx, ctx.str(label_beg), label_end - label_beg) orelse
            continue; // Unknown label -> stays literal text.

        // Assign the id on first reference; count every reference.
        if (def.index == 0) {
            ctx.next_footnote_index += 1;
            def.index = ctx.next_footnote_index;
        }
        def.ref_count += 1;

        // Park the public detail values in the dummy mark after the opener.
        const index_mark = &ctx.marks.items[@intCast(i + 1)];
        std.debug.assert(index_mark.ch == 'D');
        index_mark.beg = def.index;
        index_mark.end = def.ref_count;

        opener.flags |= MarkFlags.opener | MarkFlags.resolved;
        closer.flags |= MarkFlags.closer | MarkFlags.resolved;
    }
}

// md4x.c ~3977.
pub fn md_analyze_entity(ctx: *MD_CTX, mark_index: c_int) void {
    const opener = &ctx.marks.items[@intCast(mark_index)];
    var off: OFF = undefined;

    if (mark_index + 1 >= ctx.nMarks()) return;
    const closer = &ctx.marks.items[@intCast(mark_index + 1)];
    if (closer.ch != ';') return;

    if (md_is_entity(ctx, opener.beg, closer.end, &off)) {
        md_resolve_range(ctx, mark_index, mark_index + 1);
        opener.end = closer.end;
    }
}

// md4x.c ~4005.
pub fn md_analyze_table_cell_boundary(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks.items[@intCast(mark_index)];
    mark.flags |= MarkFlags.resolved;
    mark.next = -1;

    if (ctx.table_cell_boundaries_head < 0)
        ctx.table_cell_boundaries_head = mark_index
    else
        ctx.marks.items[@intCast(ctx.table_cell_boundaries_tail)].next = mark_index;
    ctx.table_cell_boundaries_tail = mark_index;
    ctx.n_table_cell_boundaries += 1;
}

// md4x.c ~4024. Split a longer mark into two; the new mark takes `n` chars.
pub fn md_split_emph_mark(ctx: *MD_CTX, mark_index: c_int, n: SZ) c_int {
    const mark = &ctx.marks.items[@intCast(mark_index)];
    const new_mark_index: c_int = mark_index + @as(c_int, @intCast(mark.end - mark.beg - n));
    const dummy = &ctx.marks.items[@intCast(new_mark_index)];

    dummy.* = mark.*;
    mark.end -= n;
    dummy.beg = mark.end;

    return new_mark_index;
}

// md4x.c ~4041.
pub fn md_analyze_emph(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks.items[@intCast(mark_index)];

    if (mark.flags & MarkFlags.potential_closer != 0) {
        var opener: ?*MD_MARK = null;
        var opener_index: c_int = 0;
        var opener_stacks: [6]*MD_MARKSTACK = undefined;
        var n_opener_stacks: usize = 0;
        const flags = mark.flags;

        opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MarkFlags.emph_mod3_0 | MarkFlags.emph_oc);
        n_opener_stacks += 1;
        if ((flags & MarkFlags.emph_mod3_mask) != MarkFlags.emph_mod3_2) {
            opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MarkFlags.emph_mod3_1 | MarkFlags.emph_oc);
            n_opener_stacks += 1;
        }
        if ((flags & MarkFlags.emph_mod3_mask) != MarkFlags.emph_mod3_1) {
            opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MarkFlags.emph_mod3_2 | MarkFlags.emph_oc);
            n_opener_stacks += 1;
        }
        opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MarkFlags.emph_mod3_0);
        n_opener_stacks += 1;
        if ((flags & MarkFlags.emph_oc == 0) or (flags & MarkFlags.emph_mod3_mask) != MarkFlags.emph_mod3_2) {
            opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MarkFlags.emph_mod3_1);
            n_opener_stacks += 1;
        }
        if ((flags & MarkFlags.emph_oc == 0) or (flags & MarkFlags.emph_mod3_mask) != MarkFlags.emph_mod3_1) {
            opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MarkFlags.emph_mod3_2);
            n_opener_stacks += 1;
        }

        var i: usize = 0;
        while (i < n_opener_stacks) : (i += 1) {
            if (opener_stacks[i].top >= 0) {
                const m_index = opener_stacks[i].top;
                const m = &ctx.marks.items[@intCast(m_index)];
                if (opener == null or m.end > opener.?.end) {
                    opener_index = m_index;
                    opener = m;
                }
            }
        }

        if (opener != null) {
            const opener_size = opener.?.end - opener.?.beg;
            const closer_size = mark.end - mark.beg;
            const stack = md_opener_stack(ctx, opener_index);

            if (opener_size > closer_size) {
                opener_index = md_split_emph_mark(ctx, opener_index, closer_size);
                md_mark_stack_push(ctx, stack, opener_index);
            } else if (opener_size < closer_size) {
                _ = md_split_emph_mark(ctx, mark_index, closer_size - opener_size);
            }

            _ = md_mark_stack_pop(ctx, stack);

            md_rollback(ctx, opener_index, mark_index, MD_ROLLBACK_CROSSING);
            md_resolve_range(ctx, opener_index, mark_index);
            return;
        }
    }

    if (mark.flags & MarkFlags.potential_opener != 0)
        md_mark_stack_push(ctx, md_emph_stack(ctx, mark.ch, mark.flags), mark_index);
}

// md4x.c ~4108.
pub fn md_analyze_tilde(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks.items[@intCast(mark_index)];
    const stack = md_opener_stack(ctx, mark_index);

    if ((mark.flags & MarkFlags.potential_closer != 0) and stack.top >= 0) {
        const opener_index = stack.top;
        _ = md_mark_stack_pop(ctx, stack);
        md_rollback(ctx, opener_index, mark_index, MD_ROLLBACK_CROSSING);
        md_resolve_range(ctx, opener_index, mark_index);
        return;
    }

    if (mark.flags & MarkFlags.potential_opener != 0)
        md_mark_stack_push(ctx, stack, mark_index);
}

// md4c d2a08e5 (post-fork-point). A plain LIFO resolver: `==` carries no
// flanking rules beyond the whitespace adjacency the collector already applied,
// and opener and closer are always the same length. `md_rollback` with
// MD_ROLLBACK_CROSSING is upstream's `md_pop_openers` — it pops every stack
// down past the opener without dummying the marks in between.
pub fn md_analyze_highlight(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks.items[@intCast(mark_index)];
    const stack = &ctx.opener_stacks[EQUAL_OPENERS];

    // Defensive: the collector only ever emits runs of exactly two.
    if (mark.end - mark.beg != 2) return;

    if ((mark.flags & MarkFlags.potential_closer != 0) and stack.top >= 0) {
        const opener_index = stack.top;
        md_rollback(ctx, opener_index, mark_index, MD_ROLLBACK_CROSSING);
        md_resolve_range(ctx, opener_index, mark_index);
        return;
    }

    if (mark.flags & MarkFlags.potential_opener != 0)
        md_mark_stack_push(ctx, stack, mark_index);
}

// md4x.c ~4131.
pub fn md_analyze_dollar(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks.items[@intCast(mark_index)];

    if ((mark.flags & MarkFlags.potential_closer != 0) and ctx.opener_stacks[DOLLAR_OPENERS].top >= 0) {
        const opener = &ctx.marks.items[@intCast(ctx.opener_stacks[DOLLAR_OPENERS].top)];
        const opener_index = ctx.opener_stacks[DOLLAR_OPENERS].top;
        const closer = mark;
        const closer_index = mark_index;

        if (opener.end - opener.beg == closer.end - closer.beg) {
            _ = md_mark_stack_pop(ctx, &ctx.opener_stacks[DOLLAR_OPENERS]);
            md_rollback(ctx, opener_index, closer_index, MD_ROLLBACK_ALL);
            md_resolve_range(ctx, opener_index, closer_index);
            ctx.opener_stacks[DOLLAR_OPENERS].top = -1;
            return;
        }
    }

    if (mark.flags & MarkFlags.potential_opener != 0)
        md_mark_stack_push(ctx, &ctx.opener_stacks[DOLLAR_OPENERS], mark_index);
}

// The cursor the two scans below carry across calls is a SIGNED MARK INDEX, not
// a pointer. Both walks legitimately run one step past their end — the left one
// down to -1, the right one up to `nMarks()` — and only the right of those is a
// legal pointer value. Forming `marks.items.ptr - 1` was out-of-range pointer
// arithmetic (poison under `getelementptr`), and the left scan additionally
// STORED it through `p_cursor` for the next call to read back. An `isize` index
// represents both out-of-range terminals exactly, with no pointer ever formed.
pub const MarkCursor = isize;

// md4x.c ~4159.
pub fn md_scan_left_for_resolved_mark(ctx: *MD_CTX, mark_from: MarkCursor, off: OFF, p_cursor: ?*MarkCursor) ?*MD_MARK {
    var idx = mark_from;
    while (idx >= 0) : (idx -= 1) {
        const mark = &ctx.marks.items[@intCast(idx)];
        if (mark.ch == 'D' or mark.beg > off) continue;
        if (mark.beg <= off and off < mark.end and (mark.flags & MarkFlags.resolved != 0)) {
            if (p_cursor != null) p_cursor.?.* = idx;
            return mark;
        }
        if (mark.end <= off) break;
    }
    if (p_cursor != null) p_cursor.?.* = idx;
    return null;
}

// md4x.c ~4181.
pub fn md_scan_right_for_resolved_mark(ctx: *MD_CTX, mark_from: MarkCursor, off: OFF, p_cursor: ?*MarkCursor) ?*MD_MARK {
    var idx = mark_from;
    const n_marks: MarkCursor = ctx.nMarks();
    while (idx < n_marks) : (idx += 1) {
        const mark = &ctx.marks.items[@intCast(idx)];
        if (mark.ch == 'D' or mark.end <= off) continue;
        if (mark.beg <= off and off < mark.end and (mark.flags & MarkFlags.resolved != 0)) {
            if (p_cursor != null) p_cursor.?.* = idx;
            return mark;
        }
        if (mark.beg > off) break;
    }
    if (p_cursor != null) p_cursor.?.* = idx;
    return null;
}

// md4x.c ~4381.
//
// Scans one segment of a suspected permissive autolink (e-mail user name,
// hostname, path, query or fragment), each parameterized by its component
// delimiter, the extra non-alnum characters allowed inside a word
// (`word_extra`) and the delimiters allowed *between* two words
// (`word_delims`). A word delimiter that ends the run is rolled back, so it
// stays outside the link.
//
// `off_in` is the start offset; the scan runs towards `end` (backwards when
// `scan_backwards`, i.e. `off_in > end`). Writes the resulting offset through
// `p_end` and returns the number of components, or -1 on unbalanced brackets.
//
// NOTE: `off -= 1` / `off - 1` cannot underflow: backwards scans only step
// while `off != end` with `off > end >= 0`, and every forward call site passes
// `off_in >= 1` (the opener mark of a permissive autolink always ends at least
// one byte into the line).
fn md_analyze_permissive_autolink_segment(
    ctx: *MD_CTX,
    off_in: OFF,
    end: OFF,
    p_end: *OFF,
    scan_backwards: bool,
    component_delim: CHAR,
    word_extra: [*:0]const u8,
    word_delims: [*:0]const u8,
    p_cursor: *MarkCursor,
) c_int {
    var off: OFF = off_in;
    var n_components: c_int = 0;
    var n_open_brackets: c_int = 0;
    var seen_word_delim: bool = true;
    var seen_component_delim: bool = true;
    var component_beg: OFF = off;

    while (off != end) {
        if (scan_backwards) off -= 1;

        // Only accept extra and delimiter characters if they're not part of a
        // resolved mark.
        if (!ctx.isAlnum(off) and !ctx.isWhitespace(off)) {
            if ((!scan_backwards and md_scan_right_for_resolved_mark(ctx, p_cursor.*, off, p_cursor) != null) or
                (scan_backwards and md_scan_left_for_resolved_mark(ctx, p_cursor.*, off, p_cursor) != null))
            {
                if (scan_backwards) off += 1;
                break;
            }
        }

        // The autolink can be _inside_ brackets so we disallow unbalanced
        // bracket pairs in the URL. (Note the brackets are not allowed in
        // e-mail username, so we happily skip this in that case.)
        if (!scan_backwards) {
            if (ctx.ch(off) == '(') {
                n_open_brackets += 1;
            } else if (ctx.ch(off) == ')') {
                if (n_open_brackets <= 0) break;
                n_open_brackets -= 1;
            }
        }

        if (ctx.isAlnum(off) or ctx.isAnyOf(off, word_extra)) {
            seen_word_delim = false;
            seen_component_delim = false;
        } else {
            if (seen_word_delim) break;

            if (ctx.isAnyOf(off, word_delims)) {
                seen_word_delim = true;
            } else if (component_delim != 0 and ctx.ch(off) == component_delim) {
                if (seen_component_delim) break;
                seen_component_delim = true;
                component_beg = off;
                n_components += 1;
            } else {
                if (scan_backwards) off += 1;
                break;
            }
        }

        if (!scan_backwards) off += 1;
    }

    // Rollback falsely consumed delimiter.
    if (seen_word_delim or seen_component_delim)
        off = if (scan_backwards) off + 1 else off - 1;

    if (off != component_beg) n_components += 1;

    if (n_open_brackets != 0) return -1;

    p_end.* = off;
    return n_components;
}

// md4x.c ~4459.
pub fn md_analyze_permissive_autolink(ctx: *MD_CTX, mark_index: c_int) void {
    const opener = &ctx.marks.items[@intCast(mark_index)];
    const closer = &ctx.marks.items[@intCast(mark_index + 1)]; // The dummy.
    const line_beg: OFF = closer.beg;
    const line_end: OFF = closer.end;
    var beg: OFF = opener.beg;
    var end: OFF = opener.end;
    var left_cursor: MarkCursor = mark_index;
    var right_cursor: MarkCursor = mark_index;

    // E-mail requires the user name (before '@', i.e. scanning backwards).
    if (opener.ch == '@') {
        if (md_analyze_permissive_autolink_segment(ctx, beg, line_beg, &beg, true, 0, "", ".-_+", &left_cursor) < 1)
            return;
    }

    // Verify there's line boundary, whitespace, allowed punctuation or resolved
    // opener mark just before the suspected autolink.
    if (beg > line_beg and !ctx.isUnicodeWhitespaceBefore(beg) and !ctx.isAnyOf(beg - 1, "({[")) {
        const left_mark = md_scan_left_for_resolved_mark(ctx, left_cursor, beg - 1, &left_cursor);
        if (left_mark == null or (left_mark.?.flags & MarkFlags.opener == 0)) return;
    }

    // Scan for hostname segment. Hostname is mandatory and requires at least
    // two components delimited with a dot.
    if (md_analyze_permissive_autolink_segment(ctx, end, line_end, &end, false, '.', "", "-_", &right_cursor) < 2)
        return;

    if (opener.ch != '@') {
        // Scan for path segment.
        if (end < line_end and ctx.ch(end) == '/') {
            if (md_analyze_permissive_autolink_segment(ctx, end + 1, line_end, &end, false, '/', ".+-_~%", "", &right_cursor) < 0)
                return;

            // Path can also end with additional '/' if its a directory.
            if (end < line_end and ctx.ch(end) == '/') end += 1;
        }

        // Scan for query segment.
        if (end < line_end and ctx.ch(end) == '?') {
            if (md_analyze_permissive_autolink_segment(ctx, end + 1, line_end, &end, false, '&', "._=()", "+-", &right_cursor) < 0)
                return;
        }

        // Scan for fragment segment.
        if (end < line_end and ctx.ch(end) == '#') {
            if (md_analyze_permissive_autolink_segment(ctx, end + 1, line_end, &end, false, 0, "", ".-+_", &right_cursor) < 0)
                return;
        }
    }

    // Verify there's line boundary, whitespace, allowed punctuation or resolved
    // closer mark just after the suspected autolink.
    if (end < line_end and !ctx.isUnicodeWhitespace(end) and !ctx.isAnyOf(end, ")}].!?,;")) {
        const right_mark = md_scan_right_for_resolved_mark(ctx, right_cursor, end, &right_cursor);
        if (right_mark == null or (right_mark.?.flags & MarkFlags.closer == 0)) return;
    }

    // Success, we are an autolink.
    opener.beg = beg;
    opener.end = beg;
    closer.beg = end;
    closer.end = end;
    closer.ch = opener.ch;
    md_resolve_range(ctx, mark_index, mark_index + 1);
}

pub const MD_ANALYZE_NOSKIP_EMPH: u8 = 0x01;

// md4x.c ~4344.
pub fn md_analyze_marks(ctx: *MD_CTX, lines: []const MD_LINE, mark_beg: c_int, mark_end: c_int, mark_chars: [*:0]const u8, flags: u8) void {
    var i: c_int = mark_beg;
    var last_end: OFF = lines[0].beg;

    while (i < mark_end) {
        const mark = &ctx.marks.items[@intCast(i)];

        if (mark.flags & MarkFlags.resolved != 0) {
            if ((mark.flags & MarkFlags.opener != 0) and mark.ch != 'C' and
                !((flags & MD_ANALYZE_NOSKIP_EMPH != 0) and ISANYOF_(mark.ch, "*_~=")))
            {
                i = mark.next + 1;
            } else {
                i += 1;
            }
            continue;
        }

        if (!ISANYOF_(mark.ch, mark_chars)) {
            i += 1;
            continue;
        }

        if (mark.beg < last_end) {
            i += 1;
            continue;
        }

        switch (mark.ch) {
            '[', '!', ']' => md_analyze_bracket(ctx, i),
            '&' => md_analyze_entity(ctx, i),
            '|' => md_analyze_table_cell_boundary(ctx, i),
            '_', '*' => md_analyze_emph(ctx, i),
            '~' => md_analyze_tilde(ctx, i),
            '$' => md_analyze_dollar(ctx, i),
            '=' => md_analyze_highlight(ctx, i),
            '.', ':', '@' => md_analyze_permissive_autolink(ctx, i),
            else => {},
        }

        if (mark.flags & MarkFlags.resolved != 0) {
            if (mark.flags & MarkFlags.opener != 0)
                last_end = ctx.marks.items[@intCast(mark.next)].end
            else
                last_end = mark.end;
        }

        i += 1;
    }
}

// md4x.c ~4410.
pub fn md_push_inline_attr(ctx: *MD_CTX, closer_index: c_int, attrs_beg: OFF, attrs_end: OFF) error{OutOfMemory}!void {
    ctx.inline_attrs.append(ctx.alloc, .{
        .closer_index = closer_index,
        .attrs_beg = attrs_beg,
        .attrs_end = attrs_end,
        .skip_end = attrs_end + 1,
    }) catch {
        ctx.log("realloc() failed.");
        return error.OutOfMemory;
    };
}

// md4x.c ~4436.
pub fn md_find_inline_attr(ctx: *MD_CTX, closer_index: c_int, raw: *[*c]const CHAR, size: *SZ, skip_end: ?*OFF) c_int {
    if (skip_end != null) skip_end.?.* = 0;
    for (ctx.inline_attrs.items) |attr| {
        if (attr.closer_index == closer_index) {
            raw.* = ctx.str(attr.attrs_beg);
            size.* = attr.attrs_end - attr.attrs_beg;
            if (skip_end != null) skip_end.?.* = attr.skip_end;
            return 1;
        }
    }
    return 0;
}

// md4x.c ~4454.
pub fn md_resolve_attrs(ctx: *MD_CTX) c_int {
    ctx.inline_attrs.clearRetainingCapacity();

    var i: c_int = 0;
    while (i < ctx.nMarks()) : (i += 1) {
        const mark = &ctx.marks.items[@intCast(i)];

        if (mark.flags & MarkFlags.resolved == 0) continue;
        if (mark.flags & MarkFlags.closer == 0) continue;
        if (mark.ch == 'C') continue;
        if (mark.ch == 'D') continue;
        if (mark.ch != '*' and mark.ch != '_' and mark.ch != '`' and mark.ch != '~' and mark.ch != '=' and mark.ch != ']') continue;

        if (mark.ch == ']') {
            const opener_index = mark.prev;
            if (opener_index >= 0) {
                const opener = &ctx.marks.items[@intCast(opener_index)];
                if (opener_index + 1 < ctx.nMarks() and ctx.marks.items[@intCast(opener_index + 1)].ch == 'S') continue;
                if (opener.ch == '[' and opener.end - opener.beg >= 2 and mark.end - mark.beg >= 2) continue;
                // `[^1]{.cls}`: footnote wins, the attrs are not consumed. The
                // span is self-contained (no text between enter and leave), so
                // there is nothing for a `{...}` to attach to, and stretching
                // the closer's `end` here would silently eat the braces from the
                // output. Neither md4c nor md4x had a rule; this is the choice.
                if (opener.ch == '[' and (opener.flags & MarkFlags.footnote_ref) != 0) continue;
            }
        }

        if (mark.end >= ctx.size or ctx.ch(mark.end) != '{') continue;
        if (!md_is_attr_opener(ctx, mark.end)) continue;

        const brace_end = (md_match_brace(ctx, mark.end) catch return -1) orelse continue;

        const attrs_beg = mark.end + 1;
        if (!md_is_attr_content(ctx, attrs_beg, brace_end)) continue;
        md_push_inline_attr(ctx, i, attrs_beg, brace_end) catch return -1;

        if (mark.ch != '*' and mark.ch != '_') mark.end = brace_end + 1;
    }

    return 0;
}

// md4x.c ~4538.
pub fn md_analyze_inlines(ctx: *MD_CTX, lines: []const MD_LINE, table_mode: bool) c_int {
    var ret: c_int = 0;

    ctx.marks.clearRetainingCapacity();

    ret = md_collect_marks(ctx, lines, table_mode);
    if (ret != 0) return ret;

    // (1) Links.
    md_analyze_marks(ctx, lines, 0, ctx.nMarks(), "[]!", 0);
    ret = md_resolve_links(ctx, lines);
    if (ret != 0) return ret;
    ctx.opener_stacks[BRACKET_OPENERS].top = -1;
    ctx.unresolved_link_head = -1;
    ctx.unresolved_link_tail = -1;

    // (1b) Footnote references. Must run after links, so a footnote pair inside
    // a resolved link is still found and one inside a link URL is already dead.
    md_resolve_footnote_refs(ctx);

    if (table_mode) {
        // (2) Table cell boundaries.
        ctx.n_table_cell_boundaries = 0;
        md_analyze_marks(ctx, lines, 0, ctx.nMarks(), "|", 0);
        return ret;
    }

    // (3) Emphasis/strong; permissive autolinks.
    md_analyze_link_contents(ctx, lines, 0, ctx.nMarks());

    // (4) Trailing {attrs}.
    ret = md_resolve_attrs(ctx);
    if (ret != 0) return ret;

    return ret;
}

// md4x.c ~4574.
pub fn md_analyze_link_contents(ctx: *MD_CTX, lines: []const MD_LINE, mark_beg: c_int, mark_end: c_int) void {
    md_analyze_marks(ctx, lines, mark_beg, mark_end, "&", 0);
    // Every mark char is listed literally; md4c built these strings from the
    // dialect flags, but md4x has one dialect so the sets are constant.
    md_analyze_marks(ctx, lines, mark_beg, mark_end, "*_~$=", 0);
    md_analyze_marks(ctx, lines, mark_beg, mark_end, "@:.", MD_ANALYZE_NOSKIP_EMPH);

    var i: usize = 0;
    while (i < ctx.opener_stacks.len) : (i += 1) ctx.opener_stacks[i].top = -1;
}

// ---- Span enter/leave helpers + emission (md4x.c ~4594..5197) ----

pub inline fn mdEnterSpan(ctx: *MD_CTX, detail: *const c.SpanDetail) c_int {
    const ret = ctx.parser.enter_span(detail, ctx.userdata);
    if (ret != 0) ctx.log("Aborted from enter_span() callback.");
    return ret;
}

pub inline fn mdLeaveSpan(ctx: *MD_CTX, detail: *const c.SpanDetail) c_int {
    const ret = ctx.parser.leave_span(detail, ctx.userdata);
    if (ret != 0) ctx.log("Aborted from leave_span() callback.");
    return ret;
}

// The pointer+size shape is kept for the ~30 internal call sites (which all
// derive their run from `ctx.str(off)` plus an offset delta); the slice the
// callback contract wants is formed here, at the single emission boundary.
pub inline fn mdText(ctx: *MD_CTX, ty: c.TextType, str: [*c]const CHAR, size: SZ) c_int {
    if (size > 0) {
        const ret = ctx.parser.text(ty, str[0..size], ctx.userdata);
        if (ret != 0) {
            ctx.log("Aborted from text() callback.");
            return ret;
        }
    }
    return 0;
}

// md4x.c ~4594.
pub fn md_enter_leave_span_a(ctx: *MD_CTX, enter: bool, ty: c.SpanType, dest: [*c]const CHAR, dest_size: SZ, is_autolink: bool, title: [*c]const CHAR, title_size: SZ) c_int {
    var href_build: MD_ATTRIBUTE_BUILD = .{};
    var title_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.SpanADetail = .{};
    var ret: c_int = 0;

    md_build_attribute(ctx, dest, dest_size, if (is_autolink) MD_BUILD_ATTR_NO_ESCAPES else 0, &det.href, &href_build) catch {
        ret = -1;
    };
    if (ret == 0) {
        md_build_attribute(ctx, title, title_size, 0, &det.title, &title_build) catch {
            ret = -1;
        };
    }
    if (ret == 0) {
        det.is_autolink = is_autolink;
        const d = spanADetailFor(ty, det);
        ret = if (enter) mdEnterSpan(ctx, &d) else mdLeaveSpan(ctx, &d);
    }

    md_free_attribute(ctx, &href_build);
    md_free_attribute(ctx, &title_build);
    return ret;
}

// The em/strong/code/del/u detail. A null `raw_a` (no trailing `{...}`) is the
// empty slice: before Phase 4c step 3 these spans got a NULL detail pointer
// instead, but every consumer's guard was `detail != null and
// raw_attrs.len > 0`, so the two cases were never distinguishable.
inline fn attrsDetail(raw_a: [*c]const CHAR, raw_a_sz: SZ) c.SpanAttrsDetail {
    return .{ .raw_attrs = if (raw_a != null) raw_a[0..raw_a_sz] else &.{} };
}

// `ty` here is either `.a` or `.img` — the link and image paths share one
// builder. Before Phase 4c the `.img` case handed the renderer a
// `MD_SPAN_A_DETAIL*` that it blind-cast to `MD_SPAN_IMG_DETAIL*`, relying on
// the two structs sharing a prefix layout; the union makes the projection
// explicit (and the field values it produces are exactly what the old cast
// read).
inline fn spanADetailFor(ty: c.SpanType, det: c.SpanADetail) c.SpanDetail {
    return switch (ty) {
        .img => .{ .img = .{ .src = det.href, .title = det.title, .raw_attrs = det.raw_attrs } },
        else => .{ .a = det },
    };
}

// md4x.c ~4643.
pub fn md_enter_leave_span_component(ctx: *MD_CTX, enter: bool, tag: [*c]const CHAR, tag_size: SZ, raw_props: [*c]const CHAR, raw_props_size: SZ) c_int {
    var tag_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.SpanComponentDetail = .{};
    var ret: c_int = 0;

    md_build_attribute(ctx, tag, tag_size, 0, &det.tag_name, &tag_build) catch {
        ret = -1;
    };
    if (ret == 0) {
        if (raw_props != null) det.raw_props = raw_props[0..raw_props_size];
        const d: c.SpanDetail = .{ .component = det };
        ret = if (enter) mdEnterSpan(ctx, &d) else mdLeaveSpan(ctx, &d);
    }

    md_free_attribute(ctx, &tag_build);
    return ret;
}

// md4x.c ~4669.
pub fn md_enter_leave_span_a_with_attrs(ctx: *MD_CTX, enter: bool, ty: c.SpanType, dest: [*c]const CHAR, dest_size: SZ, is_autolink: bool, title: [*c]const CHAR, title_size: SZ, raw_attrs: [*c]const CHAR, raw_attrs_size: SZ) c_int {
    var href_build: MD_ATTRIBUTE_BUILD = .{};
    var title_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.SpanADetail = .{};
    var ret: c_int = 0;

    md_build_attribute(ctx, dest, dest_size, if (is_autolink) MD_BUILD_ATTR_NO_ESCAPES else 0, &det.href, &href_build) catch {
        ret = -1;
    };
    if (ret == 0) {
        md_build_attribute(ctx, title, title_size, 0, &det.title, &title_build) catch {
            ret = -1;
        };
    }
    if (ret == 0) {
        det.is_autolink = is_autolink;
        if (raw_attrs != null) det.raw_attrs = raw_attrs[0..raw_attrs_size];
        const d = spanADetailFor(ty, det);
        ret = if (enter) mdEnterSpan(ctx, &d) else mdLeaveSpan(ctx, &d);
    }

    md_free_attribute(ctx, &href_build);
    md_free_attribute(ctx, &title_build);
    return ret;
}

// A footnote reference is emitted as a SELF-CONTAINED span: enter and leave fire
// back to back with no text callback between them, so the renderer gets
// everything from the detail. md4c a8b0d3e.
pub fn md_enter_leave_span_footnote_ref(ctx: *MD_CTX, id: c_uint, ref_id: c_uint, label: [*c]const CHAR, label_size: SZ) c_int {
    var label_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.SpanFootnoteRefDetail = .{ .id = id, .ref_id = ref_id };
    var ret: c_int = 0;

    md_build_attribute(ctx, label, label_size, 0, &det.label, &label_build) catch {
        ret = -1;
    };
    if (ret == 0) {
        const d: c.SpanDetail = .{ .footnote_ref = det };
        ret = mdEnterSpan(ctx, &d);
        if (ret == 0) ret = mdLeaveSpan(ctx, &d);
    }

    md_free_attribute(ctx, &label_build);
    return ret;
}

// md4x.c ~4700.
pub fn md_enter_leave_span_span(ctx: *MD_CTX, enter: bool, raw_attrs: [*c]const CHAR, raw_attrs_size: SZ) c_int {
    var det: c.SpanSpanDetail = .{};
    if (raw_attrs != null) det.raw_attrs = raw_attrs[0..raw_attrs_size];
    const d: c.SpanDetail = .{ .span = det };
    return if (enter) mdEnterSpan(ctx, &d) else mdLeaveSpan(ctx, &d);
}

// Emit a verbatim (code / latexmath / raw HTML) text run from a table cell,
// substituting `|` for every `\|`.
//
// GFM splits a table row on unescaped `|` *before* inline parsing, and drops the
// backslash of an escaped one while building the cell's string. The escape
// therefore takes effect even inside a code span, where an ordinary inline
// backslash escape does nothing: `` `\|` `` is `<code>|</code>` (GFM example
// 200). md4x parses cells in place -- there is no per-cell string to rewrite --
// so the unescape happens at emission instead, by breaking the run into pieces
// around each `\|`.
//
// Only verbatim runs need this. In normal text the `\|` was collected as an
// escape mark and md_process_inlines already emits just the `|`.
fn md_emit_verbatim_text(ctx: *MD_CTX, text_type: c.TextType, beg: OFF, end: OFF) c_int {
    var seg: OFF = beg;
    var off: OFF = beg;

    while (off + 1 < end) : (off += 1) {
        if (ctx.ch(off) != '\\' or ctx.ch(off + 1) != '|') continue;

        if (off > seg) {
            const ret = mdText(ctx, text_type, ctx.str(seg), off - seg);
            if (ret != 0) return ret;
        }
        const ret = mdText(ctx, text_type, "|", 1);
        if (ret != 0) return ret;

        off += 1;
        seg = off + 1;
    }

    if (end > seg) return mdText(ctx, text_type, ctx.str(seg), end - seg);
    return 0;
}

// md4x.c ~4721. Render the output per the analyzed ctx.marks.
pub fn md_process_inlines(ctx: *MD_CTX, lines: []const MD_LINE) c_int {
    var text_type: c.TextType = undefined;
    var line: [*c]const MD_LINE = lines.ptr;
    var mark: [*c]MD_MARK = undefined;
    var off: OFF = lines[0].beg;
    const end: OFF = lines[lines.len - 1].end;
    var tmp: OFF = undefined;
    // While a code/latexmath span is open, where its closer begins. The
    // line-joining rule below needs the span's own end, not the paragraph's.
    var span_end: OFF = 0;
    var attr_skip_to: OFF = 0;
    var enforce_hardbreak: c_int = 0;
    var ret: c_int = 0;

    mark = ctx.marks.items.ptr;
    while (mark.*.flags & MarkFlags.resolved == 0) mark += 1;

    text_type = c.TextType.normal;

    main: while (true) {
        tmp = if (line.*.end < mark.*.beg) line.*.end else mark.*.beg;
        if (tmp > off) {
            ret = if (ctx.in_table_cell and text_type != c.TextType.normal)
                md_emit_verbatim_text(ctx, text_type, off, tmp)
            else
                mdText(ctx, text_type, ctx.str(off), tmp - off);
            if (ret != 0) return ret;
            off = tmp;
        }

        if (off >= mark.*.beg) {
            switch (mark.*.ch) {
                '\\' => {
                    if (ctx.isNewline(mark.*.beg + 1)) {
                        enforce_hardbreak = 1;
                    } else {
                        ret = mdText(ctx, text_type, ctx.str(mark.*.beg + 1), 1);
                        if (ret != 0) return ret;
                    }
                },

                ' ' => {
                    ret = mdText(ctx, text_type, " ", 1);
                    if (ret != 0) return ret;
                },

                '`' => {
                    var raw_a: [*c]const CHAR = null;
                    var raw_a_sz: SZ = 0;
                    if (mark.*.flags & MarkFlags.opener != 0)
                        _ = md_find_inline_attr(ctx, mark.*.next, &raw_a, &raw_a_sz, null)
                    else
                        _ = md_find_inline_attr(ctx, @intCast((@intFromPtr(mark) - @intFromPtr(ctx.marks.items.ptr)) / @sizeOf(MD_MARK)), &raw_a, &raw_a_sz, null);

                    const det: c.SpanDetail = .{ .code = attrsDetail(raw_a, raw_a_sz) };
                    if (mark.*.flags & MarkFlags.opener != 0) {
                        ret = mdEnterSpan(ctx, &det);
                        if (ret != 0) return ret;
                        text_type = c.TextType.code;
                        span_end = ctx.marks.items[@intCast(mark.*.next)].beg;
                    } else {
                        ret = mdLeaveSpan(ctx, &det);
                        if (ret != 0) return ret;
                        text_type = c.TextType.normal;
                    }
                },

                '_', '*' => {
                    ret = emitEmphasis(ctx, mark, &off, &attr_skip_to);
                    if (ret != 0) return ret;
                },

                '~' => {
                    var raw_a: [*c]const CHAR = null;
                    var raw_a_sz: SZ = 0;
                    if (mark.*.flags & MarkFlags.opener != 0)
                        _ = md_find_inline_attr(ctx, mark.*.next, &raw_a, &raw_a_sz, null)
                    else
                        _ = md_find_inline_attr(ctx, @intCast((@intFromPtr(mark) - @intFromPtr(ctx.marks.items.ptr)) / @sizeOf(MD_MARK)), &raw_a, &raw_a_sz, null);

                    const det: c.SpanDetail = .{ .del = attrsDetail(raw_a, raw_a_sz) };
                    if (mark.*.flags & MarkFlags.opener != 0) {
                        ret = mdEnterSpan(ctx, &det);
                    } else {
                        ret = mdLeaveSpan(ctx, &det);
                    }
                    if (ret != 0) return ret;
                },

                // Highlight (`==x==`). Unlike md4c this span carries a
                // SpanAttrsDetail so `==x=={.cls}` composes with ATTRIBUTES;
                // md_resolve_attrs has already stretched the closer's `end`
                // over the `{...}`, which is also why there is no
                // `end - beg == 2` guard here (md4c has one, and it is
                // unreachable there: the collector only emits runs of two).
                '=' => {
                    var raw_a: [*c]const CHAR = null;
                    var raw_a_sz: SZ = 0;
                    if (mark.*.flags & MarkFlags.opener != 0)
                        _ = md_find_inline_attr(ctx, mark.*.next, &raw_a, &raw_a_sz, null)
                    else
                        _ = md_find_inline_attr(ctx, @intCast((@intFromPtr(mark) - @intFromPtr(ctx.marks.items.ptr)) / @sizeOf(MD_MARK)), &raw_a, &raw_a_sz, null);

                    const det: c.SpanDetail = .{ .mark = attrsDetail(raw_a, raw_a_sz) };
                    if (mark.*.flags & MarkFlags.opener != 0) {
                        ret = mdEnterSpan(ctx, &det);
                    } else {
                        ret = mdLeaveSpan(ctx, &det);
                    }
                    if (ret != 0) return ret;
                },

                '$' => {
                    const math_inline: c.SpanDetail = .{ .latexmath = {} };
                    const math_display: c.SpanDetail = .{ .latexmath_display = {} };
                    if (mark.*.flags & MarkFlags.opener != 0) {
                        ret = mdEnterSpan(ctx, if ((mark.*.end - off) % 2 != 0) &math_inline else &math_display);
                        if (ret != 0) return ret;
                        text_type = c.TextType.latexmath;
                        span_end = ctx.marks.items[@intCast(mark.*.next)].beg;
                    } else {
                        ret = mdLeaveSpan(ctx, if ((mark.*.end - off) % 2 != 0) &math_inline else &math_display);
                        if (ret != 0) return ret;
                        text_type = c.TextType.normal;
                    }
                },

                '[', '!', ']' => {
                    const opener: [*c]MD_MARK = if (mark.*.ch != ']') mark else &ctx.marks.items[@intCast(mark.*.prev)];
                    const closer: [*c]MD_MARK = &ctx.marks.items[@intCast(opener.*.next)];

                    // Footnote reference: self-contained span, no text emitted.
                    // Only the opener is ever seen here — the opener's `end` is
                    // redirected past the whole `[^label]`, so the post-switch
                    // `off = mark.end` skips the label text and the `]` closer.
                    if (opener.*.flags & MarkFlags.footnote_ref != 0) {
                        const index_mark: [*c]MD_MARK = opener + 1;
                        ret = md_enter_leave_span_footnote_ref(ctx, index_mark.*.beg, index_mark.*.end, ctx.str(opener.*.end), closer.*.beg - opener.*.end);
                        if (ret != 0) return ret;
                        mark.*.end = closer.*.end;
                    } else {
                        const dest_mark: [*c]MD_MARK = opener + 1;
                        const title_mark: [*c]MD_MARK = opener + 2;

                        if (dest_mark.*.ch == 'S') {
                            const raw_a = ctx.str(dest_mark.*.beg);
                            const raw_a_sz = dest_mark.*.end - dest_mark.*.beg;
                            ret = md_enter_leave_span_span(ctx, mark.*.ch != ']', raw_a, raw_a_sz);
                            if (ret != 0) return ret;

                            if (mark.*.ch == ']') {
                                while (mark.*.end > line.*.end and @intFromPtr(line) < @intFromPtr(&lines[lines.len - 1])) line += 1;
                            }
                        } else {
                            var raw_a: [*c]const CHAR = null;
                            var raw_a_sz: SZ = 0;
                            const closer_idx: c_int = @intCast((@intFromPtr(closer) - @intFromPtr(ctx.marks.items.ptr)) / @sizeOf(MD_MARK));
                            _ = md_find_inline_attr(ctx, closer_idx, &raw_a, &raw_a_sz, null);

                            const title_ptr: [*c]const CHAR = @ptrCast(@alignCast(md_mark_get_ptr(ctx, @intCast((@intFromPtr(title_mark) - @intFromPtr(ctx.marks.items.ptr)) / @sizeOf(MD_MARK)))));
                            const title_sz: SZ = @bitCast(title_mark.*.prev);

                            if (raw_a != null) {
                                ret = md_enter_leave_span_a_with_attrs(ctx, mark.*.ch != ']', if (opener.*.ch == '!') c.SpanType.img else c.SpanType.a, ctx.str(dest_mark.*.beg), dest_mark.*.end - dest_mark.*.beg, false, title_ptr, title_sz, raw_a, raw_a_sz);
                            } else {
                                ret = md_enter_leave_span_a(ctx, mark.*.ch != ']', if (opener.*.ch == '!') c.SpanType.img else c.SpanType.a, ctx.str(dest_mark.*.beg), dest_mark.*.end - dest_mark.*.beg, false, title_ptr, title_sz);
                            }
                            if (ret != 0) return ret;

                            if (mark.*.ch == ']') {
                                while (mark.*.end > line.*.end and @intFromPtr(line) < @intFromPtr(&lines[lines.len - 1])) line += 1;
                            }
                        }
                    }
                },

                // Interpolation run: one verbatim text callback for the whole
                // `{{ ... }}`, newlines included. The opener's `end` is moved
                // past the closer so the loop skips the interior and the
                // closer mark alike (the same trick as a footnote reference).
                '{' => {
                    const closer: [*c]MD_MARK = &ctx.marks.items[@intCast(mark.*.next)];
                    ret = if (ctx.in_table_cell)
                        md_emit_verbatim_text(ctx, c.TextType.binding, mark.*.beg, closer.*.end)
                    else
                        mdText(ctx, c.TextType.binding, ctx.str(mark.*.beg), closer.*.end - mark.*.beg);
                    if (ret != 0) return ret;
                    mark.*.end = closer.*.end;
                    while (mark.*.end > line.*.end and @intFromPtr(line) < @intFromPtr(&lines[lines.len - 1])) line += 1;
                },
                '}' => {},

                '<', '>' => {
                    if (mark.*.flags & MarkFlags.autolink == 0) {
                        // Raw HTML.
                        if (mark.*.flags & MarkFlags.opener != 0)
                            text_type = c.TextType.html
                        else
                            text_type = c.TextType.normal;
                    } else {
                        ret = emitPermissiveAutolink(ctx, mark, off);
                        if (ret != 0) return ret;
                    }
                },

                '@', ':', '.' => {
                    ret = emitPermissiveAutolink(ctx, mark, off);
                    if (ret != 0) return ret;
                },

                '&' => {
                    ret = mdText(ctx, c.TextType.entity, ctx.str(mark.*.beg), mark.*.end - mark.*.beg);
                    if (ret != 0) return ret;
                },

                // Emoji shortcode: the whole `:name:` run is replaced by the
                // emoji's UTF-8 bytes, as ordinary text, so every renderer
                // inherits the substitution with no new SAX surface.
                //
                // The table is re-probed here rather than parked in the mark:
                // MD_MARK has no field to spare (the `prev`/`next` pointer-store
                // trick is the link machinery's), and this runs once per emoji
                // actually emitted over a name the collector already matched.
                'E' => {
                    const name: [*]const u8 = @ptrCast(ctx.str(mark.*.beg + 1));
                    if (emoji.emoji_lookup(name[0 .. mark.*.end - mark.*.beg - 2])) |chars| {
                        ret = mdText(ctx, text_type, @ptrCast(chars.ptr), @intCast(chars.len));
                    } else {
                        ret = mdText(ctx, text_type, ctx.str(mark.*.beg), mark.*.end - mark.*.beg);
                    }
                    if (ret != 0) return ret;
                },

                'C' => {
                    const opener: [*c]MD_MARK = if (mark.*.flags & MarkFlags.opener != 0) mark else &ctx.marks.items[@intCast(mark.*.prev)];
                    const closer: [*c]MD_MARK = &ctx.marks.items[@intCast(opener.*.next)];
                    const props_mark: [*c]MD_MARK = opener + 1;
                    const tag_str = ctx.str(opener.*.beg + 1);
                    var name_end_off: OFF = opener.*.beg + 1;
                    var raw_props: [*c]const CHAR = null;
                    var raw_props_size: SZ = 0;

                    while (name_end_off < opener.*.end and (ctx.isAlnum(name_end_off) or ctx.ch(name_end_off) == '-')) name_end_off += 1;
                    const tag_size: SZ = name_end_off - (opener.*.beg + 1);

                    if (props_mark.*.ch == 'D' and props_mark.*.end > props_mark.*.beg) {
                        raw_props = ctx.str(props_mark.*.beg);
                        raw_props_size = props_mark.*.end - props_mark.*.beg;
                    }

                    if (mark.*.flags & MarkFlags.opener != 0) {
                        ret = md_enter_leave_span_component(ctx, true, tag_str, tag_size, raw_props, raw_props_size);
                        if (ret != 0) return ret;
                        if (opener.*.end == closer.*.beg) {
                            ret = md_enter_leave_span_component(ctx, false, tag_str, tag_size, raw_props, raw_props_size);
                            if (ret != 0) return ret;
                        }
                    } else {
                        if (opener.*.end != closer.*.beg) {
                            ret = md_enter_leave_span_component(ctx, false, tag_str, tag_size, raw_props, raw_props_size);
                            if (ret != 0) return ret;
                        }
                    }
                },

                0 => {
                    ret = mdText(ctx, c.TextType.nullchar, "", 1);
                    if (ret != 0) return ret;
                },

                127 => break :main,

                else => {},
            }

            if (attr_skip_to > 0) {
                off = attr_skip_to;
                attr_skip_to = 0;
            } else {
                off = mark.*.end;
            }

            mark += 1;
            while ((mark.*.flags & MarkFlags.resolved == 0) or mark.*.beg < off) mark += 1;
        }

        if (off >= line.*.end) {
            if (off >= end) break :main;

            if (text_type == c.TextType.code or text_type == c.TextType.latexmath) {
                tmp = off;
                while (off < ctx.size and ctx.isBlank(off)) off += 1;
                if (off > tmp) {
                    ret = mdText(ctx, text_type, ctx.str(tmp), off - tmp);
                    if (ret != 0) return ret;
                }
                // The line ending itself becomes one space (CommonMark 6.1:
                // "line endings are converted to spaces"). Testing `off ==
                // line->end` -- what md4c does -- silently drops that space
                // whenever the line carried trailing blanks, because
                // md_analyze_line has already trimmed them off `line->end`
                // while the loop above re-emits them verbatim: `off` then sits
                // past `line->end`, not on it. Ask the question directly
                // instead -- are we standing on the line terminator? -- which
                // is also false in the one case the old test was guarding
                // against, a span closer having advanced `off` into a later
                // line. Spec examples 335, 337 and 640.
                //
                // `off < span_end` keeps the span's *final* line ending out of
                // it: md_resolve_codespans has already pulled the closer in
                // past a stripped leading/trailing space, so a newline at the
                // closer was consumed by that strip and owes no space. Note
                // `end` is the whole paragraph's end and is useless here.
                // Example 336 (`` ``\nfoo \n`` `` -> `foo `, not `foo  `).
                if (off < span_end and ctx.isNewline(off)) {
                    ret = mdText(ctx, text_type, " ", 1);
                    if (ret != 0) return ret;
                }
            } else if (text_type == c.TextType.html) {
                tmp = off;
                while (tmp < end and ctx.isBlank(tmp)) tmp += 1;
                if (tmp > off) {
                    ret = mdText(ctx, c.TextType.html, ctx.str(off), tmp - off);
                    if (ret != 0) return ret;
                }
                ret = mdText(ctx, c.TextType.html, "\n", 1);
                if (ret != 0) return ret;
            } else {
                var break_type: c.TextType = c.TextType.softbr;

                if (text_type == c.TextType.normal) {
                    if (enforce_hardbreak != 0) {
                        break_type = c.TextType.br;
                    } else {
                        while (off < ctx.size and ctx.isBlank(off)) off += 1;
                        if (off >= line.*.end + 2 and ctx.ch(off - 2) == ' ' and ctx.ch(off - 1) == ' ' and ctx.isNewline(off))
                            break_type = c.TextType.br;
                    }
                }

                ret = mdText(ctx, break_type, "\n", 1);
                if (ret != 0) return ret;
            }

            line += 1;
            // Do not skip back: a span closer may already have advanced `off`
            // past the beginning of this line, and those bytes are consumed.
            off = @max(off, line.*.beg);
            enforce_hardbreak = 0;
        }
    }

    return ret;
}

// Emit emphasis/strong for '*' and '_'. md4x.c ~4838.
pub fn emitEmphasis(ctx: *MD_CTX, mark: [*c]MD_MARK, off_p: *OFF, attr_skip_to: *OFF) c_int {
    var ret: c_int = 0;
    var raw_a: [*c]const CHAR = null;
    var raw_a_sz: SZ = 0;
    if (mark.*.flags & MarkFlags.opener != 0)
        _ = md_find_inline_attr(ctx, mark.*.next, &raw_a, &raw_a_sz, null)
    else
        _ = md_find_inline_attr(ctx, @intCast((@intFromPtr(mark) - @intFromPtr(ctx.marks.items.ptr)) / @sizeOf(MD_MARK)), &raw_a, &raw_a_sz, attr_skip_to);

    // Only the outermost em/strong of a `*`-run carries the trailing {attrs};
    // the nested ones get a bare detail.
    const attrs = attrsDetail(raw_a, raw_a_sz);
    const em_attrs: c.SpanDetail = .{ .em = attrs };
    const em_bare: c.SpanDetail = .{ .em = .{} };
    const strong_attrs: c.SpanDetail = .{ .strong = attrs };
    const strong_bare: c.SpanDetail = .{ .strong = .{} };

    var off = off_p.*;
    if (mark.*.flags & MarkFlags.opener != 0) {
        var first: c_int = 1;
        if ((mark.*.end - off) % 2 != 0) {
            ret = mdEnterSpan(ctx, if (first != 0 and raw_a != null) &em_attrs else &em_bare);
            if (ret != 0) {
                off_p.* = off;
                return ret;
            }
            first = 0;
            off += 1;
        }
        while (off + 1 < mark.*.end) {
            ret = mdEnterSpan(ctx, if (first != 0 and raw_a != null) &strong_attrs else &strong_bare);
            if (ret != 0) {
                off_p.* = off;
                return ret;
            }
            first = 0;
            off += 2;
        }
    } else {
        const total: c_int = @intCast(mark.*.end - off);
        const has_em = @mod(total, 2);
        const n_strong = @divTrunc(total, 2);
        var si: c_int = 0;
        while (off + 1 < mark.*.end) {
            si += 1;
            ret = mdLeaveSpan(ctx, if (has_em == 0 and si == n_strong and raw_a != null) &strong_attrs else &strong_bare);
            if (ret != 0) {
                off_p.* = off;
                return ret;
            }
            off += 2;
        }
        if (has_em != 0) {
            ret = mdLeaveSpan(ctx, if (raw_a != null) &em_attrs else &em_bare);
            if (ret != 0) {
                off_p.* = off;
                return ret;
            }
            off += 1;
        }
    }
    off_p.* = off;
    return ret;
}

// Emit permissive autolink / autolink (the '@', ':', '.', and '<'/'>'-autolink
// fallthrough case). md4x.c ~5038.
pub fn emitPermissiveAutolink(ctx: *MD_CTX, mark: [*c]MD_MARK, off: OFF) c_int {
    var ret: c_int = 0;
    const opener: [*c]MD_MARK = if (mark.*.flags & MarkFlags.opener != 0) mark else &ctx.marks.items[@intCast(mark.*.prev)];
    const closer: [*c]MD_MARK = &ctx.marks.items[@intCast(opener.*.next)];
    var dest: [*c]const CHAR = ctx.str(opener.*.end);
    var dest_size: SZ = closer.*.beg - opener.*.end;
    _ = off;

    if (mark.*.flags & MarkFlags.opener != 0)
        closer.*.flags |= MarkFlags.valid_permissive_autolink;

    if (opener.*.ch == '@' or opener.*.ch == '.' or
        (opener.*.ch == '<' and (opener.*.flags & MarkFlags.autolink_missing_mailto != 0)))
    {
        dest_size += 7;
        if (md_temp_buffer(ctx, dest_size * @sizeOf(CHAR)) != 0) return -1;
        const prefix: [*c]const CHAR = if (opener.*.ch == '.') "http://" else "mailto:";
        @memcpy(@as([*]u8, @ptrCast(ctx.buffer))[0..7], @as([*]const u8, @ptrCast(prefix))[0..7]);
        @memcpy(@as([*]u8, @ptrCast(ctx.buffer + 7))[0..@intCast(dest_size - 7)], @as([*]const u8, @ptrCast(dest))[0..@intCast(dest_size - 7)]);
        dest = ctx.buffer;
    }

    if (closer.*.flags & MarkFlags.valid_permissive_autolink != 0)
        ret = md_enter_leave_span_a(ctx, mark.*.flags & MarkFlags.opener != 0, c.SpanType.a, dest, dest_size, true, null, 0);
    return ret;
}
