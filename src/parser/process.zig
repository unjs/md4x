// MD4X parser — block-content processing module (Subsystem E).
//
// Leaf/table/code/verbatim block-content processing, highlight parsing, fenced
// code detail setup, md_process_leaf_block / md_process_all_blocks, and the
// md_process_line / md_process_doc drivers. Extracted verbatim from the
// monolithic src/md4x.zig (pure refactor — no logic change). See AGENTS.md.

const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const refdefs = @import("refdefs.zig");
const inlines = @import("inlines.zig");
const blocks = @import("blocks.zig");

const c = types.c;
const CHAR = types.CHAR;
const SZ = types.SZ;
const OFF = types.OFF;
const MD_SIZE = types.MD_SIZE;
const MD_CTX = types.MD_CTX;
const c_allocator = types.c_allocator;
const MD_LINE = types.MD_LINE;
const MD_LINE_ANALYSIS = types.MD_LINE_ANALYSIS;
const MD_VERBATIMLINE = types.MD_VERBATIMLINE;
const MD_BLOCK = types.MD_BLOCK;
const MD_BLOCK_CONTAINER = types.MD_BLOCK_CONTAINER;
const MD_BLOCK_CONTAINER_OPENER = types.MD_BLOCK_CONTAINER_OPENER;
const MD_BLOCK_CONTAINER_CLOSER = types.MD_BLOCK_CONTAINER_CLOSER;
const MD_BLOCK_LOOSE_LIST = types.MD_BLOCK_LOOSE_LIST;
const MD_BLOCK_SETEXT_HEADER = types.MD_BLOCK_SETEXT_HEADER;
const MD_BLOCK_HAS_ATTRS = types.MD_BLOCK_HAS_ATTRS;
const MD_BLOCK_ATTRS_HOISTED = types.MD_BLOCK_ATTRS_HOISTED;
const MD_BLOCK_UNWRAP_P = types.MD_BLOCK_UNWRAP_P;
const MD_BLOCK_FOLDED_WRAPPER = types.MD_BLOCK_FOLDED_WRAPPER;
const ISBLANK_ = util.ISBLANK_;

const MD_ATTRIBUTE_BUILD = util.MD_ATTRIBUTE_BUILD;
const md_build_attribute = util.md_build_attribute;
const md_free_attribute = util.md_free_attribute;
const md_text_with_null_replacement = util.md_text_with_null_replacement;
const memmove = util.memmove;

const md_build_ref_def_hashtable = refdefs.md_build_ref_def_hashtable;
const md_build_footnote_def_hashtable = refdefs.md_build_footnote_def_hashtable;

const mdText = inlines.mdText;
const md_analyze_inlines = inlines.md_analyze_inlines;
const md_mark_free_ptr = inlines.md_mark_free_ptr;
const md_process_inlines = inlines.md_process_inlines;

const md_add_line_into_current_block = blocks.md_add_line_into_current_block;
const md_analyze_line = blocks.md_analyze_line;
const md_dummy_blank_line = blocks.md_dummy_blank_line;
const md_end_current_block = blocks.md_end_current_block;
const md_leave_child_containers = blocks.md_leave_child_containers;
const md_start_new_block = blocks.md_start_new_block;

// ============================================================================
//  Subsystem E — block processing + md_process_line/doc + md_parse glue.
// ============================================================================

// Block-level enter/leave helpers mirroring MD_ENTER_BLOCK / MD_LEAVE_BLOCK.
pub inline fn mdEnterBlock(ctx: *MD_CTX, detail: *const c.BlockDetail) c_int {
    const ret = ctx.parser.enter_block(detail, ctx.userdata);
    if (ret != 0) ctx.log("Aborted from enter_block() callback.");
    return ret;
}

pub inline fn mdLeaveBlock(ctx: *MD_CTX, detail: *const c.BlockDetail) c_int {
    const ret = ctx.parser.leave_block(detail, ctx.userdata);
    if (ret != 0) ctx.log("Aborted from leave_block() callback.");
    return ret;
}

// MD_TEXT_INSECURE — NUL-replacement text emission (md4x.c ~543).
pub inline fn mdTextInsecure(ctx: *MD_CTX, ty: c.TextType, str: [*c]const CHAR, size: SZ) c_int {
    if (size > 0) {
        const ret = md_text_with_null_replacement(ctx, ty, str, size);
        if (ret != 0) {
            ctx.log("Aborted from text() callback.");
            return ret;
        }
    }
    return 0;
}

// md4x.c ~5205.
pub fn md_analyze_table_alignment(ctx: *MD_CTX, beg: OFF, end: OFF, align_arr: [*c]c.Align, n_align_in: c_int) void {
    const align_map = [_]c.Align{ c.Align.default, c.Align.left, c.Align.right, c.Align.center };
    var off: OFF = beg;
    var n_align = n_align_in;
    var ai: usize = 0;

    while (n_align > 0) {
        var index: usize = 0; // index into align_map[]

        // Bounded by the row end, like the three sibling loops (upstream ecbb091).
        // `n_align` is the dash-group count `md_is_table_underline` measured on
        // this very row, so today it cannot outrun the groups present — but
        // `ctx.ch()` indexes a `[*c]` pointer, which Zig does not bounds-check in
        // ANY build mode, so an unbounded scan here would walk past the input
        // buffer entirely rather than panic. Running out of row now yields the
        // default alignment instead of an over-read.
        while (off < end and ctx.ch(off) != '-') off += 1;
        if (off > beg and ctx.ch(off - 1) == ':') index |= 1;
        while (off < end and ctx.ch(off) == '-') off += 1;
        if (off < end and ctx.ch(off) == ':') index |= 2;

        align_arr[ai] = align_map[index];
        ai += 1;
        n_align -= 1;
    }
}

// md4x.c ~5232.
pub fn md_process_table_cell(ctx: *MD_CTX, cell_type: c.BlockType, align_val: c.Align, beg_in: OFF, end_in: OFF) c_int {
    var line: MD_LINE = undefined;
    var ret: c_int = 0;
    var beg = beg_in;
    var end = end_in;

    while (beg < end and ctx.isWhitespace(beg)) beg += 1;
    while (end > beg and ctx.isWhitespace(end - 1)) end -= 1;

    // `cell_type` is `.th` or `.td`; both arms carry a BlockTdDetail.
    const det: c.BlockDetail = switch (cell_type) {
        .th => .{ .th = .{ .@"align" = align_val } },
        else => .{ .td = .{ .@"align" = align_val } },
    };
    line.beg = beg;
    line.end = end;

    ret = mdEnterBlock(ctx, &det);
    if (ret != 0) return ret;
    // Tells the inline emitter that `\|` is the cell-splitting escape and has to
    // be unescaped even in verbatim runs (md_emit_verbatim_text).
    const outer_in_table_cell = ctx.in_table_cell;
    ctx.in_table_cell = true;
    ret = md_process_normal_block_contents(ctx, @as([*]const MD_LINE, @ptrCast(&line))[0..1]);
    ctx.in_table_cell = outer_in_table_cell;
    if (ret < 0) return ret;
    ret = mdLeaveBlock(ctx, &det);
    if (ret != 0) return ret;
    return ret;
}

