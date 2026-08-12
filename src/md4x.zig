// MD4X: Markdown parser for C
// (http://github.com/unjs/md4x)
//
// Copyright (c) 2026 Pooya Parsa <pooya@pi0.io>
// Copyright (c) 2016-2024 Martin Mitáš (original md4c)
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
// Zig port of src/md4x.c — byte-for-byte identical behavior. UTF-8 build only
// (MD4X_USE_UTF8). This file is built incrementally across several agent passes;
// subsystems are added in dependency order (see PARSER-PORT.md). Until the final
// pass wires it into build.zig, the build keeps using the C parser src/md4x.c.
//
// === Pass A: Foundation ===
// MD_CTX struct; char-class helpers (CH/STR/ISxxx, md_strchr); UTF-8 decode
// (md_decode_utf8/_before, md_decode_unicode); the unicode classifiers
// (whitespace/punct/fold) wired through unicode_tables.zig; growable buffers +
// MD_CHECK/MD_TEMP_BUFFER; entity hook (entity_lookup via entity.h); MD_ATTRIBUTE
// building + text-collecting buffer.

const std = @import("std");
const builtin = @import("builtin");
const utbl = @import("unicode_tables.zig");
const entity = @import("entity.zig");
const types = @import("parser/types.zig");
const util = @import("parser/util.zig");
const refdefs = @import("parser/refdefs.zig");
const inlines = @import("parser/inlines.zig");
const blocks = @import("parser/blocks.zig");
const process = @import("parser/process.zig");

// Re-expose the shared @cImport (md4x.h, entity.h). Defined once in types.zig.
pub const c = types.c;

const c_allocator = types.c_allocator;

// "These are omnipresent so lets save some typing." (md4x.c) ABI scalar aliases.
const CHAR = types.CHAR; // == c_char (signed char, 8-bit)
const SZ = types.SZ; // == c_uint (32-bit)
const OFF = types.OFF; // == c_uint (32-bit)
const MD_SIZE = types.MD_SIZE; // explicit alias used in a few signatures

// SZ_MAX / OFF_MAX (UTF-8 build: 32-bit unsigned).
const SZ_MAX = types.SZ_MAX;
const OFF_MAX = types.OFF_MAX;

// ----------------------------------------------------------------------------
// Boolean constants and small helpers (`SIZEOF_ARRAY` becomes `.len`).
// ----------------------------------------------------------------------------

// ----------------------------------------------------------------------------
// Internal types — re-exposed from parser/types.zig (pure module split).
// ----------------------------------------------------------------------------

const MD_LINETYPE = types.MD_LINETYPE;
const MD_LINE_ANALYSIS = types.MD_LINE_ANALYSIS;
const MD_LINE = types.MD_LINE;
const MD_VERBATIMLINE = types.MD_VERBATIMLINE;
const MD_BLOCK_CONTAINER_OPENER = types.MD_BLOCK_CONTAINER_OPENER;
const MD_BLOCK_CONTAINER_CLOSER = types.MD_BLOCK_CONTAINER_CLOSER;
const MD_BLOCK_CONTAINER = types.MD_BLOCK_CONTAINER;
const MD_BLOCK_LOOSE_LIST = types.MD_BLOCK_LOOSE_LIST;
const MD_BLOCK_SETEXT_HEADER = types.MD_BLOCK_SETEXT_HEADER;
const MD_BLOCK = types.MD_BLOCK;
const MD_CONTAINER = types.MD_CONTAINER;
const MD_MARK = types.MD_MARK;
const MarkFlags = types.MarkFlags;
const CODESPAN_MARK_MAXLEN = types.CODESPAN_MARK_MAXLEN;
const MD_REF_DEF = types.MD_REF_DEF;
const MD_REF_DEF_LIST = types.MD_REF_DEF_LIST;
const MD_MARKSTACK = types.MD_MARKSTACK;
const MD_BLOCK_COMPONENT_INFO = types.MD_BLOCK_COMPONENT_INFO;
const MD_SLOT_INFO = types.MD_SLOT_INFO;
const MD_BLOCK_ALERT_INFO = types.MD_BLOCK_ALERT_INFO;
const MD_INLINE_ATTR_INFO = types.MD_INLINE_ATTR_INFO;
const MD_CTX = types.MD_CTX;

// ----------------------------------------------------------------------------
// Low-level utilities — re-exposed from parser/util.zig (pure module split).
// ----------------------------------------------------------------------------

const uval = util.uval;
const ISIN_ = util.ISIN_;
const ISANYOF2_ = util.ISANYOF2_;
const ISANYOF3_ = util.ISANYOF3_;
const ISASCII_ = util.ISASCII_;
const ISBLANK_ = util.ISBLANK_;
const ISNEWLINE_ = util.ISNEWLINE_;
const ISWHITESPACE_ = util.ISWHITESPACE_;
const ISCNTRL_ = util.ISCNTRL_;
const ISPUNCT_ = util.ISPUNCT_;
const ISUPPER_ = util.ISUPPER_;
const ISLOWER_ = util.ISLOWER_;
const ISALPHA_ = util.ISALPHA_;
const ISDIGIT_ = util.ISDIGIT_;
const ISXDIGIT_ = util.ISXDIGIT_;
const ISALNUM_ = util.ISALNUM_;
const ISANYOF_ = util.ISANYOF_;
const md_strchr = util.md_strchr;
const md_ascii_case_eq = util.md_ascii_case_eq;
const md_ascii_eq = util.md_ascii_eq;
const md_text_with_null_replacement = util.md_text_with_null_replacement;
const md_temp_buffer = util.md_temp_buffer;
const MD_UNICODE_FOLD_INFO = util.MD_UNICODE_FOLD_INFO;
const md_unicode_bsearch = util.md_unicode_bsearch;
const md_is_unicode_whitespace = util.md_is_unicode_whitespace;
const md_is_unicode_punct = util.md_is_unicode_punct;
const md_get_unicode_fold_info = util.md_get_unicode_fold_info;
const IS_UTF8_LEAD1 = util.IS_UTF8_LEAD1;
const IS_UTF8_LEAD2 = util.IS_UTF8_LEAD2;
const IS_UTF8_LEAD3 = util.IS_UTF8_LEAD3;
const IS_UTF8_LEAD4 = util.IS_UTF8_LEAD4;
const IS_UTF8_TAIL = util.IS_UTF8_TAIL;
const md_decode_utf8 = util.md_decode_utf8;
const md_decode_utf8_before = util.md_decode_utf8_before;
const md_decode_unicode = util.md_decode_unicode;
const ISUNICODEWHITESPACE_ = util.ISUNICODEWHITESPACE_;
const md_merge_lines = util.md_merge_lines;
const md_merge_lines_alloc = util.md_merge_lines_alloc;
const md_skip_unicode_whitespace = util.md_skip_unicode_whitespace;
const md_is_hex_entity_contents = util.md_is_hex_entity_contents;
const md_is_dec_entity_contents = util.md_is_dec_entity_contents;
const md_is_named_entity_contents = util.md_is_named_entity_contents;
const md_is_entity_str = util.md_is_entity_str;
const md_is_entity = util.md_is_entity;
const MD_ATTRIBUTE_BUILD = util.MD_ATTRIBUTE_BUILD;
const MD_BUILD_ATTR_NO_ESCAPES = util.MD_BUILD_ATTR_NO_ESCAPES;
const md_build_attr_append_substr = util.md_build_attr_append_substr;
const md_free_attribute = util.md_free_attribute;
const md_build_attribute = util.md_build_attribute;
const md_lookup_line = util.md_lookup_line;
const c_cmp_fn = util.c_cmp_fn;
const qsort = util.qsort;
const bsearch = util.bsearch;
const memcmp = util.memcmp;
const strcspn = util.strcspn;
const memmove = util.memmove;
const c_malloc_array = util.c_malloc_array;
const c_realloc_array = util.c_realloc_array;

// ----------------------------------------------------------------------------
// Reference definitions + link recognizers — re-exposed from parser/refdefs.zig.
// ----------------------------------------------------------------------------

const MD_FNV1A_BASE = refdefs.MD_FNV1A_BASE;
const MD_FNV1A_PRIME = refdefs.MD_FNV1A_PRIME;
const md_fnv1a = refdefs.md_fnv1a;
const md_fnv1a_uint = refdefs.md_fnv1a_uint;
const md_link_label_hash = refdefs.md_link_label_hash;
const md_link_label_cmp_load_fold_info = refdefs.md_link_label_cmp_load_fold_info;
const md_link_label_cmp = refdefs.md_link_label_cmp;
const md_ref_def_list_items = refdefs.md_ref_def_list_items;
const md_ref_def_cmp = refdefs.md_ref_def_cmp;
const md_ref_def_cmp_for_sort = refdefs.md_ref_def_cmp_for_sort;
const md_build_ref_def_hashtable = refdefs.md_build_ref_def_hashtable;
const md_free_ref_def_hashtable = refdefs.md_free_ref_def_hashtable;
const md_lookup_ref_def = refdefs.md_lookup_ref_def;
const md_free_ref_defs = refdefs.md_free_ref_defs;
const MD_LINK_ATTR = refdefs.MD_LINK_ATTR;
const md_is_link_label = refdefs.md_is_link_label;
const md_is_link_destination_A = refdefs.md_is_link_destination_A;
const md_is_link_destination_B = refdefs.md_is_link_destination_B;
const md_is_link_destination = refdefs.md_is_link_destination;
const md_is_link_title = refdefs.md_is_link_title;
const md_is_link_reference_definition = refdefs.md_is_link_reference_definition;
const md_is_link_reference_definition_abort = refdefs.md_is_link_reference_definition_abort;
const md_is_link_reference = refdefs.md_is_link_reference;
const md_is_inline_link_spec = refdefs.md_is_inline_link_spec;
const md_is_autolink_uri = refdefs.md_is_autolink_uri;
const md_is_autolink_email = refdefs.md_is_autolink_email;
const md_is_autolink = refdefs.md_is_autolink;

