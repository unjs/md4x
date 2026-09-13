// MD4X parser — block / line analysis module (Pass D).
//
// Block accumulation + container push/pop, the line classifier (md_analyze_line)
// and its helpers, HTML-block start/end conditions, and the block-component /
// slot recognizers. Extracted verbatim from the monolithic src/md4x.zig (pure
// refactor — no logic change). See AGENTS.md.

const std = @import("std");
const scan = @import("../scan.zig");
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
const MAX_BLOCK_INFO_RECORDS = types.MAX_BLOCK_INFO_RECORDS;
const CODE_INDENT_OFFSET = types.CODE_INDENT_OFFSET;

const uval = util.uval;
const ISANYOF2_ = util.ISANYOF2_;
const ISANYOF_ = util.ISANYOF_;
const ISBLANK_ = util.ISBLANK_;
const md_ascii_case_eq = util.md_ascii_case_eq;
const md_ascii_eq = util.md_ascii_eq;
const memcmp = util.memcmp;

const md_is_link_reference_definition = refdefs.md_is_link_reference_definition;
const md_is_footnote_definition = refdefs.md_is_footnote_definition;

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

// The column count is stored in the 16-bit `MD_BLOCK.bits.data`, so refuse at
// the opener rather than truncating at emission (see conventions.md). Upstream
// md4c deleted its cap entirely in 589681b and now silently wraps mod 65536
// (65 536 columns emit zero `<th>`), which md4x deliberately does not copy.
// DoS protection is the density check in `md_process_leaf_block`, not this cap.
pub const TABLE_MAXCOLCOUNT: c_uint = 65535;

// `MD_MIN` for unsigned values.
pub inline fn MIN_u(a: c_uint, b: c_uint) c_uint {
    return if (a < b) a else b;
}

// --- block-bytes growable buffer ---------------------------------------------

// md_push_block_bytes (md4x.c ~5984). Returns a raw pointer into ctx.block_bytes,
// or null on OOM (mirroring C's NULL). Fixes ctx.current_block after realloc.
//
// All the bookkeeping is `usize`. md4c does it in `int`, so the growth step
// signed-overflows once the arena passes 1 677 392 853 bytes — reachable from a
// ~140 MB document, since a blank line inside a fenced code block costs 12
// arena bytes per input byte. Past that point the counters no longer describe
// the allocation and the returned slot pointer stops being inside it. `usize`
// removes the overflow; `types.MAX_BLOCK_BYTES` keeps the arena inside what
// `MD_CONTAINER.block_byte_off` (an OFF) can address, and both the demand test
// and the growth step are written so they cannot wrap on a 32-bit usize either
// (wasm32), where `MAX_BLOCK_BYTES == maxInt(usize)`.
pub fn md_push_block_bytes(ctx: *MD_CTX, n_bytes: usize) ?*anyopaque {
    // Refuse rather than wrap. Phrased as a subtraction so it holds when
    // MAX_BLOCK_BYTES is maxInt(usize).
    if (ctx.n_block_bytes > types.MAX_BLOCK_BYTES - n_bytes) {
        ctx.log("block_bytes arena limit exceeded.");
        return null;
    }
    const needed: usize = ctx.n_block_bytes + n_bytes;

    if (needed > ctx.alloc_block_bytes) {
        const old_alloc: usize = ctx.alloc_block_bytes;
        // Saturating so the 1.5x step cannot wrap; @max covers the case where
        // 1.5x is still short of the demand, @min honours the ceiling.
        const grown: usize = if (old_alloc > 0) old_alloc +| old_alloc / 2 else 512;
        ctx.alloc_block_bytes = @min(@max(grown, needed), types.MAX_BLOCK_BYTES);
        const new_block_bytes = util.arena_realloc(ctx.alloc, ctx.block_bytes, old_alloc, ctx.alloc_block_bytes);
        if (new_block_bytes == null) {
            ctx.log("realloc() failed.");
            ctx.alloc_block_bytes = old_alloc;
            return null;
        }

        // Fix the ->current_block after the reallocation.
        if (ctx.current_block != null) {
            const off_current_block: usize = @intFromPtr(ctx.current_block) - @intFromPtr(ctx.block_bytes);
            ctx.current_block = @ptrCast(@alignCast(@as([*]u8, @ptrCast(new_block_bytes)) + off_current_block));
        }

        ctx.block_bytes = new_block_bytes;
    }

    const ptr: *anyopaque = @ptrCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + ctx.n_block_bytes);
    ctx.n_block_bytes = needed;
    return ptr;
}