// md4x.c ~5256.
pub fn md_process_table_row(ctx: *MD_CTX, cell_type: c.BlockType, beg: OFF, end: OFF, align_arr: [*c]const c.Align, col_count: c_int) c_int {
    var line: MD_LINE = undefined;
    var pipe_offs: [*c]OFF = null;
    var ret: c_int = 0;

    line.beg = beg;
    line.end = end;

    // Break the line into table cells by identifying pipe characters.
    ret = md_analyze_inlines(ctx, @as([*]const MD_LINE, @ptrCast(&line))[0..1], true);
    if (ret < 0) {
        ctx.table_cell_boundaries_head = -1;
        ctx.table_cell_boundaries_tail = -1;
        return ret;
    }

    const n: c_int = ctx.n_table_cell_boundaries + 2;
    pipe_offs = util.alloc_array_a(OFF, ctx.alloc, @intCast(n));
    if (pipe_offs == null) {
        ctx.log("malloc() failed.");
        ctx.table_cell_boundaries_head = -1;
        ctx.table_cell_boundaries_tail = -1;
        return -1;
    }
    var j: c_int = 0;
    pipe_offs[@intCast(j)] = beg;
    j += 1;
    {
        var i: c_int = ctx.table_cell_boundaries_head;
        while (i >= 0) : (i = ctx.marks.items[@intCast(i)].next) {
            pipe_offs[@intCast(j)] = ctx.marks.items[@intCast(i)].end;
            j += 1;
        }
    }
    pipe_offs[@intCast(j)] = end + 1;
    j += 1;

    // Process cells.
    ret = mdEnterBlock(ctx, &.{ .tr = {} });
    if (ret != 0) {
        util.free_array_a(OFF, ctx.alloc, pipe_offs, @intCast(n));
        ctx.table_cell_boundaries_head = -1;
        ctx.table_cell_boundaries_tail = -1;
        return ret;
    }
    var k: c_int = 0;
    {
        var i: c_int = 0;
        while (i < j - 1 and k < col_count) : (i += 1) {
            if (pipe_offs[@intCast(i)] < pipe_offs[@intCast(i + 1)] - 1) {
                ret = md_process_table_cell(ctx, cell_type, align_arr[@intCast(k)], pipe_offs[@intCast(i)], pipe_offs[@intCast(i + 1)] - 1);
                k += 1;
                if (ret < 0) {
                    util.free_array_a(OFF, ctx.alloc, pipe_offs, @intCast(n));
                    ctx.table_cell_boundaries_head = -1;
                    ctx.table_cell_boundaries_tail = -1;
                    return ret;
                }
            }
        }
    }
    // Make sure we call enough table cells even if the current table contains
    // too few of them.
    while (k < col_count) {
        ret = md_process_table_cell(ctx, cell_type, align_arr[@intCast(k)], 0, 0);
        k += 1;
        if (ret < 0) {
            util.free_array_a(OFF, ctx.alloc, pipe_offs, @intCast(n));
            ctx.table_cell_boundaries_head = -1;
            ctx.table_cell_boundaries_tail = -1;
            return ret;
        }
    }
    ret = mdLeaveBlock(ctx, &.{ .tr = {} });

    util.free_array_a(OFF, ctx.alloc, pipe_offs, @intCast(n));
    ctx.table_cell_boundaries_head = -1;
    ctx.table_cell_boundaries_tail = -1;
    return ret;
}

// md4x.c ~5311.
pub fn md_process_table_block_contents(ctx: *MD_CTX, col_count: c_int, lines: []const MD_LINE) c_int {
    var align_arr: [*c]c.Align = null;
    var ret: c_int = 0;

    align_arr = util.alloc_array_a(c.Align, ctx.alloc, @intCast(col_count));
    if (align_arr == null) {
        ctx.log("malloc() failed.");
        return -1;
    }

    md_analyze_table_alignment(ctx, lines[1].beg, lines[1].end, align_arr, col_count);

    ret = mdEnterBlock(ctx, &.{ .thead = {} });
    if (ret != 0) {
        util.free_array_a(c.Align, ctx.alloc, align_arr, @intCast(col_count));
        return ret;
    }
    ret = md_process_table_row(ctx, c.BlockType.th, lines[0].beg, lines[0].end, align_arr, col_count);
    if (ret < 0) {
        util.free_array_a(c.Align, ctx.alloc, align_arr, @intCast(col_count));
        return ret;
    }
    ret = mdLeaveBlock(ctx, &.{ .thead = {} });
    if (ret != 0) {
        util.free_array_a(c.Align, ctx.alloc, align_arr, @intCast(col_count));
        return ret;
    }

    if (lines.len > 2) {
        ret = mdEnterBlock(ctx, &.{ .tbody = {} });
        if (ret != 0) {
            util.free_array_a(c.Align, ctx.alloc, align_arr, @intCast(col_count));
            return ret;
        }
        var line_index: MD_SIZE = 2;
        while (line_index < lines.len) : (line_index += 1) {
            ret = md_process_table_row(ctx, c.BlockType.td, lines[line_index].beg, lines[line_index].end, align_arr, col_count);
            if (ret < 0) {
                util.free_array_a(c.Align, ctx.alloc, align_arr, @intCast(col_count));
                return ret;
            }
        }
        ret = mdLeaveBlock(ctx, &.{ .tbody = {} });
        if (ret != 0) {
            util.free_array_a(c.Align, ctx.alloc, align_arr, @intCast(col_count));
            return ret;
        }
    }

    util.free_array_a(c.Align, ctx.alloc, align_arr, @intCast(col_count));
    return ret;
}

// md4x.c ~5394.
pub fn md_process_normal_block_contents(ctx: *MD_CTX, lines: []const MD_LINE) c_int {
    var ret: c_int = md_analyze_inlines(ctx, lines, false);
    if (ret >= 0) ret = md_process_inlines(ctx, lines);

    // Free any temporary memory blocks stored within some dummy marks.
    var i: c_int = ctx.ptr_stack.top;
    while (i >= 0) : (i = ctx.marks.items[@intCast(i)].next) {
        md_mark_free_ptr(ctx, i);
    }
    ctx.ptr_stack.top = -1;

    return ret;
}

const indent_chunk_str: [*:0]const CHAR = "                ";
const indent_chunk_size: SZ = 16;

// Column width of the byte at `off` when the column it starts at is `col`.
inline fn md_column_width(ctx: *MD_CTX, off: OFF, col: c_uint) c_uint {
    return if (ctx.ch(off) == '\t') (((col + 4) & ~@as(c_uint, 3)) - col) else 1;
}

inline fn md_emit_spaces(ctx: *MD_CTX, text_type: c.TextType, n_in: c_uint) c_int {
    var n = n_in;
    while (n > indent_chunk_size) {
        const ret = mdText(ctx, text_type, indent_chunk_str, indent_chunk_size);
        if (ret != 0) return ret;
        n -= indent_chunk_size;
    }
    if (n > 0) return mdText(ctx, text_type, indent_chunk_str, @intCast(n));
    return 0;
}

// Emit the residual indentation of a verbatim line, i.e. what is left of its
// leading whitespace after the block's own indentation has been stripped.
//
// `indent` is a **column** count, so it cannot simply be replayed as spaces:
// CommonMark expands a tab only where the strip cut through it, and keeps a tab
// that survived it whole (spec 2.2 "Tabs", examples 2 and 5). md4c regenerates
// the indentation from a literal space string and loses those tabs; md4x
// deliberately deviates. `beg` is the line's first content byte (for a blank
// line inside the block, its newline), i.e. the end of the whitespace run.
fn md_process_verbatim_indent(ctx: *MD_CTX, text_type: c.TextType, beg: OFF, indent: c_uint) c_int {
    // The whitespace run the indentation was measured over. Without a tab in it
    // columns are bytes and plain spaces reproduce it exactly.
    var ws_beg: OFF = beg;
    var has_tab = false;
    while (ws_beg > 0 and ctx.isBlank(ws_beg - 1)) {
        ws_beg -= 1;
        has_tab = has_tab or ctx.ch(ws_beg) == '\t';
    }
    if (!has_tab) return md_emit_spaces(ctx, text_type, indent);

    // A tab's width depends on where it starts, so walk the line from its start
    // to get absolute columns: first the column of the whitespace run, then the
    // column of the content. The residual is the last `indent` columns of that.
    var off: OFF = ws_beg;
    while (off > 0 and !ctx.isNewline(off - 1)) off -= 1;
    var ws_col: c_uint = 0;
    while (off < ws_beg) : (off += 1)
        ws_col += md_column_width(ctx, off, ws_col);

    var end_col: c_uint = ws_col;
    off = ws_beg;
    while (off < beg) : (off += 1)
        end_col += md_column_width(ctx, off, end_col);

    // A residual reaching past the whitespace run has nothing to be sourced
    // from; pad it with spaces (defensive — the strip only ever eats columns
    // the whitespace run itself contributed).
    if (end_col < indent) return md_emit_spaces(ctx, text_type, indent);
    const start_col: c_uint = end_col - indent;
    if (start_col < ws_col) {
        const ret = md_emit_spaces(ctx, text_type, ws_col - start_col);
        if (ret != 0) return ret;
    }

    // Skip the bytes wholly before the residual.
    var col: c_uint = ws_col;
    off = ws_beg;
    while (off < beg) {
        const w = md_column_width(ctx, off, col);
        if (col + w > start_col) break;
        col += w;
        off += 1;
    }

    // A tab the strip cut through contributes its uncut columns as spaces.
    if (off < beg and col < start_col) {
        const w = md_column_width(ctx, off, col);
        const ret = md_emit_spaces(ctx, text_type, col + w - start_col);
        if (ret != 0) return ret;
        off += 1;
    }

    // Everything from here on survived the strip whole: emit it verbatim.
    return mdText(ctx, text_type, ctx.str(off), beg - off);
}

