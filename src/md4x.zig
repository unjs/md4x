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
const utbl = @import("unicode_tables.zig");
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

const TRUE = types.TRUE;
const FALSE = types.FALSE;

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

pub export fn md_parse(text: [*c]const CHAR, size: SZ, parser: [*c]const c.MD_PARSER, userdata: ?*anyopaque) callconv(.c) c_int {
    if (parser.*.abi_version != 0) {
        if (parser.*.debug_log != null)
            parser.*.debug_log.?("Unsupported abi_version.", userdata);
        return -1;
    }

    // Setup context structure (zero-initialized like C's memset).
    var ctx: MD_CTX = .{};
    ctx.text = text;
    ctx.size = size;
    ctx.parser = parser.*;
    ctx.userdata = userdata;
    ctx.code_indent_offset = if (ctx.parser.flags & c.MD_FLAG_NOINDENTEDCODEBLOCKS != 0) OFF_MAX else 4;
    md_build_mark_char_map(&ctx);
    ctx.doc_ends_with_newline = @intFromBool(size > 0 and ISNEWLINE_(text[size - 1]));
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

    // Clean-up.
    md_free_ref_defs(&ctx);
    md_free_ref_def_hashtable(&ctx);
    std.c.free(ctx.buffer);
    std.c.free(ctx.marks);
    std.c.free(ctx.block_bytes);
    std.c.free(@ptrCast(ctx.containers));
    std.c.free(@ptrCast(ctx.block_component_info));
    ctx.slot_info.deinit(c_allocator);
    ctx.block_alert_info.deinit(c_allocator);
    std.c.free(ctx.inline_attrs);

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
    _ = &TRUE;
    _ = &FALSE;
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

// Entity hook — thin wrapper over entity_lookup (declared via entity.h). The
// inline engine (Pass C) calls this to resolve named entities to codepoints.
inline fn entity_lookup_wrap(name: [*c]const u8, name_size: usize) ?*const c.ENTITY {
    return c.entity_lookup(name, name_size);
}

// Test-only re-exports of internal foundation functions, used by the
// unit-differential harness (test/_pass-a-diff.zig). Not part of the parser's
// API surface; later passes may extend this. No runtime cost when unused.
// Test-only driver mirroring md_process_normal_block_contents wrapped with the
// md_parse setup. Splits `text[0..size]` into MD_LINE[] at '\n' (newline
// excluded), runs analyze+process, and performs the ptr_stack cleanup + frees.
// Returns the analyze/process return value.
fn _test_run_inline(parser: *const c.MD_PARSER, text: [*c]const CHAR, size: SZ) c_int {
    var ctx: MD_CTX = .{};
    ctx.text = text;
    ctx.size = size;
    ctx.parser = parser.*;
    ctx.userdata = null;
    ctx.code_indent_offset = if (ctx.parser.flags & c.MD_FLAG_NOINDENTEDCODEBLOCKS != 0) OFF_MAX else 4;
    md_build_mark_char_map(&ctx);
    ctx.doc_ends_with_newline = @intFromBool(size > 0 and ISNEWLINE_(text[size - 1]));
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

    var ret = md_analyze_inlines(&ctx, lines[0..n_lines], FALSE);
    if (ret == 0) ret = md_process_inlines(&ctx, lines[0..n_lines]);

    // ptr_stack cleanup (mirrors md_process_normal_block_contents).
    var pi: c_int = ctx.ptr_stack.top;
    while (pi >= 0) : (pi = ctx.marks[@intCast(pi)].next) {
        std.c.free(md_mark_get_ptr(&ctx, pi));
    }
    ctx.ptr_stack.top = -1;

    std.c.free(lines);
    md_free_ref_defs(&ctx);
    md_free_ref_def_hashtable(&ctx);
    std.c.free(ctx.buffer);
    std.c.free(ctx.marks);
    std.c.free(ctx.inline_attrs);
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
    pub const flag_RESOLVED = MD_MARK_RESOLVED;
    pub const flag_OPENER = MD_MARK_OPENER;
    pub const flag_CLOSER = MD_MARK_CLOSER;
    pub const flag_POTENTIAL_OPENER = MD_MARK_POTENTIAL_OPENER;
    pub const flag_POTENTIAL_CLOSER = MD_MARK_POTENTIAL_CLOSER;

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

    if (line.type == .MD_LINE_TABLEUNDERLINE) {
        ctx.current_block.*.setType(c.MD_BLOCK_TABLE);
        ctx.current_block.*.bits.data = @truncate(line.data);
        @as(*MD_LINE_ANALYSIS, @constCast(pivot_line)).type = .MD_LINE_TABLE;
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
fn _test_run_analyze(parser: *const c.MD_PARSER, text: [*c]const CHAR, size: SZ, out_fn: TestOut, out_ud: ?*anyopaque) c_int {
    var ctx: MD_CTX = .{};
    ctx.text = text;
    ctx.size = size;
    ctx.parser = parser.*;
    ctx.userdata = null;
    ctx.code_indent_offset = if (ctx.parser.flags & c.MD_FLAG_NOINDENTEDCODEBLOCKS != 0) OFF_MAX else 4;
    ctx.doc_ends_with_newline = @intFromBool(size > 0 and ISNEWLINE_(text[size - 1]));
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
            line.enforce_new_block,                         line.beg,
            line.end,                                       line.indent,
            ctx.n_containers,                               ctx.block_component_nesting,
            ctx.frontmatter_state,                          ctx.last_line_has_list_loosening_effect,
            ctx.last_list_item_starts_with_two_blank_lines, ctx.n_block_bytes,
            ctx.n_block_components,                         @as(c_int, @intCast(ctx.slot_info.items.len)),
            @as(c_int, @intCast(ctx.block_alert_info.items.len)),
        }, out_fn, out_ud);
        var i: c_int = 0;
        while (i < ctx.n_containers) : (i += 1) {
            const co = &ctx.containers[@intCast(i)];
            emit(&fbuf, "  C[{d}] ch={d} loose={d} task={d} alert={d} start={d} mi={d} ci={d} bbo={d} tmo={d} cc={d} cfm={d}\n", .{
                i,                 uval(co.ch),      co.is_loose,    co.is_task,
                co.is_alert,       co.start,         co.mark_indent, co.contents_indent,
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
    std.c.free(ctx.block_bytes);
    std.c.free(@ptrCast(ctx.containers));
    std.c.free(@ptrCast(ctx.block_component_info));
    ctx.slot_info.deinit(c_allocator);
    ctx.block_alert_info.deinit(c_allocator);
    md_free_ref_defs(&ctx);
    md_free_ref_def_hashtable(&ctx);
    std.c.free(ctx.buffer);
    std.c.free(ctx.marks);
    std.c.free(ctx.inline_attrs);
    return ret;
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
    abort_code: c_int = 1,
    abort_on_text: bool = false,
    abort_on_block_p: bool = false,
    abort_on_enter_block: bool = false,
    abort_on_leave_block: bool = false,
    abort_on_enter_span: bool = false,
    abort_on_leave_span: bool = false,

    fn enterBlock(ty: c.MD_BLOCKTYPE, detail: ?*anyopaque, ud: ?*anyopaque) callconv(.c) c_int {
        _ = detail;
        const self: *AbortProbe = @ptrCast(@alignCast(ud.?));
        self.enter_calls += 1;
        if (self.abort_on_block_p and ty == c.MD_BLOCK_P) return self.abort_code;
        if (self.abort_on_enter_block and ty != c.MD_BLOCK_DOC) return self.abort_code;
        return 0;
    }
    fn leaveBlock(ty: c.MD_BLOCKTYPE, detail: ?*anyopaque, ud: ?*anyopaque) callconv(.c) c_int {
        _ = detail;
        const self: *AbortProbe = @ptrCast(@alignCast(ud.?));
        if (self.abort_on_leave_block and ty != c.MD_BLOCK_DOC) return self.abort_code;
        return 0;
    }
    fn enterSpan(ty: c.MD_SPANTYPE, detail: ?*anyopaque, ud: ?*anyopaque) callconv(.c) c_int {
        _ = ty;
        _ = detail;
        const self: *AbortProbe = @ptrCast(@alignCast(ud.?));
        if (self.abort_on_enter_span) return self.abort_code;
        return 0;
    }
    fn leaveSpan(ty: c.MD_SPANTYPE, detail: ?*anyopaque, ud: ?*anyopaque) callconv(.c) c_int {
        _ = ty;
        _ = detail;
        const self: *AbortProbe = @ptrCast(@alignCast(ud.?));
        if (self.abort_on_leave_span) return self.abort_code;
        return 0;
    }
    fn textCb(ty: c.MD_TEXTTYPE, str: [*c]const CHAR, size: SZ, ud: ?*anyopaque) callconv(.c) c_int {
        _ = ty;
        _ = str;
        _ = size;
        const self: *AbortProbe = @ptrCast(@alignCast(ud.?));
        self.text_calls += 1;
        if (self.abort_on_text) return self.abort_code;
        return 0;
    }

    fn parser(self: *AbortProbe) c.MD_PARSER {
        _ = self;
        var p: c.MD_PARSER = std.mem.zeroes(c.MD_PARSER);
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