// ----------------------------------------------------------------------------
// Inline mark engine + raw-HTML recognizers — re-exposed from parser/inlines.zig.
// ----------------------------------------------------------------------------

const mdText = inlines.mdText;
const md_analyze_inlines = inlines.md_analyze_inlines;
const md_analyze_link_contents = inlines.md_analyze_link_contents;
const md_build_mark_char_map = inlines.md_build_mark_char_map;
const md_collect_marks = inlines.md_collect_marks;
const md_is_html_any = inlines.md_is_html_any;
const md_is_html_tag = inlines.md_is_html_tag;
const md_mark_get_ptr = inlines.md_mark_get_ptr;
const md_process_inlines = inlines.md_process_inlines;
const md_resolve_links = inlines.md_resolve_links;

// ----------------------------------------------------------------------------
// Block/line analysis (Pass D) — re-exposed from parser/blocks.zig.
// ----------------------------------------------------------------------------

const md_add_line_into_current_block = blocks.md_add_line_into_current_block;
const md_analyze_line = blocks.md_analyze_line;
const md_dummy_blank_line = blocks.md_dummy_blank_line;
const md_end_current_block = blocks.md_end_current_block;
const md_is_container_mark = blocks.md_is_container_mark;
const md_is_html_block_end_condition = blocks.md_is_html_block_end_condition;
const md_is_html_block_start_condition = blocks.md_is_html_block_start_condition;
const md_leave_child_containers = blocks.md_leave_child_containers;
const md_line_indentation = blocks.md_line_indentation;
const md_start_new_block = blocks.md_start_new_block;

// ----------------------------------------------------------------------------
// Block-content processing (Subsystem E) — re-exposed from parser/process.zig.
// ----------------------------------------------------------------------------

const md_process_doc = process.md_process_doc;
const md_process_line = process.md_process_line;
const md_process_normal_block_contents = process.md_process_normal_block_contents;

// ============================================================================
//  Public entry point — the only non-static (exported) symbol of the parser.
// ============================================================================

pub fn md_parse(text: [*c]const CHAR, size: SZ, parser: *const c.Parser, userdata: ?*anyopaque) c_int {
    // Production always uses the libc-backed c_allocator. The allocator is split
    // out into md_parse_impl so native OOM tests can inject a
    // std.testing.FailingAllocator and sweep the full parse for crash/leak
    // freedom across every internal allocation (PLAN 8.5 / C "fuller OOM matrix").
    return md_parse_impl(c_allocator, text, size, parser, userdata);
}

fn md_parse_impl(alloc: std.mem.Allocator, text: [*c]const CHAR, size: SZ, parser: *const c.Parser, userdata: ?*anyopaque) c_int {
    // (The `abi_version` guard that used to stand here went away with the field
    // — it was a vestige of the dropped external C ABI.)

    // Setup context structure (zero-initialized like C's memset).
    var ctx: MD_CTX = .{ .alloc = alloc };
    ctx.text = text;
    ctx.size = size;
    ctx.parser = parser.*;
    ctx.userdata = userdata;
    ctx.code_indent_offset = if (ctx.parser.flags & c.MD_FLAG_NOINDENTEDCODEBLOCKS != 0) OFF_MAX else 4;
    md_build_mark_char_map(&ctx);
    ctx.doc_ends_with_newline = size > 0 and ISNEWLINE_(text[size - 1]);
    {
        const a: u64 = 16 * @as(u64, size);
        const b: u64 = 1024 * 1024;
        const m1: u64 = if (a < b) a else b;
        const m2: u64 = if (m1 < @as(u64, SZ_MAX)) m1 else @as(u64, SZ_MAX);
        ctx.max_ref_def_output = @intCast(m2);
    }

    // Reset all mark stacks and lists.
    var i: usize = 0;
    while (i < ctx.opener_stacks.len) : (i += 1) ctx.opener_stacks[i].top = -1;
    ctx.ptr_stack.top = -1;
    ctx.unresolved_link_head = -1;
    ctx.unresolved_link_tail = -1;
    ctx.table_cell_boundaries_head = -1;
    ctx.table_cell_boundaries_tail = -1;

    // All the work.
    const ret = md_process_doc(&ctx);

    // Clean-up. The hashtable holds pointers into ctx.ref_defs (simple buckets)
    // and reads the ref_defs address range to tell simple from complex buckets,
    // so it MUST be torn down before md_free_ref_defs frees/deinits ref_defs.
    md_free_ref_def_hashtable(&ctx);
    md_free_ref_defs(&ctx);
    util.free_array_a(CHAR, ctx.alloc, ctx.buffer, @intCast(ctx.alloc_buffer));
    ctx.marks.deinit(ctx.alloc);
    util.arena_free(ctx.alloc, ctx.block_bytes, @intCast(ctx.alloc_block_bytes));
    ctx.containers.deinit(ctx.alloc);
    ctx.block_component_info.deinit(ctx.alloc);
    ctx.slot_info.deinit(ctx.alloc);
    ctx.block_alert_info.deinit(ctx.alloc);
    ctx.inline_attrs.deinit(ctx.alloc);
    ctx.brace_pairs.deinit(ctx.alloc);

    return ret;
}

// ============================================================================
//  Suppress "unused" for foundation helpers consumed by later passes. These
//  reference-only declarations keep the file warning-clean while the rest of
//  the parser is ported. (No runtime effect.)
// ============================================================================
comptime {
    _ = &md_ascii_case_eq;
    _ = &md_ascii_eq;
    _ = &md_text_with_null_replacement;
    _ = &md_temp_buffer;
    _ = &md_get_unicode_fold_info;
    _ = &md_decode_unicode;
    _ = &md_merge_lines_alloc;
    _ = &md_skip_unicode_whitespace;
    _ = &md_is_entity;
    _ = &md_build_attribute;
    _ = &md_free_attribute;
    _ = &SZ_MAX;
    _ = &OFF_MAX;
    _ = &entity_lookup_wrap;
    // Pass B: ref-defs + link recognizers (consumed by Pass C/D/E).
    _ = &md_lookup_line;
    _ = &md_fnv1a;
    _ = &md_link_label_hash;
    _ = &md_link_label_cmp;
    _ = &md_build_ref_def_hashtable;
    _ = &md_free_ref_def_hashtable;
    _ = &md_lookup_ref_def;
    _ = &md_free_ref_defs;
    _ = &md_is_link_label;
    _ = &md_is_link_destination;
    _ = &md_is_link_title;
    _ = &md_is_link_reference_definition;
    _ = &md_is_link_reference;
    _ = &md_is_inline_link_spec;
    _ = &md_is_autolink;
    // Pass C: inline engine (consumed by Pass D/E).
    _ = &md_is_html_any;
    _ = &md_analyze_inlines;
    _ = &md_process_inlines;
    _ = &md_build_mark_char_map;
    _ = &md_collect_marks;
    _ = &md_resolve_links;
    _ = &md_analyze_link_contents;
}

// Entity hook — thin wrapper over entity.zig's entity_lookup. The
// inline engine (Pass C) calls this to resolve named entities to codepoints.
inline fn entity_lookup_wrap(name: [*c]const u8, name_size: usize) ?*const entity.ENTITY {
    return entity.entity_lookup(name, name_size);
}

// Test-only re-exports of internal foundation functions, used by the
// unit-differential harness (test/_pass-a-diff.zig). Not part of the parser's
// API surface; later passes may extend this. No runtime cost when unused.
// Test-only driver mirroring md_process_normal_block_contents wrapped with the
// md_parse setup. Splits `text[0..size]` into MD_LINE[] at '\n' (newline
// excluded), runs analyze+process, and performs the ptr_stack cleanup + frees.
// Returns the analyze/process return value.
fn _test_run_inline(parser: *const c.Parser, text: [*c]const CHAR, size: SZ) c_int {
    var ctx: MD_CTX = .{};
    ctx.text = text;
    ctx.size = size;
    ctx.parser = parser.*;
    ctx.userdata = null;
    ctx.code_indent_offset = if (ctx.parser.flags & c.MD_FLAG_NOINDENTEDCODEBLOCKS != 0) OFF_MAX else 4;
    md_build_mark_char_map(&ctx);
    ctx.doc_ends_with_newline = size > 0 and ISNEWLINE_(text[size - 1]);
    ctx.max_ref_def_output = 1024 * 1024;

    var i: usize = 0;
    while (i < ctx.opener_stacks.len) : (i += 1) ctx.opener_stacks[i].top = -1;
    ctx.ptr_stack.top = -1;
    ctx.unresolved_link_head = -1;
    ctx.unresolved_link_tail = -1;
    ctx.table_cell_boundaries_head = -1;
    ctx.table_cell_boundaries_tail = -1;

    const lines = c_malloc_array(MD_LINE, @as(usize, size) + 2);
    var n_lines: MD_SIZE = 0;
    var beg: OFF = 0;
    var off: OFF = 0;
    while (off <= size) : (off += 1) {
        if (off == size or text[off] == '\n') {
            lines[n_lines].beg = beg;
            lines[n_lines].end = off;
            n_lines += 1;
            beg = off + 1;
            if (off == size) break;
        }
    }
    if (n_lines == 0) {
        lines[0].beg = 0;
        lines[0].end = 0;
        n_lines = 1;
    }

    var ret = md_analyze_inlines(&ctx, lines[0..n_lines], false);
    if (ret == 0) ret = md_process_inlines(&ctx, lines[0..n_lines]);

    // ptr_stack cleanup (mirrors md_process_normal_block_contents).
    var pi: c_int = ctx.ptr_stack.top;
    while (pi >= 0) : (pi = ctx.marks.items[@intCast(pi)].next) {
        std.c.free(md_mark_get_ptr(&ctx, pi));
    }
    ctx.ptr_stack.top = -1;

    std.c.free(lines);
    // Hashtable before ref_defs: it indexes into ctx.ref_defs (see md_parse_impl).
    md_free_ref_def_hashtable(&ctx);
    md_free_ref_defs(&ctx);
    util.free_array_a(CHAR, ctx.alloc, ctx.buffer, @intCast(ctx.alloc_buffer));
    ctx.marks.deinit(ctx.alloc);
    ctx.inline_attrs.deinit(ctx.alloc);
    ctx.brace_pairs.deinit(ctx.alloc);
    return ret;
}