// md4x.c ~5412. `preserve_tabs` selects CommonMark's tab handling for the
// residual indentation (see md_process_verbatim_indent). Frontmatter passes
// false: its body goes to libyaml, which rejects a tab as indentation, and
// md4c's regenerate-as-spaces has been quietly making tab-indented YAML parse.
pub fn md_process_verbatim_block_contents(ctx: *MD_CTX, text_type: c.TextType, lines: []const MD_VERBATIMLINE, preserve_tabs: bool) c_int {
    var ret: c_int = 0;

    var line_index: MD_SIZE = 0;
    while (line_index < lines.len) : (line_index += 1) {
        const line = &lines[line_index];

        // Output code indentation.
        if (line.indent > 0) {
            ret = if (preserve_tabs)
                md_process_verbatim_indent(ctx, text_type, line.beg, line.indent)
            else
                md_emit_spaces(ctx, text_type, line.indent);
            if (ret != 0) return ret;
        }

        // Output the code line itself.
        ret = mdTextInsecure(ctx, text_type, ctx.str(line.beg), line.end - line.beg);
        if (ret != 0) return ret;

        // Enforce end-of-line.
        ret = mdText(ctx, text_type, "\n", 1);
        if (ret != 0) return ret;
    }

    return ret;
}

// md4x.c ~5446.
pub fn md_process_code_block_contents(ctx: *MD_CTX, is_fenced: c_int, lines_in: []const MD_VERBATIMLINE) c_int {
    var lines = lines_in;

    if (is_fenced != 0) {
        // Skip the first line in case of fenced code: It is the fence.
        lines = lines[1..];
    } else {
        // Ignore blank lines at start/end of indented code block.
        while (lines.len > 0 and lines[0].beg == lines[0].end) {
            lines = lines[1..];
        }
        while (lines.len > 0 and lines[lines.len - 1].beg == lines[lines.len - 1].end) {
            lines = lines[0 .. lines.len - 1];
        }
    }

    if (lines.len == 0) return 0;

    return md_process_verbatim_block_contents(ctx, c.TextType.code, lines, true);
}

// md4x.c ~5473. Parse highlight ranges string (e.g. "1-3,5,7") into expanded
// array. Returns heap-allocated array (null on empty/error) and sets out_count.
pub fn md_parse_highlights(ctx: *MD_CTX, str: [*c]const CHAR, size: SZ, out_count: *c_uint) [*c]c_uint {
    var arr: [*c]c_uint = null;
    var capacity: c_uint = 0;
    var count: c_uint = 0;
    var pos: SZ = 0;

    out_count.* = 0;

    while (pos < size) {
        var start_num: c_uint = 0;
        var end_num: c_uint = 0;

        // Skip whitespace and commas.
        while (pos < size and (str[pos] == ',' or str[pos] == ' ')) pos += 1;
        if (pos >= size) break;

        // Parse number.
        if (str[pos] < '0' or str[pos] > '9') break;
        while (pos < size and str[pos] >= '0' and str[pos] <= '9') {
            start_num = start_num *% 10 +% @as(c_uint, str[pos] - '0');
            if (start_num > 100000) break;
            pos += 1;
        }
        if (start_num > 100000) break;
        end_num = start_num;

        // Range?
        if (pos < size and str[pos] == '-') {
            pos += 1;
            end_num = 0;
            if (pos >= size or str[pos] < '0' or str[pos] > '9') break;
            while (pos < size and str[pos] >= '0' and str[pos] <= '9') {
                end_num = end_num *% 10 +% @as(c_uint, str[pos] - '0');
                if (end_num > 100000) break;
                pos += 1;
            }
            if (end_num > 100000) break;
        }

        // Safety limit.
        if (end_num < start_num or (end_num - start_num) > 10000) break;
        if (count + (end_num - start_num + 1) > 100000) break;
        var nn: c_uint = start_num;
        while (nn <= end_num) : (nn += 1) {
            if (count >= capacity) {
                const new_cap: c_uint = if (capacity == 0) 16 else capacity * 2;
                const tmp = util.realloc_array_a(c_uint, ctx.alloc, arr, @intCast(capacity), @intCast(new_cap));
                if (tmp == null) {
                    util.free_array_a(c_uint, ctx.alloc, arr, @intCast(capacity));
                    return null;
                }
                arr = tmp;
                capacity = new_cap;
            }
            arr[count] = nn;
            count += 1;
        }
    }

    if (count == 0) {
        util.free_array_a(c_uint, ctx.alloc, arr, @intCast(capacity));
        return null;
    }
    // Shrink-to-fit so the freed length equals the reported count (the detail
    // carries `highlights` as a slice, with no capacity). A shrink realloc resizes
    // in place on c_allocator / the testing allocator, so it effectively never
    // fails here; if it ever did (OOM), drop the highlights cleanly rather than
    // leave a capacity≠count buffer the caller would free by the wrong length.
    if (count < capacity) {
        const shr = util.realloc_array_a(c_uint, ctx.alloc, arr, @intCast(capacity), @intCast(count));
        if (shr == null) {
            util.free_array_a(c_uint, ctx.alloc, arr, @intCast(capacity));
            return null;
        }
        arr = shr;
        capacity = count;
    }
    out_count.* = count;
    return arr;
}

