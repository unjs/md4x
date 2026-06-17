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
const TRUE = types.TRUE;
const FALSE = types.FALSE;
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

const MD_ATTRIBUTE_BUILD = util.MD_ATTRIBUTE_BUILD;
const md_build_attribute = util.md_build_attribute;
const md_free_attribute = util.md_free_attribute;
const md_text_with_null_replacement = util.md_text_with_null_replacement;
const memmove = util.memmove;

const md_build_ref_def_hashtable = refdefs.md_build_ref_def_hashtable;

const mdText = inlines.mdText;
const md_analyze_inlines = inlines.md_analyze_inlines;
const md_mark_get_ptr = inlines.md_mark_get_ptr;
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
pub inline fn mdEnterBlock(ctx: *MD_CTX, ty: c.MD_BLOCKTYPE, detail: ?*anyopaque) c_int {
    const ret = ctx.parser.enter_block.?(ty, detail, ctx.userdata);
    if (ret != 0) ctx.log("Aborted from enter_block() callback.");
    return ret;
}

pub inline fn mdLeaveBlock(ctx: *MD_CTX, ty: c.MD_BLOCKTYPE, detail: ?*anyopaque) c_int {
    const ret = ctx.parser.leave_block.?(ty, detail, ctx.userdata);
    if (ret != 0) ctx.log("Aborted from leave_block() callback.");
    return ret;
}

// MD_TEXT_INSECURE — NUL-replacement text emission (md4x.c ~543).
pub inline fn mdTextInsecure(ctx: *MD_CTX, ty: c.MD_TEXTTYPE, str: [*c]const CHAR, size: SZ) c_int {
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
pub fn md_analyze_table_alignment(ctx: *MD_CTX, beg: OFF, end: OFF, align_arr: [*c]c.MD_ALIGN, n_align_in: c_int) void {
    const align_map = [_]c.MD_ALIGN{ c.MD_ALIGN_DEFAULT, c.MD_ALIGN_LEFT, c.MD_ALIGN_RIGHT, c.MD_ALIGN_CENTER };
    var off: OFF = beg;
    var n_align = n_align_in;
    var ai: usize = 0;

    while (n_align > 0) {
        var index: usize = 0; // index into align_map[]

        while (ctx.ch(off) != '-') off += 1;
        if (off > beg and ctx.ch(off - 1) == ':') index |= 1;
        while (off < end and ctx.ch(off) == '-') off += 1;
        if (off < end and ctx.ch(off) == ':') index |= 2;

        align_arr[ai] = align_map[index];
        ai += 1;
        n_align -= 1;
    }
}

// md4x.c ~5232.
pub fn md_process_table_cell(ctx: *MD_CTX, cell_type: c.MD_BLOCKTYPE, align_val: c.MD_ALIGN, beg_in: OFF, end_in: OFF) c_int {
    var line: MD_LINE = undefined;
    var det: c.MD_BLOCK_TD_DETAIL = undefined;
    var ret: c_int = 0;
    var beg = beg_in;
    var end = end_in;

    while (beg < end and ctx.isWhitespace(beg)) beg += 1;
    while (end > beg and ctx.isWhitespace(end - 1)) end -= 1;

    det.@"align" = align_val;
    line.beg = beg;
    line.end = end;

    ret = mdEnterBlock(ctx, cell_type, &det);
    if (ret != 0) return ret;
    ret = md_process_normal_block_contents(ctx, @as([*]const MD_LINE, @ptrCast(&line))[0..1]);
    if (ret < 0) return ret;
    ret = mdLeaveBlock(ctx, cell_type, &det);
    if (ret != 0) return ret;
    return ret;
}

// md4x.c ~5256.
pub fn md_process_table_row(ctx: *MD_CTX, cell_type: c.MD_BLOCKTYPE, beg: OFF, end: OFF, align_arr: [*c]const c.MD_ALIGN, col_count: c_int) c_int {
    var line: MD_LINE = undefined;
    var pipe_offs: [*c]OFF = null;
    var ret: c_int = 0;

    line.beg = beg;
    line.end = end;

    // Break the line into table cells by identifying pipe characters.
    ret = md_analyze_inlines(ctx, @as([*]const MD_LINE, @ptrCast(&line))[0..1], TRUE);
    if (ret < 0) {
        ctx.table_cell_boundaries_head = -1;
        ctx.table_cell_boundaries_tail = -1;
        return ret;
    }

    const n: c_int = ctx.n_table_cell_boundaries + 2;
    pipe_offs = @ptrCast(@alignCast(std.c.malloc(@as(usize, @intCast(n)) * @sizeOf(OFF))));
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
        while (i >= 0) : (i = ctx.marks[@intCast(i)].next) {
            pipe_offs[@intCast(j)] = ctx.marks[@intCast(i)].end;
            j += 1;
        }
    }
    pipe_offs[@intCast(j)] = end + 1;
    j += 1;

    // Process cells.
    ret = mdEnterBlock(ctx, c.MD_BLOCK_TR, null);
    if (ret != 0) {
        std.c.free(pipe_offs);
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
                    std.c.free(pipe_offs);
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
            std.c.free(pipe_offs);
            ctx.table_cell_boundaries_head = -1;
            ctx.table_cell_boundaries_tail = -1;
            return ret;
        }
    }
    ret = mdLeaveBlock(ctx, c.MD_BLOCK_TR, null);

    std.c.free(pipe_offs);
    ctx.table_cell_boundaries_head = -1;
    ctx.table_cell_boundaries_tail = -1;
    return ret;
}