pub const _testing = struct {
    pub const fn_decode_utf8 = md_decode_utf8;
    pub const fn_decode_utf8_before = md_decode_utf8_before;
    pub const fn_is_unicode_whitespace = md_is_unicode_whitespace;
    pub const fn_is_unicode_punct = md_is_unicode_punct;
    pub const fn_get_unicode_fold_info = md_get_unicode_fold_info;
    pub const FoldInfo = MD_UNICODE_FOLD_INFO;
    pub const fn_strchr = md_strchr;
    pub const Ctx = MD_CTX;
    pub const AttrBuild = MD_ATTRIBUTE_BUILD;
    pub const fn_build_attribute = md_build_attribute;
    pub const fn_free_attribute = md_free_attribute;
    pub const fn_is_entity_str = md_is_entity_str;
    pub const Char = CHAR;

    // Pass B re-exports.
    pub const fn_fnv1a = md_fnv1a;
    pub const fn_link_label_hash = md_link_label_hash;
    pub const fn_link_label_cmp = md_link_label_cmp;
    pub const fn_lookup_line = md_lookup_line;
    pub const fn_build_ref_def_hashtable = md_build_ref_def_hashtable;
    pub const fn_free_ref_def_hashtable = md_free_ref_def_hashtable;
    pub const fn_lookup_ref_def = md_lookup_ref_def;
    pub const fn_free_ref_defs = md_free_ref_defs;
    pub const fn_is_link_label = md_is_link_label;
    pub const fn_is_link_destination = md_is_link_destination;
    pub const fn_is_link_title = md_is_link_title;
    pub const fn_is_link_reference_definition = md_is_link_reference_definition;
    pub const fn_is_link_reference = md_is_link_reference;
    pub const fn_is_inline_link_spec = md_is_inline_link_spec;
    pub const fn_is_autolink = md_is_autolink;
    pub const RefDef = MD_REF_DEF;
    pub const LinkAttr = MD_LINK_ATTR;
    pub const Line = MD_LINE;

    // Pass C re-exports.
    pub const fn_is_html_any = md_is_html_any;
    pub const fn_build_mark_char_map = md_build_mark_char_map;
    pub const fn_collect_marks = md_collect_marks;
    pub const fn_analyze_inlines = md_analyze_inlines;
    pub const fn_process_inlines = md_process_inlines;
    pub const Mark = MD_MARK;
    pub const fn_run_inline = _test_run_inline;
    pub const MarkFlags = types.MarkFlags;

    // Pass D re-exports (block / line analysis).
    pub const Block = MD_BLOCK;
    pub const Container = MD_CONTAINER;
    pub const LineAnalysis = MD_LINE_ANALYSIS;
    pub const LineType = MD_LINETYPE;
    pub const fn_analyze_line = md_analyze_line;
    pub const fn_is_html_block_start_condition = md_is_html_block_start_condition;
    pub const fn_is_html_block_end_condition = md_is_html_block_end_condition;
    pub const fn_is_container_mark = md_is_container_mark;
    pub const fn_line_indentation = md_line_indentation;
    pub const fn_run_analyze = _test_run_analyze;
};

// A local copy of md_process_line (officially Pass E glue, but needed here to
// drive md_analyze_line's pivot_line/current_block state exactly as the real
// md_process_doc would — otherwise classification would diverge). It mirrors
// md4x.c md_process_line() faithfully but emits NO SAX callbacks (we only want
// the block-accumulation side effects that feed back into classification).
fn _test_process_line(ctx: *MD_CTX, p_pivot_line: *[*c]const MD_LINE_ANALYSIS, line: *MD_LINE_ANALYSIS) c_int {
    const pivot_line = p_pivot_line.*;
    var ret: c_int = 0;

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

    if (line.type == .table_underline) {
        ctx.current_block.*.setType(c.BlockType.table);
        ctx.current_block.*.bits.data = @truncate(line.data);
        @as(*MD_LINE_ANALYSIS, @constCast(pivot_line)).type = .table;
        ret = md_add_line_into_current_block(ctx, line);
        if (ret < 0) return ret;
        return 0;
    }

    if (line.type != pivot_line.*.type) {
        ret = md_end_current_block(ctx);
        if (ret < 0) return ret;
    }

    if (ctx.current_block == null) {
        ret = md_start_new_block(ctx, line);
        if (ret < 0) return ret;
        p_pivot_line.* = line;
    }

    ret = md_add_line_into_current_block(ctx, line);
    if (ret < 0) return ret;

    return ret;
}

// Test-only driver: run the md_process_doc line loop (md_analyze_line +
// md_process_line) over an entire document, dumping every line's classification
// plus the live container-stack state via the supplied C output callback. Block
// PROCESSING is skipped — we only want classification + container/block-
// accumulation deltas to differential.
const TestOut = *const fn ([*c]const u8, usize, ?*anyopaque) callconv(.c) void;
fn _test_run_analyze(parser: *const c.Parser, text: [*c]const CHAR, size: SZ, out_fn: TestOut, out_ud: ?*anyopaque) c_int {
    var ctx: MD_CTX = .{};
    ctx.text = text;
    ctx.size = size;
    ctx.parser = parser.*;
    ctx.userdata = null;
    ctx.code_indent_offset = if (ctx.parser.flags & c.MD_FLAG_NOINDENTEDCODEBLOCKS != 0) OFF_MAX else 4;
    ctx.doc_ends_with_newline = size > 0 and ISNEWLINE_(text[size - 1]);
    ctx.max_ref_def_output = 1024 * 1024;

    var line_buf = [2]MD_LINE_ANALYSIS{ .{}, .{} };
    var pivot_line: [*c]const MD_LINE_ANALYSIS = &md_dummy_blank_line;
    var line: *MD_LINE_ANALYSIS = &line_buf[0];
    var off: OFF = 0;
    var ret: c_int = 0;
    var fbuf: [512]u8 = undefined;
    const emit = struct {
        fn f(buf: []u8, comptime fmt: []const u8, a: anytype, ofn: TestOut, oud: ?*anyopaque) void {
            const s = std.fmt.bufPrint(buf, fmt, a) catch return;
            ofn(s.ptr, s.len, oud);
        }
    }.f;

    while (off < ctx.size) {
        if (@as([*c]const MD_LINE_ANALYSIS, line) == pivot_line)
            line = if (line == &line_buf[0]) &line_buf[1] else &line_buf[0];

        ret = md_analyze_line(&ctx, off, &off, pivot_line, line);
        if (ret < 0) break;

        emit(&fbuf, "L type={d} data={d} enf={d} beg={d} end={d} indent={d} | nc={d} bcn={d} fm={d} llhle={d} llistwo={d} nblk={d} ncomp={d} nslot={d} nalert={d}\n", .{
            @intFromEnum(line.type),                        line.data,
            @intFromBool(line.enforce_new_block),           line.beg,
            line.end,                                       line.indent,
            ctx.nContainers(),                               ctx.block_component_nesting,
            ctx.frontmatter_state,                          @intFromBool(ctx.last_line_has_list_loosening_effect),
            @intFromBool(ctx.last_list_item_starts_with_two_blank_lines), ctx.n_block_bytes,
            @as(c_int, @intCast(ctx.block_component_info.items.len)), @as(c_int, @intCast(ctx.slot_info.items.len)),
            @as(c_int, @intCast(ctx.block_alert_info.items.len)),
        }, out_fn, out_ud);
        var i: c_int = 0;
        while (i < ctx.nContainers()) : (i += 1) {
            const co = &ctx.containers.items[@intCast(i)];
            emit(&fbuf, "  C[{d}] ch={d} loose={d} task={d} alert={d} start={d} mi={d} ci={d} bbo={d} tmo={d} cc={d} cfm={d}\n", .{
                i,                 uval(co.ch),      co.is_loose,    @intFromBool(co.is_task),
                @intFromBool(co.is_alert), co.start,   co.mark_indent, co.contents_indent,
                co.block_byte_off, co.task_mark_off, co.colon_count, co.comp_fm_state,
            }, out_fn, out_ud);
        }

        ret = _test_process_line(&ctx, &pivot_line, line);
        if (ret < 0) break;
    }

    if (ret == 0) {
        _ = md_end_current_block(&ctx);
        _ = md_leave_child_containers(&ctx, 0);
    }

    // Cleanup.
    util.arena_free(ctx.alloc, ctx.block_bytes, @intCast(ctx.alloc_block_bytes));
    ctx.containers.deinit(ctx.alloc);
    ctx.block_component_info.deinit(ctx.alloc);
    ctx.slot_info.deinit(ctx.alloc);
    ctx.block_alert_info.deinit(ctx.alloc);
    // Hashtable before ref_defs: it indexes into ctx.ref_defs (see md_parse_impl).
    md_free_ref_def_hashtable(&ctx);
    md_free_ref_defs(&ctx);
    util.free_array_a(CHAR, ctx.alloc, ctx.buffer, @intCast(ctx.alloc_buffer));
    ctx.marks.deinit(ctx.alloc);
    ctx.inline_attrs.deinit(ctx.alloc);
    ctx.brace_pairs.deinit(ctx.alloc);
    return ret;
}

