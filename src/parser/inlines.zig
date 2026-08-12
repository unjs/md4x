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

const c = types.c;
const CHAR = types.CHAR;
const SZ = types.SZ;
const OFF = types.OFF;
const OFF_MAX = types.OFF_MAX;
const MD_SIZE = types.MD_SIZE;
const TRUE = types.TRUE;
const FALSE = types.FALSE;
const MD_CTX = types.MD_CTX;
const MD_LINE = types.MD_LINE;
const MD_MARK = types.MD_MARK;
const MD_MARKSTACK = types.MD_MARKSTACK;
const MD_INLINE_ATTR_INFO = types.MD_INLINE_ATTR_INFO;
const c_allocator = types.c_allocator;
const CODESPAN_MARK_MAXLEN = types.CODESPAN_MARK_MAXLEN;
const MD_MARK_POTENTIAL_OPENER = types.MD_MARK_POTENTIAL_OPENER;
const MD_MARK_POTENTIAL_CLOSER = types.MD_MARK_POTENTIAL_CLOSER;
const MD_MARK_OPENER = types.MD_MARK_OPENER;
const MD_MARK_CLOSER = types.MD_MARK_CLOSER;
const MD_MARK_RESOLVED = types.MD_MARK_RESOLVED;
const MD_MARK_EMPH_OC = types.MD_MARK_EMPH_OC;
const MD_MARK_EMPH_MOD3_0 = types.MD_MARK_EMPH_MOD3_0;
const MD_MARK_EMPH_MOD3_1 = types.MD_MARK_EMPH_MOD3_1;
const MD_MARK_EMPH_MOD3_2 = types.MD_MARK_EMPH_MOD3_2;
const MD_MARK_EMPH_MOD3_MASK = types.MD_MARK_EMPH_MOD3_MASK;
const MD_MARK_AUTOLINK = types.MD_MARK_AUTOLINK;
const MD_MARK_AUTOLINK_MISSING_MAILTO = types.MD_MARK_AUTOLINK_MISSING_MAILTO;
const MD_MARK_VALIDPERMISSIVEAUTOLINK = types.MD_MARK_VALIDPERMISSIVEAUTOLINK;
const MD_MARK_HASNESTEDBRACKETS = types.MD_MARK_HASNESTEDBRACKETS;

const ISANYOF_ = util.ISANYOF_;
const ISWHITESPACE_ = util.ISWHITESPACE_;
const MD_ATTRIBUTE_BUILD = util.MD_ATTRIBUTE_BUILD;
const MD_BUILD_ATTR_NO_ESCAPES = util.MD_BUILD_ATTR_NO_ESCAPES;
const md_ascii_eq = util.md_ascii_eq;
const md_build_attribute = util.md_build_attribute;
const md_free_attribute = util.md_free_attribute;
const md_is_entity = util.md_is_entity;
const md_lookup_line = util.md_lookup_line;
const md_temp_buffer = util.md_temp_buffer;
const c_realloc_array = util.c_realloc_array;

const MD_LINK_ATTR = refdefs.MD_LINK_ATTR;
const md_is_autolink = refdefs.md_is_autolink;
const md_is_inline_link_spec = refdefs.md_is_inline_link_spec;
const md_is_link_reference = refdefs.md_is_link_reference;

// ============================================================================
//  Pass C — Raw HTML recognizers (needed by md_collect_marks). These are
//  shared with Pass D block analysis (HTML block type 7) but only depend on
//  char helpers + md_ascii_eq + md_lookup_line, so they live here.
// ============================================================================

// Faithful port of md_is_html_tag (md4x.c ~1131). n_lines == 0 => whole tag
// must be on one line (block-start probe).
pub fn md_is_html_tag(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var attr_state: c_int = undefined;
    var off: OFF = beg;
    var line_end: OFF = if (lines.len > 0) lines[0].end else ctx.size;
    var line_index: MD_SIZE = 0;

    if (off + 1 >= line_end) return FALSE;
    off += 1;

    attr_state = 0;

    if (ctx.ch(off) == '/') {
        attr_state = -1;
        off += 1;
    }

    // Tag name.
    if (off >= line_end or !ctx.isAlpha(off)) return FALSE;
    off += 1;
    while (off < line_end and (ctx.isAlnum(off) or ctx.ch(off) == '-')) off += 1;

    while (true) {
        while (off < line_end and !ctx.isNewline(off)) {
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
                if (off >= max_end) return FALSE;
                p_end.* = off + 1;
                return TRUE;
            } else if (attr_state <= 2 and ctx.ch(off) == '/' and off + 1 < line_end and ctx.ch(off + 1) == '>') {
                // End with digraph '/>'.
                off += 1;
                if (off >= max_end) return FALSE;
                p_end.* = off + 1;
                return TRUE;
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
                    return FALSE;
                }
                off += 1;
            } else {
                return FALSE;
            }
        }

        // Must be on a single line (HTML block start cond. type 7).
        if (lines.len == 0) return FALSE;

        line_index += 1;
        if (line_index >= lines.len) return FALSE;

        off = lines[line_index].beg;
        line_end = lines[line_index].end;

        if (attr_state == 0 or attr_state == 41) attr_state = 1;

        if (off >= max_end) return FALSE;
    }
}

// Faithful port of md_scan_for_html_closer (md4x.c ~1249).
pub fn md_scan_for_html_closer(ctx: *MD_CTX, str: [*c]const CHAR, len: MD_SIZE, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF, p_scan_horizon: *OFF) c_int {
    var off: OFF = beg;
    var line_index: MD_SIZE = 0;

    if (off < p_scan_horizon.* and p_scan_horizon.* >= max_end -% len) {
        return FALSE;
    }

    while (true) {
        while (off + len <= lines[line_index].end and off + len <= max_end) {
            if (md_ascii_eq(ctx.str(off), str, len) != 0) {
                p_end.* = off + len;
                return TRUE;
            }
            off += 1;
        }

        line_index += 1;
        if (off >= max_end or line_index >= lines.len) {
            p_scan_horizon.* = off;
            return FALSE;
        }

        off = lines[line_index].beg;
    }
}

pub fn md_is_html_comment(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off: OFF = beg;
    if (off + 4 >= lines[0].end) return FALSE;
    if (ctx.ch(off + 1) != '!' or ctx.ch(off + 2) != '-' or ctx.ch(off + 3) != '-') return FALSE;
    off += 2; // Skip only "<!" so we accept "<!-->" or "<!--->".
    return md_scan_for_html_closer(ctx, "-->", 3, lines, off, max_end, p_end, &ctx.html_comment_horizon);
}

pub fn md_is_html_processing_instruction(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off: OFF = beg;
    if (off + 2 >= lines[0].end) return FALSE;
    if (ctx.ch(off + 1) != '?') return FALSE;
    off += 2;
    return md_scan_for_html_closer(ctx, "?>", 2, lines, off, max_end, p_end, &ctx.html_proc_instr_horizon);
}

pub fn md_is_html_declaration(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off: OFF = beg;
    if (off + 2 >= lines[0].end) return FALSE;
    if (ctx.ch(off + 1) != '!') return FALSE;
    off += 2;
    if (off >= lines[0].end or !ctx.isAlpha(off)) return FALSE;
    off += 1;
    while (off < lines[0].end and ctx.isAlpha(off)) off += 1;
    return md_scan_for_html_closer(ctx, ">", 1, lines, off, max_end, p_end, &ctx.html_decl_horizon);
}