// md4x.c ~5544.
pub fn md_setup_fenced_code_detail(ctx: *MD_CTX, block: *const MD_BLOCK, det: *c.BlockCodeDetail, info_build: *MD_ATTRIBUTE_BUILD, lang_build: *MD_ATTRIBUTE_BUILD, filename_build: *MD_ATTRIBUTE_BUILD) c_int {
    const fence_line: *const MD_VERBATIMLINE = @ptrCast(@alignCast(@as([*]const MD_BLOCK, @ptrCast(block)) + 1));
    var beg: OFF = fence_line.beg;
    var end: OFF = fence_line.end;
    const fence_ch: CHAR = ctx.ch(fence_line.beg);

    // Skip the fence itself.
    while (beg < ctx.size and ctx.ch(beg) == fence_ch) beg += 1;
    // Trim initial spaces.
    while (beg < ctx.size and ctx.ch(beg) == ' ') beg += 1;
    // Trim trailing spaces.
    while (end > beg and ctx.ch(end - 1) == ' ') end -= 1;

    // Build info string attribute (full info string).
    md_build_attribute(ctx, ctx.str(beg), end - beg, 0, &det.info, info_build) catch return -1;

    // Build lang attribute (first word of info string).
    var lang_end: OFF = beg;
    while (lang_end < end and !ctx.isWhitespace(lang_end)) lang_end += 1;
    md_build_attribute(ctx, ctx.str(beg), lang_end - beg, 0, &det.lang, lang_build) catch return -1;

    det.fence_char = fence_ch;

    // Parse extended metadata from the rest of the info string (after lang).
    var rest_beg: OFF = lang_end;
    while (rest_beg < end and ctx.isWhitespace(rest_beg)) rest_beg += 1;

    if (rest_beg < end) {
        var fn_open: OFF = 0;
        var fn_close: OFF = 0;
        var fn_beg: OFF = 0;
        var fn_end: OFF = 0;
        var hl_open: OFF = 0;
        var hl_close: OFF = 0;
        var hl_beg: OFF = 0;
        var hl_end: OFF = 0;
        var has_filename: c_int = 0;
        var has_highlights: c_int = 0;

        // Find [filename] — scan for '[', then matching ']' with backslash escapes.
        {
            var i: OFF = rest_beg;
            while (i < end) : (i += 1) {
                if (ctx.ch(i) == '[') {
                    fn_open = i;
                    var jj: OFF = i + 1;
                    while (jj < end) : (jj += 1) {
                        if (ctx.ch(jj) == '\\' and jj + 1 < end) {
                            jj += 1; // skip escaped char
                        } else if (ctx.ch(jj) == ']') {
                            fn_close = jj + 1;
                            fn_beg = i + 1;
                            fn_end = jj;
                            has_filename = 1;
                            break;
                        }
                    }
                    break; // only match first '['
                }
            }
        }

        // Find {highlights}.
        {
            var i: OFF = rest_beg;
            while (i < end) : (i += 1) {
                if (ctx.ch(i) == '{') {
                    hl_open = i;
                    var jj: OFF = i + 1;
                    while (jj < end) : (jj += 1) {
                        if (ctx.ch(jj) == '}') {
                            hl_close = jj + 1;
                            hl_beg = i + 1;
                            hl_end = jj;
                            has_highlights = 1;
                            break;
                        }
                    }
                    break;
                }
            }
        }

        // Build filename attribute (handling backslash escapes).
        if (has_filename != 0 and fn_end > fn_beg) {
            md_build_attribute(ctx, ctx.str(fn_beg), fn_end - fn_beg, 0, &det.filename, filename_build) catch return -1;
        }

        // Parse highlights into expanded integer array.
        if (has_highlights != 0 and hl_end > hl_beg) {
            var hl_count: c_uint = 0;
            const hl = md_parse_highlights(ctx, ctx.str(hl_beg), hl_end - hl_beg, &hl_count);
            if (hl != null) det.highlights = hl[0..hl_count];
        }

        // Build meta from remaining text (exclude [..] and {..} regions).
        {
            var meta_len: SZ = 0;
            const meta_cap: usize = @as(usize, end - rest_beg) + 1;
            const meta_buf: [*c]CHAR = util.alloc_array_a(CHAR, ctx.alloc, meta_cap);
            if (meta_buf == null) {
                ctx.log("malloc() failed.");
                return -1;
            }

            var pos: OFF = rest_beg;
            while (pos < end) {
                // Skip bracket region.
                if (has_filename != 0 and pos == fn_open) {
                    pos = fn_close;
                    continue;
                }
                // Skip brace region.
                if (has_highlights != 0 and pos == hl_open) {
                    pos = hl_close;
                    continue;
                }
                meta_buf[meta_len] = ctx.ch(pos);
                meta_len += 1;
                pos += 1;
            }

            // Trim whitespace.
            while (meta_len > 0 and (meta_buf[meta_len - 1] == ' ' or meta_buf[meta_len - 1] == '\t'))
                meta_len -= 1;
            {
                var trim_start: SZ = 0;
                while (trim_start < meta_len and (meta_buf[trim_start] == ' ' or meta_buf[trim_start] == '\t'))
                    trim_start += 1;
                if (trim_start > 0) {
                    meta_len -= trim_start;
                    _ = memmove(meta_buf, meta_buf + trim_start, @as(usize, meta_len) * @sizeOf(CHAR));
                }
            }

            if (meta_len > 0) {
                const meta_copy: [*c]CHAR = util.alloc_array_a(CHAR, ctx.alloc, @as(usize, meta_len) + 1);
                if (meta_copy == null) {
                    util.free_array_a(CHAR, ctx.alloc, meta_buf, meta_cap);
                    ctx.log("malloc() failed.");
                    return -1;
                }
                @memcpy(meta_copy[0..meta_len], meta_buf[0..meta_len]);
                meta_copy[meta_len] = 0;
                // The slice excludes the NUL; md_free_code_detail frees len + 1.
                det.meta = meta_copy[0..meta_len];
            }

            util.free_array_a(CHAR, ctx.alloc, meta_buf, meta_cap);
        }
    }

    return 0;
}

// Release the two heap buffers a fenced-code detail owns. Both are allocated
// through `ctx.alloc` and freed by their exact element count: `meta` is stored
// as a slice that excludes its trailing NUL, so it frees `len + 1`.
fn md_free_code_detail(ctx: *MD_CTX, code: *const c.BlockCodeDetail) void {
    if (code.meta.len > 0)
        util.free_array_a(CHAR, ctx.alloc, @constCast(code.meta.ptr), code.meta.len + 1);
    if (code.highlights.len > 0)
        util.free_array_a(c_uint, ctx.alloc, @constCast(code.highlights.ptr), code.highlights.len);
}

// --- block attributes --------------------------------------------------------
//
// A trailing `{...}` run on a block's LAST line attaches its attributes to that
// block. The run has to be separated from the text before it by a blank, and
// that blank is the whole rule that tells the block form apart from the inline
// one: `[span]{a}` binds to the span, `[span] {a}` binds to the paragraph.
//
// Nothing is copied and no side table is kept. `md_resolve_block_attrs` shortens
// the line to just before the run and records the fact in the block's flag byte;
// the bytes are recovered at emission time by re-scanning forward from the
// shortened end. Which element the run lands on is decided by the same pass,
// because a paragraph's run lifts to the enclosing element in the two cases the
// syntax spells out — a tight list item, and a blockquote holding nothing but
// that one paragraph (which then also loses its `<p>` wrapper).

// Does the line `[beg, end)` end in an attribute run? Returns where its text
// ends once the run and the blanks before it are cut off, or null when there is
// no run. The run's bytes are not reported: `md_recover_block_attrs` reads them
// straight back off the shortened line.
fn md_find_block_attrs(ctx: *MD_CTX, beg: OFF, end: OFF) ?OFF {
    if (end <= beg or ctx.ch(end - 1) != '}')
        return null;

    // The last top-level '{' of the line. Depth counting (not "the last '{'"),
    // so a brace inside a quoted value cannot be mistaken for the opener.
    var depth: c_int = 0;
    var open: OFF = 0;
    var seen: bool = false;
    var i: OFF = beg;
    while (i < end) : (i += 1) {
        if (ctx.ch(i) == '{') {
            if (depth == 0) {
                open = i;
                seen = true;
            }
            depth += 1;
        } else if (ctx.ch(i) == '}') {
            if (depth > 0) depth -= 1;
        }
    }
    if (!seen or depth != 0)
        return null;

    // A blank must precede the run: without it this is an inline attribute list
    // bound to whatever ends right before the brace.
    if (open <= beg or !ISBLANK_(ctx.ch(open - 1)))
        return null;
    if (!inlines.md_is_attr_opener(ctx, open))
        return null;

    // ... and the run has to be the one closing the line.
    var d: c_int = 0;
    i = open;
    while (i < end) : (i += 1) {
        if (ctx.ch(i) == '{') {
            d += 1;
        } else if (ctx.ch(i) == '}') {
            d -= 1;
            if (d == 0) break;
        }
    }
    if (i != end - 1)
        return null;

    // `{}` carries nothing and `{"}` is not an attribute list; leave either as
    // literal text rather than eating it. So is a run of bare keys alone
    // (`Hello {title}`): after a blank that is a JSX-style expression, not a
    // boolean prop on the paragraph — see md_is_bare_attr_content.
    var blank = true;
    i = open + 1;
    while (i < end - 1) : (i += 1) {
        if (!ISBLANK_(ctx.ch(i))) {
            blank = false;
            break;
        }
    }
    if (blank or !inlines.md_is_attr_content(ctx, open + 1, end - 1))
        return null;
    if (inlines.md_is_bare_attr_content(ctx, open + 1, end - 1))
        return null;

    var text_end: OFF = open;
    while (text_end > beg and ISBLANK_(ctx.ch(text_end - 1)))
        text_end -= 1;
    if (text_end == beg)
        return null;

    return text_end;
}

// Re-scan the run `md_resolve_block_attrs` cut off the end of `line`. Written
// defensively rather than trusting the flag: an unexpected shape yields the
// empty attribute string, never an out-of-range slice.
fn md_recover_block_attrs(ctx: *MD_CTX, line: *const MD_LINE) []const CHAR {
    var i: OFF = line.end;
    while (i < ctx.size and ISBLANK_(ctx.ch(i)))
        i += 1;
    if (i >= ctx.size or ctx.ch(i) != '{')
        return &.{};

    const open: OFF = i;
    var depth: c_int = 0;
    while (i < ctx.size and !ctx.isNewline(i)) : (i += 1) {
        if (ctx.ch(i) == '{') {
            depth += 1;
        } else if (ctx.ch(i) == '}') {
            depth -= 1;
            if (depth == 0)
                return ctx.str(open + 1)[0 .. i - open - 1];
        }
    }
    return &.{};
}

// The attribute run a leaf block kept for itself (empty once it was lifted to
// an enclosing container).
fn md_block_own_attrs(ctx: *MD_CTX, block: *const MD_BLOCK) []const CHAR {
    const flags: c_uint = block.bits.flags;
    if (flags & MD_BLOCK_HAS_ATTRS == 0 or flags & MD_BLOCK_ATTRS_HOISTED != 0)
        return &.{};
    if (block.n_lines == 0)
        return &.{};
    const lines: [*]const MD_LINE = @ptrCast(@alignCast(@as([*]const MD_BLOCK, @ptrCast(block)) + 1));
    return md_recover_block_attrs(ctx, &lines[block.n_lines - 1]);
}