// build.zig pins the test artifact to a SAFE optimize mode independently of the
// global -Doptimize default (which is .ReleaseFast, for the shipping
// artifacts). Bounds checks, @intCast range checks, overflow checks and
// `unreachable` panics are precisely what make the OOM sweep's "never a crash"
// assertion mean anything; under ReleaseFast it degrades to "no hard segfault".
// This test fails loudly if that pin is ever removed.
test "test artifact is built with runtime safety armed" {
    try std.testing.expect(std.debug.runtime_safety);
    try std.testing.expect(builtin.mode == .ReleaseSafe or builtin.mode == .Debug);
}

test "unicode classifiers wired to tables" {
    // ASCII fast-path sanity.
    try std.testing.expect(md_is_unicode_whitespace(' '));
    try std.testing.expect(!md_is_unicode_whitespace('a'));
    try std.testing.expect(md_is_unicode_punct('!'));
    // Non-ASCII via tables.
    try std.testing.expect(md_is_unicode_whitespace(0x00a0)); // NBSP
    try std.testing.expect(md_is_unicode_punct(0x2010)); // hyphen
    try std.testing.expect(!md_is_unicode_punct(0x0041)); // 'A' not punct
}

test "fold info ascii + non-ascii" {
    var info: MD_UNICODE_FOLD_INFO = .{};
    md_get_unicode_fold_info('A', &info);
    try std.testing.expectEqual(@as(c_uint, 'a'), info.codepoints[0]);
    try std.testing.expectEqual(@as(c_uint, 1), info.n_codepoints);
    md_get_unicode_fold_info(0x00df, &info); // ß → "ss"
    try std.testing.expectEqual(@as(c_uint, 2), info.n_codepoints);
    try std.testing.expectEqual(@as(c_uint, 0x73), info.codepoints[0]);
    try std.testing.expectEqual(@as(c_uint, 0x73), info.codepoints[1]);
}

test "fnv1a known vector" {
    // FNV-1a of "" is the base; of "a" is the standard 32-bit value.
    try std.testing.expectEqual(MD_FNV1A_BASE, md_fnv1a(MD_FNV1A_BASE, "", 0));
    const a = "a";
    try std.testing.expectEqual(@as(c_uint, 0xe40c292c), md_fnv1a(MD_FNV1A_BASE, a.ptr, 1));
    const foobar = "foobar";
    try std.testing.expectEqual(@as(c_uint, 0xbf9cf968), md_fnv1a(MD_FNV1A_BASE, foobar.ptr, 6));
}

// Regression: a callback aborting with a *non-zero* (here positive) return must
// stop the enclosing emitter immediately, matching md4c's MD_ENTER_BLOCK /
// MD_LEAVE_BLOCK / MD_TEXT macros (which abort on `ret != 0`). A prior version of
// the Zig port checked `ret < 0` at these call sites, so positive abort codes
// were logged-as-aborted but silently ignored and emission continued.
const AbortProbe = struct {
    text_calls: u32 = 0,
    enter_calls: u32 = 0,
    // The non-zero code a triggered callback returns. md_parse must propagate
    // this EXACT value (positive or negative) as its own return value.
    abort_code: c.CallbackResult = 1,
    abort_on_text: bool = false,
    abort_on_block_p: bool = false,
    abort_on_enter_block: bool = false,
    abort_on_leave_block: bool = false,
    abort_on_enter_span: bool = false,
    abort_on_leave_span: bool = false,
    // The DOC block is deliberately split out from abort_on_{enter,leave}_block:
    // md_process_doc's own bookends test `!= 0`, not `< 0`, so the doc block has
    // a DIFFERENT observable contract (see the doc-level test below).
    abort_on_enter_doc: bool = false,
    abort_on_leave_doc: bool = false,

    fn enterBlock(detail: *const c.BlockDetail, ud: ?*anyopaque) c.CallbackResult {
        const self: *AbortProbe = @ptrCast(@alignCast(ud.?));
        self.enter_calls += 1;
        if (self.abort_on_block_p and detail.* == .p) return self.abort_code;
        if (self.abort_on_enter_block and detail.* != .doc) return self.abort_code;
        if (self.abort_on_enter_doc and detail.* == .doc) return self.abort_code;
        return 0;
    }
    fn leaveBlock(detail: *const c.BlockDetail, ud: ?*anyopaque) c.CallbackResult {
        const self: *AbortProbe = @ptrCast(@alignCast(ud.?));
        if (self.abort_on_leave_block and detail.* != .doc) return self.abort_code;
        if (self.abort_on_leave_doc and detail.* == .doc) return self.abort_code;
        return 0;
    }
    fn enterSpan(detail: *const c.SpanDetail, ud: ?*anyopaque) c.CallbackResult {
        _ = detail;
        const self: *AbortProbe = @ptrCast(@alignCast(ud.?));
        if (self.abort_on_enter_span) return self.abort_code;
        return 0;
    }
    fn leaveSpan(detail: *const c.SpanDetail, ud: ?*anyopaque) c.CallbackResult {
        _ = detail;
        const self: *AbortProbe = @ptrCast(@alignCast(ud.?));
        if (self.abort_on_leave_span) return self.abort_code;
        return 0;
    }
    fn textCb(ty: c.TextType, str: []const CHAR, ud: ?*anyopaque) c.CallbackResult {
        _ = ty;
        _ = str;
        const self: *AbortProbe = @ptrCast(@alignCast(ud.?));
        self.text_calls += 1;
        if (self.abort_on_text) return self.abort_code;
        return 0;
    }

    fn parser(self: *AbortProbe) c.Parser {
        _ = self;
        var p: c.Parser = .{};
        p.flags = c.MD_DIALECT_ALL;
        p.enter_block = AbortProbe.enterBlock;
        p.leave_block = AbortProbe.leaveBlock;
        p.enter_span = AbortProbe.enterSpan;
        p.leave_span = AbortProbe.leaveSpan;
        p.text = AbortProbe.textCb;
        return p;
    }
};

test "callback abort: positive text() return stops verbatim emission" {
    var probe: AbortProbe = .{ .abort_on_text = true };
    var p = probe.parser();
    // A 4-line fenced code block. The verbatim emitter calls text() once per
    // line (+ a newline). With the fix, the first text()=1 aborts the emitter,
    // so exactly one text callback fires. With the old `< 0` check, every line
    // and newline would still be emitted (8 text calls).
    const input = "```\nA\nB\nC\nD\n```\n";
    _ = md_parse(@ptrCast(input), @intCast(input.len), &p, &probe);
    try std.testing.expectEqual(@as(u32, 1), probe.text_calls);
}

test "callback abort: positive enter_block() return stops block emission" {
    var probe: AbortProbe = .{ .abort_on_block_p = true };
    var p = probe.parser();
    // enter_block(MD_BLOCK_P) returns 1. With the fix, md_process_leaf_block
    // returns immediately, so the paragraph's inline text is never emitted.
    // With the old `< 0` check, inline processing would continue (1 text call).
    const input = "hello world\n";
    _ = md_parse(@ptrCast(input), @intCast(input.len), &p, &probe);
    try std.testing.expectEqual(@as(u32, 0), probe.text_calls);
}

// md_parse's abort-code propagation contract (md4c parity). md4c's internal
// MD_CHECK macro propagates only `< 0` (via `goto abort`), while the callback
// macros (MD_ENTER/LEAVE_BLOCK/SPAN, MD_TEXT) stop emission on any `!= 0`. The
// net OBSERVABLE behavior at md_parse, for each of the five callbacks:
//   - a NEGATIVE callback code propagates verbatim as md_parse's return value;
//   - a POSITIVE callback code stops emission but md_parse returns 0 (the
//     positive code is never caught by an MD_CHECK(<0) boundary and is then
//     overwritten by a subsequent leave_block/leave_span returning 0).
// All bundled renderers abort with negative codes, so they always observe their
// exact code. This matrix is locked here so the Phase 2.2 error-union refactor —
// which moves OOM (-1 runtime error) onto error{} while keeping callback-abort
// codes a DISTINCT non-error return path — cannot silently alter it.
test "callback abort: md_parse return-value matrix (md4c parity)" {
    const Case = struct { field: []const u8, input: []const u8 };
    const cases = [_]Case{
        .{ .field = "text", .input = "hello\n" },
        .{ .field = "enter_block", .input = "# heading\n" },
        .{ .field = "leave_block", .input = "para\n" },
        .{ .field = "enter_span", .input = "a **b** c\n" },
        .{ .field = "leave_span", .input = "a *b* c\n" },
    };
    inline for (cases) |cs| {
        // Negative code → propagated verbatim.
        var neg: AbortProbe = .{ .abort_code = -7 };
        @field(neg, "abort_on_" ++ cs.field) = true;
        var pn = neg.parser();
        try std.testing.expectEqual(@as(c_int, -7), md_parse(@ptrCast(cs.input.ptr), @intCast(cs.input.len), &pn, &neg));

        // Positive code → emission aborts, but md_parse returns 0.
        var pos: AbortProbe = .{ .abort_code = 5 };
        @field(pos, "abort_on_" ++ cs.field) = true;
        var pp = pos.parser();
        try std.testing.expectEqual(@as(c_int, 0), md_parse(@ptrCast(cs.input.ptr), @intCast(cs.input.len), &pp, &pos));
    }
}