pub fn md_start_new_block(ctx: *MD_CTX, line: *const MD_LINE_ANALYSIS) c_int {
    // MD_ASSERT(ctx->current_block == NULL);
    const block_raw = md_push_block_bytes(ctx, @sizeOf(MD_BLOCK));
    if (block_raw == null)
        return -1;
    const block: *MD_BLOCK = @ptrCast(@alignCast(block_raw));
    ctx.last_block_off = ctx.n_block_bytes - @sizeOf(MD_BLOCK);

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

// Eat from start of current (textual) block any reference definitions and/or
// footnote definitions. (Both can only be at the start of it, as neither can
// break a paragraph.)
pub fn md_consume_link_reference_definitions(ctx: *MD_CTX) c_int {
    const lines: [*c]MD_LINE = @ptrCast(@alignCast(ctx.current_block + 1));
    const n_lines: MD_SIZE = ctx.current_block.*.n_lines;
    var n: MD_SIZE = 0;

    while (n < n_lines) {
        var n_consumed: c_int = 0;

        // A line starting `[^` is offered to the footnote recognizer FIRST.
        // Otherwise `[^x]: url` is swallowed by the link-reference recognizer
        // as a ref def labelled `^x` — which is exactly the mis-parse the
        // footnote extension fixes.
        if (lines[n].beg + 1 < ctx.size and
            ctx.ch(lines[n].beg) == '[' and ctx.ch(lines[n].beg + 1) == '^')
        {
            n_consumed = md_is_footnote_definition(ctx, lines[n..n_lines]);
            if (n_consumed < 0)
                return -1;
        }

        if (n_consumed == 0) {
            n_consumed = md_is_link_reference_definition(ctx, lines[n..n_lines]);
            if (n_consumed < 0)
                return -1;
        }

        // Neither kind of definition?
        if (n_consumed == 0)
            break;

        n += @intCast(n_consumed);
    }

    if (n > 0) {
        if (n == n_lines) {
            // Remove complete block.
            ctx.n_block_bytes -= @as(usize, n) * @sizeOf(MD_LINE);
            ctx.n_block_bytes -= @sizeOf(MD_BLOCK);
            ctx.current_block = null;
        } else {
            // Remove just some initial lines from the block.
            const dst = @as([*]u8, @ptrCast(lines));
            const src = @as([*]const u8, @ptrCast(lines + n));
            const count = (n_lines - n) * @sizeOf(MD_LINE);
            std.mem.copyForwards(u8, dst[0..count], src[0..count]);
            ctx.current_block.*.n_lines -= n;
            ctx.n_block_bytes -= @as(usize, n) * @sizeOf(MD_LINE);
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

// Split the LAST line off the current paragraph block, so that line alone can
// become a table header row and everything before it stays a paragraph. This is
// what lets a table interrupt a paragraph (`md_process_line`'s .table_underline
// arm calls it; the classifier already checked the block is a `p` with lines).
//
// The paragraph is closed through `md_end_current_block`, so it still gets its
// leading link-reference / footnote definitions eaten — and may vanish entirely
// if that is all it held, which is why nothing here may assume it survived.
pub fn md_split_off_table_header(ctx: *MD_CTX) c_int {
    const lines: [*c]MD_LINE = @ptrCast(@alignCast(ctx.current_block + 1));
    const n_lines: MD_SIZE = ctx.current_block.*.n_lines;

    // Nothing above the header row: the block already IS the header.
    if (n_lines <= 1)
        return 0;

    // By value: the arena moves under md_push_block_bytes below.
    const header: MD_LINE = lines[n_lines - 1];

    // Close the paragraph without its last line.
    ctx.current_block.*.n_lines = n_lines - 1;
    ctx.n_block_bytes -= @sizeOf(MD_LINE);
    var ret = md_end_current_block(ctx);
    if (ret < 0) return ret;

    // Reopen a one-line block holding just the header row. The caller retypes
    // it to `table` immediately.
    const header_analysis: MD_LINE_ANALYSIS = .{ .type = .text, .beg = header.beg, .end = header.end };
    ret = md_start_new_block(ctx, &header_analysis);
    if (ret < 0) return ret;
    return md_add_line_into_current_block(ctx, &header_analysis);
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
    ctx.last_block_off = ctx.n_block_bytes - @sizeOf(MD_BLOCK);

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

pub fn md_is_hr_line(ctx: *MD_CTX, beg: OFF, p_end: *OFF, p_killer: *OFF) bool {
    var off: OFF = beg + 1;
    var n: c_int = 1;

    while (off < ctx.size and (ctx.ch(off) == ctx.ch(beg) or ctx.ch(off) == ' ' or ctx.ch(off) == '\t')) {
        if (ctx.ch(off) == ctx.ch(beg))
            n += 1;
        off += 1;
    }

    if (n < 3) {
        p_killer.* = off;
        return false;
    }

    // Nothing else can be present on the line.
    if (off < ctx.size and !ctx.isNewline(off)) {
        p_killer.* = off;
        return false;
    }

    p_end.* = off;
    return true;
}

pub fn md_is_atxheader_line(ctx: *MD_CTX, beg: OFF, p_beg: *OFF, p_end: *OFF, p_level: *c_uint) bool {
    var off: OFF = beg + 1;

    while (off < ctx.size and ctx.ch(off) == '#' and off - beg < 7)
        off += 1;
    const n: OFF = off - beg;

    if (n > 6)
        return false;
    p_level.* = n;

    if (off < ctx.size and !ctx.isBlank(off) and !ctx.isNewline(off))
        return false;

    while (off < ctx.size and ctx.isBlank(off))
        off += 1;
    p_beg.* = off;
    p_end.* = off;
    return true;
}

pub fn md_is_setext_underline(ctx: *MD_CTX, beg: OFF, p_end: *OFF, p_level: *c_uint) bool {
    var off: OFF = beg + 1;

    while (off < ctx.size and ctx.ch(off) == ctx.ch(beg))
        off += 1;

    // Optionally, space(s) or tabs can follow.
    while (off < ctx.size and ctx.isBlank(off))
        off += 1;

    // But nothing more is allowed on the line.
    if (off < ctx.size and !ctx.isNewline(off))
        return false;

    p_level.* = if (ctx.ch(beg) == '=') 1 else 2;
    p_end.* = off;
    return true;
}

pub fn md_is_table_underline(ctx: *MD_CTX, beg: OFF, p_end: *OFF, p_col_count: *c_uint) bool {
    var off: OFF = beg;
    var found_pipe: bool = false;
    var col_count: c_uint = 0;

    if (off < ctx.size and ctx.ch(off) == '|') {
        found_pipe = true;
        off += 1;
        while (off < ctx.size and ctx.isWhitespace(off))
            off += 1;
    }

    while (true) {
        var delimited: bool = false;

        // Cell underline ("-----", ":----", "----:" or ":----:")
        if (off < ctx.size and ctx.ch(off) == ':')
            off += 1;
        if (off >= ctx.size or ctx.ch(off) != '-')
            return false;
        while (off < ctx.size and ctx.ch(off) == '-')
            off += 1;
        if (off < ctx.size and ctx.ch(off) == ':')
            off += 1;

        col_count += 1;
        if (col_count > TABLE_MAXCOLCOUNT) {
            ctx.log("Suppressing table (column_count > TABLE_MAXCOLCOUNT)");
            return false;
        }

        // Pipe delimiter (optional at the end of line).
        while (off < ctx.size and ctx.isWhitespace(off))
            off += 1;
        if (off < ctx.size and ctx.ch(off) == '|') {
            delimited = true;
            found_pipe = true;
            off += 1;
            while (off < ctx.size and ctx.isWhitespace(off))
                off += 1;
        }

        // Success, if we reach end of line.
        if (off >= ctx.size or ctx.isNewline(off))
            break;

        if (!delimited)
            return false;
    }

    if (!found_pipe)
        return false;

    p_end.* = off;
    p_col_count.* = col_count;
    return true;
}

pub fn md_is_opening_code_fence(ctx: *MD_CTX, beg: OFF, p_end: *OFF) bool {
    var off: OFF = beg;

    while (off < ctx.size and ctx.ch(off) == ctx.ch(beg))
        off += 1;

    // Fence must have at least three characters.
    if (off - beg < 3)
        return false;

    ctx.code_fence_length = off - beg;

    // Optionally, space(s) can follow.
    while (off < ctx.size and ctx.ch(off) == ' ')
        off += 1;

    // Optionally, an info string can follow.
    while (off < ctx.size and !ctx.isNewline(off)) {
        // Backtick-based fence must not contain '`' in the info string.
        if (ctx.ch(beg) == '`' and ctx.ch(off) == '`')
            return false;
        off += 1;
    }

    p_end.* = off;
    return true;
}

pub fn md_is_closing_code_fence(ctx: *MD_CTX, ch: CHAR, beg: OFF, p_end: *OFF) bool {
    var off: OFF = beg;
    var ret: bool = false;

    // Closing fence must have at least the same length and use same char.
    while (off < ctx.size and ctx.ch(off) == ch)
        off += 1;
    if (off - beg < ctx.code_fence_length) {
        // goto out;
        p_end.* = off;
        return ret;
    }

    // Optionally, space(s) or tab(s) can follow.
    while (off < ctx.size and ctx.isBlank(off))
        off += 1;

    // But nothing more is allowed on the line.
    if (off < ctx.size and !ctx.isNewline(off)) {
        p_end.* = off;
        return ret;
    }

    ret = true;

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

// Returns type of the raw HTML block (1..7), or 0 if not an HTML block. NOT a
// boolean — the value is stored in ctx.html_block_type and compared against 6/7.
pub fn md_is_html_block_start_condition(ctx: *MD_CTX, beg: OFF) c_int {
    var off: OFF = beg + 1;

    // Check for type 1: <pre, <script, <style or <textarea. The tag name has to
    // be followed by a space, a tab, '>' or the end of the line, the same check
    // the type 6 branch below performs. (md4c matches on the bare prefix, so
    // `<textareaa` starts a raw HTML block there; md4x deliberately deviates.)
    for (t1) |tag| {
        if (off + tag.len <= ctx.size) {
            if (md_ascii_case_eq(ctx.str(off), tag.name, tag.len)) {
                const tmp: OFF = off + tag.len;
                if (tmp >= ctx.size)
                    return 1;
                if (ctx.isBlank(tmp) or ctx.isNewline(tmp) or ctx.ch(tmp) == '>')
                    return 1;
                break;
            }
        }
    }

    // Check for type 2: <!--
    if (off + 3 <= ctx.size and ctx.ch(off) == '!' and ctx.ch(off + 1) == '-' and ctx.ch(off + 2) == '-')
        return 2;

    // Check for type 3: <?
    if (off < ctx.size and ctx.ch(off) == '?')
        return 3;

    // Check for type 4 or 5: <!
    if (off < ctx.size and ctx.ch(off) == '!') {
        // Type 4: <! followed by an ASCII letter. (md4c tests ISASCII here,
        // which swallows `<!_`, `<![`, `<! ` and — because type 4 wins over
        // type 5 — makes type 5 unreachable. md4x deliberately deviates.)
        if (off + 1 < ctx.size and ctx.isAlpha(off + 1))
            return 4;

        // Type 5: <![CDATA[
        if (off + 8 <= ctx.size) {
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

    return 0;
}

// Case-sensitive check whether substring 'what' is between 'beg' and EOL.
pub fn md_line_contains(ctx: *MD_CTX, beg: OFF, what: [*c]const CHAR, what_len: SZ, p_end: *OFF) bool {
    var i: OFF = beg;
    while (i + what_len < ctx.size) : (i += 1) {
        if (ctx.isNewline(i))
            break;
        if (memcmp(ctx.str(i), what, what_len) == 0) {
            p_end.* = i + what_len;
            return true;
        }
    }

    p_end.* = i;
    return false;
}

// Returns the raw-HTML block type (1..7) the line closes, or 0. NOT a boolean:
// callers compare the result against ctx.html_block_type and against 6/7.
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
                                return 1;
                            }
                        }
                    }
                }
                off += 1;
            }
            p_end.* = off;
            return 0;
        },

        2 => return if (md_line_contains(ctx, beg, "-->", 3, p_end)) 2 else 0,
        3 => return if (md_line_contains(ctx, beg, "?>", 2, p_end)) 3 else 0,
        4 => return if (md_line_contains(ctx, beg, ">", 1, p_end)) 4 else 0,
        5 => return if (md_line_contains(ctx, beg, "]]>", 3, p_end)) 5 else 0,

        6, 7 => {
            if (beg >= ctx.size or ctx.isNewline(beg)) {
                // Blank line ends types 6 and 7.
                p_end.* = beg;
                return ctx.html_block_type;
            }
            return 0;
        },

        else => unreachable, // MD_UNREACHABLE
    }
}