// The attribute run lifted onto a container from its first child. The child is
// always the block immediately after the opener in the arena, which is exactly
// what `md_resolve_block_attrs` requires before it sets MD_BLOCK_ATTRS_HOISTED.
fn md_block_hoisted_attrs(ctx: *MD_CTX, byte_off: usize, block: *const MD_BLOCK) []const CHAR {
    if (block.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER_OPENER)) == 0)
        return &.{};

    const child_off: usize = byte_off + @sizeOf(MD_BLOCK);
    if (child_off + @sizeOf(MD_BLOCK) > ctx.n_block_bytes)
        return &.{};

    const child: *const MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + child_off));
    const flags: c_uint = child.bits.flags;
    if (flags & MD_BLOCK_HAS_ATTRS == 0 or flags & MD_BLOCK_ATTRS_HOISTED == 0)
        return &.{};
    if (child.n_lines == 0)
        return &.{};

    const lines: [*]const MD_LINE = @ptrCast(@alignCast(@as([*]const MD_BLOCK, @ptrCast(child)) + 1));
    return md_recover_block_attrs(ctx, &lines[child.n_lines - 1]);
}

// One frame per open container while md_resolve_block_attrs walks the arena.
const MD_BLOCK_ATTR_FRAME = struct {
    btype: c.BlockType,
    /// Arena offset of the container's own opener block.
    self_off: usize,
    /// Only meaningful on a `ul`/`ol` frame: the list's final looseness, which
    /// the block layer may have flipped on retroactively.
    is_loose: bool,
    /// Set for an `li` whose list is tight — the only case where the item's
    /// paragraph is suppressed, hence the only one where lifting to the item is
    /// the right call.
    in_tight_list: bool,
    /// Direct children seen so far, and the arena offset of the first of them.
    child_count: MD_SIZE,
    first_child_off: usize,
};

// Consume every block's trailing `{...}` and decide which element it lands on,
// and fold every `::ul` / `::ol` / `::table` / `::blockquote` / `::pre` wrapper
// into the single same-tagged child it holds. Runs once, over the finished
// block arena, before any callback fires — both decisions need the whole block
// tree, which a streaming renderer never has in hand.
fn md_resolve_block_attrs(ctx: *MD_CTX) error{OutOfMemory}!void {
    // Local to the pass — deliberately not an MD_CTX field, since nothing
    // outside it ever reads the stack.
    var stack: std.ArrayListUnmanaged(MD_BLOCK_ATTR_FRAME) = .empty;
    defer stack.deinit(ctx.alloc);

    var byte_off: usize = 0;
    while (byte_off < ctx.n_block_bytes) {
        const block: *MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + byte_off));
        const btype = block.getType();
        const flags: c_uint = block.bits.flags;

        if (flags & MD_BLOCK_CONTAINER != 0) {
            // Closer first, then opener — the order md_process_all_blocks emits
            // them in, so the frames nest the same way.
            if (flags & MD_BLOCK_CONTAINER_CLOSER != 0 and stack.items.len > 0) {
                const frame = stack.pop().?;
                md_close_block_attr_frame(ctx, &frame);
                // After md_close_block_attr_frame: a quote that just took a
                // lifted run must not also take a wrapper's props.
                md_fold_wrapper_component(ctx, &frame, block);
            }

            if (flags & MD_BLOCK_CONTAINER_OPENER != 0) {
                md_count_block_attr_child(&stack, byte_off);
                // Read the parent out as a plain bool before appending: the
                // append may reallocate, so nothing may survive it as a pointer.
                const in_tight_list = btype == c.BlockType.li and stack.items.len > 0 and blk: {
                    const parent = stack.items[stack.items.len - 1];
                    break :blk (parent.btype == c.BlockType.ul or parent.btype == c.BlockType.ol) and
                        !parent.is_loose;
                };
                stack.append(ctx.alloc, .{
                    .btype = btype,
                    .self_off = byte_off,
                    .is_loose = flags & MD_BLOCK_LOOSE_LIST != 0,
                    .in_tight_list = in_tight_list,
                    .child_count = 0,
                    .first_child_off = 0,
                }) catch {
                    ctx.log("realloc() failed.");
                    return error.OutOfMemory;
                };
            }

            byte_off += @sizeOf(MD_BLOCK);
            continue;
        }

        md_count_block_attr_child(&stack, byte_off);

        if ((btype == c.BlockType.p or btype == c.BlockType.h) and block.n_lines > 0) {
            const lines: [*]MD_LINE = @ptrCast(@alignCast(@as([*]MD_BLOCK, @ptrCast(block)) + 1));
            const last = &lines[block.n_lines - 1];
            if (md_find_block_attrs(ctx, last.beg, last.end)) |text_end| {
                last.end = text_end;
                block.bits.flags |= @as(u8, @truncate(MD_BLOCK_HAS_ATTRS));
            }
        }

        const line_size: usize = if (btype == c.BlockType.code or btype == c.BlockType.html or btype == c.BlockType.frontmatter)
            @sizeOf(MD_VERBATIMLINE)
        else
            @sizeOf(MD_LINE);
        byte_off += @as(usize, block.n_lines) * line_size;
        byte_off += @sizeOf(MD_BLOCK);
    }
}

fn md_count_block_attr_child(stack: *std.ArrayListUnmanaged(MD_BLOCK_ATTR_FRAME), byte_off: usize) void {
    if (stack.items.len == 0)
        return;
    const frame = &stack.items[stack.items.len - 1];
    if (frame.child_count == 0)
        frame.first_child_off = byte_off;
    frame.child_count +|= 1;
}

// Decide, now that the container is complete, whether its first child's run
// belongs to the container rather than to the child.
fn md_close_block_attr_frame(ctx: *MD_CTX, frame: *const MD_BLOCK_ATTR_FRAME) void {
    const lift_to_li = frame.btype == c.BlockType.li and frame.in_tight_list and frame.child_count >= 1;
    // The blockquote form is the single-paragraph one only: with a second block
    // in the quote the attributes stay on the paragraphs.
    const lift_to_quote = frame.btype == c.BlockType.quote and frame.child_count == 1;
    if (!lift_to_li and !lift_to_quote)
        return;

    if (frame.first_child_off + @sizeOf(MD_BLOCK) > ctx.n_block_bytes)
        return;
    const child: *MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + frame.first_child_off));
    if (child.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER)) != 0)
        return;
    if (child.getType() != c.BlockType.p)
        return;
    if (child.bits.flags & @as(u8, @truncate(MD_BLOCK_HAS_ATTRS)) == 0)
        return;

    child.bits.flags |= @as(u8, @truncate(MD_BLOCK_ATTRS_HOISTED));
    // A one-paragraph blockquote renders its text directly, with the attributes
    // on the <blockquote>; a list item's paragraph is already suppressed by the
    // tight-list rule, so it needs no extra marker.
    if (lift_to_quote)
        child.bits.flags |= @as(u8, @truncate(MD_BLOCK_UNWRAP_P));
}

// The block type a `::name` wrapper folds into, or null when `name` is not one
// of the five wrapper tags. `::pre` folds into the `code` block that renders as
// `<pre><code>`; the other four name their block type directly.
// `.agents/comark/attributes.md:306-360`.
fn md_wrapper_fold_target(name: []const CHAR) ?c.BlockType {
    if (std.mem.eql(u8, name, "ul")) return c.BlockType.ul;
    if (std.mem.eql(u8, name, "ol")) return c.BlockType.ol;
    if (std.mem.eql(u8, name, "table")) return c.BlockType.table;
    if (std.mem.eql(u8, name, "blockquote")) return c.BlockType.quote;
    if (std.mem.eql(u8, name, "pre")) return c.BlockType.code;
    return null;
}

fn md_block_at(ctx: *MD_CTX, byte_off: usize) *MD_BLOCK {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + byte_off));
}