// The DOC block is the documented EXCEPTION to the matrix above, and it is the
// code that is right, not the old wording. md_process_doc's own bookends test
// `!= 0`, not `< 0` (process.zig, `mdEnterBlock(ctx, &.{ .doc = {} })` and
// `mdLeaveBlock(ctx, &.{ .doc = {} })`), and md_parse returns md_process_doc's
// value verbatim. So a POSITIVE code on the .doc block DOES propagate:
// md_parse returns 5, not 0. That is genuine md4c parity — upstream's
// MD_ENTER_BLOCK / MD_LEAVE_BLOCK abort on `!= 0`, and md_process_doc is the
// one place the callback result is not funnelled through an MD_CHECK(< 0)
// boundary before reaching the caller.
//
// Do NOT "fix" those two `!= 0` tests into `< 0` to make the doc block match
// the intermediate boundaries: it would silently break md4c parity, and the
// corpus gate would stay green because every bundled renderer aborts with
// negative codes only. This test is the only guard in either direction.
test "callback abort: doc-level enter/leave propagate BOTH signs (md4c parity)" {
    const input = "# h\n\npara with *em*\n";
    inline for (.{ "enter_doc", "leave_doc" }) |field| {
        // Negative code → propagated verbatim (same as every other boundary).
        var neg: AbortProbe = .{ .abort_code = -7 };
        @field(neg, "abort_on_" ++ field) = true;
        var pn = neg.parser();
        try std.testing.expectEqual(@as(c_int, -7), md_parse(@ptrCast(input.ptr), @intCast(input.len), &pn, &neg));

        // Positive code → ALSO propagated verbatim (the doc-level exception;
        // at every other boundary this would be 0).
        var pos: AbortProbe = .{ .abort_code = 5 };
        @field(pos, "abort_on_" ++ field) = true;
        var pp = pos.parser();
        try std.testing.expectEqual(@as(c_int, 5), md_parse(@ptrCast(input.ptr), @intCast(input.len), &pp, &pos));
    }
}

// An abort on enter_block(.doc) must stop the parse before ANY content is
// emitted — the `!= 0` bookend returns straight out of md_process_doc.
test "callback abort: enter_block(.doc) emits nothing" {
    var probe: AbortProbe = .{ .abort_code = 5, .abort_on_enter_doc = true };
    var p = probe.parser();
    const input = "# h\n\npara\n";
    try std.testing.expectEqual(@as(c_int, 5), md_parse(@ptrCast(input), @intCast(input.len), &p, &probe));
    try std.testing.expectEqual(@as(u32, 0), probe.text_calls);
    try std.testing.expectEqual(@as(u32, 1), probe.enter_calls);
}

test "no callback abort: md_parse returns 0" {
    var probe: AbortProbe = .{};
    var p = probe.parser();
    const input = "# h\n\npara with *em* and `code`\n\n- list\n";
    try std.testing.expectEqual(@as(c_int, 0), md_parse(@ptrCast(input), @intCast(input.len), &p, &probe));
}

test "link label hash + cmp: whitespace & case-fold equivalence" {
    // Case-fold + whitespace collapse mean these labels are equivalent.
    const a = "Foo   Bar";
    const b = "foo bar";
    try std.testing.expectEqual(md_link_label_hash(a.ptr, a.len), md_link_label_hash(b.ptr, b.len));
    try std.testing.expectEqual(@as(c_int, 0), md_link_label_cmp(a.ptr, a.len, b.ptr, b.len));
    // Distinct labels differ.
    const c1 = "foo";
    const c2 = "bar";
    try std.testing.expect(md_link_label_cmp(c1.ptr, c1.len, c2.ptr, c2.len) != 0);
    // German sharp-s folds to "ss".
    const sharp = "stra\xc3\x9fe"; // straße
    const ss = "STRASSE";
    try std.testing.expectEqual(@as(c_int, 0), md_link_label_cmp(sharp.ptr, sharp.len, ss.ptr, ss.len));
}

test "decode_utf8: 1/2/3/4-byte sequences + truncation fallback" {
    var sz: SZ = 0;
    const one = "A";
    try std.testing.expectEqual(@as(c_uint, 0x41), md_decode_utf8(one.ptr, 1, &sz));
    try std.testing.expectEqual(@as(SZ, 1), sz);
    const two = "\xc3\xa9"; // é U+00E9
    try std.testing.expectEqual(@as(c_uint, 0xe9), md_decode_utf8(two.ptr, 2, &sz));
    try std.testing.expectEqual(@as(SZ, 2), sz);
    const three = "\xe2\x82\xac"; // € U+20AC
    try std.testing.expectEqual(@as(c_uint, 0x20ac), md_decode_utf8(three.ptr, 3, &sz));
    try std.testing.expectEqual(@as(SZ, 3), sz);
    const four = "\xf0\x9f\x98\x80"; // 😀 U+1F600
    try std.testing.expectEqual(@as(c_uint, 0x1f600), md_decode_utf8(four.ptr, 4, &sz));
    try std.testing.expectEqual(@as(SZ, 4), sz);
    // A multibyte lead with insufficient bytes decodes as a lone byte (size 1).
    // CHAR is signed, and the fallback returns uval(str[0]) verbatim, so a high
    // byte sign-extends exactly as C's (unsigned)(signed char) would (ABI parity).
    try std.testing.expectEqual(@as(c_uint, 0xffffffc3), md_decode_utf8(two.ptr, 1, &sz));
    try std.testing.expectEqual(@as(SZ, 1), sz);
}

test "growArray: 1.5x growth schedule + data survives realloc" {
    var arr: [*c]u32 = null;
    var alloc: c_int = 0;
    var n: c_int = 0;
    defer std.c.free(arr);

    // First push from empty grows to min_alloc.
    try util.growArray(u32, &arr, &alloc, n, 8);
    try std.testing.expectEqual(@as(c_int, 8), alloc);
    arr[@intCast(n)] = 100;
    n += 1;

    // No realloc until n reaches capacity.
    while (n < 8) : (n += 1) {
        try util.growArray(u32, &arr, &alloc, n, 8);
        try std.testing.expectEqual(@as(c_int, 8), alloc);
        arr[@intCast(n)] = @intCast(n);
    }

    // n == alloc == 8 → grow by 1.5x to 12.
    try util.growArray(u32, &arr, &alloc, n, 8);
    try std.testing.expectEqual(@as(c_int, 12), alloc);

    // Data written before the realloc must survive it.
    try std.testing.expectEqual(@as(u32, 100), arr[0]);
    try std.testing.expectEqual(@as(u32, 7), arr[7]);
}

// PLAN 8.5: the typed MD_CTX growable arrays now allocate through ctx.alloc, so
// a std.testing.FailingAllocator can drive the OOM paths that fuzzing can't
// reach (the libc-malloc build never injects allocation failure).
test "OOM: ctx array pushes return error.OutOfMemory and stay empty" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ctx: MD_CTX = .{ .alloc = fa.allocator() };
    // The first push needs an allocation; with fail_index 0 it must fail
    // gracefully (ctx.log is a no-op since parser.debug_log is null).
    try std.testing.expectError(error.OutOfMemory, inlines.md_add_mark(&ctx));
    try std.testing.expectEqual(@as(usize, 0), ctx.marks.items.len);
    try std.testing.expectError(error.OutOfMemory, blocks.md_push_slot_info(&ctx, 0, 1));
    try std.testing.expectEqual(@as(usize, 0), ctx.slot_info.items.len);
    // deinit on never-grown lists is a no-op and must not crash.
    ctx.marks.deinit(ctx.alloc);
    ctx.slot_info.deinit(ctx.alloc);
}

test "OOM: deinit frees all array storage (no leak)" {
    // std.testing.allocator flags leaks at test end; passing here proves the
    // ArrayList migration's .deinit releases everything the pushes grew.
    var ctx: MD_CTX = .{ .alloc = std.testing.allocator };
    _ = try inlines.md_add_mark(&ctx);
    _ = try inlines.md_add_mark(&ctx);
    _ = try blocks.md_push_slot_info(&ctx, 1, 2);
    _ = try blocks.md_push_block_alert_info(&ctx, 3, 4);
    try std.testing.expect(ctx.marks.items.len == 2 and ctx.slot_info.items.len == 1);
    ctx.marks.deinit(ctx.alloc);
    ctx.slot_info.deinit(ctx.alloc);
    ctx.block_alert_info.deinit(ctx.alloc);
}

// PLAN C ("fuller OOM matrix"): the raw byte arenas (block_bytes, the ref-def
// hashtable, MD_REF_DEF_LIST buckets) now allocate through ctx.alloc via the
// util.arena_* helpers, so the FailingAllocator can drive their OOM paths too.

test "OOM: arena_alloc/realloc/free roundtrip + injected failure" {
    // Happy path under the leak-checking testing allocator.
    const a = util.arena_alloc(std.testing.allocator, 64);
    try std.testing.expect(a != null);
    const b = util.arena_realloc(std.testing.allocator, a, 64, 256);
    try std.testing.expect(b != null);
    util.arena_free(std.testing.allocator, b, 256);
    // realloc(null, ...) behaves like a fresh alloc; free(null, ...) is a no-op.
    const cptr = util.arena_realloc(std.testing.allocator, null, 0, 32);
    try std.testing.expect(cptr != null);
    util.arena_free(std.testing.allocator, cptr, 32);
    util.arena_free(std.testing.allocator, null, 0);
    // Injected OOM: the first allocation fails, arena_alloc returns null.
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(util.arena_alloc(fa.allocator(), 64) == null);
}