// md4x.c ~5311.
pub fn md_process_table_block_contents(ctx: *MD_CTX, col_count: c_int, lines: []const MD_LINE) c_int {
    var align_arr: [*c]c.MD_ALIGN = null;
    var ret: c_int = 0;

    align_arr = @ptrCast(@alignCast(std.c.malloc(@as(usize, @intCast(col_count)) * @sizeOf(c.MD_ALIGN))));
    if (align_arr == null) {
        ctx.log("malloc() failed.");
        return -1;
    }

    md_analyze_table_alignment(ctx, lines[1].beg, lines[1].end, align_arr, col_count);

    ret = mdEnterBlock(ctx, c.MD_BLOCK_THEAD, null);
    if (ret != 0) {
        std.c.free(align_arr);
        return ret;
    }
    ret = md_process_table_row(ctx, c.MD_BLOCK_TH, lines[0].beg, lines[0].end, align_arr, col_count);
    if (ret < 0) {
        std.c.free(align_arr);
        return ret;
    }
    ret = mdLeaveBlock(ctx, c.MD_BLOCK_THEAD, null);
    if (ret != 0) {
        std.c.free(align_arr);
        return ret;
    }

    if (lines.len > 2) {
        ret = mdEnterBlock(ctx, c.MD_BLOCK_TBODY, null);
        if (ret != 0) {
            std.c.free(align_arr);
            return ret;
        }
        var line_index: MD_SIZE = 2;
        while (line_index < lines.len) : (line_index += 1) {
            ret = md_process_table_row(ctx, c.MD_BLOCK_TD, lines[line_index].beg, lines[line_index].end, align_arr, col_count);
            if (ret < 0) {
                std.c.free(align_arr);
                return ret;
            }
        }
        ret = mdLeaveBlock(ctx, c.MD_BLOCK_TBODY, null);
        if (ret != 0) {
            std.c.free(align_arr);
            return ret;
        }
    }

    std.c.free(align_arr);
    return ret;
}

// md4x.c ~5394.
pub fn md_process_normal_block_contents(ctx: *MD_CTX, lines: []const MD_LINE) c_int {
    var ret: c_int = md_analyze_inlines(ctx, lines, FALSE);
    if (ret >= 0) ret = md_process_inlines(ctx, lines);

    // Free any temporary memory blocks stored within some dummy marks.
    var i: c_int = ctx.ptr_stack.top;
    while (i >= 0) : (i = ctx.marks[@intCast(i)].next) {
        std.c.free(md_mark_get_ptr(ctx, i));
    }
    ctx.ptr_stack.top = -1;

    return ret;
}