// Now that the container is complete: is it a wrapper component holding exactly
// one same-tagged child? If so, mark both of its bookend blocks so nothing is
// emitted for them, and the child takes the wrapper's props instead.
//
// A wrapper emitted as a second, OUTER element of the same tag is invalid HTML
// that browsers reparent (`<ul>` directly inside `<ul>`, `<table>` inside
// `<table>`) and a wrong AST shape for every consumer.
fn md_fold_wrapper_component(ctx: *MD_CTX, frame: *const MD_BLOCK_ATTR_FRAME, closer: *MD_BLOCK) void {
    // Anything but "exactly one child, tags match" keeps today's nesting.
    if (frame.btype != c.BlockType.component or frame.child_count != 1)
        return;
    if (frame.self_off + @sizeOf(MD_BLOCK) > ctx.n_block_bytes)
        return;
    if (frame.first_child_off + @sizeOf(MD_BLOCK) > ctx.n_block_bytes)
        return;

    const opener = md_block_at(ctx, frame.self_off);
    const comp_idx: usize = opener.bits.data;
    if (comp_idx >= ctx.block_component_info.items.len)
        return;
    const info = &ctx.block_component_info.items[comp_idx];
    if (info.name_end <= info.name_beg)
        return;
    // A `::pre Some Title{...}` title has no home on the folded element, so the
    // wrapper stays a component rather than silently losing it.
    if (info.title_end > info.title_beg)
        return;

    const name = ctx.str(info.name_beg)[0 .. info.name_end - info.name_beg];
    const target = md_wrapper_fold_target(name) orelse return;

    const child = md_block_at(ctx, frame.first_child_off);
    if (child.getType() != target)
        return;

    // `table` and `code` are leaf blocks; the other three are containers, and
    // `first_child_off` is where their OPENER sits.
    const want_container = target != c.BlockType.table and target != c.BlockType.code;
    const is_container = child.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER)) != 0;
    if (want_container != is_container)
        return;
    if (want_container and child.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER_OPENER)) == 0)
        return;

    // A one-paragraph blockquote already carries a lifted `{...}` run in the one
    // `raw_attrs` slot the detail has. Two attribute sources, one slot: leave
    // the pair nested rather than drop either.
    if (target == c.BlockType.quote and
        md_block_hoisted_attrs(ctx, frame.first_child_off, child).len > 0)
        return;

    opener.bits.flags |= @as(u8, @truncate(MD_BLOCK_FOLDED_WRAPPER));
    closer.bits.flags |= @as(u8, @truncate(MD_BLOCK_FOLDED_WRAPPER));
}

// The `{props}` of a folded wrapper, read off its opener block.
fn md_folded_wrapper_attrs(ctx: *MD_CTX, block: *const MD_BLOCK) []const CHAR {
    const comp_idx: usize = block.bits.data;
    if (comp_idx >= ctx.block_component_info.items.len)
        return &.{};
    const info = &ctx.block_component_info.items[comp_idx];
    if (info.props_beg == 0 or info.props_end <= info.props_beg)
        return &.{};
    return ctx.str(info.props_beg)[0 .. info.props_end - info.props_beg];
}

// md4x.c ~5714.
pub fn md_process_leaf_block(ctx: *MD_CTX, block: *const MD_BLOCK, fold_attrs: []const CHAR) c_int {
    var info_build: MD_ATTRIBUTE_BUILD = .{};
    var lang_build: MD_ATTRIBUTE_BUILD = .{};
    var filename_build: MD_ATTRIBUTE_BUILD = .{};
    var is_in_tight_list: bool = undefined;
    var clean_fence_code_detail: bool = false;
    var ret: c_int = 0;

    if (ctx.nContainers() == 0)
        is_in_tight_list = false
    else
        is_in_tight_list = (ctx.containers.items[@intCast(ctx.nContainers() - 1)].is_loose == 0);

    const block_lines: [*]const MD_BLOCK = @ptrCast(block);

    // For a large table, check its density: if it is too low, suppress the
    // interpretation as a table, as a safety measure against quadratic output
    // size explosion (every missing cell is "helpfully" filled in with an empty
    // <td></td>). See https://github.com/mity/md4c/issues/345. Upstream mutates
    // `block->type` in place; demoting the local is equivalent, because the
    // only later reader of the stored type (`md_process_all_blocks`) uses it
    // just to pick MD_LINE vs MD_VERBATIMLINE, and `.table` and `.p` agree.
    const raw_btype = block.getType();
    const btype = blk: {
        if (raw_btype != c.BlockType.table) break :blk raw_btype;

        const n_cols: usize = block.bits.data;
        const n_rows: usize = block.n_lines;
        // n_cols > 32 also keeps the divisions below well defined.
        if (n_cols <= 32 or n_rows <= 4096 / n_cols) break :blk raw_btype;

        // Input bytes encoding the table: every line's contents, plus one byte
        // per line break. `usize` because Zig traps on overflow in Debug.
        const lines = @as([*]const MD_LINE, @ptrCast(@alignCast(block_lines + 1)))[0..n_rows];
        var table_input_size: usize = n_rows;
        for (lines) |l| table_input_size += l.end - l.beg;

        if (table_input_size / n_cols < n_rows / 4) {
            // Fewer than ~25% as many input bytes as cells to be generated.
            ctx.log("Suppressing too sparse table (see https://github.com/mity/md4c/issues/345)");
            break :blk c.BlockType.p;
        }
        break :blk raw_btype;
    };

    // The detail is the union arm named by the runtime block type; the switch
    // below fills in whatever fields that arm actually carries. (This replaces
    // the pre-4c `extern union` scratch slot + `?*anyopaque` selector.)
    var det: c.BlockDetail = .default(btype);

    switch (btype) {
        c.BlockType.h => {
            det.h.level = block.bits.data;
            det.h.raw_attrs = md_block_own_attrs(ctx, block);
        },
        c.BlockType.p => det.p.raw_attrs = md_block_own_attrs(ctx, block),
        c.BlockType.code => {
            // For fenced code block, we may need to set the info string.
            if (block.bits.data != 0) {
                clean_fence_code_detail = true;
                ret = md_setup_fenced_code_detail(ctx, block, &det.code, &info_build, &lang_build, &filename_build);
                if (ret < 0) {
                    md_free_attribute(ctx, &info_build);
                    md_free_attribute(ctx, &lang_build);
                    md_free_attribute(ctx, &filename_build);
                    md_free_code_detail(ctx, &det.code);
                    return ret;
                }
            }
            det.code.raw_attrs = fold_attrs;
        },
        c.BlockType.table => {
            det.table.col_count = block.bits.data;
            det.table.head_row_count = 1;
            det.table.body_row_count = block.n_lines - 2;
            det.table.raw_attrs = fold_attrs;
        },
        else => {},
    }

    // A paragraph loses its bookends inside a tight list item, and in the
    // one-paragraph blockquote form where the quote carries the attributes.
    const suppress_p = btype == c.BlockType.p and
        (is_in_tight_list or block.bits.flags & @as(u8, @truncate(MD_BLOCK_UNWRAP_P)) != 0);

    if (!suppress_p) {
        ret = mdEnterBlock(ctx, &det);
        if (ret != 0) {
            if (clean_fence_code_detail) {
                md_free_attribute(ctx, &info_build);
                md_free_attribute(ctx, &lang_build);
                md_free_attribute(ctx, &filename_build);
                md_free_code_detail(ctx, &det.code);
            }
            return ret;
        }
    }

    // Process the block contents according to its type.
    switch (btype) {
        c.BlockType.hr => {},
        c.BlockType.code => ret = md_process_code_block_contents(ctx, @intFromBool(block.bits.data != 0), @as([*]const MD_VERBATIMLINE, @ptrCast(@alignCast(block_lines + 1)))[0..block.n_lines]),
        c.BlockType.html => ret = md_process_verbatim_block_contents(ctx, c.TextType.html, @as([*]const MD_VERBATIMLINE, @ptrCast(@alignCast(block_lines + 1)))[0..block.n_lines], true),
        c.BlockType.frontmatter => {
            // Skip the opening fence line (first line is the --- opener).
            const vlines: [*]const MD_VERBATIMLINE = @ptrCast(@alignCast(block_lines + 1));
            ret = md_process_verbatim_block_contents(ctx, c.TextType.normal, (vlines + 1)[0 .. block.n_lines - 1], false);
        },
        c.BlockType.table => ret = md_process_table_block_contents(ctx, @intCast(block.bits.data), @as([*]const MD_LINE, @ptrCast(@alignCast(block_lines + 1)))[0..block.n_lines]),
        else => ret = md_process_normal_block_contents(ctx, @as([*]const MD_LINE, @ptrCast(@alignCast(block_lines + 1)))[0..block.n_lines]),
    }
    if (ret < 0) {
        if (clean_fence_code_detail) {
            md_free_attribute(ctx, &info_build);
            md_free_attribute(ctx, &lang_build);
            md_free_attribute(ctx, &filename_build);
            md_free_code_detail(ctx, &det.code);
        }
        return ret;
    }

    if (!suppress_p) {
        ret = mdLeaveBlock(ctx, &det);
        if (ret != 0) {
            if (clean_fence_code_detail) {
                md_free_attribute(ctx, &info_build);
                md_free_attribute(ctx, &lang_build);
                md_free_attribute(ctx, &filename_build);
                md_free_code_detail(ctx, &det.code);
            }
            return ret;
        }
    }

    if (clean_fence_code_detail) {
        md_free_attribute(ctx, &info_build);
        md_free_attribute(ctx, &lang_build);
        md_free_attribute(ctx, &filename_build);
        md_free_code_detail(ctx, &det.code);
    }
    return ret;
}

