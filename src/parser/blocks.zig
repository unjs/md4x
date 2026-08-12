// MD4X parser — block / line analysis module (Pass D).
//
// Block accumulation + container push/pop, the line classifier (md_analyze_line)
// and its helpers, HTML-block start/end conditions, and the block-component /
// slot recognizers. Extracted verbatim from the monolithic src/md4x.zig (pure
// refactor — no logic change). See AGENTS.md.

const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const refdefs = @import("refdefs.zig");
const inlines = @import("inlines.zig");
const process = @import("process.zig");

const c = types.c;
const CHAR = types.CHAR;
const SZ = types.SZ;
const OFF = types.OFF;
const MD_SIZE = types.MD_SIZE;
const TRUE = types.TRUE;
const FALSE = types.FALSE;
const MD_CTX = types.MD_CTX;
const MD_LINE = types.MD_LINE;
const MD_LINE_ANALYSIS = types.MD_LINE_ANALYSIS;
const MD_VERBATIMLINE = types.MD_VERBATIMLINE;
const MD_BLOCK = types.MD_BLOCK;
const MD_CONTAINER = types.MD_CONTAINER;
const MD_BLOCK_COMPONENT_INFO = types.MD_BLOCK_COMPONENT_INFO;
const MD_SLOT_INFO = types.MD_SLOT_INFO;
const MD_BLOCK_ALERT_INFO = types.MD_BLOCK_ALERT_INFO;
const c_allocator = types.c_allocator;
const MD_BLOCK_CONTAINER_OPENER = types.MD_BLOCK_CONTAINER_OPENER;
const MD_BLOCK_CONTAINER_CLOSER = types.MD_BLOCK_CONTAINER_CLOSER;
const MD_BLOCK_LOOSE_LIST = types.MD_BLOCK_LOOSE_LIST;
const MD_BLOCK_SETEXT_HEADER = types.MD_BLOCK_SETEXT_HEADER;

const uval = util.uval;
const ISANYOF2_ = util.ISANYOF2_;
const ISANYOF_ = util.ISANYOF_;
const ISBLANK_ = util.ISBLANK_;
const md_ascii_case_eq = util.md_ascii_case_eq;
const md_ascii_eq = util.md_ascii_eq;
const memcmp = util.memcmp;
const strcspn = util.strcspn;
const c_realloc_array = util.c_realloc_array;

const md_is_link_reference_definition = refdefs.md_is_link_reference_definition;

const md_is_html_tag = inlines.md_is_html_tag;

const md_process_all_blocks = process.md_process_all_blocks;
const md_process_doc = process.md_process_doc;
const md_process_line = process.md_process_line;

// ============================================================================
//  Pass D — Block / line analysis (md4x.c ~5984..7859)
// ============================================================================
//
// Block accumulation, container push/pop, the line classifier, and the
// HTML-block start/end conditions that feed it. md_process_block /
// md_process_all_blocks / md_process_line / md_process_doc / md_parse glue is
// Pass E. Reference C = the FIXED src/md4x.c.

pub const TABLE_MAXCOLCOUNT: c_uint = 128; // md4x.c #define (DoS cap).

// `MD_MIN` for unsigned values.
pub inline fn MIN_u(a: c_uint, b: c_uint) c_uint {
    return if (a < b) a else b;
}

// --- block-bytes growable buffer ---------------------------------------------

// md_push_block_bytes (md4x.c ~5984). Returns a raw pointer into ctx.block_bytes,
// or null on OOM (mirroring C's NULL). Fixes ctx.current_block after realloc.
pub fn md_push_block_bytes(ctx: *MD_CTX, n_bytes: c_int) ?*anyopaque {
    if (ctx.n_block_bytes + n_bytes > ctx.alloc_block_bytes) {
        const old_alloc: usize = @intCast(ctx.alloc_block_bytes);
        ctx.alloc_block_bytes = if (ctx.alloc_block_bytes > 0)
            ctx.alloc_block_bytes + @divTrunc(ctx.alloc_block_bytes, 2)
        else
            512;
        const new_block_bytes = util.arena_realloc(ctx.alloc, ctx.block_bytes, old_alloc, @intCast(ctx.alloc_block_bytes));
        if (new_block_bytes == null) {
            ctx.log("realloc() failed.");
            ctx.alloc_block_bytes = @intCast(old_alloc);
            return null;
        }

        // Fix the ->current_block after the reallocation.
        if (ctx.current_block != null) {
            const off_current_block: OFF = @intCast(@intFromPtr(ctx.current_block) - @intFromPtr(ctx.block_bytes));
            ctx.current_block = @ptrCast(@alignCast(@as([*]u8, @ptrCast(new_block_bytes)) + off_current_block));
        }

        ctx.block_bytes = new_block_bytes;
    }

    const ptr: *anyopaque = @ptrCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + @as(usize, @intCast(ctx.n_block_bytes)));
    ctx.n_block_bytes += n_bytes;
    return ptr;
}

pub fn md_start_new_block(ctx: *MD_CTX, line: *const MD_LINE_ANALYSIS) c_int {
    // MD_ASSERT(ctx->current_block == NULL);
    const block_raw = md_push_block_bytes(ctx, @sizeOf(MD_BLOCK));
    if (block_raw == null)
        return -1;
    const block: *MD_BLOCK = @ptrCast(@alignCast(block_raw));

    switch (line.type) {
        .hr => block.setType(c.BlockType.hr),
        .atx_header, .setext_header => block.setType(c.BlockType.h),
        .fenced_code, .indented_code => block.setType(c.BlockType.code),
        .text => block.setType(c.BlockType.p),
        .html => block.setType(c.BlockType.html),
        .frontmatter => block.setType(c.BlockType.frontmatter),
        // .blank / .setext_underline / .table_underline / default: MD_UNREACHABLE.
        else => unreachable,
    }

    block.bits.flags = 0;
    block.bits.data = @truncate(line.data);
    block.n_lines = 0;

    ctx.current_block = block;
    return 0;
}

// Eat from start of current (textual) block any reference definitions.
pub fn md_consume_link_reference_definitions(ctx: *MD_CTX) c_int {
    const lines: [*c]MD_LINE = @ptrCast(@alignCast(ctx.current_block + 1));
    const n_lines: MD_SIZE = ctx.current_block.*.n_lines;
    var n: MD_SIZE = 0;

    while (n < n_lines) {
        const n_link_ref_lines = md_is_link_reference_definition(ctx, lines[n..n_lines]);
        // Not a reference definition?
        if (n_link_ref_lines == 0)
            break;
        // Ref def but could not be stored (OOM).
        if (n_link_ref_lines < 0)
            return -1;
        n += @intCast(n_link_ref_lines);
    }

    if (n > 0) {
        if (n == n_lines) {
            // Remove complete block.
            ctx.n_block_bytes -= @intCast(n * @sizeOf(MD_LINE));
            ctx.n_block_bytes -= @sizeOf(MD_BLOCK);
            ctx.current_block = null;
        } else {
            // Remove just some initial lines from the block.
            const dst = @as([*]u8, @ptrCast(lines));
            const src = @as([*]const u8, @ptrCast(lines + n));
            const count = (n_lines - n) * @sizeOf(MD_LINE);
            std.mem.copyForwards(u8, dst[0..count], src[0..count]);
            ctx.current_block.*.n_lines -= n;
            ctx.n_block_bytes -= @intCast(n * @sizeOf(MD_LINE));
        }
    }

    return 0;
}

pub fn md_end_current_block(ctx: *MD_CTX) c_int {
    var ret: c_int = 0;

    if (ctx.current_block == null)
        return ret;

    // Check whether there is a reference definition.
    if (ctx.current_block.*.getType() == c.BlockType.p or
        (ctx.current_block.*.getType() == c.BlockType.h and (ctx.current_block.*.bits.flags & MD_BLOCK_SETEXT_HEADER != 0)))
    {
        const lines: [*c]MD_LINE = @ptrCast(@alignCast(ctx.current_block + 1));
        if (lines[0].beg < ctx.size and ctx.ch(lines[0].beg) == '[') {
            ret = md_consume_link_reference_definitions(ctx);
            if (ret < 0) return ret;
            if (ctx.current_block == null)
                return ret;
        }
    }

    if (ctx.current_block.*.getType() == c.BlockType.h and (ctx.current_block.*.bits.flags & MD_BLOCK_SETEXT_HEADER != 0)) {
        const n_lines: MD_SIZE = ctx.current_block.*.n_lines;

        if (n_lines > 1) {
            // Get rid of the underline.
            ctx.current_block.*.n_lines -= 1;
            ctx.n_block_bytes -= @sizeOf(MD_LINE);
        } else {
            // Only the underline has left after eating the ref. defs.
            ctx.current_block.*.setType(c.BlockType.p);
            return 0;
        }
    }

    // Mark we are not building any block anymore.
    ctx.current_block = null;

    return ret;
}