// md4x.c ~5412.
pub fn md_process_verbatim_block_contents(ctx: *MD_CTX, text_type: c.MD_TEXTTYPE, lines: []const MD_VERBATIMLINE) c_int {
    const indent_chunk_str: [*:0]const CHAR = "                ";
    const indent_chunk_size: SZ = 16;
    var ret: c_int = 0;

    var line_index: MD_SIZE = 0;
    while (line_index < lines.len) : (line_index += 1) {
        const line = &lines[line_index];
        var indent: c_int = @intCast(line.indent);

        // Output code indentation.
        while (indent > @as(c_int, @intCast(indent_chunk_size))) {
            ret = mdText(ctx, text_type, indent_chunk_str, indent_chunk_size);
            if (ret != 0) return ret;
            indent -= @intCast(indent_chunk_size);
        }
        if (indent > 0) {
            ret = mdText(ctx, text_type, indent_chunk_str, @intCast(indent));
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

    return md_process_verbatim_block_contents(ctx, c.MD_TEXT_CODE, lines);
}

// md4x.c ~5473. Parse highlight ranges string (e.g. "1-3,5,7") into expanded
// array. Returns heap-allocated array (null on empty/error) and sets out_count.
pub fn md_parse_highlights(str: [*c]const CHAR, size: SZ, out_count: *c_uint) [*c]c_uint {
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
                const tmp: [*c]c_uint = @ptrCast(@alignCast(std.c.realloc(arr, @as(usize, new_cap) * @sizeOf(c_uint))));
                if (tmp == null) {
                    std.c.free(arr);
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
        std.c.free(arr);
        return null;
    }
    out_count.* = count;
    return arr;
}

// md4x.c ~5544.
pub fn md_setup_fenced_code_detail(ctx: *MD_CTX, block: *const MD_BLOCK, det: *c.MD_BLOCK_CODE_DETAIL, info_build: *MD_ATTRIBUTE_BUILD, lang_build: *MD_ATTRIBUTE_BUILD, filename_build: *MD_ATTRIBUTE_BUILD) c_int {
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
            det.highlights = md_parse_highlights(ctx.str(hl_beg), hl_end - hl_beg, &det.highlight_count);
        }

        // Build meta from remaining text (exclude [..] and {..} regions).
        {
            var meta_len: SZ = 0;
            const meta_buf: [*c]CHAR = @ptrCast(@alignCast(std.c.malloc(@as(usize, end - rest_beg + 1) * @sizeOf(CHAR))));
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
                const meta_copy: [*c]CHAR = @ptrCast(@alignCast(std.c.malloc(@as(usize, meta_len + 1) * @sizeOf(CHAR))));
                if (meta_copy == null) {
                    std.c.free(meta_buf);
                    ctx.log("malloc() failed.");
                    return -1;
                }
                @memcpy(meta_copy[0..meta_len], meta_buf[0..meta_len]);
                meta_copy[meta_len] = 0;
                det.meta = meta_copy;
                det.meta_size = @intCast(meta_len);
            }

            std.c.free(meta_buf);
        }
    }

    return 0;
}