test "OOM: full md_parse sweep is crash- and leak-free under FailingAllocator" {
    // A document that exercises every ctx.alloc-routed allocation: link reference
    // definitions (ref_defs array + ref_def_hashtable + a duplicate to walk the
    // bucket path), headings/paragraphs/lists/code (block_bytes), emphasis
    // (marks), a table (pipe_offs + align_arr scratch), a fenced code block with
    // filename + highlight metadata (md_build_attribute info/lang/filename +
    // meta_buf/meta_copy), an inline link title with an entity (md_build_attribute
    // non-trivial path), and inline/block components with attributes. std.testing.
    // allocator flags any leak; FailingAllocator turns each successive internal
    // allocation into OOM so every abort/cleanup path runs.
    //
    // The second titled link carries a 15-substring title (8 entities separated
    // by literal text), which is the ONLY thing in this document that drives
    // md_build_attr_append_substr past its initial capacity of 8. Without it the
    // `old_alloc > 0` growth branch never executes at all, and the two reallocs'
    // partial-failure states (types grown, offsets not) are never freed — which
    // is precisely how the wrong-length free of PLAN item 1c stayed invisible.
    // Do not shrink it below 9 substrings.
    const src =
        "[a]: /x \"t\"\n[b]: /y\n[a]: /dup\n\n" ++
        "# Heading *em* `c`\n\nParagraph linking [a] and [b] with **strong**.\n\n" ++
        "A [titled](/u \"a &amp; b\") link and :badge[New]{color=\"blue\" #id .cls}.\n\n" ++
        "Grown [t](/u \"a&amp;b&amp;c&amp;d&amp;e&amp;f&amp;g&amp;h\") title.\n\n" ++
        "| a | b |\n|:--|--:|\n| 1 | 2 |\n| 3 | 4 |\n\n" ++
        "```js [app.js] {1-2,4} extra\ncode line\nmore code\n```\n\n" ++
        "::alert{type=\"info\"}\nNested **content** here.\n::\n\n" ++
        "Mail me@example.com or visit www.example.org for details.\n\n" ++
        "- one\n- two\n  - nested\n\n> quote\n";
    var probe: AbortProbe = .{};
    var p = probe.parser();
    var fail: usize = 0;
    while (fail < 900) : (fail += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail });
        const ret = md_parse_impl(fa.allocator(), @ptrCast(src.ptr), @intCast(src.len), &p, &probe);
        // Either a clean parse (0) or a graceful OOM abort (-1) — never a crash,
        // and ctx.alloc allocations are always released (else the allocator
        // would report a leak at test end).
        try std.testing.expect(ret == 0 or ret == -1);
    }
}

// ---------------------------------------------------------------------------
// Golden SAX event trace (Phase 4c step 1).
//
// The abort matrix above freezes md_parse's RETURN codes. This freezes what the
// parser actually HANDS to a renderer: the full ordered sequence of
// enter_block/leave_block/enter_span/leave_span/text events, each with its
// detail struct's field values spelled out — including every MD_ATTRIBUTE's
// substring type/offset table.
//
// Phase 4c re-packages that detail mechanism (extern struct + ?*anyopaque ->
// idiomatic Zig types; the [*c] substring arrays -> slices) across the emission
// path and all seven renderers. The corpus harness only compares each
// renderer's final bytes, so it can miss a packaging change that two renderers
// happen to paper over. This test compares the raw SAX stream instead, so any
// change in event order, event type, detail field, or substring table is a
// direct failure with a readable diff.
//
// The expected trace is a RECORDED baseline, not a hand-derived spec: its job
// is to make 4c's "byte-identical behavior" claim mechanically checkable. If a
// deliberate behavior change ever lands, re-record it and say so in the commit.
// ---------------------------------------------------------------------------

const TraceProbe = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,
    alloc: std.mem.Allocator,
    depth: usize = 0,
    oom: bool = false,

    fn raw(self: *TraceProbe, comptime fmt: []const u8, args: anytype) void {
        if (self.oom) return;
        self.out.print(self.alloc, fmt, args) catch {
            self.oom = true;
        };
    }

    fn indent(self: *TraceProbe) void {
        var i: usize = 0;
        while (i < self.depth) : (i += 1) self.raw("  ", .{});
    }

    /// Escape control characters so one event is always one line.
    fn quoted(self: *TraceProbe, str: [*c]const u8, size: SZ) void {
        self.raw("\"", .{});
        var i: SZ = 0;
        while (i < size) : (i += 1) {
            const ch = str[i];
            switch (ch) {
                '\n' => self.raw("\\n", .{}),
                '\r' => self.raw("\\r", .{}),
                '\t' => self.raw("\\t", .{}),
                '"' => self.raw("\\\"", .{}),
                '\\' => self.raw("\\\\", .{}),
                0 => self.raw("\\0", .{}),
                else => {
                    if (ch < 0x20 or ch == 0x7f) {
                        self.raw("\\x{x:0>2}", .{ch});
                    } else {
                        self.raw("{c}", .{ch});
                    }
                },
            }
        }
        self.raw("\"", .{});
    }

    /// An MD_ATTRIBUTE, including its substring type/offset table — the part
    /// Phase 4c converts from [*c] arrays to slices.
    fn attr(self: *TraceProbe, name: []const u8, a: c.Attribute) void {
        self.raw(" {s}=", .{name});
        if (a.text.len == 0) {
            // An unset attribute; md_build_attribute never yields a non-empty
            // pointer with a zero size, so this is the old `text == NULL` test.
            self.raw("<null>", .{});
            return;
        }
        const total = a.size();
        self.quoted(a.text.ptr, total);
        // substr_offsets is terminated by an entry equal to .size(); substr_types
        // has exactly one fewer entry than substr_offsets.
        if (a.substr_offsets.len != a.substr_types.len + 1) {
            self.raw("[<no-substr>]", .{});
            return;
        }
        self.raw("[", .{});
        var i: usize = 0;
        while (i < a.substr_types.len and a.substr_offsets[i] != total) : (i += 1) {
            if (i > 0) self.raw(",", .{});
            self.raw("{s}@{d}", .{ textTypeName(a.substr_types[i]), a.substr_offsets[i] });
        }
        self.raw("|end@{d}]", .{total});
    }

    fn blockTypeName(t: c.BlockType) []const u8 {
        return switch (t) {
            c.BlockType.doc => "DOC",
            c.BlockType.quote => "QUOTE",
            c.BlockType.ul => "UL",
            c.BlockType.ol => "OL",
            c.BlockType.li => "LI",
            c.BlockType.hr => "HR",
            c.BlockType.h => "H",
            c.BlockType.code => "CODE",
            c.BlockType.html => "HTML",
            c.BlockType.p => "P",
            c.BlockType.table => "TABLE",
            c.BlockType.thead => "THEAD",
            c.BlockType.tbody => "TBODY",
            c.BlockType.tr => "TR",
            c.BlockType.th => "TH",
            c.BlockType.td => "TD",
            c.BlockType.frontmatter => "FRONTMATTER",
            c.BlockType.component => "COMPONENT",
            c.BlockType.template => "TEMPLATE",
            c.BlockType.alert => "ALERT",
        };
    }

    fn spanTypeName(t: c.SpanType) []const u8 {
        return switch (t) {
            c.SpanType.em => "EM",
            c.SpanType.strong => "STRONG",
            c.SpanType.a => "A",
            c.SpanType.img => "IMG",
            c.SpanType.code => "CODE",
            c.SpanType.del => "DEL",
            c.SpanType.latexmath => "LATEXMATH",
            c.SpanType.latexmath_display => "LATEXMATH_DISPLAY",
            c.SpanType.wikilink => "WIKILINK",
            c.SpanType.u => "U",
            c.SpanType.component => "COMPONENT",
            c.SpanType.span => "SPAN",
        };
    }

    fn textTypeName(t: c.TextType) []const u8 {
        return switch (t) {
            c.TextType.normal => "NORMAL",
            c.TextType.nullchar => "NULLCHAR",
            c.TextType.br => "BR",
            c.TextType.softbr => "SOFTBR",
            c.TextType.entity => "ENTITY",
            c.TextType.code => "CODE",
            c.TextType.html => "HTML",
            c.TextType.latexmath => "LATEXMATH",
        };
    }

    fn rawStr(self: *TraceProbe, name: []const u8, s: []const c.MD_CHAR) void {
        self.raw(" {s}=", .{name});
        if (s.len == 0) self.raw("<null>", .{}) else self.quoted(s.ptr, @intCast(s.len));
    }

    /// The pre-4c emission path signalled "this block carries no detail" two
    /// different ways: a NULL pointer for DOC/THEAD/TBODY/TR, and a non-null
    /// pointer into an unread union slot for QUOTE/HR/HTML/P/FRONTMATTER. The
    /// union's `void` arms carry neither, so the two spellings below are a
    /// purely cosmetic reproduction of that historical split — kept so the
    /// golden trace stays byte-identical across the representation change.
    fn blockDetail(self: *TraceProbe, detail: *const c.BlockDetail) void {
        switch (detail.*) {
            c.BlockType.doc, c.BlockType.thead, c.BlockType.tbody, c.BlockType.tr => self.raw(" <no-detail>", .{}),
            c.BlockType.quote, c.BlockType.hr, c.BlockType.html, c.BlockType.p, c.BlockType.frontmatter => self.raw(" <detail:opaque>", .{}),
            c.BlockType.ul => |x| {
                self.raw(" is_tight={d} mark='{c}'", .{ @intFromBool(x.is_tight), x.mark });
            },
            c.BlockType.ol => |x| {
                self.raw(" start={d} is_tight={d} delim='{c}'", .{ x.start, @intFromBool(x.is_tight), x.mark_delimiter });
            },
            c.BlockType.li => |x| {
                self.raw(" is_task={d} task_mark='{c}' off={d}", .{ @intFromBool(x.is_task), if (x.task_mark == 0) @as(u8, '-') else x.task_mark, x.task_mark_offset });
            },
            c.BlockType.h => |x| {
                self.raw(" level={d}", .{x.level});
            },
            c.BlockType.code => |x| {
                self.attr("info", x.info);
                self.attr("lang", x.lang);
                self.raw(" fence='{c}'", .{if (x.fence_char == 0) @as(u8, '-') else x.fence_char});
                self.attr("filename", x.filename);
                self.rawStr("meta", x.meta);
                self.raw(" highlights=[", .{});
                for (x.highlights, 0..) |h, i| {
                    if (i > 0) self.raw(",", .{});
                    self.raw("{d}", .{h});
                }
                self.raw("]", .{});
            },
            c.BlockType.table => |x| {
                self.raw(" cols={d} head_rows={d} body_rows={d}", .{ x.col_count, x.head_row_count, x.body_row_count });
            },
            c.BlockType.th, c.BlockType.td => |x| {
                self.raw(" align={d}", .{@intFromEnum(x.@"align")});
            },
            c.BlockType.component => |x| {
                self.attr("tag", x.tag_name);
                self.rawStr("props", x.raw_props);
                self.rawStr("title", x.title);
            },
            c.BlockType.template => |x| {
                self.attr("name", x.name);
            },
            c.BlockType.alert => |x| {
                self.attr("type", x.type_name);
            },
        }
    }

    fn spanDetail(self: *TraceProbe, detail: *const c.SpanDetail) void {
        switch (detail.*) {
            // The two math spans never carried a detail (see blockDetail's note
            // on the historical NULL-pointer spelling).
            c.SpanType.latexmath, c.SpanType.latexmath_display => self.raw(" <no-detail>", .{}),
            c.SpanType.a => |x| {
                self.attr("href", x.href);
                self.attr("title", x.title);
                self.rawStr("attrs", x.raw_attrs);
                self.raw(" autolink={d}", .{@intFromBool(x.is_autolink)});
            },
            c.SpanType.img => |x| {
                self.attr("src", x.src);
                self.attr("title", x.title);
                self.rawStr("attrs", x.raw_attrs);
            },
            c.SpanType.wikilink => |x| {
                self.attr("target", x.target);
            },
            c.SpanType.component => |x| {
                self.attr("tag", x.tag_name);
                self.rawStr("props", x.raw_props);
            },
            c.SpanType.span => |x| {
                self.rawStr("attrs", x.raw_attrs);
            },
            // em/strong/code/del/u carry SpanAttrsDetail; an empty raw_attrs is
            // the old "NULL detail" case.
            c.SpanType.em, c.SpanType.strong, c.SpanType.code, c.SpanType.del, c.SpanType.u => |x| {
                if (x.raw_attrs.len == 0) self.raw(" <no-detail>", .{}) else self.rawStr("attrs", x.raw_attrs);
            },
        }
    }

    fn enterBlock(detail: *const c.BlockDetail, ud: ?*anyopaque) c.CallbackResult {
        const self: *TraceProbe = @ptrCast(@alignCast(ud.?));
        self.indent();
        self.raw("+block {s}", .{blockTypeName(std.meta.activeTag(detail.*))});
        self.blockDetail(detail);
        self.raw("\n", .{});
        self.depth += 1;
        return 0;
    }
    fn leaveBlock(detail: *const c.BlockDetail, ud: ?*anyopaque) c.CallbackResult {
        const self: *TraceProbe = @ptrCast(@alignCast(ud.?));
        if (self.depth > 0) self.depth -= 1;
        self.indent();
        self.raw("-block {s}\n", .{blockTypeName(std.meta.activeTag(detail.*))});
        return 0;
    }
    fn enterSpan(detail: *const c.SpanDetail, ud: ?*anyopaque) c.CallbackResult {
        const self: *TraceProbe = @ptrCast(@alignCast(ud.?));
        self.indent();
        self.raw("+span {s}", .{spanTypeName(std.meta.activeTag(detail.*))});
        self.spanDetail(detail);
        self.raw("\n", .{});
        self.depth += 1;
        return 0;
    }
    fn leaveSpan(detail: *const c.SpanDetail, ud: ?*anyopaque) c.CallbackResult {
        const self: *TraceProbe = @ptrCast(@alignCast(ud.?));
        if (self.depth > 0) self.depth -= 1;
        self.indent();
        self.raw("-span {s}\n", .{spanTypeName(std.meta.activeTag(detail.*))});
        return 0;
    }
    fn textCb(ty: c.TextType, str: []const CHAR, ud: ?*anyopaque) c.CallbackResult {
        const self: *TraceProbe = @ptrCast(@alignCast(ud.?));
        self.indent();
        self.raw("text {s} ", .{textTypeName(ty)});
        self.quoted(str.ptr, @intCast(str.len));
        self.raw("\n", .{});
        return 0;
    }

    fn parser() c.Parser {
        var p: c.Parser = .{};
        p.flags = c.MD_DIALECT_ALL;
        p.enter_block = TraceProbe.enterBlock;
        p.leave_block = TraceProbe.leaveBlock;
        p.enter_span = TraceProbe.enterSpan;
        p.leave_span = TraceProbe.leaveSpan;
        p.text = TraceProbe.textCb;
        return p;
    }
};