// md4x.c ~5814.
pub fn md_process_all_blocks(ctx: *MD_CTX) c_int {
    // Walks the block_bytes arena, so it tracks ctx.n_block_bytes's type.
    var byte_off: usize = 0;
    var ret: c_int = 0;
    var comp_name_build: MD_ATTRIBUTE_BUILD = .{};
    var clean_component_detail: bool = false;

    // Consume trailing `{...}` runs and settle which element each one belongs to
    // before a single callback fires — the decision needs the whole block tree.
    md_resolve_block_attrs(ctx) catch return -1;

    // ctx.containers now is reused for tracking loose/tight lists.
    ctx.containers.clearRetainingCapacity();

    // The props of a folded `::ul` / `::ol` / `::table` / `::blockquote` /
    // `::pre` wrapper, waiting for the block that swallowed it — always the very
    // next one in the arena, which is what the fold decision required.
    var fold_attrs: []const CHAR = &.{};

    while (byte_off < ctx.n_block_bytes) {
        const block: *MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + byte_off));
        const btype = block.getType();

        // A folded wrapper emits nothing at all: its opener hands its props to
        // the child, its closer is dropped, and neither touches ctx.containers
        // (only the `p` bookends read that, and no fold target is a `p`).
        if ((block.bits.flags & @as(u8, @truncate(MD_BLOCK_FOLDED_WRAPPER))) != 0) {
            if ((block.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER_OPENER))) != 0)
                fold_attrs = md_folded_wrapper_attrs(ctx, block);
            byte_off += @sizeOf(MD_BLOCK);
            continue;
        }

        const block_fold_attrs = fold_attrs;
        fold_attrs = &.{};

        // The detail is the union arm named by the runtime block type (see
        // md_process_leaf_block); the switch below fills in its fields.
        var det: c.BlockDetail = .default(btype);

        switch (btype) {
            c.BlockType.ul => {
                det.ul.is_tight = (block.bits.flags & @as(u8, @truncate(MD_BLOCK_LOOSE_LIST))) == 0;
                det.ul.mark = @intCast(block.bits.data);
                det.ul.raw_attrs = block_fold_attrs;
            },
            c.BlockType.ol => {
                det.ol.start = block.n_lines;
                det.ol.is_tight = (block.bits.flags & @as(u8, @truncate(MD_BLOCK_LOOSE_LIST))) == 0;
                det.ol.mark_delimiter = @intCast(block.bits.data);
                det.ol.raw_attrs = block_fold_attrs;
            },
            c.BlockType.li => {
                det.li.is_task = block.bits.data != 0;
                det.li.task_mark = @intCast(block.bits.data);
                det.li.task_mark_offset = @intCast(block.n_lines);
                det.li.raw_attrs = md_block_hoisted_attrs(ctx, byte_off, block);
            },
            // Mutually exclusive by construction: md_fold_wrapper_component
            // refuses a quote that already carries a lifted run.
            c.BlockType.quote => det.quote.raw_attrs = if (block_fold_attrs.len > 0)
                block_fold_attrs
            else
                md_block_hoisted_attrs(ctx, byte_off, block),
            c.BlockType.component => {
                const comp_idx: c_int = @intCast(block.bits.data);
                if (comp_idx >= 0 and comp_idx < @as(c_int, @intCast(ctx.block_component_info.items.len))) {
                    const info = &ctx.block_component_info.items[@intCast(comp_idx)];
                    const name_beg = info.name_beg;
                    const name_end = info.name_end;
                    const props_beg = info.props_beg;
                    const props_end = info.props_end;
                    const t_beg = info.title_beg;
                    const t_end = info.title_end;

                    comp_name_build = .{};
                    md_build_attribute(ctx, ctx.str(name_beg), name_end - name_beg, 0, &det.component.tag_name, &comp_name_build) catch {
                        md_free_attribute(ctx, &comp_name_build);
                        return -1;
                    };
                    clean_component_detail = true;

                    if (props_beg > 0 and props_end > props_beg) {
                        det.component.raw_props = ctx.str(props_beg)[0 .. props_end - props_beg];
                    }
                    if (t_beg > 0 and t_end > t_beg) {
                        det.component.title = ctx.str(t_beg)[0 .. t_end - t_beg];
                    }
                }
            },
            c.BlockType.template => {
                const slot_idx: c_int = @intCast(block.bits.data);
                if (slot_idx >= 0 and slot_idx < @as(c_int, @intCast(ctx.slot_info.items.len))) {
                    const info = &ctx.slot_info.items[@intCast(slot_idx)];
                    const name_beg = info.name_beg;
                    const name_end = info.name_end;

                    comp_name_build = .{};
                    md_build_attribute(ctx, ctx.str(name_beg), name_end - name_beg, 0, &det.template.name, &comp_name_build) catch {
                        md_free_attribute(ctx, &comp_name_build);
                        return -1;
                    };
                    clean_component_detail = true;
                }
            },
            c.BlockType.alert => {
                const alert_idx: c_int = @intCast(block.bits.data);
                if (alert_idx >= 0 and alert_idx < @as(c_int, @intCast(ctx.block_alert_info.items.len))) {
                    const info = &ctx.block_alert_info.items[@intCast(alert_idx)];
                    const type_beg = info.type_beg;
                    const type_end = info.type_end;

                    comp_name_build = .{};
                    md_build_attribute(ctx, ctx.str(type_beg), type_end - type_beg, 0, &det.alert.type_name, &comp_name_build) catch {
                        md_free_attribute(ctx, &comp_name_build);
                        return -1;
                    };
                    clean_component_detail = true;
                }
            },
            else => {},
        }

        if ((block.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER))) != 0) {
            if ((block.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER_CLOSER))) != 0) {
                ret = mdLeaveBlock(ctx, &det);
                if (ret != 0) {
                    if (clean_component_detail) md_free_attribute(ctx, &comp_name_build);
                    return ret;
                }

                // The `> 0` is hardening, not a known repro: the block layer is
                // believed to keep openers and closers balanced. But `items.len`
                // is a `usize`, so a lone closer would wrap it to ~0 and
                // `md_process_leaf_block`'s `containers.items[nContainers() - 1]`
                // would then read out of a slice whose length is nonsense —
                // unchecked in the shipping ReleaseFast build.
                if ((btype == c.BlockType.ul or btype == c.BlockType.ol or btype == c.BlockType.quote or btype == c.BlockType.component or btype == c.BlockType.template or btype == c.BlockType.alert) and
                    ctx.containers.items.len > 0)
                    ctx.containers.items.len -= 1;
            }

            if ((block.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER_OPENER))) != 0) {
                ret = mdEnterBlock(ctx, &det);
                if (ret != 0) {
                    if (clean_component_detail) md_free_attribute(ctx, &comp_name_build);
                    return ret;
                }

                if (btype == c.BlockType.ul or btype == c.BlockType.ol or btype == c.BlockType.quote or
                    btype == c.BlockType.component or btype == c.BlockType.template or btype == c.BlockType.alert)
                {
                    const is_loose: u8 = if (btype == c.BlockType.ul or btype == c.BlockType.ol)
                        @intCast(block.bits.flags & @as(u8, @truncate(MD_BLOCK_LOOSE_LIST)))
                    else
                        1;
                    // Reuse phase: capacity already covers the max nesting from the
                    // block-parse pass, so this append never actually reallocs.
                    ctx.containers.append(ctx.alloc, .{ .is_loose = is_loose }) catch {
                        if (clean_component_detail) md_free_attribute(ctx, &comp_name_build);
                        return -1;
                    };
                }
            }
        } else {
            ret = md_process_leaf_block(ctx, block, block_fold_attrs);
            if (ret < 0) {
                if (clean_component_detail) md_free_attribute(ctx, &comp_name_build);
                return ret;
            }

            if (btype == c.BlockType.code or btype == c.BlockType.html or btype == c.BlockType.frontmatter)
                byte_off += @as(usize, block.n_lines) * @sizeOf(MD_VERBATIMLINE)
            else
                byte_off += @as(usize, block.n_lines) * @sizeOf(MD_LINE);
        }

        if (clean_component_detail) {
            md_free_attribute(ctx, &comp_name_build);
            clean_component_detail = false;
        }

        byte_off += @sizeOf(MD_BLOCK);
    }

    ctx.n_block_bytes = 0;
    ctx.last_block_off = 0;

    return ret;
}