pub fn md_add_line_into_current_block(ctx: *MD_CTX, analysis: *const MD_LINE_ANALYSIS) c_int {
    // MD_ASSERT(ctx->current_block != NULL);
    const bt = ctx.current_block.*.getType();
    if (bt == c.BlockType.code or bt == c.BlockType.html or bt == c.BlockType.frontmatter) {
        const line_raw = md_push_block_bytes(ctx, @sizeOf(MD_VERBATIMLINE));
        if (line_raw == null)
            return -1;
        const line: *MD_VERBATIMLINE = @ptrCast(@alignCast(line_raw));
        line.indent = analysis.indent;
        line.beg = analysis.beg;
        line.end = analysis.end;
    } else {
        const line_raw = md_push_block_bytes(ctx, @sizeOf(MD_LINE));
        if (line_raw == null)
            return -1;
        const line: *MD_LINE = @ptrCast(@alignCast(line_raw));
        line.beg = analysis.beg;
        line.end = analysis.end;
    }
    ctx.current_block.*.n_lines += 1;

    return 0;
}

pub fn md_push_container_bytes(ctx: *MD_CTX, ty: c.BlockType, start: c_uint, data: c_uint, flags: c_uint) c_int {
    var ret: c_int = 0;

    ret = md_end_current_block(ctx);
    if (ret < 0) return ret;

    const block_raw = md_push_block_bytes(ctx, @sizeOf(MD_BLOCK));
    if (block_raw == null)
        return -1;
    const block: *MD_BLOCK = @ptrCast(@alignCast(block_raw));

    block.setType(ty);
    block.bits.flags = @truncate(flags);
    block.bits.data = @truncate(data);
    block.n_lines = start;

    return ret;
}

// --- component / slot / alert info arrays ------------------------------------

pub fn md_push_block_component_info(ctx: *MD_CTX, colon_count: c_uint, name_beg: OFF, name_end: OFF, props_beg: OFF, props_end: OFF, title_beg: OFF, title_end: OFF) error{OutOfMemory}!c_int {
    const idx: c_int = @intCast(ctx.block_component_info.items.len);
    ctx.block_component_info.append(ctx.alloc, .{
        .colon_count = colon_count,
        .name_beg = name_beg,
        .name_end = name_end,
        .props_beg = props_beg,
        .props_end = props_end,
        .title_beg = title_beg,
        .title_end = title_end,
    }) catch {
        ctx.log("realloc() failed.");
        return error.OutOfMemory;
    };
    return idx;
}

pub fn md_push_slot_info(ctx: *MD_CTX, name_beg: OFF, name_end: OFF) error{OutOfMemory}!c_int {
    const idx: c_int = @intCast(ctx.slot_info.items.len);
    ctx.slot_info.append(ctx.alloc, .{ .name_beg = name_beg, .name_end = name_end }) catch {
        ctx.log("realloc() failed.");
        return error.OutOfMemory;
    };
    return idx;
}

pub fn md_push_block_alert_info(ctx: *MD_CTX, type_beg: OFF, type_end: OFF) error{OutOfMemory}!c_int {
    const idx: c_int = @intCast(ctx.block_alert_info.items.len);
    ctx.block_alert_info.append(ctx.alloc, .{ .type_beg = type_beg, .type_end = type_end }) catch {
        ctx.log("realloc() failed.");
        return error.OutOfMemory;
    };
    return idx;
}

// --- line classification helpers ---------------------------------------------

pub fn md_is_hr_line(ctx: *MD_CTX, beg: OFF, p_end: *OFF, p_killer: *OFF) c_int {
    var off: OFF = beg + 1;
    var n: c_int = 1;

    while (off < ctx.size and (ctx.ch(off) == ctx.ch(beg) or ctx.ch(off) == ' ' or ctx.ch(off) == '\t')) {
        if (ctx.ch(off) == ctx.ch(beg))
            n += 1;
        off += 1;
    }

    if (n < 3) {
        p_killer.* = off;
        return FALSE;
    }

    // Nothing else can be present on the line.
    if (off < ctx.size and !ctx.isNewline(off)) {
        p_killer.* = off;
        return FALSE;
    }

    p_end.* = off;
    return TRUE;
}

pub fn md_is_atxheader_line(ctx: *MD_CTX, beg: OFF, p_beg: *OFF, p_end: *OFF, p_level: *c_uint) c_int {
    var off: OFF = beg + 1;

    while (off < ctx.size and ctx.ch(off) == '#' and off - beg < 7)
        off += 1;
    const n: OFF = off - beg;

    if (n > 6)
        return FALSE;
    p_level.* = n;

    if ((ctx.parser.flags & c.MD_FLAG_PERMISSIVEATXHEADERS == 0) and off < ctx.size and
        !ctx.isBlank(off) and !ctx.isNewline(off))
        return FALSE;

    while (off < ctx.size and ctx.isBlank(off))
        off += 1;
    p_beg.* = off;
    p_end.* = off;
    return TRUE;
}

pub fn md_is_setext_underline(ctx: *MD_CTX, beg: OFF, p_end: *OFF, p_level: *c_uint) c_int {
    var off: OFF = beg + 1;

    while (off < ctx.size and ctx.ch(off) == ctx.ch(beg))
        off += 1;

    // Optionally, space(s) or tabs can follow.
    while (off < ctx.size and ctx.isBlank(off))
        off += 1;

    // But nothing more is allowed on the line.
    if (off < ctx.size and !ctx.isNewline(off))
        return FALSE;

    p_level.* = if (ctx.ch(beg) == '=') 1 else 2;
    p_end.* = off;
    return TRUE;
}

pub fn md_is_table_underline(ctx: *MD_CTX, beg: OFF, p_end: *OFF, p_col_count: *c_uint) c_int {
    var off: OFF = beg;
    var found_pipe: c_int = FALSE;
    var col_count: c_uint = 0;

    if (off < ctx.size and ctx.ch(off) == '|') {
        found_pipe = TRUE;
        off += 1;
        while (off < ctx.size and ctx.isWhitespace(off))
            off += 1;
    }

    while (true) {
        var delimited: c_int = FALSE;

        // Cell underline ("-----", ":----", "----:" or ":----:")
        if (off < ctx.size and ctx.ch(off) == ':')
            off += 1;
        if (off >= ctx.size or ctx.ch(off) != '-')
            return FALSE;
        while (off < ctx.size and ctx.ch(off) == '-')
            off += 1;
        if (off < ctx.size and ctx.ch(off) == ':')
            off += 1;

        col_count += 1;
        if (col_count > TABLE_MAXCOLCOUNT) {
            ctx.log("Suppressing table (column_count > TABLE_MAXCOLCOUNT)");
            return FALSE;
        }

        // Pipe delimiter (optional at the end of line).
        while (off < ctx.size and ctx.isWhitespace(off))
            off += 1;
        if (off < ctx.size and ctx.ch(off) == '|') {
            delimited = TRUE;
            found_pipe = TRUE;
            off += 1;
            while (off < ctx.size and ctx.isWhitespace(off))
                off += 1;
        }

        // Success, if we reach end of line.
        if (off >= ctx.size or ctx.isNewline(off))
            break;

        if (delimited == FALSE)
            return FALSE;
    }

    if (found_pipe == FALSE)
        return FALSE;

    p_end.* = off;
    p_col_count.* = col_count;
    return TRUE;
}