// md4x.c ~5714.
pub fn md_process_leaf_block(ctx: *MD_CTX, block: *const MD_BLOCK) c_int {
    const DetUnion = extern union {
        header: c.MD_BLOCK_H_DETAIL,
        code: c.MD_BLOCK_CODE_DETAIL,
        table: c.MD_BLOCK_TABLE_DETAIL,
    };
    var det: DetUnion = std.mem.zeroes(DetUnion);
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

    const btype = block.getType();
    const block_lines: [*]const MD_BLOCK = @ptrCast(block);

    switch (btype) {
        c.MD_BLOCK_H => det.header.level = block.bits.data,
        c.MD_BLOCK_CODE => {
            // For fenced code block, we may need to set the info string.
            if (block.bits.data != 0) {
                det.code = std.mem.zeroes(c.MD_BLOCK_CODE_DETAIL);
                clean_fence_code_detail = true;
                ret = md_setup_fenced_code_detail(ctx, block, &det.code, &info_build, &lang_build, &filename_build);
                if (ret < 0) {
                    md_free_attribute(ctx, &info_build);
                    md_free_attribute(ctx, &lang_build);
                    md_free_attribute(ctx, &filename_build);
                    std.c.free(@ptrCast(@constCast(det.code.meta)));
                    std.c.free(@ptrCast(@constCast(det.code.highlights)));
                    return ret;
                }
            }
        },
        c.MD_BLOCK_TABLE => {
            det.table.col_count = block.bits.data;
            det.table.head_row_count = 1;
            det.table.body_row_count = block.n_lines - 2;
        },
        else => {},
    }

    if (!is_in_tight_list or btype != c.MD_BLOCK_P) {
        ret = mdEnterBlock(ctx, btype, &det);
        if (ret != 0) {
            if (clean_fence_code_detail) {
                md_free_attribute(ctx, &info_build);
                md_free_attribute(ctx, &lang_build);
                md_free_attribute(ctx, &filename_build);
                std.c.free(@ptrCast(@constCast(det.code.meta)));
                std.c.free(@ptrCast(@constCast(det.code.highlights)));
            }
            return ret;
        }
    }

    // Process the block contents according to its type.
    switch (btype) {
        c.MD_BLOCK_HR => {},
        c.MD_BLOCK_CODE => ret = md_process_code_block_contents(ctx, @intFromBool(block.bits.data != 0), @as([*]const MD_VERBATIMLINE, @ptrCast(@alignCast(block_lines + 1)))[0..block.n_lines]),
        c.MD_BLOCK_HTML => ret = md_process_verbatim_block_contents(ctx, c.MD_TEXT_HTML, @as([*]const MD_VERBATIMLINE, @ptrCast(@alignCast(block_lines + 1)))[0..block.n_lines]),
        c.MD_BLOCK_FRONTMATTER => {
            // Skip the opening fence line (first line is the --- opener).
            const vlines: [*]const MD_VERBATIMLINE = @ptrCast(@alignCast(block_lines + 1));
            ret = md_process_verbatim_block_contents(ctx, c.MD_TEXT_NORMAL, (vlines + 1)[0 .. block.n_lines - 1]);
        },
        c.MD_BLOCK_TABLE => ret = md_process_table_block_contents(ctx, @intCast(block.bits.data), @as([*]const MD_LINE, @ptrCast(@alignCast(block_lines + 1)))[0..block.n_lines]),
        else => ret = md_process_normal_block_contents(ctx, @as([*]const MD_LINE, @ptrCast(@alignCast(block_lines + 1)))[0..block.n_lines]),
    }
    if (ret < 0) {
        if (clean_fence_code_detail) {
            md_free_attribute(ctx, &info_build);
            md_free_attribute(ctx, &lang_build);
            md_free_attribute(ctx, &filename_build);
            std.c.free(@ptrCast(@constCast(det.code.meta)));
            std.c.free(@ptrCast(@constCast(det.code.highlights)));
        }
        return ret;
    }

    if (!is_in_tight_list or btype != c.MD_BLOCK_P) {
        ret = mdLeaveBlock(ctx, btype, &det);
        if (ret != 0) {
            if (clean_fence_code_detail) {
                md_free_attribute(ctx, &info_build);
                md_free_attribute(ctx, &lang_build);
                md_free_attribute(ctx, &filename_build);
                std.c.free(@ptrCast(@constCast(det.code.meta)));
                std.c.free(@ptrCast(@constCast(det.code.highlights)));
            }
            return ret;
        }
    }

    if (clean_fence_code_detail) {
        md_free_attribute(ctx, &info_build);
        md_free_attribute(ctx, &lang_build);
        md_free_attribute(ctx, &filename_build);
        std.c.free(@ptrCast(@constCast(det.code.meta)));
        std.c.free(@ptrCast(@constCast(det.code.highlights)));
    }
    return ret;
}