// --- block component / slot recognizers --------------------------------------

// Balanced `{...}` run whose opening brace sits at `off`, bounded by the end of the
// line. Depth-counting rather than "stop at the first '}'", so a quoted prop value
// may itself hold braces (`obj='{"key": "value"}'`); this mirrors the inline
// component scanner in inlines.zig. On success reports the run's interior through
// `p_beg`/`p_end` and returns the offset just past the closing brace; returns null
// when the run stays unbalanced to the end of the line.
fn md_scan_brace_run(ctx: *MD_CTX, off: OFF, p_beg: *OFF, p_end: *OFF) ?OFF {
    var brace_depth: c_int = 1;
    var j: OFF = off + 1;
    while (j < ctx.size and !ctx.isNewline(j) and brace_depth > 0) {
        if (ctx.ch(j) == '{') brace_depth += 1 else if (ctx.ch(j) == '}') brace_depth -= 1;
        if (brace_depth > 0) j += 1;
    }
    if (brace_depth != 0)
        return null;
    p_beg.* = off + 1;
    p_end.* = j;
    return j + 1;
}

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
        if (md_scan_brace_run(ctx, off, p_props_beg, p_props_end)) |run_end|
            off = run_end;
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
            if (md_scan_brace_run(ctx, off, p_props_beg, p_props_end)) |run_end|
                off = run_end;
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

// The open block component that a `::` closer at `off` actually closes, or null.
// Recognizing a closer is not enough to act on one: an orphan `::` with no open
// component stays literal text, and a closer belongs to the innermost component
// whose opener was no wider than it, so `::` inside `:::outer` closes `:::outer`
// rather than dangling. Reports the closer's end through `p_end` on a match.
pub fn md_block_component_closer_target(ctx: *MD_CTX, off: OFF, p_end: *OFF) ?c_int {
    if (off >= ctx.size or ctx.ch(off) != ':')
        return null;

    const closer_colons = md_is_block_component_closer(ctx, off, p_end);
    if (closer_colons == 0)
        return null;

    var i: c_int = ctx.nContainers() - 1;
    while (i >= 0) : (i -= 1) {
        if (ctx.containers.items[@intCast(i)].ch == ':' and
            ctx.containers.items[@intCast(i)].colon_count <= closer_colons)
            return i;
    }
    return null;
}