pub fn md_is_opening_code_fence(ctx: *MD_CTX, beg: OFF, p_end: *OFF) c_int {
    var off: OFF = beg;

    while (off < ctx.size and ctx.ch(off) == ctx.ch(beg))
        off += 1;

    // Fence must have at least three characters.
    if (off - beg < 3)
        return FALSE;

    ctx.code_fence_length = off - beg;

    // Optionally, space(s) can follow.
    while (off < ctx.size and ctx.ch(off) == ' ')
        off += 1;

    // Optionally, an info string can follow.
    while (off < ctx.size and !ctx.isNewline(off)) {
        // Backtick-based fence must not contain '`' in the info string.
        if (ctx.ch(beg) == '`' and ctx.ch(off) == '`')
            return FALSE;
        off += 1;
    }

    p_end.* = off;
    return TRUE;
}

pub fn md_is_closing_code_fence(ctx: *MD_CTX, ch: CHAR, beg: OFF, p_end: *OFF) c_int {
    var off: OFF = beg;
    var ret: c_int = FALSE;

    // Closing fence must have at least the same length and use same char.
    while (off < ctx.size and ctx.ch(off) == ch)
        off += 1;
    if (off - beg < ctx.code_fence_length) {
        // goto out;
        p_end.* = off;
        return ret;
    }

    // Optionally, space(s) can follow
    while (off < ctx.size and ctx.ch(off) == ' ')
        off += 1;

    // But nothing more is allowed on the line.
    if (off < ctx.size and !ctx.isNewline(off)) {
        p_end.* = off;
        return ret;
    }

    ret = TRUE;

    // Note we set *p_end even on failure.
    p_end.* = off;
    return ret;
}

// --- HTML block start/end conditions -----------------------------------------

pub const TAG = struct {
    name: [*c]const CHAR,
    len: u8,
};
pub inline fn mkTag(comptime name: []const u8) TAG {
    return .{ .name = @ptrCast(name.ptr), .len = name.len };
}

pub const t1 = [_]TAG{ mkTag("pre"), mkTag("script"), mkTag("style"), mkTag("textarea") };

pub const a6 = [_]TAG{ mkTag("address"), mkTag("article"), mkTag("aside") };
pub const b6 = [_]TAG{ mkTag("base"), mkTag("basefont"), mkTag("blockquote"), mkTag("body") };
pub const c6 = [_]TAG{ mkTag("caption"), mkTag("center"), mkTag("col"), mkTag("colgroup") };
pub const d6 = [_]TAG{ mkTag("dd"), mkTag("details"), mkTag("dialog"), mkTag("dir"), mkTag("div"), mkTag("dl"), mkTag("dt") };
pub const f6 = [_]TAG{ mkTag("fieldset"), mkTag("figcaption"), mkTag("figure"), mkTag("footer"), mkTag("form"), mkTag("frame"), mkTag("frameset") };
pub const h6 = [_]TAG{ mkTag("h1"), mkTag("h2"), mkTag("h3"), mkTag("h4"), mkTag("h5"), mkTag("h6"), mkTag("head"), mkTag("header"), mkTag("hr"), mkTag("html") };
pub const tag_i6 = [_]TAG{mkTag("iframe")};
pub const l6 = [_]TAG{ mkTag("legend"), mkTag("li"), mkTag("link") };
pub const m6 = [_]TAG{ mkTag("main"), mkTag("menu"), mkTag("menuitem") };
pub const n6 = [_]TAG{ mkTag("nav"), mkTag("noframes") };
pub const o6 = [_]TAG{ mkTag("ol"), mkTag("optgroup"), mkTag("option") };
pub const p6 = [_]TAG{ mkTag("p"), mkTag("param") };
pub const s6 = [_]TAG{ mkTag("search"), mkTag("section"), mkTag("summary") };
pub const t6 = [_]TAG{ mkTag("table"), mkTag("tbody"), mkTag("td"), mkTag("tfoot"), mkTag("th"), mkTag("thead"), mkTag("title"), mkTag("tr"), mkTag("track") };
pub const tag_u6 = [_]TAG{mkTag("ul")};
pub const xx = [_]TAG{};

pub const map6 = [26][]const TAG{
    &a6, &b6, &c6, &d6, &xx, &f6, &xx, &h6,     &tag_i6, &xx, &xx, &l6, &m6,
    &n6, &o6, &p6, &xx, &xx, &s6, &t6, &tag_u6, &xx,     &xx, &xx, &xx, &xx,
};

// Returns type of the raw HTML block, or FALSE (0) if not an HTML block.
pub fn md_is_html_block_start_condition(ctx: *MD_CTX, beg: OFF) c_int {
    var off: OFF = beg + 1;

    // Check for type 1: <script, <pre, or <style
    for (t1) |tag| {
        if (off + tag.len <= ctx.size) {
            if (md_ascii_case_eq(ctx.str(off), tag.name, tag.len))
                return 1;
        }
    }

    // Check for type 2: <!--
    if (off + 3 < ctx.size and ctx.ch(off) == '!' and ctx.ch(off + 1) == '-' and ctx.ch(off + 2) == '-')
        return 2;

    // Check for type 3: <?
    if (off < ctx.size and ctx.ch(off) == '?')
        return 3;

    // Check for type 4 or 5: <!
    if (off < ctx.size and ctx.ch(off) == '!') {
        // Type 4: <! followed by uppercase letter (C tests ISASCII here).
        if (off + 1 < ctx.size and ctx.isAscii(off + 1))
            return 4;

        // Type 5: <![CDATA[
        if (off + 8 < ctx.size) {
            if (md_ascii_eq(ctx.str(off), "![CDATA[", 8))
                return 5;
        }
    }

    // Check for type 6: Many possible starting tags.
    if (off + 1 < ctx.size and (ctx.isAlpha(off) or (ctx.ch(off) == '/' and ctx.isAlpha(off + 1)))) {
        if (ctx.ch(off) == '/')
            off += 1;

        const slot: usize = if (ctx.isUpper(off)) @intCast(uval(ctx.ch(off)) - 'A') else @intCast(uval(ctx.ch(off)) - 'a');
        const tags = map6[slot];

        for (tags) |tag| {
            if (off + tag.len <= ctx.size) {
                if (md_ascii_case_eq(ctx.str(off), tag.name, tag.len)) {
                    const tmp: OFF = off + tag.len;
                    if (tmp >= ctx.size)
                        return 6;
                    if (ctx.isBlank(tmp) or ctx.isNewline(tmp) or ctx.ch(tmp) == '>')
                        return 6;
                    if (tmp + 1 < ctx.size and ctx.ch(tmp) == '/' and ctx.ch(tmp + 1) == '>')
                        return 6;
                    break;
                }
            }
        }
    }

    // Check for type 7: any COMPLETE other opening or closing tag.
    if (off + 1 < ctx.size) {
        var end: OFF = undefined;

        if (md_is_html_tag(ctx, &[_]MD_LINE{}, beg, ctx.size, &end)) {
            // Only optional whitespace and new line may follow.
            while (end < ctx.size and ctx.isWhitespace(end))
                end += 1;
            if (end >= ctx.size or ctx.isNewline(end))
                return 7;
        }
    }

    return FALSE;
}

// Case-sensitive check whether substring 'what' is between 'beg' and EOL.
pub fn md_line_contains(ctx: *MD_CTX, beg: OFF, what: [*c]const CHAR, what_len: SZ, p_end: *OFF) c_int {
    var i: OFF = beg;
    while (i + what_len < ctx.size) : (i += 1) {
        if (ctx.isNewline(i))
            break;
        if (memcmp(ctx.str(i), what, what_len) == 0) {
            p_end.* = i + what_len;
            return TRUE;
        }
    }

    p_end.* = i;
    return FALSE;
}