// md4x.c ~5814.
pub fn md_process_all_blocks(ctx: *MD_CTX) c_int {
    var byte_off: c_int = 0;
    var ret: c_int = 0;
    var comp_name_build: MD_ATTRIBUTE_BUILD = .{};
    var clean_component_detail: bool = false;

    // ctx.containers now is reused for tracking loose/tight lists.
    ctx.containers.clearRetainingCapacity();

    while (byte_off < ctx.n_block_bytes) {
        const block: *MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + @as(usize, @intCast(byte_off))));
        const DetUnion = extern union {
            ul: c.MD_BLOCK_UL_DETAIL,
            ol: c.MD_BLOCK_OL_DETAIL,
            li: c.MD_BLOCK_LI_DETAIL,
            component: c.MD_BLOCK_COMPONENT_DETAIL,
            tmpl: c.MD_BLOCK_TEMPLATE_DETAIL,
            alert: c.MD_BLOCK_ALERT_DETAIL,
        };
        var det: DetUnion = std.mem.zeroes(DetUnion);

        const btype = block.getType();
        switch (btype) {
            c.MD_BLOCK_UL => {
                det.ul.is_tight = if ((block.bits.flags & @as(u8, @truncate(MD_BLOCK_LOOSE_LIST))) != 0) FALSE else TRUE;
                det.ul.mark = @intCast(block.bits.data);
            },
            c.MD_BLOCK_OL => {
                det.ol.start = block.n_lines;
                det.ol.is_tight = if ((block.bits.flags & @as(u8, @truncate(MD_BLOCK_LOOSE_LIST))) != 0) FALSE else TRUE;
                det.ol.mark_delimiter = @intCast(block.bits.data);
            },
            c.MD_BLOCK_LI => {
                det.li.is_task = @intFromBool(block.bits.data != 0);
                det.li.task_mark = @intCast(block.bits.data);
                det.li.task_mark_offset = @intCast(block.n_lines);
            },
            c.MD_BLOCK_COMPONENT => {
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
                        det.component.raw_props = ctx.str(props_beg);
                        det.component.raw_props_size = props_end - props_beg;
                    }
                    if (t_beg > 0 and t_end > t_beg) {
                        det.component.title = ctx.str(t_beg);
                        det.component.title_size = t_end - t_beg;
                    }
                }
            },
            c.MD_BLOCK_TEMPLATE => {
                const slot_idx: c_int = @intCast(block.bits.data);
                if (slot_idx >= 0 and slot_idx < @as(c_int, @intCast(ctx.slot_info.items.len))) {
                    const info = &ctx.slot_info.items[@intCast(slot_idx)];
                    const name_beg = info.name_beg;
                    const name_end = info.name_end;

                    comp_name_build = .{};
                    md_build_attribute(ctx, ctx.str(name_beg), name_end - name_beg, 0, &det.tmpl.name, &comp_name_build) catch {
                        md_free_attribute(ctx, &comp_name_build);
                        return -1;
                    };
                    clean_component_detail = true;
                }
            },
            c.MD_BLOCK_ALERT => {
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
                ret = mdLeaveBlock(ctx, btype, &det);
                if (ret != 0) {
                    if (clean_component_detail) md_free_attribute(ctx, &comp_name_build);
                    return ret;
                }

                if (btype == c.MD_BLOCK_UL or btype == c.MD_BLOCK_OL or btype == c.MD_BLOCK_QUOTE or btype == c.MD_BLOCK_COMPONENT or btype == c.MD_BLOCK_TEMPLATE or btype == c.MD_BLOCK_ALERT)
                    ctx.containers.items.len -= 1;
            }

            if ((block.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER_OPENER))) != 0) {
                ret = mdEnterBlock(ctx, btype, &det);
                if (ret != 0) {
                    if (clean_component_detail) md_free_attribute(ctx, &comp_name_build);
                    return ret;
                }

                if (btype == c.MD_BLOCK_UL or btype == c.MD_BLOCK_OL or btype == c.MD_BLOCK_QUOTE or
                    btype == c.MD_BLOCK_COMPONENT or btype == c.MD_BLOCK_TEMPLATE or btype == c.MD_BLOCK_ALERT)
                {
                    const is_loose: u8 = if (btype == c.MD_BLOCK_UL or btype == c.MD_BLOCK_OL)
                        @intCast(block.bits.flags & @as(u8, @truncate(MD_BLOCK_LOOSE_LIST)))
                    else
                        @intFromBool(TRUE != 0);
                    // Reuse phase: capacity already covers the max nesting from the
                    // block-parse pass, so this append never actually reallocs.
                    ctx.containers.append(c_allocator, .{ .is_loose = is_loose }) catch {
                        if (clean_component_detail) md_free_attribute(ctx, &comp_name_build);
                        return -1;
                    };
                }
            }
        } else {
            ret = md_process_leaf_block(ctx, block);
            if (ret < 0) {
                if (clean_component_detail) md_free_attribute(ctx, &comp_name_build);
                return ret;
            }

            if (btype == c.MD_BLOCK_CODE or btype == c.MD_BLOCK_HTML or btype == c.MD_BLOCK_FRONTMATTER)
                byte_off += @intCast(block.n_lines * @sizeOf(MD_VERBATIMLINE))
            else
                byte_off += @intCast(block.n_lines * @sizeOf(MD_LINE));
        }

        if (clean_component_detail) {
            md_free_attribute(ctx, &comp_name_build);
            clean_component_detail = false;
        }

        byte_off += @sizeOf(MD_BLOCK);
    }

    ctx.n_block_bytes = 0;

    return ret;
}