/// Exercises every block type, span type, and text type that carries a detail
/// struct, so the trace covers the whole packaging surface Phase 4c rewrites.
const trace_doc =
    \\---
    \\title: Doc
    \\tags: [a, b]
    \\---
    \\
    \\# Heading *one*
    \\
    \\Setext
    \\======
    \\
    \\Para **strong**, *em*, `code`, ~~del~~, _u_, &amp; ent, &#65; num.
    \\
    \\Link [text](/url "the title") and auto <https://a.example/> and
    \\bare https://b.example/ and mail@c.example and www.d.example.
    \\
    \\![alt](/img.png "img title"){.responsive}
    \\
    \\Math $x^2$ and $$y_1$$ and [[Wiki Target]].
    \\
    \\Attrs: **bold**{.hi} *it*{#id} `cs`{.l} ~~d~~{.r} _uu_{.a} [sp]{.cls}
    \\
    \\Hard break\
    \\after break, soft
    \\break here.
    \\
    \\> quoted
    \\
    \\> [!WARNING]
    \\> alert body
    \\
    \\- [ ] todo
    \\- [x] done
    \\- plain
    \\
    \\1. one
    \\1. two
    \\
    \\* loose
    \\
    \\* list
    \\
    \\---
    \\
    \\    indented code
    \\
    \\```js [app.js] {1-2,4}
    \\const x = 1;
    \\const y = 2;
    \\```
    \\
    \\<div class="raw">
    \\block html
    \\</div>
    \\
    \\Inline <b>html</b> span.
    \\
    \\| left | center | right | plain |
    \\| :--- | :----: | ----: | ----- |
    \\| a    | b      | c     | d     |
    \\| e    | f      | g     | h     |
    \\
    \\::card{#cid .ccls color="blue" flag}
    \\
    \\---
    \\icon: star
    \\---
    \\
    \\default slot
    \\
    \\#header
    \\## Slot heading
    \\
    \\#footer
    \\footer text
    \\::
    \\
    \\:::danger STOP {level="high"}
    \\titled container
    \\:::
    \\
    \\Inline :badge[New]{color="red"} and :icon-star standalone.
    \\
    \\<!-- a comment -->
    \\
;

test "SAX event trace: golden baseline (freezes detail packaging for Phase 4c)" {
    var probe = TraceProbe{ .alloc = std.testing.allocator };
    defer probe.out.deinit(std.testing.allocator);
    var p = TraceProbe.parser();

    // A NUL byte in the input drives MD_TEXT_NULLCHAR, which no other suite
    // covers (the fuzz harness and the JS surface both exclude NUL).
    const input = trace_doc ++ "\nnul\x00char\n";

    const ret = md_parse(@ptrCast(input.ptr), @intCast(input.len), &p, &probe);
    try std.testing.expectEqual(@as(c_int, 0), ret);
    try std.testing.expect(!probe.oom);

    try std.testing.expectEqualStrings(expected_trace, probe.out.items);
}

const expected_trace =
    \\+block DOC <no-detail>
    \\  +block FRONTMATTER <detail:opaque>
    \\    text NORMAL "title: Doc"
    \\    text NORMAL "\n"
    \\    text NORMAL "tags: [a, b]"
    \\    text NORMAL "\n"
    \\  -block FRONTMATTER
    \\  +block H level=1
    \\    text NORMAL "Heading "
    \\    +span EM <no-detail>
    \\      text NORMAL "one"
    \\    -span EM
    \\  -block H
    \\  +block H level=1
    \\    text NORMAL "Setext"
    \\  -block H
    \\  +block P <detail:opaque>
    \\    text NORMAL "Para "
    \\    +span STRONG <no-detail>
    \\      text NORMAL "strong"
    \\    -span STRONG
    \\    text NORMAL ", "
    \\    +span EM <no-detail>
    \\      text NORMAL "em"
    \\    -span EM
    \\    text NORMAL ", "
    \\    +span CODE <no-detail>
    \\      text CODE "code"
    \\    -span CODE
    \\    text NORMAL ", "
    \\    +span DEL <no-detail>
    \\      text NORMAL "del"
    \\    -span DEL
    \\    text NORMAL ", "
    \\    +span U <no-detail>
    \\      text NORMAL "u"
    \\    -span U
    \\    text NORMAL ", "
    \\    text ENTITY "&amp;"
    \\    text NORMAL " ent, "
    \\    text ENTITY "&#65;"
    \\    text NORMAL " num."
    \\  -block P
    \\  +block P <detail:opaque>
    \\    text NORMAL "Link "
    \\    +span A href="/url"[NORMAL@0|end@4] title="the title"[NORMAL@0|end@9] attrs=<null> autolink=0
    \\      text NORMAL "text"
    \\    -span A
    \\    text NORMAL " and auto "
    \\    +span A href="https://a.example/"[NORMAL@0|end@18] title=<null> attrs=<null> autolink=1
    \\      text NORMAL "https://a.example/"
    \\    -span A
    \\    text NORMAL " and"
    \\    text SOFTBR "\n"
    \\    text NORMAL "bare "
    \\    +span A href="https://b.example/"[NORMAL@0|end@18] title=<null> attrs=<null> autolink=1
    \\      text NORMAL "https://b.example/"
    \\    -span A
    \\    text NORMAL " and "
    \\    +span A href="mailto:mail@c.example"[NORMAL@0|end@21] title=<null> attrs=<null> autolink=1
    \\      text NORMAL "mail@c.example"
    \\    -span A
    \\    text NORMAL " and "
    \\    +span A href="http://www.d.example"[NORMAL@0|end@20] title=<null> attrs=<null> autolink=1
    \\      text NORMAL "www.d.example"
    \\    -span A
    \\    text NORMAL "."
    \\  -block P
    \\  +block P <detail:opaque>
    \\    +span IMG src="/img.png"[NORMAL@0|end@8] title="img title"[NORMAL@0|end@9] attrs=".responsive"
    \\      text NORMAL "alt"
    \\    -span IMG
    \\  -block P
    \\  +block P <detail:opaque>
    \\    text NORMAL "Math "
    \\    +span LATEXMATH <no-detail>
    \\      text LATEXMATH "x^2"
    \\    -span LATEXMATH
    \\    text NORMAL " and "
    \\    +span LATEXMATH_DISPLAY <no-detail>
    \\      text LATEXMATH "y_1"
    \\    -span LATEXMATH_DISPLAY
    \\    text NORMAL " and "
    \\    +span WIKILINK target="Wiki Target"[NORMAL@0|end@11]
    \\      text NORMAL "Wiki Target"
    \\    -span WIKILINK
    \\    text NORMAL "."
    \\  -block P
    \\  +block P <detail:opaque>
    \\    text NORMAL "Attrs: "
    \\    +span STRONG attrs=".hi"
    \\      text NORMAL "bold"
    \\    -span STRONG
    \\    text NORMAL " "
    \\    +span EM attrs="#id"
    \\      text NORMAL "it"
    \\    -span EM
    \\    text NORMAL " "
    \\    +span CODE attrs=".l"
    \\      text CODE "cs"
    \\    -span CODE
    \\    text NORMAL " "
    \\    +span DEL attrs=".r"
    \\      text NORMAL "d"
    \\    -span DEL
    \\    text NORMAL " "
    \\    +span U attrs=".a"
    \\      text NORMAL "uu"
    \\    -span U
    \\    text NORMAL " "
    \\    +span SPAN attrs=".cls"
    \\      text NORMAL "sp"
    \\    -span SPAN
    \\  -block P
    \\  +block P <detail:opaque>
    \\    text NORMAL "Hard break"
    \\    text BR "\n"
    \\    text NORMAL "after break, soft"
    \\    text SOFTBR "\n"
    \\    text NORMAL "break here."
    \\  -block P
    \\  +block QUOTE <detail:opaque>
    \\    +block P <detail:opaque>
    \\      text NORMAL "quoted"
    \\    -block P
    \\  -block QUOTE
    \\  +block ALERT type="WARNING"[NORMAL@0|end@7]
    \\    +block P <detail:opaque>
    \\      text NORMAL "alert body"
    \\    -block P
    \\  -block ALERT
    \\  +block UL is_tight=1 mark='-'
    \\    +block LI is_task=1 task_mark=' ' off=502
    \\      text NORMAL "todo"
    \\    -block LI
    \\    +block LI is_task=1 task_mark='x' off=513
    \\      text NORMAL "done"
    \\    -block LI
    \\    +block LI is_task=0 task_mark='-' off=0
    \\      text NORMAL "plain"
    \\    -block LI
    \\  -block UL
    \\  +block OL start=1 is_tight=1 delim='.'
    \\    +block LI is_task=0 task_mark='-' off=0
    \\      text NORMAL "one"
    \\    -block LI
    \\    +block LI is_task=0 task_mark='-' off=0
    \\      text NORMAL "two"
    \\    -block LI
    \\  -block OL
    \\  +block UL is_tight=0 mark='*'
    \\    +block LI is_task=0 task_mark='-' off=0
    \\      +block P <detail:opaque>
    \\        text NORMAL "loose"
    \\      -block P
    \\    -block LI
    \\    +block LI is_task=0 task_mark='-' off=0
    \\      +block P <detail:opaque>
    \\        text NORMAL "list"
    \\      -block P
    \\    -block LI
    \\  -block UL
    \\  +block HR <detail:opaque>
    \\  -block HR
    \\  +block CODE info=<null> lang=<null> fence='-' filename=<null> meta=<null> highlights=[]
    \\    text CODE "indented code"
    \\    text CODE "\n"
    \\  -block CODE
    \\  +block CODE info="js [app.js] {1-2,4}"[NORMAL@0|end@19] lang="js"[NORMAL@0|end@2] fence='`' filename="app.js"[NORMAL@0|end@6] meta=<null> highlights=[1,2,4]
    \\    text CODE "const x = 1;"
    \\    text CODE "\n"
    \\    text CODE "const y = 2;"
    \\    text CODE "\n"
    \\  -block CODE
    \\  +block HTML <detail:opaque>
    \\    text HTML "<div class=\"raw\">"
    \\    text HTML "\n"
    \\    text HTML "block html"
    \\    text HTML "\n"
    \\    text HTML "</div>"
    \\    text HTML "\n"
    \\  -block HTML
    \\  +block P <detail:opaque>
    \\    text NORMAL "Inline "
    \\    text HTML "<b>"
    \\    text NORMAL "html"
    \\    text HTML "</b>"
    \\    text NORMAL " span."
    \\  -block P
    \\  +block TABLE cols=4 head_rows=1 body_rows=2
    \\    +block THEAD <no-detail>
    \\      +block TR <no-detail>
    \\        +block TH align=1
    \\          text NORMAL "left"
    \\        -block TH
    \\        +block TH align=2
    \\          text NORMAL "center"
    \\        -block TH
    \\        +block TH align=3
    \\          text NORMAL "right"
    \\        -block TH
    \\        +block TH align=0
    \\          text NORMAL "plain"
    \\        -block TH
    \\      -block TR
    \\    -block THEAD
    \\    +block TBODY <no-detail>
    \\      +block TR <no-detail>
    \\        +block TD align=1
    \\          text NORMAL "a"
    \\        -block TD
    \\        +block TD align=2
    \\          text NORMAL "b"
    \\        -block TD
    \\        +block TD align=3
    \\          text NORMAL "c"
    \\        -block TD
    \\        +block TD align=0
    \\          text NORMAL "d"
    \\        -block TD
    \\      -block TR
    \\      +block TR <no-detail>
    \\        +block TD align=1
    \\          text NORMAL "e"
    \\        -block TD
    \\        +block TD align=2
    \\          text NORMAL "f"
    \\        -block TD
    \\        +block TD align=3
    \\          text NORMAL "g"
    \\        -block TD
    \\        +block TD align=0
    \\          text NORMAL "h"
    \\        -block TD
    \\      -block TR
    \\    -block TBODY
    \\  -block TABLE
    \\  +block COMPONENT tag="card"[NORMAL@0|end@4] props="#cid .ccls color=\"blue\" flag" title=<null>
    \\    +block FRONTMATTER <detail:opaque>
    \\      text NORMAL "icon: star"
    \\      text NORMAL "\n"
    \\    -block FRONTMATTER
    \\    +block P <detail:opaque>
    \\      text NORMAL "default slot"
    \\    -block P
    \\    +block TEMPLATE name="header"[NORMAL@0|end@6]
    \\      +block H level=2
    \\        text NORMAL "Slot heading"
    \\      -block H
    \\    -block TEMPLATE
    \\    +block TEMPLATE name="footer"[NORMAL@0|end@6]
    \\      +block P <detail:opaque>
    \\        text NORMAL "footer text"
    \\      -block P
    \\    -block TEMPLATE
    \\  -block COMPONENT
    \\  +block COMPONENT tag="danger"[NORMAL@0|end@6] props="level=\"high\"" title="STOP"
    \\    +block P <detail:opaque>
    \\      text NORMAL "titled container"
    \\    -block P
    \\  -block COMPONENT
    \\  +block P <detail:opaque>
    \\    text NORMAL "Inline "
    \\    +span COMPONENT tag="badge"[NORMAL@0|end@5] props="color=\"red\""
    \\      text NORMAL "New"
    \\    -span COMPONENT
    \\    text NORMAL " and "
    \\    +span COMPONENT tag="icon-star"[NORMAL@0|end@9] props=<null>
    \\    -span COMPONENT
    \\    text NORMAL " standalone."
    \\  -block P
    \\  +block HTML <detail:opaque>
    \\    text HTML "<!-- a comment -->"
    \\    text HTML "\n"
    \\  -block HTML
    \\  +block P <detail:opaque>
    \\    text NORMAL "nul"
    \\    text NULLCHAR "\0"
    \\    text NORMAL "char"
    \\  -block P
    \\-block DOC
++ "\n";