pub fn md_is_html_cdata(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    const open_str = "<![CDATA[";
    const open_size: SZ = open_str.len;
    var off: OFF = beg;
    if (off + open_size >= lines[0].end) return FALSE;
    if (std.mem.eql(u8, @as([*]const u8, @ptrCast(ctx.str(off)))[0..open_size], open_str) == false) return FALSE;
    off += open_size;
    return md_scan_for_html_closer(ctx, "]]>", 3, lines, off, max_end, p_end, &ctx.html_cdata_horizon);
}

pub fn md_is_html_any(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    if (md_is_html_tag(ctx, lines, beg, max_end, p_end) != 0) return TRUE;
    if (md_is_html_comment(ctx, lines, beg, max_end, p_end) != 0) return TRUE;
    if (md_is_html_processing_instruction(ctx, lines, beg, max_end, p_end) != 0) return TRUE;
    if (md_is_html_declaration(ctx, lines, beg, max_end, p_end) != 0) return TRUE;
    if (md_is_html_cdata(ctx, lines, beg, max_end, p_end) != 0) return TRUE;
    return FALSE;
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

// md4x.c ~2609. Returns the base index into ctx.opener_stacks for the given
// emphasis char + flags (applying the EMPH_OC offset of +3 and the mod3 offset).
pub fn md_emph_stack_index(ch: CHAR, flags: u8) usize {
    var idx: usize = switch (ch) {
        '*' => ASTERISK_OPENERS_oo_mod3_0,
        '_' => UNDERSCORE_OPENERS_oo_mod3_0,
        else => unreachable,
    };

    if (flags & MD_MARK_EMPH_OC != 0) idx += 3;

    switch (flags & MD_MARK_EMPH_MOD3_MASK) {
        MD_MARK_EMPH_MOD3_0 => idx += 0,
        MD_MARK_EMPH_MOD3_1 => idx += 1,
        MD_MARK_EMPH_MOD3_2 => idx += 2,
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

pub inline fn md_resolve_range(ctx: *MD_CTX, opener_index: c_int, closer_index: c_int) void {
    const opener = &ctx.marks.items[@intCast(opener_index)];
    const closer = &ctx.marks.items[@intCast(closer_index)];
    opener.next = closer_index;
    closer.prev = opener_index;
    opener.flags |= MD_MARK_OPENER | MD_MARK_RESOLVED;
    closer.flags |= MD_MARK_CLOSER | MD_MARK_RESOLVED;
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
            ctx.marks.items[@intCast(j)].ch = 'D';
            ctx.marks.items[@intCast(j)].flags = 0;
        }
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

    const flags = ctx.parser.flags;
    if (flags & c.MD_FLAG_STRIKETHROUGH != 0) ctx.mark_char_map['~'] = 1;
    if (flags & c.MD_FLAG_LATEXMATHSPANS != 0) ctx.mark_char_map['$'] = 1;
    if (flags & c.MD_FLAG_PERMISSIVEEMAILAUTOLINKS != 0) ctx.mark_char_map['@'] = 1;
    if (flags & (c.MD_FLAG_PERMISSIVEURLAUTOLINKS | c.MD_FLAG_COMPONENTS) != 0) ctx.mark_char_map[':'] = 1;
    if (flags & c.MD_FLAG_PERMISSIVEWWWAUTOLINKS != 0) ctx.mark_char_map['.'] = 1;
    if ((flags & c.MD_FLAG_TABLES != 0) or (flags & c.MD_FLAG_WIKILINKS != 0)) ctx.mark_char_map['|'] = 1;

    if (flags & c.MD_FLAG_COLLAPSEWHITESPACE != 0) {
        var i: usize = 0;
        while (i < ctx.mark_char_map.len) : (i += 1) {
            if (ISWHITESPACE_(@bitCast(@as(u8, @intCast(i))))) ctx.mark_char_map[i] = 1;
        }
    }
}

// md4x.c ~2828. Detect a code span starting at `beg`.
pub fn md_is_code_span(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, opener: *MD_MARK, closer: *MD_MARK, last_potential_closers: *[CODESPAN_MARK_MAXLEN]OFF, p_reached_paragraph_end: *c_int) c_int {
    const opener_beg: OFF = beg;
    var opener_end: OFF = undefined;
    var closer_beg: OFF = undefined;
    var closer_end: OFF = undefined;
    var mark_len: SZ = undefined;
    var line_end: OFF = undefined;
    var has_space_after_opener: c_int = FALSE;
    var has_eol_after_opener: c_int = FALSE;
    var has_space_before_closer: c_int = FALSE;
    var has_eol_before_closer: c_int = FALSE;
    var has_only_space: c_int = TRUE;
    var line_index: MD_SIZE = 0;

    line_end = lines[0].end;
    opener_end = opener_beg;
    while (opener_end < line_end and ctx.ch(opener_end) == '`') opener_end += 1;
    has_space_after_opener = @intFromBool(opener_end < line_end and ctx.ch(opener_end) == ' ');
    has_eol_after_opener = @intFromBool(opener_end == line_end);

    opener.end = opener_end;

    mark_len = opener_end - opener_beg;
    if (mark_len > CODESPAN_MARK_MAXLEN) return FALSE;

    if (last_potential_closers[mark_len - 1] >= lines[lines.len - 1].end or
        (p_reached_paragraph_end.* != 0 and last_potential_closers[mark_len - 1] < opener_end))
        return FALSE;

    closer_beg = opener_end;
    closer_end = opener_end;

    while (true) {
        while (closer_beg < line_end and ctx.ch(closer_beg) != '`') {
            if (ctx.ch(closer_beg) != ' ') has_only_space = FALSE;
            closer_beg += 1;
        }
        closer_end = closer_beg;
        while (closer_end < line_end and ctx.ch(closer_end) == '`') closer_end += 1;

        if (closer_end - closer_beg == mark_len) {
            has_space_before_closer = @intFromBool(closer_beg > lines[line_index].beg and ctx.ch(closer_beg - 1) == ' ');
            has_eol_before_closer = @intFromBool(closer_beg == lines[line_index].beg);
            break;
        }

        if (closer_end - closer_beg > 0) {
            has_only_space = FALSE;
            if (closer_end - closer_beg < CODESPAN_MARK_MAXLEN) {
                const li = closer_end - closer_beg - 1;
                if (closer_beg > last_potential_closers[li]) last_potential_closers[li] = closer_beg;
            }
        }

        if (closer_end >= line_end) {
            line_index += 1;
            if (line_index >= lines.len) {
                p_reached_paragraph_end.* = TRUE;
                return FALSE;
            }
            line_end = lines[line_index].end;
            closer_beg = lines[line_index].beg;
        } else {
            closer_beg = closer_end;
        }
    }

    if (has_only_space == FALSE and
        (has_space_after_opener != 0 or has_eol_after_opener != 0) and
        (has_space_before_closer != 0 or has_eol_before_closer != 0))
    {
        if (has_space_after_opener != 0) {
            opener_end += 1;
        } else {
            opener_end = lines[1].beg;
        }

        if (has_space_before_closer != 0) {
            closer_beg -= 1;
        } else {
            closer_beg = lines[line_index - 1].end;
            while (closer_beg < ctx.size and ctx.isBlank(closer_beg)) closer_beg += 1;
        }
    }

    opener.ch = '`';
    opener.beg = opener_beg;
    opener.end = opener_end;
    opener.flags = MD_MARK_POTENTIAL_OPENER;
    closer.ch = '`';
    closer.beg = closer_beg;
    closer.end = closer_end;
    closer.flags = MD_MARK_POTENTIAL_CLOSER;
    return TRUE;
}

// md4x.c ~3056. Collect all significant marks for the given lines.
pub fn md_collect_marks(ctx: *MD_CTX, lines: []const MD_LINE, table_mode: c_int) c_int {
    var line_index: MD_SIZE = 0;
    var ret: c_int = 0;
    var codespan_last_potential_closers = [_]OFF{0} ** CODESPAN_MARK_MAXLEN;
    var codespan_scanned_till_paragraph_end: c_int = FALSE;

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
                    if (addMark(ctx, ch, off, off + 2, MD_MARK_RESOLVED) == null) {
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

                    if (left_level > 0 and left_level >= right_level) flags |= MD_MARK_POTENTIAL_CLOSER;
                    if (right_level > 0 and right_level >= left_level) flags |= MD_MARK_POTENTIAL_OPENER;
                    if (flags == (MD_MARK_POTENTIAL_OPENER | MD_MARK_POTENTIAL_CLOSER)) flags |= MD_MARK_EMPH_OC;

                    switch ((tmp - off) % 3) {
                        0 => flags |= MD_MARK_EMPH_MOD3_0,
                        1 => flags |= MD_MARK_EMPH_MOD3_1,
                        2 => flags |= MD_MARK_EMPH_MOD3_2,
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
                if (is_code_span != 0) {
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
                if (addMark(ctx, ch, off, off + 1, MD_MARK_POTENTIAL_OPENER) == null) {
                    ret = -1;
                    return ret;
                }
                off += 1;
                continue :scan;
            }

            // Potential entity end.
            if (ch == ';') {
                if (ctx.nMarks() > 0 and ctx.marks.items[@intCast(ctx.nMarks() - 1)].ch == '&') {
                    if (addMark(ctx, ch, off, off + 1, MD_MARK_POTENTIAL_CLOSER) == null) {
                        ret = -1;
                        return ret;
                    }
                }
                off += 1;
                continue :scan;
            }

            // Potential autolink or raw HTML start/end.
            if (ch == '<') {
                if (ctx.parser.flags & c.MD_FLAG_NOHTMLSPANS == 0) {
                    var html_end: OFF = undefined;
                    const is_html = md_is_html_any(ctx, line[0 .. lines.len - line_index], off, lines[lines.len - 1].end, &html_end);
                    if (is_html != 0) {
                        if (addMark(ctx, '<', off, off, MD_MARK_OPENER | MD_MARK_RESOLVED) == null) {
                            ret = -1;
                            return ret;
                        }
                        if (addMark(ctx, '>', html_end, html_end, MD_MARK_CLOSER | MD_MARK_RESOLVED) == null) {
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
                }

                var autolink_end: OFF = undefined;
                var missing_mailto: c_int = undefined;
                const is_autolink = md_is_autolink(ctx, off, lines[lines.len - 1].end, &autolink_end, &missing_mailto);
                if (is_autolink != 0) {
                    var flags: u8 = MD_MARK_RESOLVED | MD_MARK_AUTOLINK;
                    if (missing_mailto != 0) flags |= MD_MARK_AUTOLINK_MISSING_MAILTO;

                    if (addMark(ctx, '<', off, off + 1, MD_MARK_OPENER | flags) == null) {
                        ret = -1;
                        return ret;
                    }
                    if (addMark(ctx, '>', autolink_end - 1, autolink_end, MD_MARK_CLOSER | flags) == null) {
                        ret = -1;
                        return ret;
                    }
                    ctx.marks.items[@intCast(ctx.nMarks() - 2)].next = ctx.nMarks() - 1;
                    ctx.marks.items[@intCast(ctx.nMarks() - 1)].prev = ctx.nMarks() - 2;
                    off = autolink_end;
                    continue :scan;
                }

                off += 1;
                continue :scan;
            }

            // Potential link or its part.
            if (ch == '[' or (ch == '!' and off + 1 < line.*.end and ctx.ch(off + 1) == '[')) {
                const tmp: OFF = if (ch == '[') off + 1 else off + 2;
                if (addMark(ctx, ch, off, tmp, MD_MARK_POTENTIAL_OPENER) == null) {
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
                if (addMark(ctx, ch, off, off + 1, MD_MARK_POTENTIAL_CLOSER) == null) {
                    ret = -1;
                    return ret;
                }
                off += 1;
                continue :scan;
            }

            // Potential permissive e-mail autolink.
            if (ch == '@') {
                if (line.*.beg + 1 <= off and ctx.isAlnum(off - 1) and off + 3 < line.*.end and ctx.isAlnum(off + 1)) {
                    if (addMark(ctx, ch, off, off + 1, MD_MARK_POTENTIAL_OPENER) == null) {
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

            // Potential inline component or permissive URL autolink.
            if (ch == ':') {
                comp: {
                    if ((ctx.parser.flags & c.MD_FLAG_COMPONENTS != 0) and
                        off + 1 < line.*.end and ctx.isAlpha(off + 1) and
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
                                if (addMark(ctx, 'C', off, opener_end, MD_MARK_OPENER | MD_MARK_RESOLVED) == null) {
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
                                if (addMark(ctx, 'C', off, opener_end, MD_MARK_OPENER | MD_MARK_RESOLVED) == null) {
                                    ret = -1;
                                    return ret;
                                }
                                if (addMark(ctx, 'D', props_beg, props_end, 0) == null) {
                                    ret = -1;
                                    return ret;
                                }
                                if (addMark(ctx, 'C', closer_beg, closer_end, MD_MARK_CLOSER | MD_MARK_RESOLVED) == null) {
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
                if (ctx.parser.flags & c.MD_FLAG_PERMISSIVEURLAUTOLINKS != 0) {
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

                        if (line.*.beg + scheme_size <= off and md_ascii_eq(ctx.str(off - scheme_size), scheme, scheme_size) != 0 and
                            off + 1 + suffix_size < line.*.end and md_ascii_eq(ctx.str(off + 1), suffix, suffix_size) != 0)
                        {
                            if (addMark(ctx, ch, off - scheme_size, off + 1 + suffix_size, MD_MARK_POTENTIAL_OPENER) == null) {
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
                if (line.*.beg + 3 <= off and md_ascii_eq(ctx.str(off - 3), "www", 3) != 0 and
                    (off - 3 == line.*.beg or ctx.isUnicodeWhitespaceBefore(off - 3) or ctx.isUnicodePunctBefore(off - 3)))
                {
                    if (addMark(ctx, ch, off - 3, off + 1, MD_MARK_POTENTIAL_OPENER) == null) {
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

            // Potential table cell boundary or wiki link label delimiter.
            if ((table_mode != 0 or ctx.parser.flags & c.MD_FLAG_WIKILINKS != 0) and ch == '|') {
                if (addMark(ctx, ch, off, off + 1, 0) == null) {
                    ret = -1;
                    return ret;
                }
                off += 1;
                continue :scan;
            }

            // Potential strikethrough/equation start/end.
            if (ch == '$' or ch == '~') {
                var tmp: OFF = off + 1;
                while (tmp < line.*.end and ctx.ch(tmp) == ch) tmp += 1;

                if (tmp - off <= 2) {
                    var flags: u8 = MD_MARK_POTENTIAL_OPENER | MD_MARK_POTENTIAL_CLOSER;
                    if (off > line.*.beg and !ctx.isUnicodeWhitespaceBefore(off) and !ctx.isUnicodePunctBefore(off))
                        flags &= ~MD_MARK_POTENTIAL_OPENER;
                    if (tmp < line.*.end and !ctx.isUnicodeWhitespace(tmp) and !ctx.isUnicodePunct(tmp))
                        flags &= ~MD_MARK_POTENTIAL_CLOSER;
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
                    if (addMark(ctx, ch, off, tmp, MD_MARK_RESOLVED) == null) {
                        ret = -1;
                        return ret;
                    }
                }
                off = tmp;
                continue :scan;
            }

            // NULL character.
            if (ch == 0) {
                if (addMark(ctx, ch, off, off + 1, MD_MARK_RESOLVED) == null) {
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
            ctx.marks.items[@intCast(insert_pos)].flags = MD_MARK_CLOSER | MD_MARK_RESOLVED;
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
    if (addMark(ctx, 127, ctx.size, ctx.size, MD_MARK_RESOLVED) == null) {
        ret = -1;
        return ret;
    }

    return ret;
}

// md4x.c ~3628.
pub fn md_analyze_bracket(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks.items[@intCast(mark_index)];

    if (mark.flags & MD_MARK_POTENTIAL_OPENER != 0) {
        if (ctx.opener_stacks[BRACKET_OPENERS].top >= 0)
            ctx.marks.items[@intCast(ctx.opener_stacks[BRACKET_OPENERS].top)].flags |= MD_MARK_HASNESTEDBRACKETS;
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
        var is_link: c_int = FALSE;

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

        // Wiki links: [[destination]] or [[destination|label]].
        if ((ctx.parser.flags & c.MD_FLAG_WIKILINKS != 0) and
            (opener.end - opener.beg == 1) and
            next_opener != null and
            next_opener.?.ch == '[' and
            (next_opener.?.beg == opener.beg -% 1) and
            (next_opener.?.end - next_opener.?.beg == 1) and
            next_closer != null and
            next_closer.?.ch == ']' and
            (next_closer.?.beg == closer.beg + 1) and
            (next_closer.?.end - next_closer.?.beg == 1))
        {
            var delim: ?*MD_MARK = null;
            var delim_index: c_int = opener_index + 1;
            var dest_beg: OFF = undefined;
            var dest_end: OFF = undefined;

            is_link = TRUE;

            while (delim_index < closer_index) {
                const m = &ctx.marks.items[@intCast(delim_index)];
                if (m.ch == '|') {
                    delim = m;
                    break;
                }
                if (m.ch != 'D') {
                    if (m.beg - opener.end > 100) break;
                    if (m.ch != 'D' and (m.flags & MD_MARK_OPENER != 0)) delim_index = m.next;
                }
                delim_index += 1;
            }

            dest_beg = opener.end;
            dest_end = if (delim != null) delim.?.beg else closer.beg;
            if (dest_end - dest_beg == 0 or dest_end - dest_beg > 100) is_link = FALSE;

            if (is_link != 0) {
                var off: OFF = dest_beg;
                while (off < dest_end) : (off += 1) {
                    if (ctx.isNewline(off)) {
                        is_link = FALSE;
                        break;
                    }
                }
            }

            if (is_link != 0) {
                if (delim != null) {
                    if (delim.?.end < closer.beg) {
                        md_rollback(ctx, opener_index, delim_index, MD_ROLLBACK_ALL);
                        md_rollback(ctx, delim_index, closer_index, MD_ROLLBACK_CROSSING);
                        delim.?.flags |= MD_MARK_RESOLVED;
                        opener.end = delim.?.beg;
                    } else {
                        md_rollback(ctx, opener_index, closer_index, MD_ROLLBACK_ALL);
                        closer.beg = delim.?.beg;
                        delim = null;
                    }
                }

                opener.beg = next_opener.?.beg;
                opener.next = closer_index;
                opener.flags |= MD_MARK_OPENER | MD_MARK_RESOLVED;

                closer.end = next_closer.?.end;
                closer.prev = opener_index;
                closer.flags |= MD_MARK_CLOSER | MD_MARK_RESOLVED;

                last_link_beg = opener.beg;
                last_link_end = closer.end;

                if (delim != null)
                    md_analyze_link_contents(ctx, lines, delim_index + 1, closer_index);

                opener_index = next_opener.?.prev;
                continue;
            }
        }

        if (next_opener != null and next_opener.?.beg == closer.end) {
            if (next_closer.?.beg > closer.end + 1) {
                // Might be full reference link.
                if (next_opener.?.flags & MD_MARK_HASNESTEDBRACKETS == 0)
                    is_link = md_is_link_reference(ctx, lines, next_opener.?.beg, next_closer.?.end, &attr);
            } else {
                // Might be shortcut reference link.
                if (opener.flags & MD_MARK_HASNESTEDBRACKETS == 0)
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
                is_link = md_is_inline_link_spec(ctx, lines, closer.end, &inline_link_end, &attr);
                if (is_link < 0) return -1;

                if (is_link != 0) {
                    var i: c_int = closer_index + 1;
                    while (i < ctx.nMarks()) {
                        const m = &ctx.marks.items[@intCast(i)];
                        if (m.beg >= inline_link_end) break;
                        if ((m.flags & (MD_MARK_OPENER | MD_MARK_RESOLVED)) == (MD_MARK_OPENER | MD_MARK_RESOLVED)) {
                            if (ctx.marks.items[@intCast(m.next)].beg >= inline_link_end) {
                                if (attr.title_needs_free != 0) std.c.free(attr.title);
                                is_link = FALSE;
                                break;
                            }
                            i = m.next + 1;
                        } else {
                            i += 1;
                        }
                    }
                }

                if (is_link != 0) {
                    closer.end = inline_link_end;
                }
            }

            if (is_link == 0) {
                // Might be collapsed reference link.
                if (opener.flags & MD_MARK_HASNESTEDBRACKETS == 0)
                    is_link = md_is_link_reference(ctx, lines, opener.beg, closer.end, &attr);
                if (is_link < 0) return -1;
            }

            if (is_link == 0 and (ctx.parser.flags & c.MD_FLAG_ATTRIBUTES != 0) and opener.ch == '[') {
                // Might be a [text]{attrs} span.
                if (closer.end < ctx.size and ctx.ch(closer.end) == '{') {
                    var scan: OFF = closer.end + 1;
                    var depth: c_int = 1;
                    while (scan < ctx.size and depth > 0) {
                        if (ctx.ch(scan) == '{') depth += 1 else if (ctx.ch(scan) == '}') depth -= 1;
                        scan += 1;
                    }
                    if (depth == 0) {
                        is_link = TRUE;
                        ctx.marks.items[@intCast(opener_index + 1)].ch = 'S';
                        ctx.marks.items[@intCast(opener_index + 1)].beg = closer.end + 1;
                        ctx.marks.items[@intCast(opener_index + 1)].end = scan - 1;
                        closer.end = scan;
                    }
                }
            }
        }

        if (is_link != 0) {
            opener.flags |= MD_MARK_OPENER | MD_MARK_RESOLVED;
            closer.flags |= MD_MARK_CLOSER | MD_MARK_RESOLVED;

            if (ctx.marks.items[@intCast(opener_index + 1)].ch == 'S') {
                md_analyze_link_contents(ctx, lines, opener_index + 1, closer_index);
            } else {
                ctx.marks.items[@intCast(opener_index + 1)].beg = attr.dest_beg;
                ctx.marks.items[@intCast(opener_index + 1)].end = attr.dest_end;

                md_mark_store_ptr(ctx, opener_index + 2, attr.title);
                if (attr.title_needs_free != 0)
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

                if (ctx.parser.flags & c.MD_FLAG_PERMISSIVEAUTOLINKS != 0) {
                    var first_nested_i: c_int = opener_index + 1;
                    while (ctx.marks.items[@intCast(first_nested_i)].ch == 'D' and first_nested_i < closer_index) first_nested_i += 1;

                    // NOTE: the C loop condition tests first_nested->ch (md4c quirk); preserved verbatim.
                    var last_nested_i: c_int = closer_index - 1;
                    while (ctx.marks.items[@intCast(first_nested_i)].ch == 'D' and last_nested_i > opener_index) last_nested_i -= 1;

                    const first_nested = &ctx.marks.items[@intCast(first_nested_i)];
                    const last_nested = &ctx.marks.items[@intCast(last_nested_i)];

                    if ((first_nested.flags & MD_MARK_RESOLVED != 0) and
                        first_nested.beg == opener.end and
                        ISANYOF_(first_nested.ch, "@:.") and
                        first_nested.next == last_nested_i and
                        last_nested.end == closer.beg)
                    {
                        first_nested.ch = 'D';
                        first_nested.flags &= ~MD_MARK_RESOLVED;
                        last_nested.ch = 'D';
                        last_nested.flags &= ~MD_MARK_RESOLVED;
                    }
                }
            }
        }

        opener_index = next_index;
    }

    return 0;
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
    mark.flags |= MD_MARK_RESOLVED;
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

    if (mark.flags & MD_MARK_POTENTIAL_CLOSER != 0) {
        var opener: ?*MD_MARK = null;
        var opener_index: c_int = 0;
        var opener_stacks: [6]*MD_MARKSTACK = undefined;
        var n_opener_stacks: usize = 0;
        const flags = mark.flags;

        opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MD_MARK_EMPH_MOD3_0 | MD_MARK_EMPH_OC);
        n_opener_stacks += 1;
        if ((flags & MD_MARK_EMPH_MOD3_MASK) != MD_MARK_EMPH_MOD3_2) {
            opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MD_MARK_EMPH_MOD3_1 | MD_MARK_EMPH_OC);
            n_opener_stacks += 1;
        }
        if ((flags & MD_MARK_EMPH_MOD3_MASK) != MD_MARK_EMPH_MOD3_1) {
            opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MD_MARK_EMPH_MOD3_2 | MD_MARK_EMPH_OC);
            n_opener_stacks += 1;
        }
        opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MD_MARK_EMPH_MOD3_0);
        n_opener_stacks += 1;
        if ((flags & MD_MARK_EMPH_OC == 0) or (flags & MD_MARK_EMPH_MOD3_MASK) != MD_MARK_EMPH_MOD3_2) {
            opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MD_MARK_EMPH_MOD3_1);
            n_opener_stacks += 1;
        }
        if ((flags & MD_MARK_EMPH_OC == 0) or (flags & MD_MARK_EMPH_MOD3_MASK) != MD_MARK_EMPH_MOD3_1) {
            opener_stacks[n_opener_stacks] = md_emph_stack(ctx, mark.ch, MD_MARK_EMPH_MOD3_2);
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

    if (mark.flags & MD_MARK_POTENTIAL_OPENER != 0)
        md_mark_stack_push(ctx, md_emph_stack(ctx, mark.ch, mark.flags), mark_index);
}

// md4x.c ~4108.
pub fn md_analyze_tilde(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks.items[@intCast(mark_index)];
    const stack = md_opener_stack(ctx, mark_index);

    if ((mark.flags & MD_MARK_POTENTIAL_CLOSER != 0) and stack.top >= 0) {
        const opener_index = stack.top;
        _ = md_mark_stack_pop(ctx, stack);
        md_rollback(ctx, opener_index, mark_index, MD_ROLLBACK_CROSSING);
        md_resolve_range(ctx, opener_index, mark_index);
        return;
    }

    if (mark.flags & MD_MARK_POTENTIAL_OPENER != 0)
        md_mark_stack_push(ctx, stack, mark_index);
}

// md4x.c ~4131.
pub fn md_analyze_dollar(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks.items[@intCast(mark_index)];

    if ((mark.flags & MD_MARK_POTENTIAL_CLOSER != 0) and ctx.opener_stacks[DOLLAR_OPENERS].top >= 0) {
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

    if (mark.flags & MD_MARK_POTENTIAL_OPENER != 0)
        md_mark_stack_push(ctx, &ctx.opener_stacks[DOLLAR_OPENERS], mark_index);
}

// md4x.c ~4159.
pub fn md_scan_left_for_resolved_mark(ctx: *MD_CTX, mark_from: [*c]MD_MARK, off: OFF, p_cursor: ?*[*c]MD_MARK) [*c]MD_MARK {
    var mark = mark_from;
    while (@intFromPtr(mark) >= @intFromPtr(ctx.marks.items.ptr)) : (mark -= 1) {
        if (mark.*.ch == 'D' or mark.*.beg > off) continue;
        if (mark.*.beg <= off and off < mark.*.end and (mark.*.flags & MD_MARK_RESOLVED != 0)) {
            if (p_cursor != null) p_cursor.?.* = mark;
            return mark;
        }
        if (mark.*.end <= off) break;
    }
    if (p_cursor != null) p_cursor.?.* = mark;
    return null;
}

// md4x.c ~4181.
pub fn md_scan_right_for_resolved_mark(ctx: *MD_CTX, mark_from: [*c]MD_MARK, off: OFF, p_cursor: ?*[*c]MD_MARK) [*c]MD_MARK {
    var mark = mark_from;
    const end_ptr = ctx.marks.items.ptr + @as(usize, @intCast(ctx.nMarks()));
    while (@intFromPtr(mark) < @intFromPtr(end_ptr)) : (mark += 1) {
        if (mark.*.ch == 'D' or mark.*.end <= off) continue;
        if (mark.*.beg <= off and off < mark.*.end and (mark.*.flags & MD_MARK_RESOLVED != 0)) {
            if (p_cursor != null) p_cursor.?.* = mark;
            return mark;
        }
        if (mark.*.beg > off) break;
    }
    if (p_cursor != null) p_cursor.?.* = mark;
    return null;
}

// md4x.c ~4204.
pub fn md_analyze_permissive_autolink(ctx: *MD_CTX, mark_index: c_int) void {
    const UrlMapEntry = struct {
        start_char: CHAR,
        delim_char: CHAR,
        allowed_nonalnum_chars: [*:0]const u8,
        min_components: c_int,
        optional_end_char: CHAR,
    };
    const URL_MAP = [_]UrlMapEntry{
        .{ .start_char = 0, .delim_char = '.', .allowed_nonalnum_chars = ".-_", .min_components = 2, .optional_end_char = 0 },
        .{ .start_char = '/', .delim_char = '/', .allowed_nonalnum_chars = "/.-_", .min_components = 0, .optional_end_char = '/' },
        .{ .start_char = '?', .delim_char = '&', .allowed_nonalnum_chars = "&.-+_=()", .min_components = 1, .optional_end_char = 0 },
        .{ .start_char = '#', .delim_char = 0, .allowed_nonalnum_chars = ".-+_", .min_components = 1, .optional_end_char = 0 },
    };

    const opener = &ctx.marks.items[@intCast(mark_index)];
    const closer = &ctx.marks.items[@intCast(mark_index + 1)]; // The dummy.
    const line_beg: OFF = closer.beg;
    const line_end: OFF = closer.end;
    var beg: OFF = opener.beg;
    var end: OFF = opener.end;
    var left_cursor: [*c]MD_MARK = opener;
    var left_boundary_ok: c_int = FALSE;
    var right_cursor: [*c]MD_MARK = opener;
    var right_boundary_ok: c_int = FALSE;

    if (opener.ch == '@') {
        while (beg > line_beg) {
            if (ctx.isAlnum(beg - 1)) {
                beg -= 1;
            } else if (beg >= line_beg + 2 and ctx.isAlnum(beg - 2) and
                ctx.isAnyOf(beg - 1, ".-_+") and
                md_scan_left_for_resolved_mark(ctx, left_cursor, beg - 1, &left_cursor) == null and
                ctx.isAlnum(beg))
            {
                beg -= 1;
            } else {
                break;
            }
        }
        if (beg == opener.beg) return; // empty user name
    }

    if (beg == line_beg or ctx.isUnicodeWhitespaceBefore(beg) or ctx.isAnyOf(beg - 1, "({[")) {
        left_boundary_ok = TRUE;
    } else if (ctx.isAnyOf(beg - 1, "*_~")) {
        const left_mark = md_scan_left_for_resolved_mark(ctx, left_cursor, beg - 1, &left_cursor);
        if (left_mark != null and (left_mark.*.flags & MD_MARK_OPENER != 0)) left_boundary_ok = TRUE;
    }
    if (left_boundary_ok == FALSE) return;

    var i: usize = 0;
    while (i < URL_MAP.len) : (i += 1) {
        var n_components: c_int = 0;
        var n_open_brackets: c_int = 0;

        if (URL_MAP[i].start_char != 0) {
            if (end >= line_end or ctx.ch(end) != URL_MAP[i].start_char) continue;
            if (URL_MAP[i].min_components > 0 and (end + 1 >= line_end or !ctx.isAlnum(end + 1))) continue;
            end += 1;
        }

        while (end < line_end) {
            if (ctx.isAlnum(end)) {
                if (n_components == 0) n_components += 1;
                end += 1;
            } else if (end < line_end and
                ctx.isAnyOf(end, URL_MAP[i].allowed_nonalnum_chars) and
                md_scan_right_for_resolved_mark(ctx, right_cursor, end, &right_cursor) == null and
                ((end > line_beg and (ctx.isAlnum(end - 1) or ctx.ch(end - 1) == ')')) or ctx.ch(end) == '(') and
                ((end + 1 < line_end and (ctx.isAlnum(end + 1) or ctx.ch(end + 1) == '(')) or ctx.ch(end) == ')'))
            {
                if (ctx.ch(end) == URL_MAP[i].delim_char) n_components += 1;

                if (ctx.ch(end) == '(') {
                    n_open_brackets += 1;
                } else if (ctx.ch(end) == ')') {
                    if (n_open_brackets <= 0) break;
                    n_open_brackets -= 1;
                }
                end += 1;
            } else {
                break;
            }
        }

        if (end < line_end and URL_MAP[i].optional_end_char != 0 and ctx.ch(end) == URL_MAP[i].optional_end_char)
            end += 1;

        if (n_components < URL_MAP[i].min_components or n_open_brackets != 0) return;

        if (opener.ch == '@') break; // e-mail wants only the host
    }

    if (end == line_end or ctx.isUnicodeWhitespace(end) or ctx.isAnyOf(end, ")}].!?,;")) {
        right_boundary_ok = TRUE;
    } else {
        const right_mark = md_scan_right_for_resolved_mark(ctx, right_cursor, end, &right_cursor);
        if (right_mark != null and (right_mark.*.flags & MD_MARK_CLOSER != 0)) right_boundary_ok = TRUE;
    }
    if (right_boundary_ok == FALSE) return;

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

        if (mark.flags & MD_MARK_RESOLVED != 0) {
            if ((mark.flags & MD_MARK_OPENER != 0) and mark.ch != 'C' and
                !((flags & MD_ANALYZE_NOSKIP_EMPH != 0) and ISANYOF_(mark.ch, "*_~")))
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
            '.', ':', '@' => md_analyze_permissive_autolink(ctx, i),
            else => {},
        }

        if (mark.flags & MD_MARK_RESOLVED != 0) {
            if (mark.flags & MD_MARK_OPENER != 0)
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
    if (ctx.parser.flags & c.MD_FLAG_ATTRIBUTES == 0) return 0;

    ctx.inline_attrs.clearRetainingCapacity();

    var i: c_int = 0;
    while (i < ctx.nMarks()) : (i += 1) {
        const mark = &ctx.marks.items[@intCast(i)];

        if (mark.flags & MD_MARK_RESOLVED == 0) continue;
        if (mark.flags & MD_MARK_CLOSER == 0) continue;
        if (mark.ch == 'C') continue;
        if (mark.ch == 'D') continue;
        if (mark.ch != '*' and mark.ch != '_' and mark.ch != '`' and mark.ch != '~' and mark.ch != ']') continue;

        if (mark.ch == ']') {
            const opener_index = mark.prev;
            if (opener_index >= 0) {
                const opener = &ctx.marks.items[@intCast(opener_index)];
                if (opener_index + 1 < ctx.nMarks() and ctx.marks.items[@intCast(opener_index + 1)].ch == 'S') continue;
                if (opener.ch == '[' and opener.end - opener.beg >= 2 and mark.end - mark.beg >= 2) continue;
            }
        }

        if (mark.end >= ctx.size or ctx.ch(mark.end) != '{') continue;

        var scan: OFF = mark.end + 1;
        var depth: c_int = 1;
        while (scan < ctx.size and depth > 0) {
            if (ctx.ch(scan) == '{') depth += 1 else if (ctx.ch(scan) == '}') depth -= 1;
            scan += 1;
        }
        if (depth != 0) continue;

        const attrs_beg = mark.end + 1;
        md_push_inline_attr(ctx, i, attrs_beg, scan - 1) catch return -1;

        if (mark.ch != '*' and mark.ch != '_') mark.end = scan;
    }

    return 0;
}

// md4x.c ~4538.
pub fn md_analyze_inlines(ctx: *MD_CTX, lines: []const MD_LINE, table_mode: c_int) c_int {
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

    if (table_mode != 0) {
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
    md_analyze_marks(ctx, lines, mark_beg, mark_end, "*_~$", 0);

    if (ctx.parser.flags & c.MD_FLAG_PERMISSIVEAUTOLINKS != 0) {
        md_analyze_marks(ctx, lines, mark_beg, mark_end, "@:.", MD_ANALYZE_NOSKIP_EMPH);
    }

    var i: usize = 0;
    while (i < ctx.opener_stacks.len) : (i += 1) ctx.opener_stacks[i].top = -1;
}

// ---- Span enter/leave helpers + emission (md4x.c ~4594..5197) ----

pub inline fn mdEnterSpan(ctx: *MD_CTX, detail: *const c.SpanDetail) c_int {
    const ret = ctx.parser.enter_span.?(detail, ctx.userdata);
    if (ret != 0) ctx.log("Aborted from enter_span() callback.");
    return ret;
}

pub inline fn mdLeaveSpan(ctx: *MD_CTX, detail: *const c.SpanDetail) c_int {
    const ret = ctx.parser.leave_span.?(detail, ctx.userdata);
    if (ret != 0) ctx.log("Aborted from leave_span() callback.");
    return ret;
}

// The pointer+size shape is kept for the ~30 internal call sites (which all
// derive their run from `ctx.str(off)` plus an offset delta); the slice the
// callback contract wants is formed here, at the single emission boundary.
pub inline fn mdText(ctx: *MD_CTX, ty: c.TextType, str: [*c]const CHAR, size: SZ) c_int {
    if (size > 0) {
        const ret = ctx.parser.text.?(ty, str[0..size], ctx.userdata);
        if (ret != 0) {
            ctx.log("Aborted from text() callback.");
            return ret;
        }
    }
    return 0;
}

// md4x.c ~4594.
pub fn md_enter_leave_span_a(ctx: *MD_CTX, enter: c_int, ty: c.SpanType, dest: [*c]const CHAR, dest_size: SZ, is_autolink: c_int, title: [*c]const CHAR, title_size: SZ) c_int {
    var href_build: MD_ATTRIBUTE_BUILD = .{};
    var title_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.SpanADetail = .{};
    var ret: c_int = 0;

    md_build_attribute(ctx, dest, dest_size, if (is_autolink != 0) MD_BUILD_ATTR_NO_ESCAPES else 0, &det.href, &href_build) catch {
        ret = -1;
    };
    if (ret == 0) {
        md_build_attribute(ctx, title, title_size, 0, &det.title, &title_build) catch {
            ret = -1;
        };
    }
    if (ret == 0) {
        det.is_autolink = is_autolink != 0;
        const d = spanADetailFor(ty, det);
        ret = if (enter != 0) mdEnterSpan(ctx, &d) else mdLeaveSpan(ctx, &d);
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

// md4x.c ~4623.
pub fn md_enter_leave_span_wikilink(ctx: *MD_CTX, enter: c_int, target: [*c]const CHAR, target_size: SZ) c_int {
    var target_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.SpanWikilinkDetail = .{};
    var ret: c_int = 0;

    md_build_attribute(ctx, target, target_size, 0, &det.target, &target_build) catch {
        ret = -1;
    };
    if (ret == 0) {
        const d: c.SpanDetail = .{ .wikilink = det };
        ret = if (enter != 0) mdEnterSpan(ctx, &d) else mdLeaveSpan(ctx, &d);
    }

    md_free_attribute(ctx, &target_build);
    return ret;
}

// md4x.c ~4643.
pub fn md_enter_leave_span_component(ctx: *MD_CTX, enter: c_int, tag: [*c]const CHAR, tag_size: SZ, raw_props: [*c]const CHAR, raw_props_size: SZ) c_int {
    var tag_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.SpanComponentDetail = .{};
    var ret: c_int = 0;

    md_build_attribute(ctx, tag, tag_size, 0, &det.tag_name, &tag_build) catch {
        ret = -1;
    };
    if (ret == 0) {
        if (raw_props != null) det.raw_props = raw_props[0..raw_props_size];
        const d: c.SpanDetail = .{ .component = det };
        ret = if (enter != 0) mdEnterSpan(ctx, &d) else mdLeaveSpan(ctx, &d);
    }

    md_free_attribute(ctx, &tag_build);
    return ret;
}

// md4x.c ~4669.
pub fn md_enter_leave_span_a_with_attrs(ctx: *MD_CTX, enter: c_int, ty: c.SpanType, dest: [*c]const CHAR, dest_size: SZ, is_autolink: c_int, title: [*c]const CHAR, title_size: SZ, raw_attrs: [*c]const CHAR, raw_attrs_size: SZ) c_int {
    var href_build: MD_ATTRIBUTE_BUILD = .{};
    var title_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.SpanADetail = .{};
    var ret: c_int = 0;

    md_build_attribute(ctx, dest, dest_size, if (is_autolink != 0) MD_BUILD_ATTR_NO_ESCAPES else 0, &det.href, &href_build) catch {
        ret = -1;
    };
    if (ret == 0) {
        md_build_attribute(ctx, title, title_size, 0, &det.title, &title_build) catch {
            ret = -1;
        };
    }
    if (ret == 0) {
        det.is_autolink = is_autolink != 0;
        if (raw_attrs != null) det.raw_attrs = raw_attrs[0..raw_attrs_size];
        const d = spanADetailFor(ty, det);
        ret = if (enter != 0) mdEnterSpan(ctx, &d) else mdLeaveSpan(ctx, &d);
    }

    md_free_attribute(ctx, &href_build);
    md_free_attribute(ctx, &title_build);
    return ret;
}

// md4x.c ~4700.
pub fn md_enter_leave_span_span(ctx: *MD_CTX, enter: c_int, raw_attrs: [*c]const CHAR, raw_attrs_size: SZ) c_int {
    var det: c.SpanSpanDetail = .{};
    if (raw_attrs != null) det.raw_attrs = raw_attrs[0..raw_attrs_size];
    const d: c.SpanDetail = .{ .span = det };
    return if (enter != 0) mdEnterSpan(ctx, &d) else mdLeaveSpan(ctx, &d);
}

// md4x.c ~4721. Render the output per the analyzed ctx.marks.
pub fn md_process_inlines(ctx: *MD_CTX, lines: []const MD_LINE) c_int {
    var text_type: c.TextType = undefined;
    var line: [*c]const MD_LINE = lines.ptr;
    var mark: [*c]MD_MARK = undefined;
    var off: OFF = lines[0].beg;
    const end: OFF = lines[lines.len - 1].end;
    var tmp: OFF = undefined;
    var attr_skip_to: OFF = 0;
    var enforce_hardbreak: c_int = 0;
    var ret: c_int = 0;

    mark = ctx.marks.items.ptr;
    while (mark.*.flags & MD_MARK_RESOLVED == 0) mark += 1;

    text_type = c.TextType.normal;

    main: while (true) {
        tmp = if (line.*.end < mark.*.beg) line.*.end else mark.*.beg;
        if (tmp > off) {
            ret = mdText(ctx, text_type, ctx.str(off), tmp - off);
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
                    if (mark.*.flags & MD_MARK_OPENER != 0)
                        _ = md_find_inline_attr(ctx, mark.*.next, &raw_a, &raw_a_sz, null)
                    else
                        _ = md_find_inline_attr(ctx, @intCast((@intFromPtr(mark) - @intFromPtr(ctx.marks.items.ptr)) / @sizeOf(MD_MARK)), &raw_a, &raw_a_sz, null);

                    const det: c.SpanDetail = .{ .code = attrsDetail(raw_a, raw_a_sz) };
                    if (mark.*.flags & MD_MARK_OPENER != 0) {
                        ret = mdEnterSpan(ctx, &det);
                        if (ret != 0) return ret;
                        text_type = c.TextType.code;
                    } else {
                        ret = mdLeaveSpan(ctx, &det);
                        if (ret != 0) return ret;
                        text_type = c.TextType.normal;
                    }
                },

                '_' => {
                    if (ctx.parser.flags & c.MD_FLAG_UNDERLINE != 0) {
                        var raw_a: [*c]const CHAR = null;
                        var raw_a_sz: SZ = 0;
                        if (mark.*.flags & MD_MARK_OPENER != 0)
                            _ = md_find_inline_attr(ctx, mark.*.next, &raw_a, &raw_a_sz, null)
                        else
                            _ = md_find_inline_attr(ctx, @intCast((@intFromPtr(mark) - @intFromPtr(ctx.marks.items.ptr)) / @sizeOf(MD_MARK)), &raw_a, &raw_a_sz, &attr_skip_to);

                        // Only the outermost of a run of `_` marks carries the
                        // trailing {attrs}; the rest get a bare detail.
                        const det_attrs: c.SpanDetail = .{ .u = attrsDetail(raw_a, raw_a_sz) };
                        const det_bare: c.SpanDetail = .{ .u = .{} };
                        if (mark.*.flags & MD_MARK_OPENER != 0) {
                            var first: c_int = 1;
                            while (off < mark.*.end) {
                                ret = mdEnterSpan(ctx, if (first != 0 and raw_a != null) &det_attrs else &det_bare);
                                if (ret != 0) return ret;
                                first = 0;
                                off += 1;
                            }
                        } else {
                            const count: c_int = @intCast(mark.*.end - off);
                            var idx: c_int = 0;
                            while (off < mark.*.end) {
                                ret = mdLeaveSpan(ctx, if (idx == count - 1 and raw_a != null) &det_attrs else &det_bare);
                                if (ret != 0) return ret;
                                idx += 1;
                                off += 1;
                            }
                        }
                        // break out of switch — fallthrough to post-mark handling.
                    } else {
                        ret = emitEmphasis(ctx, mark, &off, &attr_skip_to);
                        if (ret != 0) return ret;
                    }
                },

                '*' => {
                    ret = emitEmphasis(ctx, mark, &off, &attr_skip_to);
                    if (ret != 0) return ret;
                },

                '~' => {
                    var raw_a: [*c]const CHAR = null;
                    var raw_a_sz: SZ = 0;
                    if (mark.*.flags & MD_MARK_OPENER != 0)
                        _ = md_find_inline_attr(ctx, mark.*.next, &raw_a, &raw_a_sz, null)
                    else
                        _ = md_find_inline_attr(ctx, @intCast((@intFromPtr(mark) - @intFromPtr(ctx.marks.items.ptr)) / @sizeOf(MD_MARK)), &raw_a, &raw_a_sz, null);

                    const det: c.SpanDetail = .{ .del = attrsDetail(raw_a, raw_a_sz) };
                    if (mark.*.flags & MD_MARK_OPENER != 0) {
                        ret = mdEnterSpan(ctx, &det);
                    } else {
                        ret = mdLeaveSpan(ctx, &det);
                    }
                    if (ret != 0) return ret;
                },

                '$' => {
                    const math_inline: c.SpanDetail = .{ .latexmath = {} };
                    const math_display: c.SpanDetail = .{ .latexmath_display = {} };
                    if (mark.*.flags & MD_MARK_OPENER != 0) {
                        ret = mdEnterSpan(ctx, if ((mark.*.end - off) % 2 != 0) &math_inline else &math_display);
                        if (ret != 0) return ret;
                        text_type = c.TextType.latexmath;
                    } else {
                        ret = mdLeaveSpan(ctx, if ((mark.*.end - off) % 2 != 0) &math_inline else &math_display);
                        if (ret != 0) return ret;
                        text_type = c.TextType.normal;
                    }
                },

                '[', '!', ']' => {
                    const opener: [*c]MD_MARK = if (mark.*.ch != ']') mark else &ctx.marks.items[@intCast(mark.*.prev)];
                    const closer: [*c]MD_MARK = &ctx.marks.items[@intCast(opener.*.next)];

                    if ((opener.*.ch == '[' and closer.*.ch == ']') and
                        opener.*.end - opener.*.beg >= 2 and
                        closer.*.end - closer.*.beg >= 2)
                    {
                        const has_label = (opener.*.end - opener.*.beg > 2);
                        const target_sz: SZ = if (has_label) opener.*.end - (opener.*.beg + 2) else closer.*.beg - opener.*.end;

                        ret = md_enter_leave_span_wikilink(ctx, @intFromBool(mark.*.ch != ']'), if (has_label) ctx.str(opener.*.beg + 2) else ctx.str(opener.*.end), target_sz);
                        if (ret != 0) return ret;
                    } else {
                        const dest_mark: [*c]MD_MARK = opener + 1;
                        const title_mark: [*c]MD_MARK = opener + 2;

                        if (dest_mark.*.ch == 'S') {
                            const raw_a = ctx.str(dest_mark.*.beg);
                            const raw_a_sz = dest_mark.*.end - dest_mark.*.beg;
                            ret = md_enter_leave_span_span(ctx, @intFromBool(mark.*.ch != ']'), raw_a, raw_a_sz);
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
                                ret = md_enter_leave_span_a_with_attrs(ctx, @intFromBool(mark.*.ch != ']'), if (opener.*.ch == '!') c.SpanType.img else c.SpanType.a, ctx.str(dest_mark.*.beg), dest_mark.*.end - dest_mark.*.beg, FALSE, title_ptr, title_sz, raw_a, raw_a_sz);
                            } else {
                                ret = md_enter_leave_span_a(ctx, @intFromBool(mark.*.ch != ']'), if (opener.*.ch == '!') c.SpanType.img else c.SpanType.a, ctx.str(dest_mark.*.beg), dest_mark.*.end - dest_mark.*.beg, FALSE, title_ptr, title_sz);
                            }
                            if (ret != 0) return ret;

                            if (mark.*.ch == ']') {
                                while (mark.*.end > line.*.end and @intFromPtr(line) < @intFromPtr(&lines[lines.len - 1])) line += 1;
                            }
                        }
                    }
                },

                '<', '>' => {
                    if (mark.*.flags & MD_MARK_AUTOLINK == 0) {
                        // Raw HTML.
                        if (mark.*.flags & MD_MARK_OPENER != 0)
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

                'C' => {
                    const opener: [*c]MD_MARK = if (mark.*.flags & MD_MARK_OPENER != 0) mark else &ctx.marks.items[@intCast(mark.*.prev)];
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

                    if (mark.*.flags & MD_MARK_OPENER != 0) {
                        ret = md_enter_leave_span_component(ctx, 1, tag_str, tag_size, raw_props, raw_props_size);
                        if (ret != 0) return ret;
                        if (opener.*.end == closer.*.beg) {
                            ret = md_enter_leave_span_component(ctx, 0, tag_str, tag_size, raw_props, raw_props_size);
                            if (ret != 0) return ret;
                        }
                    } else {
                        if (opener.*.end != closer.*.beg) {
                            ret = md_enter_leave_span_component(ctx, 0, tag_str, tag_size, raw_props, raw_props_size);
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
            while ((mark.*.flags & MD_MARK_RESOLVED == 0) or mark.*.beg < off) mark += 1;
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
                if (off == line.*.end) {
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
                    if (enforce_hardbreak != 0 or (ctx.parser.flags & c.MD_FLAG_HARD_SOFT_BREAKS != 0)) {
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
            off = line.*.beg;
            enforce_hardbreak = 0;
        }
    }

    return ret;
}

// Emit emphasis/strong for '*' (and '_' without UNDERLINE). md4x.c ~4838.
pub fn emitEmphasis(ctx: *MD_CTX, mark: [*c]MD_MARK, off_p: *OFF, attr_skip_to: *OFF) c_int {
    var ret: c_int = 0;
    var raw_a: [*c]const CHAR = null;
    var raw_a_sz: SZ = 0;
    if (mark.*.flags & MD_MARK_OPENER != 0)
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
    if (mark.*.flags & MD_MARK_OPENER != 0) {
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
    const opener: [*c]MD_MARK = if (mark.*.flags & MD_MARK_OPENER != 0) mark else &ctx.marks.items[@intCast(mark.*.prev)];
    const closer: [*c]MD_MARK = &ctx.marks.items[@intCast(opener.*.next)];
    var dest: [*c]const CHAR = ctx.str(opener.*.end);
    var dest_size: SZ = closer.*.beg - opener.*.end;
    _ = off;

    if (mark.*.flags & MD_MARK_OPENER != 0)
        closer.*.flags |= MD_MARK_VALIDPERMISSIVEAUTOLINK;

    if (opener.*.ch == '@' or opener.*.ch == '.' or
        (opener.*.ch == '<' and (opener.*.flags & MD_MARK_AUTOLINK_MISSING_MAILTO != 0)))
    {
        dest_size += 7;
        if (md_temp_buffer(ctx, dest_size * @sizeOf(CHAR)) != 0) return -1;
        const prefix: [*c]const CHAR = if (opener.*.ch == '.') "http://" else "mailto:";
        @memcpy(@as([*]u8, @ptrCast(ctx.buffer))[0..7], @as([*]const u8, @ptrCast(prefix))[0..7]);
        @memcpy(@as([*]u8, @ptrCast(ctx.buffer + 7))[0..@intCast(dest_size - 7)], @as([*]const u8, @ptrCast(dest))[0..@intCast(dest_size - 7)]);
        dest = ctx.buffer;
    }

    if (closer.*.flags & MD_MARK_VALIDPERMISSIVEAUTOLINK != 0)
        ret = md_enter_leave_span_a(ctx, @intFromBool(mark.*.flags & MD_MARK_OPENER != 0), c.SpanType.a, dest, dest_size, TRUE, null, 0);
    return ret;
}