pub fn md_is_html_block_end_condition(ctx: *MD_CTX, beg: OFF, p_end: *OFF) c_int {
    switch (ctx.html_block_type) {
        1 => {
            var off: OFF = beg;

            while (off + 1 < ctx.size and !ctx.isNewline(off)) {
                if (ctx.ch(off) == '<' and ctx.ch(off + 1) == '/') {
                    for (t1) |tag| {
                        if (off + 2 + tag.len < ctx.size) {
                            if (md_ascii_case_eq(ctx.str(off + 2), tag.name, tag.len) and
                                ctx.ch(off + 2 + tag.len) == '>')
                            {
                                p_end.* = off + 2 + tag.len + 1;
                                return TRUE;
                            }
                        }
                    }
                }
                off += 1;
            }
            p_end.* = off;
            return FALSE;
        },

        2 => return if (md_line_contains(ctx, beg, "-->", 3, p_end) != 0) 2 else FALSE,
        3 => return if (md_line_contains(ctx, beg, "?>", 2, p_end) != 0) 3 else FALSE,
        4 => return if (md_line_contains(ctx, beg, ">", 1, p_end) != 0) 4 else FALSE,
        5 => return if (md_line_contains(ctx, beg, "]]>", 3, p_end) != 0) 5 else FALSE,

        6, 7 => {
            if (beg >= ctx.size or ctx.isNewline(beg)) {
                // Blank line ends types 6 and 7.
                p_end.* = beg;
                return ctx.html_block_type;
            }
            return FALSE;
        },

        else => unreachable, // MD_UNREACHABLE
    }
}

// --- block component / slot recognizers --------------------------------------

// ::name, ::name{props}, or ::name Title text {props}. Returns colon count (>=2)
// or 0 on failure.
pub fn md_is_block_component_opener(ctx: *MD_CTX, off_in: OFF, p_name_beg: *OFF, p_name_end: *OFF, p_props_beg: *OFF, p_props_end: *OFF, p_title_beg: *OFF, p_title_end: *OFF, p_end: *OFF) c_uint {
    var off: OFF = off_in;
    const start: OFF = off;

    while (off < ctx.size and ctx.ch(off) == ':')
        off += 1;
    const colon_count: c_uint = off - start;
    if (colon_count < 2)
        return 0;

    // Optional whitespace between colons and name.
    while (off < ctx.size and ctx.isBlank(off))
        off += 1;

    // Component name must start with a letter.
    if (off >= ctx.size or !ctx.isAlpha(off))
        return 0;

    p_name_beg.* = off;
    while (off < ctx.size and (ctx.isAlnum(off) or ctx.ch(off) == '-'))
        off += 1;
    p_name_end.* = off;

    if (p_name_end.* == p_name_beg.*)
        return 0;

    p_props_beg.* = 0;
    p_props_end.* = 0;
    p_title_beg.* = 0;
    p_title_end.* = 0;

    // Skip whitespace after name.
    while (off < ctx.size and ctx.isBlank(off))
        off += 1;

    // Check for {props} immediately after name.
    if (off < ctx.size and ctx.ch(off) == '{') {
        const brace_start: OFF = off + 1;
        var j: OFF = brace_start;
        while (j < ctx.size and !ctx.isNewline(j) and ctx.ch(j) != '}')
            j += 1;
        if (j < ctx.size and ctx.ch(j) == '}') {
            p_props_beg.* = brace_start;
            p_props_end.* = j;
            off = j + 1;
        }
    } else if (off < ctx.size and !ctx.isNewline(off)) {
        // Title text: everything until '{' or end of line.
        const title_start: OFF = off;
        while (off < ctx.size and !ctx.isNewline(off) and ctx.ch(off) != '{')
            off += 1;

        // Trim trailing whitespace from title.
        {
            var title_end: OFF = off;
            while (title_end > title_start and ISBLANK_(ctx.ch(title_end - 1)))
                title_end -= 1;
            if (title_end > title_start) {
                p_title_beg.* = title_start;
                p_title_end.* = title_end;
            }
        }

        // Check for {props} after title.
        if (off < ctx.size and ctx.ch(off) == '{') {
            const brace_start: OFF = off + 1;
            var j: OFF = brace_start;
            while (j < ctx.size and !ctx.isNewline(j) and ctx.ch(j) != '}')
                j += 1;
            if (j < ctx.size and ctx.ch(j) == '}') {
                p_props_beg.* = brace_start;
                p_props_end.* = j;
                off = j + 1;
            }
        }
    }

    // Only whitespace allowed after.
    while (off < ctx.size and ctx.isBlank(off))
        off += 1;
    if (off < ctx.size and !ctx.isNewline(off))
        return 0;

    p_end.* = off;
    return colon_count;
}

// :: (with only whitespace after). Returns colon count (>=2) or 0.
pub fn md_is_block_component_closer(ctx: *MD_CTX, off_in: OFF, p_end: *OFF) c_uint {
    var off: OFF = off_in;
    const start: OFF = off;

    while (off < ctx.size and ctx.ch(off) == ':')
        off += 1;
    const colon_count: c_uint = off - start;
    if (colon_count < 2)
        return 0;

    // Must not be followed by a name (that would be an opener).
    if (off < ctx.size and ctx.isAlpha(off))
        return 0;

    // Only whitespace allowed after.
    while (off < ctx.size and ctx.isBlank(off))
        off += 1;
    if (off < ctx.size and !ctx.isNewline(off))
        return 0;

    p_end.* = off;
    return colon_count;
}

// #slot-name (within a block component). Returns 1 on success, 0 on failure.
pub fn md_is_slot_opener(ctx: *MD_CTX, off_in: OFF, p_name_beg: *OFF, p_name_end: *OFF, p_end: *OFF) c_int {
    var off: OFF = off_in;

    if (off >= ctx.size or ctx.ch(off) != '#')
        return 0;
    off += 1;

    // Slot name must start with a letter.
    if (off >= ctx.size or !ctx.isAlpha(off))
        return 0;

    p_name_beg.* = off;
    while (off < ctx.size and (ctx.isAlnum(off) or ctx.ch(off) == '-'))
        off += 1;
    p_name_end.* = off;

    // Only whitespace allowed after.
    while (off < ctx.size and ctx.isBlank(off))
        off += 1;
    if (off < ctx.size and !ctx.isNewline(off))
        return 0;

    p_end.* = off;
    return 1;
}

// --- container push/pop ------------------------------------------------------

pub fn md_is_container_compatible(pivot_p: [*c]const MD_CONTAINER, container_p: [*c]const MD_CONTAINER) c_int {
    const pivot = &pivot_p[0];
    const container = &container_p[0];
    // Block quote has no "items" like lists.
    if (container.ch == '>')
        return FALSE;

    // Block components have no "items".
    if (container.ch == ':')
        return FALSE;

    if (container.ch != pivot.ch)
        return FALSE;
    if (container.mark_indent > pivot.contents_indent)
        return FALSE;

    return TRUE;
}

pub fn md_push_container(ctx: *MD_CTX, container: *const MD_CONTAINER) error{OutOfMemory}!void {
    ctx.containers.append(ctx.alloc, container.*) catch {
        ctx.log("realloc() failed.");
        return error.OutOfMemory;
    };
}