// md4x.c ~7866. Promoted from the Pass-D _test_process_line draft (byte-for-byte
// the C md_process_line, but driving the real SAX-callback-free block layer).
pub fn md_process_line(ctx: *MD_CTX, p_pivot_line: *[*c]const MD_LINE_ANALYSIS, line: *MD_LINE_ANALYSIS) c_int {
    const pivot_line = p_pivot_line.*;
    var ret: c_int = 0;

    // Blank line ends current leaf block.
    if (line.type == .blank) {
        ret = md_end_current_block(ctx);
        if (ret < 0) return ret;
        p_pivot_line.* = &md_dummy_blank_line;
        return 0;
    }

    if (line.enforce_new_block) {
        ret = md_end_current_block(ctx);
        if (ret < 0) return ret;
    }

    // Some line types form block on their own.
    if (line.type == .hr or line.type == .atx_header) {
        ret = md_end_current_block(ctx);
        if (ret < 0) return ret;
        ret = md_start_new_block(ctx, line);
        if (ret < 0) return ret;
        ret = md_add_line_into_current_block(ctx, line);
        if (ret < 0) return ret;
        ret = md_end_current_block(ctx);
        if (ret < 0) return ret;
        p_pivot_line.* = &md_dummy_blank_line;
        return 0;
    }

    // .setext_underline changes meaning of current block and ends it.
    if (line.type == .setext_underline) {
        ctx.current_block.*.setType(c.BlockType.h);
        ctx.current_block.*.bits.data = @truncate(line.data);
        ctx.current_block.*.bits.flags |= @as(u8, @truncate(MD_BLOCK_SETEXT_HEADER));
        ret = md_add_line_into_current_block(ctx, line);
        if (ret < 0) return ret;
        ret = md_end_current_block(ctx);
        if (ret < 0) return ret;
        if (ctx.current_block == null) {
            p_pivot_line.* = &md_dummy_blank_line;
        } else {
            line.type = .text;
            p_pivot_line.* = line;
        }
        return 0;
    }

    // .table_underline changes meaning of current block.
    if (line.type == .table_underline) {
        // Only the block's last line is the header row. If the block holds more,
        // the table is interrupting a paragraph: split the earlier lines off as
        // a paragraph of their own first.
        if (ctx.current_block.*.n_lines > 1) {
            ret = blocks.md_split_off_table_header(ctx);
            if (ret < 0) return ret;
        }
        ctx.current_block.*.setType(c.BlockType.table);
        ctx.current_block.*.bits.data = @truncate(line.data);
        @as(*MD_LINE_ANALYSIS, @constCast(pivot_line)).type = .table;
        ret = md_add_line_into_current_block(ctx, line);
        if (ret < 0) return ret;
        return 0;
    }

    // The current block also ends if the line has different type.
    if (line.type != pivot_line.*.type) {
        ret = md_end_current_block(ctx);
        if (ret < 0) return ret;
    }

    // The current line may start a new block.
    if (ctx.current_block == null) {
        ret = md_start_new_block(ctx, line);
        if (ret < 0) return ret;
        p_pivot_line.* = line;
    }

    // In all other cases the line is just a continuation of the current block.
    ret = md_add_line_into_current_block(ctx, line);
    if (ret < 0) return ret;

    return ret;
}

// Emit one footnote definition. Its body is re-parsed here, outside the block
// loop, from the heap-copied MD_LINE array captured by md_is_footnote_definition
// — so it is NOT wrapped in a `p` block: the inlines land directly inside
// `footnote_def`, matching md4c. md4c a8b0d3e.
fn md_process_footnote_def(ctx: *MD_CTX, def: *const types.MD_FOOTNOTE_DEF) c_int {
    var label_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.BlockFootnoteDefDetail = .{ .id = def.index, .ref_count = def.ref_count };
    var ret: c_int = 0;

    md_build_attribute(ctx, def.label, def.label_size, 0, &det.label, &label_build) catch {
        ret = -1;
    };

    if (ret == 0) {
        const d: c.BlockDetail = .{ .footnote_def = det };
        ret = mdEnterBlock(ctx, &d);
        if (ret == 0) ret = md_process_normal_block_contents(ctx, def.content_lines);
        if (ret == 0) ret = mdLeaveBlock(ctx, &d);
    }

    md_free_attribute(ctx, &label_build);
    return ret;
}

fn md_footnote_def_less_by_index(_: void, a: types.MD_FOOTNOTE_DEF, b: types.MD_FOOTNOTE_DEF) bool {
    // Unreferenced defs (index == 0) always sort after referenced ones.
    if (a.index == 0) return false;
    if (b.index == 0) return true;
    return a.index < b.index;
}

// Emit the footnote definitions that were actually referenced, in
// first-reference order, wrapped in one `footnote_def_section`. Called from
// md_process_doc AFTER md_process_all_blocks — this deferred emission is why the
// definition lines are copied to the heap rather than left in the block arena,
// which md_process_all_blocks has already consumed by now. md4c a8b0d3e.
fn md_process_footnote_defs(ctx: *MD_CTX) c_int {
    if (ctx.footnote_defs.items.len == 0 or ctx.next_footnote_index == 0)
        return 0;

    // Sort by index so emission follows reference order. Sorting in place is
    // safe: every lookup is done by now, and md_free_footnote_defs only needs
    // the array's bounds (unchanged), not its order.
    std.sort.pdq(types.MD_FOOTNOTE_DEF, ctx.footnote_defs.items, {}, md_footnote_def_less_by_index);

    var ret = mdEnterBlock(ctx, &.{ .footnote_def_section = {} });
    if (ret != 0) return ret;

    for (ctx.footnote_defs.items) |*def| {
        if (def.index == 0) break;
        ret = md_process_footnote_def(ctx, def);
        if (ret != 0) return ret;
    }

    return mdLeaveBlock(ctx, &.{ .footnote_def_section = {} });
}

// md4x.c ~7942.
pub fn md_process_doc(ctx: *MD_CTX) c_int {
    var pivot_line: [*c]const MD_LINE_ANALYSIS = &md_dummy_blank_line;
    // Zero-initialize the line analysis buffers (matches the FIXED md4x.c
    // memset). md_analyze_line may leave fields unwritten on certain
    // orphaned-component / setext-underline edge cases.
    var line_buf = [2]MD_LINE_ANALYSIS{ .{}, .{} };
    var line: *MD_LINE_ANALYSIS = &line_buf[0];
    var off: OFF = 0;
    var ret: c_int = 0;

    ret = mdEnterBlock(ctx, &.{ .doc = {} });
    if (ret != 0) return ret;

    while (off < ctx.size) {
        if (@as([*c]const MD_LINE_ANALYSIS, line) == pivot_line)
            line = if (line == &line_buf[0]) &line_buf[1] else &line_buf[0];

        ret = md_analyze_line(ctx, off, &off, pivot_line, line);
        if (ret < 0) return ret;
        ret = md_process_line(ctx, &pivot_line, line);
        if (ret < 0) return ret;
    }

    _ = md_end_current_block(ctx);

    ret = md_build_ref_def_hashtable(ctx);
    if (ret < 0) return ret;
    ret = md_build_footnote_def_hashtable(ctx);
    if (ret < 0) return ret;

    // Process all blocks.
    ret = md_leave_child_containers(ctx, 0);
    if (ret < 0) return ret;
    ret = md_process_all_blocks(ctx);
    if (ret < 0) return ret;

    // Emit the referenced footnote definitions, in reference order.
    ret = md_process_footnote_defs(ctx);
    if (ret < 0) return ret;

    ret = mdLeaveBlock(ctx, &.{ .doc = {} });
    if (ret != 0) return ret;

    return ret;
}