// Is there a closing `---` fence somewhere after the opening one? `off_in` sits
// at the opener's newline (or at the end of input). The scan mirrors the closer
// test in md_analyze_line's frontmatter-continuation arm: at most a three-space
// indent, three or more dashes, then nothing but spaces to the end of the line.
fn md_frontmatter_has_closing_fence(ctx: *MD_CTX, off_in: OFF) bool {
    var off: OFF = off_in;
    while (off < ctx.size) {
        // Step over the line break we are parked on.
        if (ctx.ch(off) == '\r') off += 1;
        if (off < ctx.size and ctx.ch(off) == '\n') off += 1;

        // Leading whitespace. A tab counts as a full tab stop, which is all the
        // precision the `< CODE_INDENT_OFFSET` test below needs.
        var indent: c_uint = 0;
        while (off < ctx.size and ctx.isBlank(off)) : (off += 1)
            indent += if (ctx.ch(off) == '\t') 4 else 1;

        if (indent < CODE_INDENT_OFFSET and off < ctx.size and ctx.ch(off) == '-') {
            var tmp: OFF = off;
            while (tmp < ctx.size and ctx.ch(tmp) == '-')
                tmp += 1;
            if (tmp - off >= 3) {
                while (tmp < ctx.size and ctx.ch(tmp) == ' ')
                    tmp += 1;
                if (tmp >= ctx.size or ctx.isNewline(tmp))
                    return true;
            }
        }

        // On to this line's break.
        while (off < ctx.size and !ctx.isNewline(off))
            off += 1;
    }
    return false;
}

// Does this line, spanning `beg`..`end` (the line break excluded), read as a
// YAML mapping key? A key is either a quoted scalar or a plain one, followed by
// a colon and then a space or the line end. `key:value` with no space is *not*
// a mapping in YAML — it is the plain scalar `key:value` — and a leading `- `
// makes the line a sequence entry, so both are rejected.
fn md_yaml_line_is_mapping_key(ctx: *MD_CTX, beg: OFF, end: OFF) bool {
    var off: OFF = beg;
    while (off < end and ISBLANK_(ctx.ch(off)))
        off += 1;
    if (off >= end)
        return false;

    if (ctx.isAnyOf2(off, '"', '\'')) {
        const quote: CHAR = ctx.ch(off);
        off += 1;
        while (off < end) : (off += 1) {
            if (quote == '"' and ctx.ch(off) == '\\') {
                off += 1; // Escaped byte; only `"` matters, and it is skipped.
                continue;
            }
            if (ctx.ch(off) == quote) {
                // `''` inside a single-quoted scalar is an escaped quote.
                if (quote == '\'' and off + 1 < end and ctx.ch(off + 1) == '\'') {
                    off += 1;
                    continue;
                }
                break;
            }
        }
        if (off >= end)
            return false; // Unterminated quote: not a key.
        off += 1;
        while (off < end and ISBLANK_(ctx.ch(off)))
            off += 1;
    } else {
        // A sequence entry (`- x`, or a bare `-`) is not a mapping.
        if (ctx.ch(off) == '-' and (off + 1 >= end or ISBLANK_(ctx.ch(off + 1))))
            return false;
        const key_beg: OFF = off;
        while (off < end and ctx.ch(off) != ':') {
            // ` #` starts a YAML comment, so no colon can follow on this line.
            if (ctx.ch(off) == '#' and off > key_beg and ISBLANK_(ctx.ch(off - 1)))
                return false;
            off += 1;
        }
        if (off == key_beg)
            return false; // Empty key.
    }

    return off < end and ctx.ch(off) == ':' and (off + 1 >= end or ISBLANK_(ctx.ch(off + 1)));
}

// Does the body opened by this `---` read as YAML rather than as markdown?
// Frontmatter and block component props both carry a YAML *mapping* — a
// document's metadata, a component's props object — so a body whose very first
// line of substance is anything else (a bare scalar, a sequence entry, a
// paragraph) was never metadata, and consuming it would silently delete
// document content. Such a block is not frontmatter at all: the `---` stays an
// ordinary thematic break and the lines below it stay markdown, which is also
// what CommonMark expects of `---\nFoo\n---\nBar\n---\nBaz`.
//
// A whitespace-only or comment-only body is *not* rejected: it carries nothing
// to lose, and Comark resolves both to an empty object rather than to markdown.
//
// A body with no bytes in it at all is where the two positions part company,
// and both follow Comark. In a document, `---\n---` and `---\n\n---` are two
// thematic breaks (CommonMark example 98 agrees), while `---\n \n---` and
// `---\n\n\n---` are frontmatter — one byte between the fences is the whole
// difference. In a component, an empty props block is consumed either way.
// `allow_empty_body` selects the position.
//
// Deciding this needs the lines below the opener, so the classifier looks ahead
// once, here, before committing. `off_in` sits at the opener's newline (or at
// the end of input). Blank lines and whole-line `#` comments are skipped; the
// first line carrying anything else settles it.
fn md_frontmatter_body_is_yaml(ctx: *MD_CTX, off_in: OFF, allow_empty_body: bool) bool {
    var off: OFF = off_in;
    var n_lines: c_uint = 0;
    var first_line_len: OFF = 0;

    while (off < ctx.size) {
        // Step over the line break we are parked on.
        if (ctx.ch(off) == '\r') off += 1;
        if (off < ctx.size and ctx.ch(off) == '\n') off += 1;

        const beg: OFF = off;
        var end: OFF = off;
        while (end < ctx.size and !ctx.isNewline(end))
            end += 1;
        off = end;

        var content: OFF = beg;
        var indent: c_uint = 0;
        while (content < end and ISBLANK_(ctx.ch(content))) : (content += 1)
            indent += if (ctx.ch(content) == '\t') 4 else 1;

        // The closing fence, reached before any line of substance.
        if (indent < CODE_INDENT_OFFSET and content < end and ctx.ch(content) == '-') {
            var tmp: OFF = content;
            while (tmp < end and ctx.ch(tmp) == '-')
                tmp += 1;
            if (tmp - content >= 3) {
                while (tmp < end and ctx.ch(tmp) == ' ')
                    tmp += 1;
                // Byte-empty is one line of nothing or no line at all; from two
                // lines on, the newline separating them is itself a byte.
                if (tmp >= end)
                    return allow_empty_body or n_lines >= 2 or first_line_len > 0;
            }
        }

        n_lines += 1;
        if (n_lines == 1)
            first_line_len = end - beg;

        if (content >= end)
            continue; // Blank line.
        if (ctx.ch(content) == '#')
            continue; // YAML comment.

        return md_yaml_line_is_mapping_key(ctx, content, end);
    }
    return true; // Nothing but blanks and comments to the end of input.
}