// md4x.c ~7866. Promoted from the Pass-D _test_process_line draft (byte-for-byte
// the C md_process_line, but driving the real SAX-callback-free block layer).
pub fn md_process_line(ctx: *MD_CTX, p_pivot_line: *[*c]const MD_LINE_ANALYSIS, line: *MD_LINE_ANALYSIS) c_int {
    const pivot_line = p_pivot_line.*;
    var ret: c_int = 0;

    // Blank line ends current leaf block.
    if (line.type == .MD_LINE_BLANK) {
        ret = md_end_current_block(ctx);
        if (ret < 0) return ret;
        p_pivot_line.* = &md_dummy_blank_line;
        return 0;
    }

    if (line.enforce_new_block != 0) {
        ret = md_end_current_block(ctx);
        if (ret < 0) return ret;
    }

    // Some line types form block on their own.
    if (line.type == .MD_LINE_HR or line.type == .MD_LINE_ATXHEADER) {
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

    // MD_LINE_SETEXTUNDERLINE changes meaning of current block and ends it.
    if (line.type == .MD_LINE_SETEXTUNDERLINE) {
        ctx.current_block.*.setType(c.MD_BLOCK_H);
        ctx.current_block.*.bits.data = @truncate(line.data);
        ctx.current_block.*.bits.flags |= @as(u8, @truncate(MD_BLOCK_SETEXT_HEADER));
        ret = md_add_line_into_current_block(ctx, line);
        if (ret < 0) return ret;
        ret = md_end_current_block(ctx);
        if (ret < 0) return ret;
        if (ctx.current_block == null) {
            p_pivot_line.* = &md_dummy_blank_line;
        } else {
            line.type = .MD_LINE_TEXT;
            p_pivot_line.* = line;
        }
        return 0;
    }

    // MD_LINE_TABLEUNDERLINE changes meaning of current block.
    if (line.type == .MD_LINE_TABLEUNDERLINE) {
        ctx.current_block.*.setType(c.MD_BLOCK_TABLE);
        ctx.current_block.*.bits.data = @truncate(line.data);
        @as(*MD_LINE_ANALYSIS, @constCast(pivot_line)).type = .MD_LINE_TABLE;
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

    ret = mdEnterBlock(ctx, c.MD_BLOCK_DOC, null);
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

    // Process all blocks.
    ret = md_leave_child_containers(ctx, 0);
    if (ret < 0) return ret;
    ret = md_process_all_blocks(ctx);
    if (ret < 0) return ret;

    ret = mdLeaveBlock(ctx, c.MD_BLOCK_DOC, null);
    if (ret != 0) return ret;

    return ret;
}