pub fn md_enter_child_containers(ctx: *MD_CTX, n_children: c_int) c_int {
    var ret: c_int = 0;

    var i: c_int = ctx.nContainers() - n_children;
    while (i < ctx.nContainers()) : (i += 1) {
        const cont = &ctx.containers.items[@intCast(i)];
        var is_ordered_list: c_int = FALSE;

        switch (cont.ch) {
            ')', '.' => {
                is_ordered_list = TRUE;
                // MD_FALLTHROUGH to bullet handling.
                _ = md_end_current_block(ctx);
                cont.block_byte_off = @intCast(ctx.n_block_bytes);

                ret = md_push_container_bytes(ctx, if (is_ordered_list != 0) c.BlockType.ol else c.BlockType.ul, cont.start, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, c.BlockType.li, cont.task_mark_off, if (cont.is_task != 0) @intCast(uval(ctx.ch(cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            '-', '+', '*' => {
                // Remember offset in block_bytes so we can revisit if loose.
                _ = md_end_current_block(ctx);
                cont.block_byte_off = @intCast(ctx.n_block_bytes);

                ret = md_push_container_bytes(ctx, if (is_ordered_list != 0) c.BlockType.ol else c.BlockType.ul, cont.start, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, c.BlockType.li, cont.task_mark_off, if (cont.is_task != 0) @intCast(uval(ctx.ch(cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            '>' => {
                if (cont.is_alert != 0)
                    ret = md_push_container_bytes(ctx, c.BlockType.alert, 0, cont.start, MD_BLOCK_CONTAINER_OPENER)
                else
                    ret = md_push_container_bytes(ctx, c.BlockType.quote, 0, 0, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            ':' => {
                ret = md_push_container_bytes(ctx, c.BlockType.component, 0, cont.start, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            '#' => {
                ret = md_push_container_bytes(ctx, c.BlockType.template, 0, cont.start, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            else => unreachable,
        }
    }

    return ret;
}

pub fn md_leave_child_containers(ctx: *MD_CTX, n_keep: c_int) c_int {
    var ret: c_int = 0;

    while (ctx.nContainers() > n_keep) {
        const cont = &ctx.containers.items[@intCast(ctx.nContainers() - 1)];
        var is_ordered_list: c_int = FALSE;

        switch (cont.ch) {
            ')', '.' => {
                is_ordered_list = TRUE;
                ret = md_push_container_bytes(ctx, c.BlockType.li, cont.task_mark_off, if (cont.is_task != 0) @intCast(uval(ctx.ch(cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, if (is_ordered_list != 0) c.BlockType.ol else c.BlockType.ul, 0, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
            },
            '-', '+', '*' => {
                ret = md_push_container_bytes(ctx, c.BlockType.li, cont.task_mark_off, if (cont.is_task != 0) @intCast(uval(ctx.ch(cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, if (is_ordered_list != 0) c.BlockType.ol else c.BlockType.ul, 0, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
            },
            '>' => {
                if (cont.is_alert != 0)
                    ret = md_push_container_bytes(ctx, c.BlockType.alert, 0, cont.start, MD_BLOCK_CONTAINER_CLOSER)
                else
                    ret = md_push_container_bytes(ctx, c.BlockType.quote, 0, 0, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
            },
            ':' => {
                ret = md_push_container_bytes(ctx, c.BlockType.component, 0, cont.start, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
                ctx.block_component_nesting -= 1;
            },
            '#' => {
                ret = md_push_container_bytes(ctx, c.BlockType.template, 0, cont.start, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
            },
            else => unreachable,
        }

        ctx.containers.items.len -= 1;
    }

    return ret;
}

pub fn md_is_container_mark(ctx: *MD_CTX, indent: c_uint, beg: OFF, p_end: *OFF, p_container: *MD_CONTAINER) c_int {
    var off: OFF = beg;

    if (off >= ctx.size or indent >= ctx.code_indent_offset)
        return FALSE;

    // Check for block quote mark.
    if (ctx.ch(off) == '>') {
        off += 1;
        p_container.ch = '>';
        p_container.is_loose = FALSE;
        p_container.is_task = FALSE;
        p_container.mark_indent = indent;
        p_container.contents_indent = indent + 1;
        p_end.* = off;
        return TRUE;
    }

    // Check for list item bullet mark.
    if (ctx.isAnyOf(off, "-+*") and (off + 1 >= ctx.size or ctx.isBlank(off + 1) or ctx.isNewline(off + 1))) {
        p_container.ch = ctx.ch(off);
        p_container.is_loose = FALSE;
        p_container.is_task = FALSE;
        p_container.mark_indent = indent;
        p_container.contents_indent = indent + 1;
        p_end.* = off + 1;
        return TRUE;
    }

    // Check for ordered list item marks.
    var max_end: OFF = off + 9;
    if (max_end > ctx.size)
        max_end = ctx.size;
    p_container.start = 0;
    while (off < max_end and ctx.isDigit(off)) {
        p_container.start = p_container.start * 10 + uval(ctx.ch(off)) - '0';
        off += 1;
    }
    if (off > beg and
        off < ctx.size and
        (ctx.ch(off) == '.' or ctx.ch(off) == ')') and
        (off + 1 >= ctx.size or ctx.isBlank(off + 1) or ctx.isNewline(off + 1)))
    {
        p_container.ch = ctx.ch(off);
        p_container.is_loose = FALSE;
        p_container.is_task = FALSE;
        p_container.mark_indent = indent;
        p_container.contents_indent = indent + off - beg + 1;
        p_end.* = off + 1;
        return TRUE;
    }

    return FALSE;
}

pub fn md_line_indentation(ctx: *MD_CTX, total_indent: c_uint, beg: OFF, p_end: *OFF) c_uint {
    var off: OFF = beg;
    var indent: c_uint = total_indent;

    while (off < ctx.size and ctx.isBlank(off)) {
        if (ctx.ch(off) == '\t')
            indent = (indent + 4) & ~@as(c_uint, 3)
        else
            indent += 1;
        off += 1;
    }

    p_end.* = off;
    return indent - total_indent;
}

pub const md_dummy_blank_line = MD_LINE_ANALYSIS{ .type = .blank, .data = 0, .enforce_new_block = 0, .beg = 0, .end = 0, .indent = 0 };

// Analyze type of the line and find some of its properties. Main input for
// determining type and boundaries of a block (md4x.c ~7096).
pub fn md_analyze_line(ctx: *MD_CTX, beg: OFF, p_end: *OFF, pivot_line_in: *const MD_LINE_ANALYSIS, line: *MD_LINE_ANALYSIS) c_int {
    var pivot_line = pivot_line_in;
    var total_indent: c_uint = 0;
    var n_parents: c_int = 0;
    var n_brothers: c_int = 0;
    var n_children: c_int = 0;
    var inside_component: c_int = 0;
    var container = MD_CONTAINER{};
    const prev_line_has_list_loosening_effect = ctx.last_line_has_list_loosening_effect;
    var off: OFF = beg;
    var hr_killer: OFF = 0;
    var ret: c_int = 0;

    line.indent = md_line_indentation(ctx, total_indent, off, &off);
    total_indent += line.indent;
    line.beg = off;
    line.enforce_new_block = FALSE;

    // Given the indentation and block quote marks '>', determine how many of
    // the current containers are our parents.
    while (n_parents < ctx.nContainers()) {
        const cont = &ctx.containers.items[@intCast(n_parents)];

        if (cont.ch == '>' and line.indent < ctx.code_indent_offset and
            off < ctx.size and ctx.ch(off) == '>')
        {
            // Block quote mark.
            off += 1;
            total_indent += 1;
            line.indent = md_line_indentation(ctx, total_indent, off, &off);
            total_indent += line.indent;

            // The optional 1st space after '>' is part of the block quote mark.
            if (line.indent > 0)
                line.indent -= 1;

            line.beg = off;
        } else if (cont.ch == ':') {
            // Block component: always continues. Subtract visual nesting indent.
            if (line.indent >= cont.contents_indent)
                line.indent -= cont.contents_indent;
            inside_component = 1;
        } else if (cont.ch == '#') {
            // Template slot: always continues. Subtract visual nesting indent.
            if (line.indent >= cont.contents_indent)
                line.indent -= cont.contents_indent;
            inside_component = 1;
        } else if (cont.ch != '>' and cont.ch != ':' and cont.ch != '#' and line.indent >= cont.contents_indent) {
            // List.
            line.indent -= cont.contents_indent;
        } else {
            break;
        }

        n_parents += 1;
    }

    if (off >= ctx.size or ctx.isNewline(off)) {
        // Blank line does not need any real indentation to be nested inside a
        // list, block component, or template slot.
        if (n_brothers + n_children == 0) {
            while (n_parents < ctx.nContainers() and ctx.containers.items[@intCast(n_parents)].ch != '>' and
                ctx.containers.items[@intCast(n_parents)].ch != ':' and
                ctx.containers.items[@intCast(n_parents)].ch != '#')
                n_parents += 1;
        }
    }

    classify: while (true) {
        // Check whether we are frontmatter continuation.
        if (pivot_line.type == .frontmatter) {
            line.beg = off;

            // Check for closing --- fence.
            if (line.indent < ctx.code_indent_offset and
                off < ctx.size and ctx.ch(off) == '-')
            {
                var tmp: OFF = off;
                while (tmp < ctx.size and ctx.ch(tmp) == '-')
                    tmp += 1;
                if (tmp - off >= 3) {
                    // Only spaces allowed after the dashes.
                    while (tmp < ctx.size and ctx.ch(tmp) == ' ')
                        tmp += 1;
                    if (tmp >= ctx.size or ctx.isNewline(tmp)) {
                        line.type = .blank;
                        if (pivot_line.data == 2) {
                            // Component frontmatter: mark container as done.
                            var i: c_int = ctx.nContainers() - 1;
                            while (i >= 0) : (i -= 1) {
                                if (ctx.containers.items[@intCast(i)].ch == ':') {
                                    ctx.containers.items[@intCast(i)].comp_fm_state = 2;
                                    break;
                                }
                            }
                        } else {
                            ctx.frontmatter_state = 2;
                        }
                        break :classify;
                    }
                }
            }

            line.type = .frontmatter;
            line.data = pivot_line.data;
            n_parents = ctx.nContainers();
            break :classify;
        }

        // Check whether we are fenced code continuation.
        if (pivot_line.type == .fenced_code) {
            line.beg = off;

            // Another .fenced_code unless closing fence (→ .blank).
            if (line.indent < ctx.code_indent_offset) {
                if (md_is_closing_code_fence(ctx, ctx.ch(pivot_line.beg), off, &off) != 0) {
                    line.type = .blank;
                    ctx.last_line_has_list_loosening_effect = FALSE;
                    break :classify;
                }
            }

            // Change indentation accordingly to the initial code fence.
            if (n_parents == ctx.nContainers()) {
                if (line.indent > pivot_line.indent)
                    line.indent -= pivot_line.indent
                else
                    line.indent = 0;

                line.type = .fenced_code;
                break :classify;
            }
        }

        // Check whether we are HTML block continuation.
        if (pivot_line.type == .html and ctx.html_block_type > 0) {
            if (n_parents < ctx.nContainers()) {
                // HTML block ends implicitly when enclosing container ends.
                ctx.html_block_type = 0;
            } else {
                const html_block_type = md_is_html_block_end_condition(ctx, off, &off);
                if (html_block_type > 0) {
                    // MD_ASSERT(html_block_type == ctx->html_block_type);
                    ctx.html_block_type = 0;

                    // Some end conditions serve as blank lines.
                    if (html_block_type == 6 or html_block_type == 7) {
                        line.type = .blank;
                        line.indent = 0;
                        break :classify;
                    }
                }

                line.type = .html;
                n_parents = ctx.nContainers();
                break :classify;
            }
        }

        // Check for block component closer (::).
        if ((ctx.parser.flags & c.MD_FLAG_COMPONENTS != 0) and ctx.block_component_nesting > 0 and
            (line.indent < ctx.code_indent_offset or inside_component != 0) and off < ctx.size and ctx.ch(off) == ':')
        {
            var tmp: OFF = undefined;
            const closer_colons = md_is_block_component_closer(ctx, off, &tmp);
            if (closer_colons > 0) {
                // Find the innermost open block component with matching colon count.
                var i: c_int = ctx.nContainers() - 1;
                var matched: c_int = 0;
                while (i >= 0) : (i -= 1) {
                    if (ctx.containers.items[@intCast(i)].ch == ':' and ctx.containers.items[@intCast(i)].colon_count <= closer_colons) {
                        // Close this component and everything inside it.
                        if (n_children == 0) {
                            ret = md_leave_child_containers(ctx, i);
                            if (ret < 0) return ret;
                        }

                        line.type = .blank;
                        ctx.last_line_has_list_loosening_effect = FALSE;
                        off = tmp;
                        matched = 1;
                        break;
                    }
                }
                // Use a local flag rather than re-reading line.type, which on the
                // no-match path may not have been set this call (stale/uninitialized
                // -> nondeterministic dropping of an orphaned '::' closer line).
                if (matched != 0)
                    break :classify;
            }
        }

        // Check for slot opener (#slot-name) inside a block component.
        if ((ctx.parser.flags & c.MD_FLAG_COMPONENTS != 0) and ctx.block_component_nesting > 0 and
            (line.indent < ctx.code_indent_offset or inside_component != 0) and
            pivot_line.type != .text and
            off < ctx.size and ctx.ch(off) == '#')
        {
            var name_beg: OFF = undefined;
            var name_end: OFF = undefined;
            var slot_end: OFF = undefined;
            if (md_is_slot_opener(ctx, off, &name_beg, &name_end, &slot_end) != 0) {
                const slot_idx = md_push_slot_info(ctx, name_beg, name_end) catch {
                    ret = -1;
                    return ret;
                };

                // Close any existing template container within the component.
                {
                    var i: c_int = ctx.nContainers() - 1;
                    while (i >= 0) : (i -= 1) {
                        if (ctx.containers.items[@intCast(i)].ch == '#') {
                            if (n_children == 0) {
                                ret = md_leave_child_containers(ctx, i);
                                if (ret < 0) return ret;
                            }
                            break;
                        }
                        // Stop at component boundary.
                        if (ctx.containers.items[@intCast(i)].ch == ':')
                            break;
                    }
                }

                container.ch = '#';
                container.is_loose = FALSE;
                container.is_task = FALSE;
                container.mark_indent = 0;
                container.contents_indent = line.indent;
                container.start = @intCast(slot_idx);
                container.colon_count = 0;

                if (n_brothers + n_children == 0)
                    pivot_line = &md_dummy_blank_line;
                if (n_children == 0) {
                    ret = md_leave_child_containers(ctx, n_parents + n_brothers);
                    if (ret < 0) return ret;
                }

                n_children += 1;
                md_push_container(ctx, &container) catch return -1;

                off = slot_end;
                line.type = .blank;
                break :classify;
            }
        }

        // Check for blank line.
        if (off >= ctx.size or ctx.isNewline(off)) {
            if (pivot_line.type == .indented_code and n_parents == ctx.nContainers()) {
                line.type = .indented_code;
                if (line.indent > ctx.code_indent_offset)
                    line.indent -= ctx.code_indent_offset
                else
                    line.indent = 0;
                ctx.last_line_has_list_loosening_effect = FALSE;
            } else {
                line.type = .blank;
                ctx.last_line_has_list_loosening_effect = @intFromBool(n_parents > 0 and
                    n_brothers + n_children == 0 and
                    ctx.containers.items[@intCast(n_parents - 1)].ch != '>');

                // See https://github.com/mity/md4c/issues/6 — empty list item
                // not on its first line forces list end on next non-blank line.
                if (n_parents > 0 and ctx.containers.items[@intCast(n_parents - 1)].ch != '>' and
                    n_brothers + n_children == 0 and ctx.current_block == null and
                    ctx.n_block_bytes > @as(c_int, @sizeOf(MD_BLOCK)))
                {
                    const top_block: *MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + @as(usize, @intCast(ctx.n_block_bytes - @sizeOf(MD_BLOCK)))));
                    if (top_block.typeIsRaw(c.BlockType.li))
                        ctx.last_list_item_starts_with_two_blank_lines = TRUE;
                }
            }
            break :classify;
        } else {
            // 2nd half of the hack: 2nd blank line at list item start forces end.
            if (ctx.last_list_item_starts_with_two_blank_lines != 0) {
                if (n_parents > 0 and n_parents == ctx.nContainers() and
                    ctx.containers.items[@intCast(n_parents - 1)].ch != '>' and
                    n_brothers + n_children == 0 and ctx.current_block == null and
                    ctx.n_block_bytes > @as(c_int, @sizeOf(MD_BLOCK)))
                {
                    const top_block: *MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + @as(usize, @intCast(ctx.n_block_bytes - @sizeOf(MD_BLOCK)))));
                    if (top_block.typeIsRaw(c.BlockType.li)) {
                        n_parents -= 1;

                        line.indent = total_indent;
                        if (n_parents > 0)
                            line.indent -= MIN_u(line.indent, ctx.containers.items[@intCast(n_parents - 1)].contents_indent);
                    }
                }

                ctx.last_list_item_starts_with_two_blank_lines = FALSE;
            }
            ctx.last_line_has_list_loosening_effect = FALSE;
        }

        // Check for alert syntax > [!TYPE] inside a newly opened blockquote.
        if ((ctx.parser.flags & c.MD_FLAG_ALERTS != 0) and n_children > 0 and
            line.indent < ctx.code_indent_offset and
            off < ctx.size and ctx.ch(off) == '[')
        {
            const last_cont: c_int = ctx.nContainers() - 1;
            if (last_cont >= 0 and ctx.containers.items[@intCast(last_cont)].ch == '>' and
                ctx.containers.items[@intCast(last_cont)].is_alert == 0)
            {
                var tmp: OFF = off + 1;
                if (tmp < ctx.size and ctx.ch(tmp) == '!') {
                    tmp += 1;
                    const type_beg: OFF = tmp;
                    while (tmp < ctx.size and (ctx.isAlpha(tmp) or ctx.isDigit(tmp) or ctx.ch(tmp) == '-' or ctx.ch(tmp) == '_'))
                        tmp += 1;
                    const type_end: OFF = tmp;
                    if (type_end > type_beg and tmp < ctx.size and ctx.ch(tmp) == ']') {
                        tmp += 1;
                        while (tmp < ctx.size and ctx.isBlank(tmp))
                            tmp += 1;
                        if (tmp >= ctx.size or ctx.isNewline(tmp)) {
                            const alert_idx = md_push_block_alert_info(ctx, type_beg, type_end) catch {
                                ret = -1;
                                return ret;
                            };
                            ctx.containers.items[@intCast(last_cont)].is_alert = TRUE;
                            ctx.containers.items[@intCast(last_cont)].start = @intCast(alert_idx);
                            line.type = .blank;
                            break :classify;
                        }
                    }
                }
            }
        }

        // Check whether we are Setext underline.
        if (line.indent < ctx.code_indent_offset and pivot_line.type == .text and
            off < ctx.size and ctx.isAnyOf2(off, '=', '-') and
            (n_parents == ctx.nContainers()))
        {
            var level: c_uint = undefined;

            if (md_is_setext_underline(ctx, off, &off, &level) != 0) {
                line.type = .setext_underline;
                line.data = level;
                break :classify;
            }
        }

        // Check for frontmatter opening at the very start of the document.
        if ((ctx.parser.flags & c.MD_FLAG_FRONTMATTER != 0) and
            ctx.frontmatter_state == 0 and
            line.indent < ctx.code_indent_offset and n_parents == 0 and
            off < ctx.size and ctx.ch(off) == '-')
        {
            var tmp: OFF = off;
            while (tmp < ctx.size and ctx.ch(tmp) == '-')
                tmp += 1;
            if (tmp - off >= 3) {
                while (tmp < ctx.size and ctx.ch(tmp) == ' ')
                    tmp += 1;
                if (tmp >= ctx.size or ctx.isNewline(tmp)) {
                    if (beg == 0) {
                        line.type = .frontmatter;
                        line.enforce_new_block = TRUE;
                        line.data = 1;
                        ctx.frontmatter_state = 1;
                        break :classify;
                    }
                }
            }
            ctx.frontmatter_state = 2;
        }

        // Disable frontmatter detection after first non-blank line.
        if (ctx.frontmatter_state == 0)
            ctx.frontmatter_state = 2;

        // Check for component frontmatter opener (--- inside a block component).
        if ((ctx.parser.flags & c.MD_FLAG_COMPONENTS != 0) and
            ctx.block_component_nesting > 0)
        {
            // Find the innermost component container.
            var comp_i: c_int = ctx.nContainers() - 1;
            while (comp_i >= 0) : (comp_i -= 1) {
                if (ctx.containers.items[@intCast(comp_i)].ch == ':')
                    break;
            }
            if (comp_i >= 0 and ctx.containers.items[@intCast(comp_i)].comp_fm_state == 0) {
                var found_opener: c_int = FALSE;
                if (line.indent < ctx.code_indent_offset and
                    off < ctx.size and ctx.ch(off) == '-')
                {
                    var tmp: OFF = off;
                    while (tmp < ctx.size and ctx.ch(tmp) == '-')
                        tmp += 1;
                    if (tmp - off >= 3) {
                        while (tmp < ctx.size and ctx.ch(tmp) == ' ')
                            tmp += 1;
                        if (tmp >= ctx.size or ctx.isNewline(tmp)) {
                            ctx.containers.items[@intCast(comp_i)].comp_fm_state = 1;
                            line.type = .frontmatter;
                            line.data = 2; // 2 = component frontmatter
                            line.enforce_new_block = TRUE;
                            found_opener = TRUE;
                        }
                    }
                }
                if (found_opener != 0)
                    break :classify;
                // First non-blank line is not ---; disable component frontmatter.
                ctx.containers.items[@intCast(comp_i)].comp_fm_state = 2;
            }
        }

        // Check for thematic break line.
        if (line.indent < ctx.code_indent_offset and
            off < ctx.size and off >= hr_killer and
            ctx.isAnyOf(off, "-_*"))
        {
            if (md_is_hr_line(ctx, off, &off, &hr_killer) != 0) {
                line.type = .hr;
                break :classify;
            }
        }

        // Check for "brother" container (another list item in started list).
        if (n_parents < ctx.nContainers() and n_brothers + n_children == 0) {
            var tmp: OFF = undefined;

            if (md_is_container_mark(ctx, line.indent, off, &tmp, &container) != 0 and
                md_is_container_compatible(&ctx.containers.items[@intCast(n_parents)], &container) != 0)
            {
                pivot_line = &md_dummy_blank_line;

                off = tmp;

                total_indent += container.contents_indent - container.mark_indent;
                line.indent = md_line_indentation(ctx, total_indent, off, &off);
                total_indent += line.indent;
                line.beg = off;

                // Some of the following whitespace still belongs to the mark.
                if (off >= ctx.size or ctx.isNewline(off)) {
                    container.contents_indent += 1;
                } else if (line.indent <= ctx.code_indent_offset) {
                    container.contents_indent += line.indent;
                    line.indent = 0;
                } else {
                    container.contents_indent += 1;
                    line.indent -= 1;
                }

                ctx.containers.items[@intCast(n_parents)].mark_indent = container.mark_indent;
                ctx.containers.items[@intCast(n_parents)].contents_indent = container.contents_indent;

                n_brothers += 1;
                continue :classify;
            }
        }

        // Check for indented code (cannot interrupt a paragraph; disabled
        // inside block components).
        if (line.indent >= ctx.code_indent_offset and inside_component == 0 and (pivot_line.type != .text)) {
            line.type = .indented_code;
            line.indent -= ctx.code_indent_offset;
            line.data = 0;
            break :classify;
        }

        // Check for block component opener (::name or ::name{props}).
        if ((ctx.parser.flags & c.MD_FLAG_COMPONENTS != 0) and
            (line.indent < ctx.code_indent_offset or inside_component != 0) and
            pivot_line.type != .text and
            off < ctx.size and ctx.ch(off) == ':')
        {
            var name_beg: OFF = undefined;
            var name_end: OFF = undefined;
            var props_beg: OFF = undefined;
            var props_end: OFF = undefined;
            var title_beg: OFF = undefined;
            var title_end: OFF = undefined;
            var comp_end: OFF = undefined;
            const colon_count = md_is_block_component_opener(ctx, off, &name_beg, &name_end, &props_beg, &props_end, &title_beg, &title_end, &comp_end);
            if (colon_count > 0) {
                const comp_idx = md_push_block_component_info(ctx, colon_count, name_beg, name_end, props_beg, props_end, title_beg, title_end) catch {
                    ret = -1;
                    return ret;
                };

                container.ch = ':';
                container.is_loose = FALSE;
                container.is_task = FALSE;
                container.mark_indent = 0;
                container.contents_indent = line.indent;
                container.start = @intCast(comp_idx);
                container.colon_count = colon_count;
                container.comp_fm_state = 0;

                if (n_brothers + n_children == 0)
                    pivot_line = &md_dummy_blank_line;
                if (n_children == 0) {
                    ret = md_leave_child_containers(ctx, n_parents + n_brothers);
                    if (ret < 0) return ret;
                }

                n_children += 1;
                md_push_container(ctx, &container) catch return -1;
                ctx.block_component_nesting += 1;

                off = comp_end;
                line.type = .blank;
                break :classify;
            }
        }

        // Check for start of a new container block.
        if (line.indent < ctx.code_indent_offset and
            md_is_container_mark(ctx, line.indent, off, &off, &container) != 0)
        {
            if (pivot_line.type == .text and n_parents == ctx.nContainers() and
                (off >= ctx.size or ctx.isNewline(off)) and container.ch != '>')
            {
                // Noop. List mark + blank line cannot interrupt a paragraph.
            } else if (pivot_line.type == .text and n_parents == ctx.nContainers() and
                ISANYOF2_(container.ch, '.', ')') and container.start != 1)
            {
                // Noop. Ordered list interrupts a paragraph only when start == 1.
            } else {
                total_indent += container.contents_indent - container.mark_indent;
                line.indent = md_line_indentation(ctx, total_indent, off, &off);
                total_indent += line.indent;

                line.beg = off;
                line.data = uval(container.ch);

                // Some of the following whitespace still belongs to the mark.
                if (off >= ctx.size or ctx.isNewline(off)) {
                    container.contents_indent += 1;
                } else if (line.indent <= ctx.code_indent_offset) {
                    container.contents_indent += line.indent;
                    line.indent = 0;
                } else {
                    container.contents_indent += 1;
                    line.indent -= 1;
                }

                if (n_brothers + n_children == 0)
                    pivot_line = &md_dummy_blank_line;

                if (n_children == 0) {
                    ret = md_leave_child_containers(ctx, n_parents + n_brothers);
                    if (ret < 0) return ret;
                }

                n_children += 1;
                md_push_container(ctx, &container) catch return -1;
                continue :classify;
            }
        }

        // Check whether we are table continuation.
        if (pivot_line.type == .table and n_parents == ctx.nContainers()) {
            line.type = .table;
            break :classify;
        }

        // Check for ATX header.
        if (line.indent < ctx.code_indent_offset and
            off < ctx.size and ctx.ch(off) == '#')
        {
            var level: c_uint = undefined;

            if (md_is_atxheader_line(ctx, off, &line.beg, &off, &level) != 0) {
                line.type = .atx_header;
                line.data = level;
                break :classify;
            }
        }

        // Check whether we are starting code fence.
        if (line.indent < ctx.code_indent_offset and
            off < ctx.size and ctx.isAnyOf2(off, '`', '~'))
        {
            if (md_is_opening_code_fence(ctx, off, &off) != 0) {
                line.type = .fenced_code;
                line.data = 1;
                line.enforce_new_block = TRUE;
                break :classify;
            }
        }

        // Check for start of raw HTML block.
        if (off < ctx.size and ctx.ch(off) == '<' and
            (ctx.parser.flags & c.MD_FLAG_NOHTMLBLOCKS == 0))
        {
            ctx.html_block_type = md_is_html_block_start_condition(ctx, off);

            // HTML block type 7 cannot interrupt paragraph.
            if (ctx.html_block_type == 7 and pivot_line.type == .text)
                ctx.html_block_type = 0;

            if (ctx.html_block_type > 0) {
                // The line itself also may immediately close the block.
                if (md_is_html_block_end_condition(ctx, off, &off) == ctx.html_block_type) {
                    ctx.html_block_type = 0;
                }

                line.enforce_new_block = TRUE;
                line.type = .html;
                break :classify;
            }
        }

        // Check for table underline.
        if ((ctx.parser.flags & c.MD_FLAG_TABLES != 0) and pivot_line.type == .text and
            off < ctx.size and ctx.isAnyOf3(off, '|', '-', ':') and
            n_parents == ctx.nContainers())
        {
            var col_count: c_uint = undefined;

            if (ctx.current_block != null and ctx.current_block.*.n_lines == 1 and
                md_is_table_underline(ctx, off, &off, &col_count) != 0)
            {
                line.data = col_count;
                line.type = .table_underline;
                break :classify;
            }
        }

        // By default, we are normal text line.
        line.type = .text;
        if (pivot_line.type == .text and n_brothers + n_children == 0) {
            // Lazy continuation.
            n_parents = ctx.nContainers();
        }

        // Check for task mark.
        if ((ctx.parser.flags & c.MD_FLAG_TASKLISTS != 0) and n_brothers + n_children > 0 and
            ISANYOF_(ctx.containers.items[@intCast(ctx.nContainers() - 1)].ch, "-+*.)"))
        {
            var tmp: OFF = off;

            while (tmp < ctx.size and tmp < off + 3 and ctx.isBlank(tmp))
                tmp += 1;
            if (tmp + 2 < ctx.size and ctx.ch(tmp) == '[' and
                ctx.isAnyOf(tmp + 1, "xX ") and ctx.ch(tmp + 2) == ']' and
                (tmp + 3 == ctx.size or ctx.isBlank(tmp + 3) or ctx.isNewline(tmp + 3)))
            {
                const task_container = if (n_children > 0) &ctx.containers.items[@intCast(ctx.nContainers() - 1)] else &container;
                task_container.is_task = TRUE;
                task_container.task_mark_off = tmp + 1;
                off = tmp + 3;
                while (off < ctx.size and ctx.isWhitespace(off))
                    off += 1;
                line.beg = off;
            }
        }

        break :classify;
    }

    // Scan for end of the line.
    if (ctx.doc_ends_with_newline != 0 and off < ctx.size) {
        while (true) {
            off += @intCast(strcspn(ctx.str(off), "\r\n"));

            // strcspn() can stop on zero terminator; it can appear anywhere.
            if (ctx.ch(off) == 0)
                off += 1
            else
                break;
        }
    } else {
        // Optimization: Use some loop unrolling.
        while (off + 3 < ctx.size and !ctx.isNewline(off + 0) and !ctx.isNewline(off + 1) and
            !ctx.isNewline(off + 2) and !ctx.isNewline(off + 3))
            off += 4;
        while (off < ctx.size and !ctx.isNewline(off))
            off += 1;
    }

    // Set end of the line.
    line.end = off;

    // But for ATX header, exclude the optional trailing mark.
    if (line.type == .atx_header) {
        var tmp: OFF = line.end;
        while (tmp > line.beg and ctx.isBlank(tmp - 1))
            tmp -= 1;
        while (tmp > line.beg and ctx.ch(tmp - 1) == '#')
            tmp -= 1;
        if (tmp == line.beg or ctx.isBlank(tmp - 1) or (ctx.parser.flags & c.MD_FLAG_PERMISSIVEATXHEADERS != 0))
            line.end = tmp;
    }

    // Trim trailing spaces.
    if (line.type != .indented_code and line.type != .fenced_code and line.type != .html) {
        while (line.end > line.beg and ctx.isBlank(line.end - 1))
            line.end -= 1;
    }

    // Eat also the new line.
    if (off < ctx.size and ctx.ch(off) == '\r')
        off += 1;
    if (off < ctx.size and ctx.ch(off) == '\n')
        off += 1;

    p_end.* = off;

    // If we belong to a list after seeing a blank line, the list is loose.
    if (prev_line_has_list_loosening_effect != 0 and line.type != .blank and n_parents + n_brothers > 0) {
        const cont = &ctx.containers.items[@intCast(n_parents + n_brothers - 1)];
        if (cont.ch != '>') {
            const block: *MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + cont.block_byte_off));
            block.bits.flags |= @as(u8, @truncate(MD_BLOCK_LOOSE_LIST));
        }
    }

    // Leave any containers we are not part of anymore.
    if (n_children == 0 and n_parents + n_brothers < ctx.nContainers()) {
        ret = md_leave_child_containers(ctx, n_parents + n_brothers);
        if (ret < 0) return ret;
    }

    // Enter any container we found a mark for.
    if (n_brothers > 0) {
        // MD_ASSERT(n_brothers == 1);
        ret = md_push_container_bytes(ctx, c.BlockType.li, ctx.containers.items[@intCast(n_parents)].task_mark_off, if (ctx.containers.items[@intCast(n_parents)].is_task != 0) @intCast(uval(ctx.ch(ctx.containers.items[@intCast(n_parents)].task_mark_off))) else 0, MD_BLOCK_CONTAINER_CLOSER);
        if (ret < 0) return ret;
        ret = md_push_container_bytes(ctx, c.BlockType.li, container.task_mark_off, if (container.is_task != 0) @intCast(uval(ctx.ch(container.task_mark_off))) else 0, MD_BLOCK_CONTAINER_OPENER);
        if (ret < 0) return ret;
        ctx.containers.items[@intCast(n_parents)].is_task = container.is_task;
        ctx.containers.items[@intCast(n_parents)].task_mark_off = container.task_mark_off;
    }

    if (n_children > 0) {
        ret = md_enter_child_containers(ctx, n_children);
        if (ret < 0) return ret;
    }

    return ret;
}