// ```yaml [props] — the codeblock spelling of block component props, co-equal
// with the `---` frontmatter spelling. Only ever offered in the position the
// `---` opener is offered in (the component's first non-blank content line), and
// reported as a `.frontmatter` line so the body travels the very same YAML path.
// The ordinary fence recognizer runs first so the fence-length bookkeeping and
// the no-backtick-in-info rule stay shared with fenced code; the info string then
// has to be exactly `yaml [props]`, blanks aside.
pub fn md_is_component_props_fence(ctx: *MD_CTX, beg: OFF, p_end: *OFF) bool {
    if (beg >= ctx.size or !ctx.isAnyOf2(beg, '`', '~'))
        return false;

    var end: OFF = beg;
    if (!md_is_opening_code_fence(ctx, beg, &end))
        return false;

    // The info string, with the fence run and the blanks around it trimmed off.
    var info_beg: OFF = beg + ctx.code_fence_length;
    while (info_beg < end and ISBLANK_(ctx.ch(info_beg)))
        info_beg += 1;
    var info_end: OFF = end;
    while (info_end > info_beg and ISBLANK_(ctx.ch(info_end - 1)))
        info_end -= 1;

    // `yaml` (case-insensitive, as elsewhere for info-string languages) ...
    if (info_end - info_beg < 4 or !md_ascii_case_eq(ctx.str(info_beg), "yaml", 4))
        return false;
    var off: OFF = info_beg + 4;
    while (off < info_end and ISBLANK_(ctx.ch(off)))
        off += 1;

    // ... then the `[props]` filename, and nothing else.
    if (info_end - off != 7 or !md_ascii_eq(ctx.str(off), "[props]", 7))
        return false;

    p_end.* = end;
    return true;
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

pub fn md_is_container_compatible(pivot_p: [*c]const MD_CONTAINER, container_p: [*c]const MD_CONTAINER) bool {
    const pivot = &pivot_p[0];
    const container = &container_p[0];
    // Block quote has no "items" like lists.
    if (container.ch == '>')
        return false;

    // Block components have no "items".
    if (container.ch == ':')
        return false;

    if (container.ch != pivot.ch)
        return false;
    if (container.mark_indent > pivot.contents_indent)
        return false;

    return true;
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
        var is_ordered_list: bool = false;

        switch (cont.ch) {
            ')', '.' => {
                is_ordered_list = true;
                // MD_FALLTHROUGH to bullet handling.
                _ = md_end_current_block(ctx);
                cont.block_byte_off = @intCast(ctx.n_block_bytes);

                ret = md_push_container_bytes(ctx, if (is_ordered_list) c.BlockType.ol else c.BlockType.ul, cont.start, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, c.BlockType.li, cont.task_mark_off, if (cont.is_task) @intCast(uval(ctx.ch(cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            '-', '+', '*' => {
                // Remember offset in block_bytes so we can revisit if loose.
                _ = md_end_current_block(ctx);
                cont.block_byte_off = @intCast(ctx.n_block_bytes);

                ret = md_push_container_bytes(ctx, if (is_ordered_list) c.BlockType.ol else c.BlockType.ul, cont.start, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, c.BlockType.li, cont.task_mark_off, if (cont.is_task) @intCast(uval(ctx.ch(cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            '>' => {
                if (cont.is_alert)
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
        var is_ordered_list: bool = false;

        switch (cont.ch) {
            ')', '.' => {
                is_ordered_list = true;
                ret = md_push_container_bytes(ctx, c.BlockType.li, cont.task_mark_off, if (cont.is_task) @intCast(uval(ctx.ch(cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, if (is_ordered_list) c.BlockType.ol else c.BlockType.ul, 0, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
            },
            '-', '+', '*' => {
                ret = md_push_container_bytes(ctx, c.BlockType.li, cont.task_mark_off, if (cont.is_task) @intCast(uval(ctx.ch(cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, if (is_ordered_list) c.BlockType.ol else c.BlockType.ul, 0, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
            },
            '>' => {
                if (cont.is_alert)
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

pub fn md_is_container_mark(ctx: *MD_CTX, indent: c_uint, beg: OFF, p_end: *OFF, p_container: *MD_CONTAINER) bool {
    var off: OFF = beg;

    if (off >= ctx.size or indent >= CODE_INDENT_OFFSET)
        return false;

    // Check for block quote mark.
    if (ctx.ch(off) == '>') {
        off += 1;
        p_container.ch = '>';
        p_container.is_loose = 0;
        p_container.is_task = false;
        p_container.mark_indent = indent;
        p_container.contents_indent = indent + 1;
        p_end.* = off;
        return true;
    }

    // Check for list item bullet mark.
    if (ctx.isAnyOf(off, "-+*") and (off + 1 >= ctx.size or ctx.isBlank(off + 1) or ctx.isNewline(off + 1))) {
        p_container.ch = ctx.ch(off);
        p_container.is_loose = 0;
        p_container.is_task = false;
        p_container.mark_indent = indent;
        p_container.contents_indent = indent + 1;
        p_end.* = off + 1;
        return true;
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
        p_container.is_loose = 0;
        p_container.is_task = false;
        p_container.mark_indent = indent;
        p_container.contents_indent = indent + off - beg + 1;
        p_end.* = off + 1;
        return true;
    }

    return false;
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

pub const md_dummy_blank_line = MD_LINE_ANALYSIS{ .type = .blank, .data = 0, .enforce_new_block = false, .beg = 0, .end = 0, .indent = 0 };

// True when the most recent push into `block_bytes` was an LI opener, i.e. the
// innermost list item has no content yet. md4c peeks at the arena's last
// `sizeof(MD_BLOCK)` bytes and tests `type == MD_BLOCK_LI` — but after a block
// that closes itself (an ATX heading, a thematic break) those bytes are the
// block's last `MD_LINE`, whose `beg` reads as the type byte: any line whose
// content starts at `256k + 4` (`BlockType.li == 4`) passes as an empty item and
// the next line gets ejected from the enclosing container. That is the source
// of mity/md4c#413 (`-\n  ---\n\n  b`) and of unjs/md4x#28 (a heading inside a
// `::component` at byte 256). The header offset check makes the peek exact.
fn md_top_block_is_empty_li(ctx: *const MD_CTX) bool {
    if (ctx.last_block_off + @sizeOf(MD_BLOCK) != ctx.n_block_bytes)
        return false;
    const top_block: *const MD_BLOCK = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(ctx.block_bytes)) + ctx.last_block_off));
    return top_block.getType() == c.BlockType.li and
        (top_block.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER_OPENER))) != 0;
}

// Analyze type of the line and find some of its properties. Main input for
// determining type and boundaries of a block (md4x.c ~7096).
pub fn md_analyze_line(ctx: *MD_CTX, beg: OFF, p_end: *OFF, pivot_line_in: *const MD_LINE_ANALYSIS, line: *MD_LINE_ANALYSIS) c_int {
    var pivot_line = pivot_line_in;
    var total_indent: c_uint = 0;
    var n_parents: c_int = 0;
    var n_brothers: c_int = 0;
    var n_children: c_int = 0;
    var inside_component: c_int = 0;
    // Scratch for md_block_component_closer_target; only read after a match.
    var closer_end: OFF = undefined;
    var container = MD_CONTAINER{};
    const prev_line_has_list_loosening_effect = ctx.last_line_has_list_loosening_effect;
    var off: OFF = beg;
    var hr_killer: OFF = 0;
    var ret: c_int = 0;

    line.indent = md_line_indentation(ctx, total_indent, off, &off);
    total_indent += line.indent;
    line.beg = off;
    line.enforce_new_block = false;

    // Given the indentation and block quote marks '>', determine how many of
    // the current containers are our parents.
    while (n_parents < ctx.nContainers()) {
        const cont = &ctx.containers.items[@intCast(n_parents)];

        if (cont.ch == '>' and line.indent < CODE_INDENT_OFFSET and
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

            // Codeblock-style component props close on an ordinary code fence.
            // pivot_line is the opener line (the pivot only moves when a new
            // block starts), so its first byte is the fence character.
            if (pivot_line.data == 3) {
                if (line.indent < CODE_INDENT_OFFSET and
                    md_is_closing_code_fence(ctx, ctx.ch(pivot_line.beg), off, &off))
                {
                    line.type = .blank;
                    var i: c_int = ctx.nContainers() - 1;
                    while (i >= 0) : (i -= 1) {
                        if (ctx.containers.items[@intCast(i)].ch == ':') {
                            ctx.containers.items[@intCast(i)].comp_fm_state = 2;
                            break;
                        }
                    }
                    break :classify;
                }
                line.type = .frontmatter;
                line.data = pivot_line.data;
                n_parents = ctx.nContainers();
                break :classify;
            }

            // Check for closing --- fence.
            if (line.indent < CODE_INDENT_OFFSET and
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
            if (line.indent < CODE_INDENT_OFFSET) {
                if (md_is_closing_code_fence(ctx, ctx.ch(pivot_line.beg), off, &off)) {
                    line.type = .blank;
                    ctx.last_line_has_list_loosening_effect = false;
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
            } else if (ctx.block_component_nesting > 0 and
                (line.indent < CODE_INDENT_OFFSET or inside_component != 0) and
                md_block_component_closer_target(ctx, off, &closer_end) != null)
            {
                // Same implicit end, for the container whose end is a `::` line
                // rather than a missing line prefix. Containers are matched
                // before leaf-block content, so the closer belongs to the
                // component, not to the HTML block -- and nothing below would
                // hand it back: types 6 and 7 end only at a blank line, types
                // 1-5 only at their own end condition, so the `::` would be
                // eaten as HTML text and the component would never close.
                // Tested before md_is_html_block_end_condition, which clobbers
                // `off` on its no-match path (md_line_contains, type 1).
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
        if (ctx.block_component_nesting > 0 and
            (line.indent < CODE_INDENT_OFFSET or inside_component != 0) and off < ctx.size and ctx.ch(off) == ':')
        {
            // Only `break :classify` on a match. An orphan `::` must fall through
            // to the checks below with `line.type` untouched -- reading it back
            // here to decide would read a stale/uninitialized value on the
            // no-match path, nondeterministically dropping the line.
            if (md_block_component_closer_target(ctx, off, &closer_end)) |i| {
                // Close this component and everything inside it.
                if (n_children == 0) {
                    ret = md_leave_child_containers(ctx, i);
                    if (ret < 0) return ret;
                }

                line.type = .blank;
                ctx.last_line_has_list_loosening_effect = false;
                off = closer_end;
                break :classify;
            }
        }

        // Check for slot opener (#slot-name) inside a block component.
        if (ctx.block_component_nesting > 0 and
            (line.indent < CODE_INDENT_OFFSET or inside_component != 0) and
            pivot_line.type != .text and
            off < ctx.size and ctx.ch(off) == '#')
        {
            var name_beg: OFF = undefined;
            var name_end: OFF = undefined;
            var slot_end: OFF = undefined;
            // Same 16-bit index cap as the block-component opener below; past
            // it `#slot-name` is left to render as literal text.
            if (md_is_slot_opener(ctx, off, &name_beg, &name_end, &slot_end) != 0 and
                ctx.slot_info.items.len < MAX_BLOCK_INFO_RECORDS)
            {
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
                container.is_loose = 0;
                container.is_task = false;
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
                if (line.indent > CODE_INDENT_OFFSET)
                    line.indent -= CODE_INDENT_OFFSET
                else
                    line.indent = 0;
                ctx.last_line_has_list_loosening_effect = false;
            } else {
                line.type = .blank;
                ctx.consecutive_blank_lines +|= 1;
                ctx.last_line_has_list_loosening_effect = (n_parents > 0 and
                    n_brothers + n_children == 0 and
                    ctx.containers.items[@intCast(n_parents - 1)].ch != '>');
            }
            break :classify;
        } else {
            // CommonMark requires a list item cannot begin with two (or more)
            // blank lines so we may need to forcefully end the list.
            // (See https://github.com/mity/md4c/issues/6)
            if (ctx.consecutive_blank_lines >= 2) {
                if (n_parents > 0 and n_parents == ctx.nContainers() and
                    ctx.containers.items[@intCast(n_parents - 1)].ch != '>' and
                    n_brothers + n_children == 0 and ctx.current_block == null and
                    md_top_block_is_empty_li(ctx))
                {
                    n_parents -= 1;

                    line.indent = total_indent;
                    if (n_parents > 0)
                        line.indent -= MIN_u(line.indent, ctx.containers.items[@intCast(n_parents - 1)].contents_indent);
                }
            }
            ctx.consecutive_blank_lines = 0;

            ctx.last_line_has_list_loosening_effect = false;
        }

        // Check for alert syntax > [!TYPE] inside a newly opened blockquote.
        if (n_children > 0 and
            line.indent < CODE_INDENT_OFFSET and
            off < ctx.size and ctx.ch(off) == '[')
        {
            const last_cont: c_int = ctx.nContainers() - 1;
            if (last_cont >= 0 and ctx.containers.items[@intCast(last_cont)].ch == '>' and
                !ctx.containers.items[@intCast(last_cont)].is_alert)
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
                        // Same 16-bit index cap as the block-component opener
                        // below; past it the blockquote stays a plain
                        // blockquote and `[!TYPE]` renders as literal text.
                        if ((tmp >= ctx.size or ctx.isNewline(tmp)) and
                            ctx.block_alert_info.items.len < MAX_BLOCK_INFO_RECORDS)
                        {
                            const alert_idx = md_push_block_alert_info(ctx, type_beg, type_end) catch {
                                ret = -1;
                                return ret;
                            };
                            ctx.containers.items[@intCast(last_cont)].is_alert = true;
                            ctx.containers.items[@intCast(last_cont)].start = @intCast(alert_idx);
                            line.type = .blank;
                            break :classify;
                        }
                    }
                }
            }
        }

        // Check whether we are Setext underline.
        if (line.indent < CODE_INDENT_OFFSET and pivot_line.type == .text and
            off < ctx.size and ctx.isAnyOf2(off, '=', '-') and
            (n_parents == ctx.nContainers()))
        {
            var level: c_uint = undefined;

            if (md_is_setext_underline(ctx, off, &off, &level)) {
                line.type = .setext_underline;
                line.data = level;
                break :classify;
            }
        }

        // Check for frontmatter opening at the very start of the document.
        if (ctx.frontmatter_state == 0 and
            line.indent < CODE_INDENT_OFFSET and n_parents == 0 and
            off < ctx.size and ctx.ch(off) == '-')
        {
            var tmp: OFF = off;
            while (tmp < ctx.size and ctx.ch(tmp) == '-')
                tmp += 1;
            if (tmp - off >= 3) {
                while (tmp < ctx.size and ctx.ch(tmp) == ' ')
                    tmp += 1;
                if (tmp >= ctx.size or ctx.isNewline(tmp)) {
                    // Frontmatter is *enclosed* by `---` and carries YAML, so
                    // an opening fence with no closing one, or one whose body
                    // reads as markdown rather than as a mapping, is not
                    // frontmatter at all — the block stays ordinary markdown,
                    // i.e. a thematic break plus the text after it, exactly as
                    // `***` and `___` already behave. Deciding that needs the
                    // rest of the document, so the classifier looks ahead once,
                    // here, before committing.
                    if (beg == 0 and md_frontmatter_has_closing_fence(ctx, tmp) and
                        md_frontmatter_body_is_yaml(ctx, tmp, false))
                    {
                        line.type = .frontmatter;
                        line.enforce_new_block = true;
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
        if (ctx.block_component_nesting > 0) {
            // Find the innermost component container.
            var comp_i: c_int = ctx.nContainers() - 1;
            while (comp_i >= 0) : (comp_i -= 1) {
                if (ctx.containers.items[@intCast(comp_i)].ch == ':')
                    break;
            }
            if (comp_i >= 0 and ctx.containers.items[@intCast(comp_i)].comp_fm_state == 0) {
                var found_opener: bool = false;
                if (line.indent < CODE_INDENT_OFFSET and
                    off < ctx.size and ctx.ch(off) == '-')
                {
                    var tmp: OFF = off;
                    while (tmp < ctx.size and ctx.ch(tmp) == '-')
                        tmp += 1;
                    if (tmp - off >= 3) {
                        while (tmp < ctx.size and ctx.ch(tmp) == ' ')
                            tmp += 1;
                        // Block props are YAML too (they become the component's
                        // props object), so the same body test that gates the
                        // document fence gates this one: without it a `---`
                        // meant as a thematic break swallows the lines below
                        // it, up to and including the `::` closer.
                        if ((tmp >= ctx.size or ctx.isNewline(tmp)) and
                            md_frontmatter_body_is_yaml(ctx, tmp, true))
                        {
                            ctx.containers.items[@intCast(comp_i)].comp_fm_state = 1;
                            line.type = .frontmatter;
                            line.data = 2; // 2 = component frontmatter
                            line.enforce_new_block = true;
                            found_opener = true;
                        }
                    }
                }
                // The codeblock spelling, ```yaml [props] ... ```, accepted in
                // exactly the same position and closed by an ordinary code fence.
                if (!found_opener and line.indent < CODE_INDENT_OFFSET and
                    off < ctx.size and ctx.isAnyOf2(off, '`', '~'))
                {
                    var tmp: OFF = off;
                    if (md_is_component_props_fence(ctx, off, &tmp)) {
                        ctx.containers.items[@intCast(comp_i)].comp_fm_state = 1;
                        line.type = .frontmatter;
                        line.data = 3; // 3 = component frontmatter, codeblock style
                        line.enforce_new_block = true;
                        off = tmp;
                        found_opener = true;
                    }
                }
                if (found_opener)
                    break :classify;
                // First non-blank line is neither spelling; disable component frontmatter.
                ctx.containers.items[@intCast(comp_i)].comp_fm_state = 2;
            }
        }

        // Check for thematic break line.
        if (line.indent < CODE_INDENT_OFFSET and
            off < ctx.size and off >= hr_killer and
            ctx.isAnyOf(off, "-_*"))
        {
            if (md_is_hr_line(ctx, off, &off, &hr_killer)) {
                line.type = .hr;
                break :classify;
            }
        }

        // Check for "brother" container (another list item in started list).
        if (n_parents < ctx.nContainers() and n_brothers + n_children == 0) {
            var tmp: OFF = undefined;

            if (md_is_container_mark(ctx, line.indent, off, &tmp, &container) and
                md_is_container_compatible(&ctx.containers.items[@intCast(n_parents)], &container))
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
                } else if (line.indent <= CODE_INDENT_OFFSET) {
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
        if (line.indent >= CODE_INDENT_OFFSET and inside_component == 0 and (pivot_line.type != .text)) {
            line.type = .indented_code;
            line.indent -= CODE_INDENT_OFFSET;
            line.data = 0;
            break :classify;
        }

        // Check for block component opener (::name or ::name{props}).
        if ((line.indent < CODE_INDENT_OFFSET or inside_component != 0) and
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
            // The info-record index has to survive a trip through the 16-bit
            // MD_BLOCK.bits.data, so stop recognizing openers at the cap rather
            // than wrapping onto an earlier record's name/props. See
            // types.MAX_BLOCK_INFO_RECORDS.
            if (colon_count > 0 and ctx.block_component_info.items.len < MAX_BLOCK_INFO_RECORDS) {
                const comp_idx = md_push_block_component_info(ctx, colon_count, name_beg, name_end, props_beg, props_end, title_beg, title_end) catch {
                    ret = -1;
                    return ret;
                };

                container.ch = ':';
                container.is_loose = 0;
                container.is_task = false;
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
        if (line.indent < CODE_INDENT_OFFSET and
            md_is_container_mark(ctx, line.indent, off, &off, &container))
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
                } else if (line.indent <= CODE_INDENT_OFFSET) {
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
        if (line.indent < CODE_INDENT_OFFSET and
            off < ctx.size and ctx.ch(off) == '#')
        {
            var level: c_uint = undefined;

            if (md_is_atxheader_line(ctx, off, &line.beg, &off, &level)) {
                line.type = .atx_header;
                line.data = level;
                break :classify;
            }
        }

        // Check whether we are starting code fence.
        if (line.indent < CODE_INDENT_OFFSET and
            off < ctx.size and ctx.isAnyOf2(off, '`', '~'))
        {
            if (md_is_opening_code_fence(ctx, off, &off)) {
                line.type = .fenced_code;
                line.data = 1;
                line.enforce_new_block = true;
                break :classify;
            }
        }

        // Check for start of raw HTML block. As with the ATX header and the code
        // fence above, an indented '<' is not a block start — it is indented code
        // (handled above) or a lazy paragraph continuation. (md4c lacks the indent
        // guard, so `    <div>` interrupts a paragraph there; md4x deliberately
        // deviates.) Inside a block component indented code is disabled, so the
        // guard lifts there, matching the component-aware checks above.
        if ((line.indent < CODE_INDENT_OFFSET or inside_component != 0) and
            off < ctx.size and ctx.ch(off) == '<')
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

                line.enforce_new_block = true;
                line.type = .html;
                break :classify;
            }
        }

        // Check for table underline.
        if (pivot_line.type == .text and
            off < ctx.size and ctx.isAnyOf3(off, '|', '-', ':') and
            n_parents == ctx.nContainers())
        {
            var col_count: c_uint = undefined;

            // The header row is the block's LAST line, not necessarily its
            // only one: md4c required `n_lines == 1`, so a table following a
            // paragraph line with no blank line between them stayed paragraph
            // text in full. GitHub lets the table interrupt, and the failure
            // mode of not doing so is the whole table rendering as literal
            // pipes. `md_split_off_table_header` splits the paragraph.
            if (ctx.current_block != null and ctx.current_block.*.n_lines >= 1 and
                ctx.current_block.*.getType() == c.BlockType.p and
                md_is_table_underline(ctx, off, &off, &col_count))
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
        if (n_brothers + n_children > 0 and
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
                task_container.is_task = true;
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
    //
    // Note this is quite a bottleneck of the parsing as we here iterate almost
    // over the complete document.
    //
    // This used to be a libc `strcspn(STR(off), "\r\n")` gated to glibc targets
    // (upstream md4c's `#if defined __linux__`), with an unrolled-by-4 scalar
    // loop everywhere else. Both are gone: `scan.indexOfAnyPos` is bounds-driven
    // rather than NUL-driven, so it needs neither the `doc_ends_with_newline`
    // precondition nor the mid-buffer-NUL rescan `strcspn` forced, it cannot
    // over-read a buffer that has no terminator, and it is fast on every target
    // instead of only on glibc. It also beats glibc's vectorized `strcspn` on
    // realistic input, because the win here is dropping the per-line call, not
    // the scan itself: 10 MB of 39-char lines went 22.9 -> 21.8 ms. Very long
    // lines are the one case that regresses (~1% at 4 KB/line), where the call
    // amortizes and glibc's wider AVX2 body pulls ahead.
    off = @intCast(scan.indexOfAnyPos("\r\n", null, @ptrCast(ctx.text), off, ctx.size));

    // Set end of the line.
    line.end = off;

    // But for ATX header, exclude the optional trailing mark.
    if (line.type == .atx_header) {
        var tmp: OFF = line.end;
        while (tmp > line.beg and ctx.isBlank(tmp - 1))
            tmp -= 1;
        while (tmp > line.beg and ctx.ch(tmp - 1) == '#')
            tmp -= 1;
        if (tmp == line.beg or ctx.isBlank(tmp - 1))
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
    if (prev_line_has_list_loosening_effect and line.type != .blank and n_parents + n_brothers > 0) {
        const cont = &ctx.containers.items[@intCast(n_parents + n_brothers - 1)];
        // Must be a LIST container: only the list arms of
        // md_enter_child_containers() ever assign cont.block_byte_off. The
        // md4x-only container kinds ':' (block component) and '#' (template
        // slot) leave it at its 0 default, so the upstream "not a blockquote
        // means a list" test would aim this write at block_bytes[0] — some
        // unrelated earlier block, flipping it loose.
        if (ISANYOF_(cont.ch, "-+*.)")) {
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
        ret = md_push_container_bytes(ctx, c.BlockType.li, ctx.containers.items[@intCast(n_parents)].task_mark_off, if (ctx.containers.items[@intCast(n_parents)].is_task) @intCast(uval(ctx.ch(ctx.containers.items[@intCast(n_parents)].task_mark_off))) else 0, MD_BLOCK_CONTAINER_CLOSER);
        if (ret < 0) return ret;
        ret = md_push_container_bytes(ctx, c.BlockType.li, container.task_mark_off, if (container.is_task) @intCast(uval(ctx.ch(container.task_mark_off))) else 0, MD_BLOCK_CONTAINER_OPENER);
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
