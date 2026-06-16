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

pub const c = @cImport({
    @cInclude("md4x.h");
    @cInclude("entity.h");
});

const c_allocator = std.heap.c_allocator;

// "These are omnipresent so lets save some typing." (md4x.c) ABI scalar aliases.
const CHAR = c.MD_CHAR; // == c_char (signed char, 8-bit)
const SZ = c.MD_SIZE; // == c_uint (32-bit)
const OFF = c.MD_OFFSET; // == c_uint (32-bit)
const MD_SIZE = c.MD_SIZE; // explicit alias used in a few signatures

// SZ_MAX / OFF_MAX (UTF-8 build: 32-bit unsigned).
const SZ_MAX: SZ = std.math.maxInt(SZ);
const OFF_MAX: OFF = std.math.maxInt(OFF);

const TRUE: c_int = 1;
const FALSE: c_int = 0;

// ----------------------------------------------------------------------------
// Boolean constants and small helpers (`SIZEOF_ARRAY` becomes `.len`).
// ----------------------------------------------------------------------------

// `MD_LOG(msg)` — call ctx->parser.debug_log if set. The C macro reads `ctx`
// from the enclosing scope; here it is an explicit method on *MD_CTX.
inline fn md_log(ctx: *MD_CTX, msg: [*:0]const u8) void {
    if (ctx.parser.debug_log) |cb| {
        cb(msg, ctx.userdata);
    }
}

// ============================================================================
//  Internal Types
// ============================================================================

pub const MD_LINETYPE = enum(c_int) {
    MD_LINE_BLANK,
    MD_LINE_HR,
    MD_LINE_ATXHEADER,
    MD_LINE_SETEXTHEADER,
    MD_LINE_SETEXTUNDERLINE,
    MD_LINE_INDENTEDCODE,
    MD_LINE_FENCEDCODE,
    MD_LINE_HTML,
    MD_LINE_TEXT,
    MD_LINE_TABLE,
    MD_LINE_TABLEUNDERLINE,
    MD_LINE_FRONTMATTER,
    MD_LINE_BLOCKCOMPONENT,
};

pub const MD_LINE_ANALYSIS = struct {
    type: MD_LINETYPE = .MD_LINE_BLANK,
    data: c_uint = 0,
    enforce_new_block: c_int = 0,
    beg: OFF = 0,
    end: OFF = 0,
    indent: c_uint = 0, // Indentation level.
};

pub const MD_LINE = extern struct {
    beg: OFF,
    end: OFF,
};

pub const MD_VERBATIMLINE = extern struct {
    beg: OFF,
    end: OFF,
    indent: OFF,
};

// Block flags (md4x.c ~5355). These ride in the MD_BLOCK.flags 8-bit field.
const MD_BLOCK_CONTAINER_OPENER: c_uint = 0x01;
const MD_BLOCK_CONTAINER_CLOSER: c_uint = 0x02;
const MD_BLOCK_CONTAINER: c_uint = (MD_BLOCK_CONTAINER_OPENER | MD_BLOCK_CONTAINER_CLOSER);
const MD_BLOCK_LOOSE_LIST: c_uint = 0x04;
const MD_BLOCK_SETEXT_HEADER: c_uint = 0x08;

// `struct MD_BLOCK_tag` (md4x.c ~5361). C uses bitfields:
//   MD_BLOCKTYPE type :8; unsigned flags :8; unsigned data :16; MD_SIZE n_lines;
// Blocks are stored interleaved with MD_LINE/MD_VERBATIMLINE in ctx.block_bytes
// and accessed by raw byte offset, so the in-memory layout must match C exactly.
// On little-endian the three bitfields pack into one u32 (type=byte0, flags=byte1,
// data=bytes2-3), followed by a 4-byte MD_SIZE — 8 bytes total. We model that
// with a packed struct so field reads/writes go to the right bits.
pub const MD_BLOCK = extern struct {
    bits: BlockBits = .{},
    n_lines: MD_SIZE = 0,

    const BlockBits = packed struct(u32) {
        type: u8 = 0,
        flags: u8 = 0,
        data: u16 = 0,
    };

    pub inline fn getType(self: *const MD_BLOCK) c.MD_BLOCKTYPE {
        return @intCast(self.bits.type);
    }
    pub inline fn setType(self: *MD_BLOCK, t: c.MD_BLOCKTYPE) void {
        self.bits.type = @intCast(t);
    }
};

// `struct MD_CONTAINER_tag` (md4x.c ~5379). Internal-only (never crosses the C
// ABI). C uses several `unsigned :8`/`:2` bitfields; we model with plain integer
// fields since only the *values* matter (containers live in ctx.containers, a
// distinct MD_CONTAINER[] array, not in block_bytes — so exact bit packing is
// irrelevant, mirroring the MD_REF_DEF bitfield decision in Pass B).
pub const MD_CONTAINER = extern struct {
    ch: CHAR = 0,
    is_loose: u8 = 0,
    is_task: u8 = 0,
    is_alert: u8 = 0,
    start: c_uint = 0,
    mark_indent: c_uint = 0,
    contents_indent: c_uint = 0,
    block_byte_off: OFF = 0,
    task_mark_off: OFF = 0,
    colon_count: c_uint = 0, // For block components: number of colons in opener.
    comp_fm_state: c_uint = 0, // Component frontmatter: 0=looking, 1=inside, 2=done.
};

// The mark structure. Faithful layout of `struct MD_MARK_tag` (md4x.c ~2574).
// extern struct so the field order/sizes mirror C exactly (md_mark_store_ptr
// memcpy's a `void*` over the first two OFF fields beg+end). On 64-bit,
// sizeof(void*) == 2*sizeof(OFF), matching the C assertion.
pub const MD_MARK = extern struct {
    beg: OFF = 0,
    end: OFF = 0,
    // For unresolved openers, 'next' forms a stack of unresolved openers.
    // When resolved, prev/next index the opener/closer counterpart.
    prev: c_int = 0,
    next: c_int = 0,
    ch: CHAR = 0,
    flags: u8 = 0,
};

// Mark flags (apply to ALL mark types). Verbatim from md4x.c ~2591.
const MD_MARK_POTENTIAL_OPENER: u8 = 0x01; // Maybe opener.
const MD_MARK_POTENTIAL_CLOSER: u8 = 0x02; // Maybe closer.
const MD_MARK_OPENER: u8 = 0x04; // Definitely opener.
const MD_MARK_CLOSER: u8 = 0x08; // Definitely closer.
const MD_MARK_RESOLVED: u8 = 0x10; // Resolved in any definite way.

// Mark flags specific for various mark types (they share bits).
const MD_MARK_EMPH_OC: u8 = 0x20; // Opener/closer mixed candidate ("rule of 3").
const MD_MARK_EMPH_MOD3_0: u8 = 0x40;
const MD_MARK_EMPH_MOD3_1: u8 = 0x80;
const MD_MARK_EMPH_MOD3_2: u8 = (0x40 | 0x80);
const MD_MARK_EMPH_MOD3_MASK: u8 = (0x40 | 0x80);
const MD_MARK_AUTOLINK: u8 = 0x20; // Distinguisher for '<', '>'.
const MD_MARK_AUTOLINK_MISSING_MAILTO: u8 = 0x40;
const MD_MARK_VALIDPERMISSIVEAUTOLINK: u8 = 0x20; // For permissive autolinks.
const MD_MARK_HASNESTEDBRACKETS: u8 = 0x20; // For '[' to rule out invalid labels early.

const CODESPAN_MARK_MAXLEN: usize = 32;

// Reference definition. Faithful layout of `struct MD_REF_DEF_tag` (md4x.c
// ~1635). The two trailing `unsigned char : 1` bitfields are modelled as a
// single `u8` flags byte holding bit0=label_needs_free, bit1=title_needs_free.
// We never share this struct across the C ABI (renderers don't see it), so the
// exact bit packing is irrelevant — only the field *values* matter for the
// differential. We store the two flags as plain bools for clarity.
pub const MD_REF_DEF = extern struct {
    label: [*c]CHAR = null,
    title: [*c]CHAR = null,
    hash: c_uint = 0,
    label_size: SZ = 0,
    title_size: SZ = 0,
    dest_beg: OFF = 0,
    dest_end: OFF = 0,
    label_needs_free: bool = false,
    title_needs_free: bool = false,
};

// Complex hashtable bucket: holds multiple ref-def pointers (a hash collision
// of distinct labels). Mirrors `struct MD_REF_DEF_LIST_tag` with the C
// flexible-array member `MD_REF_DEF* ref_defs[]`. We allocate
// `@sizeOf(MD_REF_DEF_LIST) + n * @sizeOf(?*MD_REF_DEF)` bytes and index past
// the header manually (see md_ref_def_list_items).
pub const MD_REF_DEF_LIST = extern struct {
    n_ref_defs: c_int = 0,
    alloc_ref_defs: c_int = 0,
    // Flexible array `MD_REF_DEF* ref_defs[]` follows in memory.
};

// "During analyzes of inline marks, we need to manage stacks of unresolved
//  openers of the given type." Top == -1 if empty.
pub const MD_MARKSTACK = struct {
    top: c_int = -1,
};

pub const MD_BLOCK_COMPONENT_INFO = struct {
    colon_count: c_uint = 0, // Number of colons in the opener fence (2+).
    name_beg: OFF = 0, // Offset of component name in source.
    name_end: OFF = 0,
    props_beg: OFF = 0, // Offset of raw props content (after '{'), or 0.
    props_end: OFF = 0, // Offset of '}', or 0.
    title_beg: OFF = 0, // Offset of title text after name, or 0.
    title_end: OFF = 0, // End offset of title text, or 0.
};

pub const MD_SLOT_INFO = struct {
    name_beg: OFF = 0, // Offset of slot name in source.
    name_end: OFF = 0,
};

pub const MD_BLOCK_ALERT_INFO = struct {
    type_beg: OFF = 0, // Offset of type name in source.
    type_end: OFF = 0,
};

pub const MD_INLINE_ATTR_INFO = struct {
    closer_index: c_int = 0, // Index of the closer mark that has attrs after it.
    attrs_beg: OFF = 0, // Offset of attrs content (after '{').
    attrs_end: OFF = 0, // Offset of '}' (exclusive).
    skip_end: OFF = 0, // Offset after '}' for text skipping.
};

// Context propagated through all the parsing. Internal struct — no C ABI needed.
// Field order/comments mirror struct MD_CTX_tag in md4x.c exactly.
pub const MD_CTX = struct {
    // Immutable stuff (parameters of md_parse()).
    text: [*c]const CHAR = null,
    size: SZ = 0,
    parser: c.MD_PARSER = std.mem.zeroes(c.MD_PARSER),
    userdata: ?*anyopaque = null,

    // When this is true, it allows some optimizations.
    doc_ends_with_newline: c_int = 0,

    // Helper temporary growing buffer.
    buffer: [*c]CHAR = null,
    alloc_buffer: c_uint = 0,

    // Reference definitions.
    ref_defs: [*c]MD_REF_DEF = null,
    n_ref_defs: c_int = 0,
    alloc_ref_defs: c_int = 0,
    ref_def_hashtable: [*c]?*anyopaque = null,
    ref_def_hashtable_size: c_int = 0,
    max_ref_def_output: SZ = 0,

    // Stack of inline/span markers.
    marks: [*c]MD_MARK = null,
    n_marks: c_int = 0,
    alloc_marks: c_int = 0,

    // UTF-8 build: 256-entry mark char map.
    mark_char_map: [256]u8 = [_]u8{0} ** 256,

    // For resolving of inline spans (the mod-3 emphasis layout). Indices:
    //   0-2  ASTERISK_OPENERS_oo_mod3_{0,1,2}   (opener-only)
    //   3-5  ASTERISK_OPENERS_oc_mod3_{0,1,2}   (opener+closer candidate)
    //   6-8  UNDERSCORE_OPENERS_oo_mod3_{0,1,2} (opener-only)
    //   9-11 UNDERSCORE_OPENERS_oc_mod3_{0,1,2} (opener+closer candidate)
    //   12   TILDE_OPENERS_1
    //   13   TILDE_OPENERS_2
    //   14   BRACKET_OPENERS
    //   15   DOLLAR_OPENERS
    opener_stacks: [16]MD_MARKSTACK = [_]MD_MARKSTACK{.{}} ** 16,

    // Stack of dummies which need to call free() for pointers stored in them.
    ptr_stack: MD_MARKSTACK = .{},

    // For resolving table rows.
    n_table_cell_boundaries: c_int = 0,
    table_cell_boundaries_head: c_int = 0,
    table_cell_boundaries_tail: c_int = 0,

    // For resolving links.
    unresolved_link_head: c_int = 0,
    unresolved_link_tail: c_int = 0,

    // For resolving raw HTML.
    html_comment_horizon: OFF = 0,
    html_proc_instr_horizon: OFF = 0,
    html_decl_horizon: OFF = 0,
    html_cdata_horizon: OFF = 0,

    // For block analysis. Holds MD_BLOCK as well as MD_LINE structures.
    block_bytes: ?*anyopaque = null,
    current_block: [*c]MD_BLOCK = null,
    n_block_bytes: c_int = 0,
    alloc_block_bytes: c_int = 0,

    // For container block analysis.
    containers: [*c]MD_CONTAINER = null,
    n_containers: c_int = 0,
    alloc_containers: c_int = 0,

    // Minimal indentation to call the block "indented code block".
    code_indent_offset: c_uint = 0,

    // Contextual info for line analysis.
    code_fence_length: SZ = 0, // For checking closing fence length.
    html_block_type: c_int = 0, // For checking closing raw HTML condition.
    frontmatter_state: c_int = 0, // 0: looking for opener, 1: inside, 2: done/disabled
    last_line_has_list_loosening_effect: c_int = 0,
    last_list_item_starts_with_two_blank_lines: c_int = 0,

    // Block component info array.
    block_component_info: [*c]MD_BLOCK_COMPONENT_INFO = null,
    n_block_components: c_int = 0,
    alloc_block_components: c_int = 0,
    block_component_nesting: c_int = 0,

    // Slot info array within block components.
    slot_info: [*c]MD_SLOT_INFO = null,
    n_slots: c_int = 0,
    alloc_slots: c_int = 0,

    // Alert info array.
    block_alert_info: [*c]MD_BLOCK_ALERT_INFO = null,
    n_block_alerts: c_int = 0,
    alloc_block_alerts: c_int = 0,

    // Inline attribute info array.
    inline_attrs: [*c]MD_INLINE_ATTR_INFO = null,
    n_inline_attrs: c_int = 0,
    alloc_inline_attrs: c_int = 0,
};

// ============================================================================
//  Helpers — character accessors / classification
// ============================================================================

// Character accessors. `CH(off)` / `STR(off)` from md4x.c operate on the
// enclosing `ctx`; here they are explicit helpers taking `ctx`.
// NOTE: ctx.text is `char*`; in classification we always reinterpret as the
// unsigned byte value to match the C `(unsigned)(ch)` casts.
inline fn CH(ctx: *const MD_CTX, off: OFF) CHAR {
    return ctx.text[off];
}
inline fn STR(ctx: *const MD_CTX, off: OFF) [*c]const CHAR {
    return ctx.text + off;
}

// Treat a CHAR (which may be signed `char`) as an unsigned byte, then widen.
// This reproduces C's `(unsigned)(ch)` on `char` operands which first promotes
// `char` to `int` (sign-extending), *but* the ISxxx macros only ever compare
// against ASCII ranges and use `(unsigned)`. md4c relies on the byte value for
// ASCII tests; for bytes >= 0x80 the comparisons fail anyway. To be exact with
// the C semantics where `(unsigned)(char)0x80 == 0xffffff80`, we sign-extend
// like C does. The ISxxx predicates are written to match that.
inline fn uval(ch: CHAR) c_uint {
    // C: (unsigned)(ch) where `ch` is plain `char`. The C parser is compiled
    // with Zig's clang where `char` is SIGNED on x86-64/aarch64 Linux + Windows
    // (the targets we ship), so `(unsigned)(char)0x80 == 0xFFFFFF80`. Zig's
    // @cImport maps C `char` to `u8` (unsigned), so we must reinterpret the
    // byte's bit pattern as a signed `i8` first, then sign-extend through c_int
    // and bitcast to unsigned — reproducing the signed-char promotion exactly.
    // (This only affects the md_decode_utf8 fallback return for invalid bytes;
    // the ASCII-range ISxxx predicates are unaffected.)
    const signed: i8 = @bitCast(@as(u8, @bitCast(ch)));
    return @bitCast(@as(c_int, signed));
}

inline fn ISIN_(ch: CHAR, ch_min: c_uint, ch_max: c_uint) bool {
    const u = uval(ch);
    return ch_min <= u and u <= ch_max;
}
inline fn ISANYOF2_(ch: CHAR, ch1: CHAR, ch2: CHAR) bool {
    return ch == ch1 or ch == ch2;
}
inline fn ISANYOF3_(ch: CHAR, ch1: CHAR, ch2: CHAR, ch3: CHAR) bool {
    return ch == ch1 or ch == ch2 or ch == ch3;
}
inline fn ISASCII_(ch: CHAR) bool {
    return uval(ch) <= 127;
}
inline fn ISBLANK_(ch: CHAR) bool {
    return ISANYOF2_(ch, ' ', '\t');
}
inline fn ISNEWLINE_(ch: CHAR) bool {
    return ISANYOF2_(ch, '\r', '\n');
}
inline fn ISWHITESPACE_(ch: CHAR) bool {
    return ISBLANK_(ch) or ISANYOF2_(ch, 11, 12); // '\v', '\f'
}
inline fn ISCNTRL_(ch: CHAR) bool {
    const u = uval(ch);
    return u <= 31 or u == 127;
}
inline fn ISPUNCT_(ch: CHAR) bool {
    return ISIN_(ch, 33, 47) or ISIN_(ch, 58, 64) or ISIN_(ch, 91, 96) or ISIN_(ch, 123, 126);
}
inline fn ISUPPER_(ch: CHAR) bool {
    return ISIN_(ch, 'A', 'Z');
}
inline fn ISLOWER_(ch: CHAR) bool {
    return ISIN_(ch, 'a', 'z');
}
inline fn ISALPHA_(ch: CHAR) bool {
    return ISUPPER_(ch) or ISLOWER_(ch);
}
inline fn ISDIGIT_(ch: CHAR) bool {
    return ISIN_(ch, '0', '9');
}
inline fn ISXDIGIT_(ch: CHAR) bool {
    return ISDIGIT_(ch) or ISIN_(ch, 'A', 'F') or ISIN_(ch, 'a', 'f');
}
inline fn ISALNUM_(ch: CHAR) bool {
    return ISALPHA_(ch) or ISDIGIT_(ch);
}

// `ISANYOF_(ch, palette)`: ch != '\0' && md_strchr(palette, ch) != NULL.
inline fn ISANYOF_(ch: CHAR, palette: [*:0]const u8) bool {
    return ch != 0 and md_strchr(palette, ch) != null;
}

// Offset-based wrappers (CH(off) variants).
inline fn ISANYOF(ctx: *const MD_CTX, off: OFF, palette: [*:0]const u8) bool {
    return ISANYOF_(CH(ctx, off), palette);
}
inline fn ISANYOF2(ctx: *const MD_CTX, off: OFF, ch1: CHAR, ch2: CHAR) bool {
    return ISANYOF2_(CH(ctx, off), ch1, ch2);
}
inline fn ISANYOF3(ctx: *const MD_CTX, off: OFF, ch1: CHAR, ch2: CHAR, ch3: CHAR) bool {
    return ISANYOF3_(CH(ctx, off), ch1, ch2, ch3);
}
inline fn ISASCII(ctx: *const MD_CTX, off: OFF) bool {
    return ISASCII_(CH(ctx, off));
}
inline fn ISBLANK(ctx: *const MD_CTX, off: OFF) bool {
    return ISBLANK_(CH(ctx, off));
}
inline fn ISNEWLINE(ctx: *const MD_CTX, off: OFF) bool {
    return ISNEWLINE_(CH(ctx, off));
}
inline fn ISWHITESPACE(ctx: *const MD_CTX, off: OFF) bool {
    return ISWHITESPACE_(CH(ctx, off));
}
inline fn ISCNTRL(ctx: *const MD_CTX, off: OFF) bool {
    return ISCNTRL_(CH(ctx, off));
}
inline fn ISPUNCT(ctx: *const MD_CTX, off: OFF) bool {
    return ISPUNCT_(CH(ctx, off));
}
inline fn ISUPPER(ctx: *const MD_CTX, off: OFF) bool {
    return ISUPPER_(CH(ctx, off));
}
inline fn ISLOWER(ctx: *const MD_CTX, off: OFF) bool {
    return ISLOWER_(CH(ctx, off));
}
inline fn ISALPHA(ctx: *const MD_CTX, off: OFF) bool {
    return ISALPHA_(CH(ctx, off));
}
inline fn ISDIGIT(ctx: *const MD_CTX, off: OFF) bool {
    return ISDIGIT_(CH(ctx, off));
}
inline fn ISXDIGIT(ctx: *const MD_CTX, off: OFF) bool {
    return ISXDIGIT_(CH(ctx, off));
}
inline fn ISALNUM(ctx: *const MD_CTX, off: OFF) bool {
    return ISALNUM_(CH(ctx, off));
}

// `md_strchr` — C's strchr(palette, ch): returns pointer to first occurrence of
// (char)ch in NUL-terminated palette, including matching the terminating NUL.
// Returns null if not found. We replicate the exact C contract (NUL match).
fn md_strchr(palette: [*:0]const u8, ch: CHAR) ?[*:0]const u8 {
    // C strchr compares (char)ch; the NUL terminator is part of the searched
    // string, so strchr(s, '\0') returns the pointer to the terminator.
    const needle: u8 = @bitCast(ch);
    var p: [*:0]const u8 = palette;
    while (true) : (p += 1) {
        if (p[0] == needle) return p;
        if (p[0] == 0) return null;
    }
}

// Case insensitive check of string equality (ASCII). Mirrors md_ascii_case_eq.
inline fn md_ascii_case_eq(s1: [*c]const CHAR, s2: [*c]const CHAR, n: SZ) c_int {
    var i: OFF = 0;
    while (i < n) : (i += 1) {
        var ch1: CHAR = s1[i];
        var ch2: CHAR = s2[i];
        // C: ch += ('A' - 'a') == ch - 32 on char; wrap in the byte domain.
        if (ISLOWER_(ch1)) ch1 -%= 32;
        if (ISLOWER_(ch2)) ch2 -%= 32;
        if (ch1 != ch2) return FALSE;
    }
    return TRUE;
}

inline fn md_ascii_eq(s1: [*c]const CHAR, s2: [*c]const CHAR, n: SZ) c_int {
    const a = @as([*]const u8, @ptrCast(s1))[0..n];
    const b = @as([*]const u8, @ptrCast(s2))[0..n];
    return if (std.mem.eql(u8, a, b)) TRUE else FALSE;
}

// `md_text_with_null_replacement` — split a run at NUL bytes, emitting
// MD_TEXT_NULLCHAR for each. Returns the callback's non-zero code or 0.
fn md_text_with_null_replacement(ctx: *MD_CTX, ttype: c.MD_TEXTTYPE, str_in: [*c]const CHAR, size_in: SZ) c_int {
    var str = str_in;
    var size = size_in;
    var off: OFF = 0;
    var ret: c_int = 0;

    while (true) {
        while (off < size and str[off] != 0) off += 1;

        if (off > 0) {
            ret = ctx.parser.text.?(ttype, str, off, ctx.userdata);
            if (ret != 0) return ret;
            str += off;
            size -= off;
            off = 0;
        }

        if (off >= size) return 0;

        ret = ctx.parser.text.?(c.MD_TEXT_NULLCHAR, "", 1, ctx.userdata);
        if (ret != 0) return ret;
        str += 1;
        size -= 1;
        off = 0;
    }
}

// ----------------------------------------------------------------------------
// MD_TEMP_BUFFER(sz) — grow ctx->buffer to at least `sz` CHARs. Returns 0 on
// success, -1 on OOM (the C macro `goto abort`s; callers translate via try).
// ----------------------------------------------------------------------------
fn md_temp_buffer(ctx: *MD_CTX, sz: SZ) c_int {
    if (sz > ctx.alloc_buffer) {
        // C: new_size = ((sz) + (sz)/2 + 128) & ~127. Arithmetic in SZ (c_uint).
        const new_size: SZ = (sz +% sz / 2 +% 128) & ~@as(SZ, 127);
        // Use raw libc realloc to mirror C exactly (realloc(ctx->buffer, new_size)).
        // ctx.buffer may be null on first call, which realloc treats as malloc.
        const new_buffer = c_realloc_array(CHAR, ctx.buffer, @intCast(new_size));
        if (new_buffer == null) {
            md_log(ctx, "realloc() failed.");
            return -1;
        }
        ctx.buffer = new_buffer;
        ctx.alloc_buffer = new_size;
    }
    return 0;
}

// ============================================================================
//  Unicode Support
// ============================================================================

pub const MD_UNICODE_FOLD_INFO = struct {
    codepoints: [3]c_uint = .{ 0, 0, 0 },
    n_codepoints: c_uint = 0,
};

// Binary search over a sorted "map" of codepoints. Range-encoding:
//   (MIN | 0x40000000) and (MAX | 0x80000000). Returns the index of the found
// record (range minimum) or -1. Faithful port of md_unicode_bsearch__.
fn md_unicode_bsearch(codepoint: c_uint, map: []const c_uint) c_int {
    var beg: c_int = 0;
    var end: c_int = @as(c_int, @intCast(map.len)) - 1;
    while (beg <= end) {
        var pivot_beg: c_int = @divTrunc(beg + end, 2);
        var pivot_end: c_int = pivot_beg;
        if (map[@intCast(pivot_end)] & 0x40000000 != 0) pivot_end += 1;
        if (map[@intCast(pivot_beg)] & 0x80000000 != 0) pivot_beg -= 1;

        if (codepoint < (map[@intCast(pivot_beg)] & 0x00ffffff)) {
            end = pivot_beg - 1;
        } else if (codepoint > (map[@intCast(pivot_end)] & 0x00ffffff)) {
            beg = pivot_end + 1;
        } else {
            return pivot_beg;
        }
    }
    return -1;
}

fn md_is_unicode_whitespace(codepoint: c_uint) c_int {
    // ASCII fast path (also CommonMark few more in this range).
    if (codepoint <= 0x7f) {
        return if (ISWHITESPACE_(@as(CHAR, @intCast(codepoint)))) TRUE else FALSE;
    }
    return if (md_unicode_bsearch(codepoint, &utbl.WHITESPACE_MAP) >= 0) TRUE else FALSE;
}

fn md_is_unicode_punct(codepoint: c_uint) c_int {
    if (codepoint <= 0x7f) {
        return if (ISPUNCT_(@as(CHAR, @intCast(codepoint)))) TRUE else FALSE;
    }
    return if (md_unicode_bsearch(codepoint, &utbl.PUNCT_MAP) >= 0) TRUE else FALSE;
}

const FoldMapEntry = struct {
    map: []const c_uint,
    data: []const c_uint,
    n_codepoints: c_uint,
};
const FOLD_MAP_LIST = [_]FoldMapEntry{
    .{ .map = &utbl.FOLD_MAP_1, .data = &utbl.FOLD_MAP_1_DATA, .n_codepoints = 1 },
    .{ .map = &utbl.FOLD_MAP_2, .data = &utbl.FOLD_MAP_2_DATA, .n_codepoints = 2 },
    .{ .map = &utbl.FOLD_MAP_3, .data = &utbl.FOLD_MAP_3_DATA, .n_codepoints = 3 },
};

fn md_get_unicode_fold_info(codepoint: c_uint, info: *MD_UNICODE_FOLD_INFO) void {
    // Fast path for ASCII characters.
    if (codepoint <= 0x7f) {
        info.codepoints[0] = codepoint;
        if (ISUPPER_(@as(CHAR, @intCast(codepoint)))) info.codepoints[0] += 'a' - 'A';
        info.n_codepoints = 1;
        return;
    }

    // Try to locate the codepoint in any of the maps.
    for (FOLD_MAP_LIST) |entry| {
        const index = md_unicode_bsearch(codepoint, entry.map);
        if (index >= 0) {
            const ui: usize = @intCast(index);
            const n_codepoints = entry.n_codepoints;
            const map = entry.map;
            const codepoints = entry.data[ui * n_codepoints ..];

            var k: usize = 0;
            while (k < n_codepoints) : (k += 1) info.codepoints[k] = codepoints[k];
            info.n_codepoints = n_codepoints;

            if (map[ui] != codepoint) {
                // The found mapping maps a whole range of codepoints; offset
                // info->codepoints[0] accordingly.
                if ((map[ui] & 0x00ffffff) + 1 == codepoints[0]) {
                    // Alternating type of the range.
                    info.codepoints[0] = codepoint + (if ((codepoint & 0x1) == (map[ui] & 0x1)) @as(c_uint, 1) else 0);
                } else {
                    // Range to range kind of mapping.
                    info.codepoints[0] += (codepoint - (map[ui] & 0x00ffffff));
                }
            }
            return;
        }
    }

    // No mapping found. Map the codepoint to itself.
    info.codepoints[0] = codepoint;
    info.n_codepoints = 1;
}

// ----------------------------------------------------------------------------
// UTF-8 codec (MD4X_USE_UTF8). Faithful port of md_decode_utf8__,
// md_decode_utf8_before__, md_decode_unicode.
// ----------------------------------------------------------------------------
inline fn IS_UTF8_LEAD1(byte: CHAR) bool {
    return @as(u8, @bitCast(byte)) <= 0x7f;
}
inline fn IS_UTF8_LEAD2(byte: CHAR) bool {
    return (@as(u8, @bitCast(byte)) & 0xe0) == 0xc0;
}
inline fn IS_UTF8_LEAD3(byte: CHAR) bool {
    return (@as(u8, @bitCast(byte)) & 0xf0) == 0xe0;
}
inline fn IS_UTF8_LEAD4(byte: CHAR) bool {
    return (@as(u8, @bitCast(byte)) & 0xf8) == 0xf0;
}
inline fn IS_UTF8_TAIL(byte: CHAR) bool {
    return (@as(u8, @bitCast(byte)) & 0xc0) == 0x80;
}

// C bit-ops use `(unsigned int)str[i]` which sign-extends the signed char. We
// replicate that exact value via uval() to keep the (rare) high-bit masking
// identical to C even though the masks (& 0x1f, & 0x3f, ...) make sign moot.
fn md_decode_utf8(str: [*c]const CHAR, str_size: SZ, p_size: ?*SZ) c_uint {
    if (!IS_UTF8_LEAD1(str[0])) {
        if (IS_UTF8_LEAD2(str[0])) {
            if (1 < str_size and IS_UTF8_TAIL(str[1])) {
                if (p_size) |ps| ps.* = 2;
                return ((uval(str[0]) & 0x1f) << 6) |
                    ((uval(str[1]) & 0x3f) << 0);
            }
        } else if (IS_UTF8_LEAD3(str[0])) {
            if (2 < str_size and IS_UTF8_TAIL(str[1]) and IS_UTF8_TAIL(str[2])) {
                if (p_size) |ps| ps.* = 3;
                return ((uval(str[0]) & 0x0f) << 12) |
                    ((uval(str[1]) & 0x3f) << 6) |
                    ((uval(str[2]) & 0x3f) << 0);
            }
        } else if (IS_UTF8_LEAD4(str[0])) {
            if (3 < str_size and IS_UTF8_TAIL(str[1]) and IS_UTF8_TAIL(str[2]) and IS_UTF8_TAIL(str[3])) {
                if (p_size) |ps| ps.* = 4;
                return ((uval(str[0]) & 0x07) << 18) |
                    ((uval(str[1]) & 0x3f) << 12) |
                    ((uval(str[2]) & 0x3f) << 6) |
                    ((uval(str[3]) & 0x3f) << 0);
            }
        }
    }
    if (p_size) |ps| ps.* = 1;
    return uval(str[0]);
}

fn md_decode_utf8_before(ctx: *const MD_CTX, off: OFF) c_uint {
    if (!IS_UTF8_LEAD1(CH(ctx, off - 1))) {
        if (off > 1 and IS_UTF8_LEAD2(CH(ctx, off - 2)) and IS_UTF8_TAIL(CH(ctx, off - 1)))
            return ((uval(CH(ctx, off - 2)) & 0x1f) << 6) |
                ((uval(CH(ctx, off - 1)) & 0x3f) << 0);

        if (off > 2 and IS_UTF8_LEAD3(CH(ctx, off - 3)) and IS_UTF8_TAIL(CH(ctx, off - 2)) and IS_UTF8_TAIL(CH(ctx, off - 1)))
            return ((uval(CH(ctx, off - 3)) & 0x0f) << 12) |
                ((uval(CH(ctx, off - 2)) & 0x3f) << 6) |
                ((uval(CH(ctx, off - 1)) & 0x3f) << 0);

        if (off > 3 and IS_UTF8_LEAD4(CH(ctx, off - 4)) and IS_UTF8_TAIL(CH(ctx, off - 3)) and IS_UTF8_TAIL(CH(ctx, off - 2)) and IS_UTF8_TAIL(CH(ctx, off - 1)))
            return ((uval(CH(ctx, off - 4)) & 0x07) << 18) |
                ((uval(CH(ctx, off - 3)) & 0x3f) << 12) |
                ((uval(CH(ctx, off - 2)) & 0x3f) << 6) |
                ((uval(CH(ctx, off - 1)) & 0x3f) << 0);
    }
    return uval(CH(ctx, off - 1));
}

inline fn md_decode_unicode(str: [*c]const CHAR, off: OFF, str_size: SZ, p_char_size: ?*SZ) c_uint {
    return md_decode_utf8(str + off, str_size - off, p_char_size);
}

// ISUNICODE* offset wrappers (UTF-8 build).
inline fn ISUNICODEWHITESPACE_(codepoint: c_uint) c_int {
    return md_is_unicode_whitespace(codepoint);
}
inline fn ISUNICODEWHITESPACE(ctx: *const MD_CTX, off: OFF) bool {
    return md_is_unicode_whitespace(md_decode_utf8(STR(ctx, off), ctx.size - off, null)) != 0;
}
inline fn ISUNICODEWHITESPACEBEFORE(ctx: *const MD_CTX, off: OFF) bool {
    return md_is_unicode_whitespace(md_decode_utf8_before(ctx, off)) != 0;
}
inline fn ISUNICODEPUNCT(ctx: *const MD_CTX, off: OFF) bool {
    return md_is_unicode_punct(md_decode_utf8(STR(ctx, off), ctx.size - off, null)) != 0;
}
inline fn ISUNICODEPUNCTBEFORE(ctx: *const MD_CTX, off: OFF) bool {
    return md_is_unicode_punct(md_decode_utf8_before(ctx, off)) != 0;
}

// ============================================================================
//  Helper string manipulations
// ============================================================================

// Fill `buffer` with copy of [beg, end) replacing line breaks with the given
// char. Caller guarantees buffer is large enough (>= end-beg). Mirrors
// md_merge_lines exactly.
fn md_merge_lines(ctx: *const MD_CTX, beg: OFF, end: OFF, lines: [*c]const MD_LINE, n_lines: MD_SIZE, line_break_replacement_char: CHAR, buffer: [*c]CHAR, p_size: *SZ) void {
    _ = n_lines;
    var ptr = buffer;
    var line_index: c_int = 0;
    var off: OFF = beg;

    while (true) {
        const line = &lines[@intCast(line_index)];
        var line_end = line.end;
        if (end < line_end) line_end = end;

        while (off < line_end) {
            ptr[0] = CH(ctx, off);
            ptr += 1;
            off += 1;
        }

        if (off >= end) {
            p_size.* = @intCast(@intFromPtr(ptr) - @intFromPtr(buffer));
            return;
        }

        ptr[0] = line_break_replacement_char;
        ptr += 1;

        line_index += 1;
        off = lines[@intCast(line_index)].beg;
    }
}

// Wrapper of md_merge_lines() which allocates the output. Returns 0 / -1.
fn md_merge_lines_alloc(ctx: *MD_CTX, beg: OFF, end: OFF, lines: [*c]const MD_LINE, n_lines: MD_SIZE, line_break_replacement_char: CHAR, p_str: *[*c]CHAR, p_size: *SZ) c_int {
    const n: usize = @intCast(end - beg);
    const buffer = c_allocator.alloc(CHAR, n) catch {
        md_log(ctx, "malloc() failed.");
        return -1;
    };
    md_merge_lines(ctx, beg, end, lines, n_lines, line_break_replacement_char, buffer.ptr, p_size);
    p_str.* = buffer.ptr;
    return 0;
}

fn md_skip_unicode_whitespace(label: [*c]const CHAR, off_in: OFF, size: SZ) OFF {
    var off = off_in;
    while (off < size) {
        var char_size: SZ = undefined;
        const codepoint = md_decode_unicode(label, off, size, &char_size);
        if (ISUNICODEWHITESPACE_(codepoint) == 0 and !ISNEWLINE_(label[off])) break;
        off += char_size;
    }
    return off;
}

// ============================================================================
//  Recognizing HTML entities
// ============================================================================

fn md_is_hex_entity_contents(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    _ = ctx;
    var off = beg;
    while (off < max_end and ISXDIGIT_(text[off]) and off - beg <= 8) off += 1;
    if (1 <= off - beg and off - beg <= 6) {
        p_end.* = off;
        return TRUE;
    }
    return FALSE;
}

fn md_is_dec_entity_contents(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    _ = ctx;
    var off = beg;
    while (off < max_end and ISDIGIT_(text[off]) and off - beg <= 8) off += 1;
    if (1 <= off - beg and off - beg <= 7) {
        p_end.* = off;
        return TRUE;
    }
    return FALSE;
}

fn md_is_named_entity_contents(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    _ = ctx;
    var off = beg;
    if (off < max_end and ISALPHA_(text[off])) {
        off += 1;
    } else {
        return FALSE;
    }
    while (off < max_end and ISALNUM_(text[off]) and off - beg <= 48) off += 1;
    if (2 <= off - beg and off - beg <= 48) {
        p_end.* = off;
        return TRUE;
    }
    return FALSE;
}

fn md_is_entity_str(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off = beg;
    // MD_ASSERT(text[off] == '&'); — defensive guard instead of UB-assert.
    off += 1;

    var is_contents: c_int = undefined;
    if (off + 2 < max_end and text[off] == '#' and (text[off + 1] == 'x' or text[off + 1] == 'X')) {
        is_contents = md_is_hex_entity_contents(ctx, text, off + 2, max_end, &off);
    } else if (off + 1 < max_end and text[off] == '#') {
        is_contents = md_is_dec_entity_contents(ctx, text, off + 1, max_end, &off);
    } else {
        is_contents = md_is_named_entity_contents(ctx, text, off, max_end, &off);
    }

    if (is_contents != 0 and off < max_end and text[off] == ';') {
        p_end.* = off + 1;
        return TRUE;
    }
    return FALSE;
}

inline fn md_is_entity(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    return md_is_entity_str(ctx, ctx.text, beg, max_end, p_end);
}

// ============================================================================
//  Attribute Management
// ============================================================================

pub const MD_ATTRIBUTE_BUILD = struct {
    text: [*c]CHAR = null,
    substr_types: [*c]c.MD_TEXTTYPE = null,
    substr_offsets: [*c]OFF = null,
    substr_count: c_int = 0,
    substr_alloc: c_int = 0,
    trivial_types: [1]c.MD_TEXTTYPE = .{0},
    trivial_offsets: [2]OFF = .{ 0, 0 },
};

const MD_BUILD_ATTR_NO_ESCAPES: c_uint = 0x0001;

fn md_build_attr_append_substr(ctx: *MD_CTX, build: *MD_ATTRIBUTE_BUILD, ttype: c.MD_TEXTTYPE, off: OFF) c_int {
    if (build.substr_count >= build.substr_alloc) {
        build.substr_alloc = if (build.substr_alloc > 0)
            build.substr_alloc + @divTrunc(build.substr_alloc, 2)
        else
            8;
        const alloc_u: usize = @intCast(build.substr_alloc);

        // realloc substr_types.
        // realloc substr_types (libc realloc tracks the old block's size).
        const new_types = c_realloc_array(c.MD_TEXTTYPE, build.substr_types, alloc_u);
        if (new_types == null) {
            md_log(ctx, "realloc() failed.");
            return -1;
        }
        build.substr_types = new_types;

        // realloc substr_offsets (+1 for final offset == raw_size).
        const new_offsets = c_realloc_array(OFF, build.substr_offsets, alloc_u + 1);
        if (new_offsets == null) {
            md_log(ctx, "realloc() failed.");
            return -1;
        }
        build.substr_offsets = new_offsets;
    }

    build.substr_types[@intCast(build.substr_count)] = ttype;
    build.substr_offsets[@intCast(build.substr_count)] = off;
    build.substr_count += 1;
    return 0;
}

fn md_free_attribute(ctx: *MD_CTX, build: *MD_ATTRIBUTE_BUILD) void {
    _ = ctx;
    if (build.substr_alloc > 0) {
        if (build.text != null) std.c.free(build.text);
        if (build.substr_types != null) std.c.free(build.substr_types);
        if (build.substr_offsets != null) std.c.free(build.substr_offsets);
    }
}

fn md_build_attribute(ctx: *MD_CTX, raw_text: [*c]const CHAR, raw_size: SZ, flags: c_uint, attr: *c.MD_ATTRIBUTE, build: *MD_ATTRIBUTE_BUILD) c_int {
    var raw_off: OFF = 0;
    var off: OFF = 0;
    var ret: c_int = 0;
    _ = &ret;

    // C: memset(build, 0, sizeof(MD_ATTRIBUTE_BUILD)). Use zeroes to match the
    // byte-level zero-init exactly (defaults could leave padding uninitialized).
    build.* = std.mem.zeroes(MD_ATTRIBUTE_BUILD);

    // Trivial path if no backslash, ampersand, or NUL.
    var is_trivial = true;
    raw_off = 0;
    while (raw_off < raw_size) : (raw_off += 1) {
        if (ISANYOF3_(raw_text[raw_off], '\\', '&', 0)) {
            is_trivial = false;
            break;
        }
    }

    if (is_trivial) {
        build.text = if (raw_size != 0) @constCast(raw_text) else null;
        build.substr_types = &build.trivial_types;
        build.substr_offsets = &build.trivial_offsets;
        build.substr_count = 1;
        build.substr_alloc = 0;
        build.trivial_types[0] = c.MD_TEXT_NORMAL;
        build.trivial_offsets[0] = 0;
        build.trivial_offsets[1] = raw_size;
        off = raw_size;
    } else {
        const buf = c_malloc_array(CHAR, raw_size);
        if (buf == null) {
            md_log(ctx, "malloc() failed.");
            md_free_attribute(ctx, build);
            return -1;
        }
        build.text = buf;

        raw_off = 0;
        off = 0;

        while (raw_off < raw_size) {
            if (raw_text[raw_off] == 0) {
                if (md_build_attr_append_substr(ctx, build, c.MD_TEXT_NULLCHAR, off) < 0) {
                    md_free_attribute(ctx, build);
                    return -1;
                }
                @memcpy(@as([*]u8, @ptrCast(build.text + off))[0..1], @as([*]const u8, @ptrCast(raw_text + raw_off))[0..1]);
                off += 1;
                raw_off += 1;
                continue;
            }

            if (raw_text[raw_off] == '&') {
                var ent_end: OFF = undefined;
                if (md_is_entity_str(ctx, raw_text, raw_off, raw_size, &ent_end) != 0) {
                    if (md_build_attr_append_substr(ctx, build, c.MD_TEXT_ENTITY, off) < 0) {
                        md_free_attribute(ctx, build);
                        return -1;
                    }
                    const n: usize = @intCast(ent_end - raw_off);
                    @memcpy(@as([*]u8, @ptrCast(build.text + off))[0..n], @as([*]const u8, @ptrCast(raw_text + raw_off))[0..n]);
                    off += ent_end - raw_off;
                    raw_off = ent_end;
                    continue;
                }
            }

            if (build.substr_count == 0 or build.substr_types[@intCast(build.substr_count - 1)] != c.MD_TEXT_NORMAL) {
                if (md_build_attr_append_substr(ctx, build, c.MD_TEXT_NORMAL, off) < 0) {
                    md_free_attribute(ctx, build);
                    return -1;
                }
            }

            if ((flags & MD_BUILD_ATTR_NO_ESCAPES) == 0 and
                raw_text[raw_off] == '\\' and raw_off + 1 < raw_size and
                (ISPUNCT_(raw_text[raw_off + 1]) or ISNEWLINE_(raw_text[raw_off + 1])))
            {
                raw_off += 1;
            }

            build.text[off] = raw_text[raw_off];
            off += 1;
            raw_off += 1;
        }
        build.substr_offsets[@intCast(build.substr_count)] = off;
    }

    attr.text = build.text;
    attr.size = off;
    attr.substr_offsets = build.substr_offsets;
    attr.substr_types = build.substr_types;
    return 0;
}

// ============================================================================
//  Line lookup (binary search over the analyzed lines)
// ============================================================================

// Faithful port of md_lookup_line (md4x.c ~558). If the offset falls into a gap
// between lines, returns the following line. n_lines/lines are MD_LINE arrays.
fn md_lookup_line(off: OFF, lines: [*c]const MD_LINE, n_lines: MD_SIZE, p_line_index: ?*MD_SIZE) *const MD_LINE {
    var lo: MD_SIZE = 0;
    var hi: MD_SIZE = n_lines - 1;
    while (lo <= hi) {
        const pivot: MD_SIZE = (lo + hi) / 2;
        const line: *const MD_LINE = @ptrCast(&lines[pivot]);

        if (off < line.beg) {
            if (hi == 0 or lines[hi - 1].end < off) {
                if (p_line_index) |p| p.* = pivot;
                return line;
            }
            hi = pivot - 1;
        } else if (off > line.end) {
            lo = pivot + 1;
        } else {
            if (p_line_index) |p| p.* = pivot;
            return line;
        }
    }

    // C: unreachable in practice (the document always has a "following" line);
    // mirror the C fall-through which returns &lines[n_lines-1] would be UB, but
    // the C code has no return here — it relies on the loop always returning.
    // We return the last line defensively (cannot be hit for well-formed input).
    return @ptrCast(&lines[n_lines - 1]);
}

// libc qsort/bsearch (not exposed by std.c in this Zig version). Same
// signatures as C. Used so ordering/tie-breaking matches glibc byte-for-byte.
const c_cmp_fn = *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;
extern "c" fn qsort(base: ?*anyopaque, nmemb: usize, size: usize, compar: c_cmp_fn) void;
extern "c" fn bsearch(key: ?*const anyopaque, base: ?*const anyopaque, nmemb: usize, size: usize, compar: c_cmp_fn) ?*anyopaque;
extern "c" fn memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) c_int;
extern "c" fn strcspn(s: [*c]const u8, reject: [*c]const u8) usize;
extern "c" fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;

// ============================================================================
//  Reference Definitions — FNV-1a, label hash/compare, hashtable build/lookup
// ============================================================================

const MD_FNV1A_BASE: c_uint = 2166136261;
const MD_FNV1A_PRIME: c_uint = 16777619;

// Faithful port of md_fnv1a (md4x.c ~1620). Wrapping multiply matches C's
// unsigned overflow semantics.
inline fn md_fnv1a(base: c_uint, data: [*]const u8, n: usize) c_uint {
    var hash: c_uint = base;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        hash ^= data[i];
        hash *%= MD_FNV1A_PRIME;
    }
    return hash;
}

// Hash one `unsigned` codepoint, matching C's `md_fnv1a(hash, &cp, sizeof(unsigned))`.
// The C code hashes the raw machine bytes of the `unsigned` (little-endian on our
// targets). We reproduce that by hashing the 4 bytes in native byte order.
inline fn md_fnv1a_uint(base: c_uint, cp: c_uint) c_uint {
    const bytes = std.mem.asBytes(&cp);
    return md_fnv1a(base, bytes.ptr, bytes.len);
}

// Faithful port of md_link_label_hash (md4x.c ~1652).
fn md_link_label_hash(label: [*c]const CHAR, size: SZ) c_uint {
    var hash: c_uint = MD_FNV1A_BASE;

    var off: OFF = md_skip_unicode_whitespace(label, 0, size);
    while (off < size) {
        var char_size: SZ = undefined;
        var codepoint = md_decode_unicode(label, off, size, &char_size);
        const is_whitespace = (ISUNICODEWHITESPACE_(codepoint) != 0) or ISNEWLINE_(label[off]);

        if (is_whitespace) {
            codepoint = ' ';
            hash = md_fnv1a_uint(hash, codepoint);
            off = md_skip_unicode_whitespace(label, off, size);
        } else {
            var fold_info: MD_UNICODE_FOLD_INFO = .{};
            md_get_unicode_fold_info(codepoint, &fold_info);
            // C: md_fnv1a(hash, fold_info.codepoints, n_codepoints * sizeof(unsigned)).
            const n: usize = @intCast(fold_info.n_codepoints);
            const bytes = std.mem.sliceAsBytes(fold_info.codepoints[0..n]);
            hash = md_fnv1a(hash, bytes.ptr, bytes.len);
            off += char_size;
        }
    }

    return hash;
}

// Faithful port of md_link_label_cmp_load_fold_info (md4x.c ~1683).
fn md_link_label_cmp_load_fold_info(label: [*c]const CHAR, off_in: OFF, size: SZ, fold_info: *MD_UNICODE_FOLD_INFO) OFF {
    var off = off_in;

    whitespace: {
        if (off >= size) {
            // Treat end of a link label as whitespace.
            break :whitespace;
        }

        var char_size: SZ = undefined;
        const codepoint = md_decode_unicode(label, off, size, &char_size);
        off += char_size;
        if (ISUNICODEWHITESPACE_(codepoint) != 0) {
            // Treat all whitespace as equivalent.
            break :whitespace;
        }

        // Get real folding info.
        md_get_unicode_fold_info(codepoint, fold_info);
        return off;
    }

    fold_info.codepoints[0] = ' ';
    fold_info.n_codepoints = 1;
    return md_skip_unicode_whitespace(label, off, size);
}

// Faithful port of md_link_label_cmp (md4x.c ~1712). Returns a tri-state int
// (sign-significant) like C — `b - a` per codepoint, so callers using the sign
// behave identically.
fn md_link_label_cmp(a_label: [*c]const CHAR, a_size: SZ, b_label: [*c]const CHAR, b_size: SZ) c_int {
    var a_fi: MD_UNICODE_FOLD_INFO = .{};
    var b_fi: MD_UNICODE_FOLD_INFO = .{};
    var a_fi_off: OFF = 0;
    var b_fi_off: OFF = 0;

    var a_off: OFF = md_skip_unicode_whitespace(a_label, 0, a_size);
    var b_off: OFF = md_skip_unicode_whitespace(b_label, 0, b_size);
    while (a_off < a_size or a_fi_off < a_fi.n_codepoints or
        b_off < b_size or b_fi_off < b_fi.n_codepoints)
    {
        // If needed, load fold info for next char.
        if (a_fi_off >= a_fi.n_codepoints) {
            a_fi_off = 0;
            a_off = md_link_label_cmp_load_fold_info(a_label, a_off, a_size, &a_fi);
        }
        if (b_fi_off >= b_fi.n_codepoints) {
            b_fi_off = 0;
            b_off = md_link_label_cmp_load_fold_info(b_label, b_off, b_size, &b_fi);
        }

        // C: cmp = b_fi.codepoints[b_fi_off] - a_fi.codepoints[a_fi_off];
        // Both operands are `unsigned`; the difference is computed in `unsigned`
        // then assigned to `int` (implementation-defined but on our targets a
        // plain bit-reinterpretation). Reproduce via wrapping subtract + bitcast.
        const diff: c_uint = b_fi.codepoints[b_fi_off] -% a_fi.codepoints[a_fi_off];
        const cmp: c_int = @bitCast(diff);
        if (cmp != 0)
            return cmp;

        a_fi_off += 1;
        b_fi_off += 1;
    }

    return 0;
}

// Pointer arithmetic helper: the flexible-array `ref_defs[]` of MD_REF_DEF_LIST
// begins immediately after the header. Returns a many-item pointer to the array.
inline fn md_ref_def_list_items(list: *MD_REF_DEF_LIST) [*c]?*MD_REF_DEF {
    const base: [*]u8 = @ptrCast(list);
    return @ptrCast(@alignCast(base + @sizeOf(MD_REF_DEF_LIST)));
}

// qsort/bsearch comparators. CRITICAL ORDERING NOTE (see PARSER-PORT.md log):
// these mirror md_ref_def_cmp / md_ref_def_cmp_for_sort byte-for-byte and are
// passed to libc qsort()/bsearch() (via std.c) so that, on the *same* glibc
// runtime, the ordering and tie-breaking are bit-identical to the C parser. The
// comparators read only the MD_REF_DEF fields + the pointer values (for sort
// stability) — they need no ctx, so they are pure `callconv(.c)` functions.
//
// `a`/`b` are `const void*` pointing at `MD_REF_DEF*` slots (i.e. *(MD_REF_DEF**)).
fn md_ref_def_cmp(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    const a_pp: *const (*const MD_REF_DEF) = @ptrCast(@alignCast(a.?));
    const b_pp: *const (*const MD_REF_DEF) = @ptrCast(@alignCast(b.?));
    const a_ref = a_pp.*;
    const b_ref = b_pp.*;

    if (a_ref.hash < b_ref.hash)
        return -1
    else if (a_ref.hash > b_ref.hash)
        return 1
    else
        return md_link_label_cmp(a_ref.label, a_ref.label_size, b_ref.label, b_ref.label_size);
}

fn md_ref_def_cmp_for_sort(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    var cmp = md_ref_def_cmp(a, b);

    // Ensure stability of the sorting (tie-break on pointer identity, exactly as
    // C does — these pointers index into ctx->ref_defs[], so this reproduces the
    // array order for equal labels).
    if (cmp == 0) {
        const a_pp: *const (*const MD_REF_DEF) = @ptrCast(@alignCast(a.?));
        const b_pp: *const (*const MD_REF_DEF) = @ptrCast(@alignCast(b.?));
        const a_ref = @intFromPtr(a_pp.*);
        const b_ref = @intFromPtr(b_pp.*);

        if (a_ref < b_ref)
            cmp = -1
        else if (a_ref > b_ref)
            cmp = 1
        else
            cmp = 0;
    }

    return cmp;
}

// Faithful port of md_build_ref_def_hashtable (md4x.c ~1793). Returns 0 / -1.
fn md_build_ref_def_hashtable(ctx: *MD_CTX) c_int {
    if (ctx.n_ref_defs == 0)
        return 0;

    ctx.ref_def_hashtable_size = @divTrunc(ctx.n_ref_defs * 5, 4);
    ctx.ref_def_hashtable = @ptrCast(@alignCast(std.c.malloc(@as(usize, @intCast(ctx.ref_def_hashtable_size)) * @sizeOf(?*anyopaque))));
    if (ctx.ref_def_hashtable == null) {
        md_log(ctx, "malloc() failed.");
        return -1;
    }
    @memset(ctx.ref_def_hashtable[0..@intCast(ctx.ref_def_hashtable_size)], null);

    const ref_defs_base = @intFromPtr(ctx.ref_defs);
    const ref_defs_end = @intFromPtr(ctx.ref_defs + @as(usize, @intCast(ctx.n_ref_defs)));

    // Build the buckets.
    var i: c_int = 0;
    while (i < ctx.n_ref_defs) : (i += 1) {
        const def: *MD_REF_DEF = @ptrCast(&ctx.ref_defs[@intCast(i)]);

        def.hash = md_link_label_hash(def.label, def.label_size);
        const slot: usize = @intCast(@mod(def.hash, @as(c_uint, @intCast(ctx.ref_def_hashtable_size))));
        const bucket = ctx.ref_def_hashtable[slot];

        if (bucket == null) {
            // Empty bucket: point it at the def.
            ctx.ref_def_hashtable[slot] = @ptrCast(def);
            continue;
        }

        const bucket_addr = @intFromPtr(bucket);
        if (ref_defs_base <= bucket_addr and bucket_addr < ref_defs_end) {
            // Bucket holds one ref-def. Same label (dup) or hash conflict?
            const old_def: *MD_REF_DEF = @ptrCast(@alignCast(bucket));

            if (md_link_label_cmp(def.label, def.label_size, old_def.label, old_def.label_size) == 0) {
                // Duplicate label: ignore this ref-def.
                continue;
            }

            // Promote to a complex bucket.
            const list: ?*MD_REF_DEF_LIST = @ptrCast(@alignCast(std.c.malloc(@sizeOf(MD_REF_DEF_LIST) + 2 * @sizeOf(?*MD_REF_DEF))));
            if (list == null) {
                md_log(ctx, "malloc() failed.");
                return -1;
            }
            const l = list.?;
            const items = md_ref_def_list_items(l);
            items[0] = old_def;
            items[1] = def;
            l.n_ref_defs = 2;
            l.alloc_ref_defs = 2;
            ctx.ref_def_hashtable[slot] = @ptrCast(l);
            continue;
        }

        // Append to the existing complex bucket. (Duplicates within complex
        // buckets are resolved after sorting, below — matching C.)
        var list: *MD_REF_DEF_LIST = @ptrCast(@alignCast(bucket));
        if (list.n_ref_defs >= list.alloc_ref_defs) {
            const new_alloc = list.alloc_ref_defs + @divTrunc(list.alloc_ref_defs, 2);
            const list_tmp: ?*MD_REF_DEF_LIST = @ptrCast(@alignCast(std.c.realloc(list, @sizeOf(MD_REF_DEF_LIST) + @as(usize, @intCast(new_alloc)) * @sizeOf(?*MD_REF_DEF))));
            if (list_tmp == null) {
                md_log(ctx, "realloc() failed.");
                return -1;
            }
            list = list_tmp.?;
            list.alloc_ref_defs = new_alloc;
            ctx.ref_def_hashtable[slot] = @ptrCast(list);
        }

        const items = md_ref_def_list_items(list);
        items[@intCast(list.n_ref_defs)] = def;
        list.n_ref_defs += 1;
    }

    // Sort the complex buckets so we can bsearch() them.
    i = 0;
    while (i < ctx.ref_def_hashtable_size) : (i += 1) {
        const bucket = ctx.ref_def_hashtable[@intCast(i)];
        if (bucket == null)
            continue;
        const bucket_addr = @intFromPtr(bucket);
        if (ref_defs_base <= bucket_addr and bucket_addr < ref_defs_end)
            continue;

        const list: *MD_REF_DEF_LIST = @ptrCast(@alignCast(bucket));
        const items = md_ref_def_list_items(list);
        qsort(@ptrCast(items), @intCast(list.n_ref_defs), @sizeOf(?*MD_REF_DEF), md_ref_def_cmp_for_sort);

        // Disable duplicates in the complex bucket by forcing duplicate records
        // to point to the 1st such ref-def (so lookup always resolves the same).
        var j: c_int = 1;
        while (j < list.n_ref_defs) : (j += 1) {
            if (md_ref_def_cmp(@ptrCast(&items[@intCast(j - 1)]), @ptrCast(&items[@intCast(j)])) == 0)
                items[@intCast(j)] = items[@intCast(j - 1)];
        }
    }

    return 0;
}

// Faithful port of md_free_ref_def_hashtable (md4x.c ~1907).
fn md_free_ref_def_hashtable(ctx: *MD_CTX) void {
    if (ctx.ref_def_hashtable != null) {
        const ref_defs_base = @intFromPtr(ctx.ref_defs);
        const ref_defs_end = @intFromPtr(ctx.ref_defs + @as(usize, @intCast(ctx.n_ref_defs)));

        var i: c_int = 0;
        while (i < ctx.ref_def_hashtable_size) : (i += 1) {
            const bucket = ctx.ref_def_hashtable[@intCast(i)];
            if (bucket == null)
                continue;
            const bucket_addr = @intFromPtr(bucket);
            if (ref_defs_base <= bucket_addr and bucket_addr < ref_defs_end)
                continue;
            std.c.free(bucket);
        }

        std.c.free(@ptrCast(ctx.ref_def_hashtable));
    }
}

// Faithful port of md_lookup_ref_def (md4x.c ~1925). Returns the matching
// const MD_REF_DEF* or null.
fn md_lookup_ref_def(ctx: *MD_CTX, label: [*c]const CHAR, label_size: SZ) ?*const MD_REF_DEF {
    if (ctx.ref_def_hashtable_size == 0)
        return null;

    const hash = md_link_label_hash(label, label_size);
    const slot: usize = @intCast(@mod(hash, @as(c_uint, @intCast(ctx.ref_def_hashtable_size))));
    const bucket = ctx.ref_def_hashtable[slot];

    if (bucket == null) {
        return null;
    }

    const ref_defs_base = @intFromPtr(ctx.ref_defs);
    const ref_defs_end = @intFromPtr(ctx.ref_defs + @as(usize, @intCast(ctx.n_ref_defs)));
    const bucket_addr = @intFromPtr(bucket);

    if (ref_defs_base <= bucket_addr and bucket_addr < ref_defs_end) {
        const def: *const MD_REF_DEF = @ptrCast(@alignCast(bucket));
        if (md_link_label_cmp(def.label, def.label_size, label, label_size) == 0)
            return def
        else
            return null;
    } else {
        const list: *MD_REF_DEF_LIST = @ptrCast(@alignCast(bucket));
        var key_buf: MD_REF_DEF = .{};
        key_buf.label = @constCast(label);
        key_buf.label_size = label_size;
        key_buf.hash = md_link_label_hash(key_buf.label, key_buf.label_size);
        const key: *const MD_REF_DEF = &key_buf;

        const items = md_ref_def_list_items(list);
        const ret = bsearch(@ptrCast(&key), @ptrCast(items), @intCast(list.n_ref_defs), @sizeOf(?*MD_REF_DEF), md_ref_def_cmp);
        if (ret) |r| {
            const rp: *const (?*MD_REF_DEF) = @ptrCast(@alignCast(r));
            return rp.*;
        } else {
            return null;
        }
    }
}

// Faithful port of md_free_ref_defs (md4x.c ~2491).
fn md_free_ref_defs(ctx: *MD_CTX) void {
    var i: c_int = 0;
    while (i < ctx.n_ref_defs) : (i += 1) {
        const def: *MD_REF_DEF = @ptrCast(&ctx.ref_defs[@intCast(i)]);
        if (def.label_needs_free)
            std.c.free(def.label);
        if (def.title_needs_free)
            std.c.free(def.title);
    }
    std.c.free(ctx.ref_defs);
}

// ============================================================================
//  Recognizing Links
// ============================================================================

// Mirrors `struct MD_LINK_ATTR_tag` (md4x.c ~1975). Internal — no C ABI.
pub const MD_LINK_ATTR = struct {
    dest_beg: OFF = 0,
    dest_end: OFF = 0,
    title: [*c]CHAR = null,
    title_size: SZ = 0,
    title_needs_free: c_int = 0,
};

// Faithful port of md_is_link_label (md4x.c ~1986).
fn md_is_link_label(
    ctx: *MD_CTX,
    lines: [*c]const MD_LINE,
    n_lines: MD_SIZE,
    beg: OFF,
    p_end: *OFF,
    p_beg_line_index: *MD_SIZE,
    p_end_line_index: *MD_SIZE,
    p_contents_beg: *OFF,
    p_contents_end: *OFF,
) c_int {
    var off = beg;
    var contents_beg: OFF = 0;
    var contents_end: OFF = 0;
    var line_index: MD_SIZE = 0;
    var len: c_int = 0;

    p_beg_line_index.* = 0;

    if (CH(ctx, off) != '[')
        return FALSE;
    off += 1;

    while (true) {
        const line_end = lines[line_index].end;

        while (off < line_end) {
            if (CH(ctx, off) == '\\' and off + 1 < ctx.size and (ISPUNCT(ctx, off + 1) or ISNEWLINE(ctx, off + 1))) {
                if (contents_end == 0) {
                    contents_beg = off;
                    p_beg_line_index.* = line_index;
                }
                contents_end = off + 2;
                off += 2;
            } else if (CH(ctx, off) == '[') {
                return FALSE;
            } else if (CH(ctx, off) == ']') {
                if (contents_beg < contents_end) {
                    // Success.
                    p_contents_beg.* = contents_beg;
                    p_contents_end.* = contents_end;
                    p_end.* = off + 1;
                    p_end_line_index.* = line_index;
                    return TRUE;
                } else {
                    // Link label must have some non-whitespace contents.
                    return FALSE;
                }
            } else {
                var char_size: SZ = undefined;
                const codepoint = md_decode_unicode(ctx.text, off, ctx.size, &char_size);
                if (ISUNICODEWHITESPACE_(codepoint) == 0) {
                    if (contents_end == 0) {
                        contents_beg = off;
                        p_beg_line_index.* = line_index;
                    }
                    contents_end = off + char_size;
                }

                off += char_size;
            }

            len += 1;
            if (len > 999)
                return FALSE;
        }

        line_index += 1;
        len += 1;
        if (line_index < n_lines)
            off = lines[line_index].beg
        else
            break;
    }

    return FALSE;
}

// Faithful port of md_is_link_destination_A (md4x.c ~2060).
fn md_is_link_destination_A(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF, p_contents_beg: *OFF, p_contents_end: *OFF) c_int {
    var off = beg;

    if (off >= max_end or CH(ctx, off) != '<')
        return FALSE;
    off += 1;

    while (off < max_end) {
        if (CH(ctx, off) == '\\' and off + 1 < max_end and ISPUNCT(ctx, off + 1)) {
            off += 2;
            continue;
        }

        if (ISNEWLINE(ctx, off) or CH(ctx, off) == '<')
            return FALSE;

        if (CH(ctx, off) == '>') {
            // Success.
            p_contents_beg.* = beg + 1;
            p_contents_end.* = off;
            p_end.* = off + 1;
            return TRUE;
        }

        off += 1;
    }

    return FALSE;
}

// Faithful port of md_is_link_destination_B (md4x.c ~2093).
fn md_is_link_destination_B(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF, p_contents_beg: *OFF, p_contents_end: *OFF) c_int {
    var off = beg;
    var parenthesis_level: c_int = 0;

    while (off < max_end) {
        if (CH(ctx, off) == '\\' and off + 1 < max_end and ISPUNCT(ctx, off + 1)) {
            off += 2;
            continue;
        }

        if (ISWHITESPACE(ctx, off) or ISCNTRL(ctx, off))
            break;

        // Balanced pairs of unescaped '(' ')', nesting capped at 32 (cmark #214).
        if (CH(ctx, off) == '(') {
            parenthesis_level += 1;
            if (parenthesis_level > 32)
                return FALSE;
        } else if (CH(ctx, off) == ')') {
            if (parenthesis_level == 0)
                break;
            parenthesis_level -= 1;
        }

        off += 1;
    }

    if (parenthesis_level != 0 or off == beg)
        return FALSE;

    // Success.
    p_contents_beg.* = beg;
    p_contents_end.* = off;
    p_end.* = off;
    return TRUE;
}

// Faithful port of md_is_link_destination (md4x.c ~2134).
inline fn md_is_link_destination(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF, p_contents_beg: *OFF, p_contents_end: *OFF) c_int {
    if (CH(ctx, beg) == '<')
        return md_is_link_destination_A(ctx, beg, max_end, p_end, p_contents_beg, p_contents_end)
    else
        return md_is_link_destination_B(ctx, beg, max_end, p_end, p_contents_beg, p_contents_end);
}

// Faithful port of md_is_link_title (md4x.c ~2144).
fn md_is_link_title(
    ctx: *MD_CTX,
    lines: [*c]const MD_LINE,
    n_lines: MD_SIZE,
    beg: OFF,
    p_end: *OFF,
    p_beg_line_index: *MD_SIZE,
    p_end_line_index: *MD_SIZE,
    p_contents_beg: *OFF,
    p_contents_end: *OFF,
) c_int {
    var off = beg;
    var closer_char: CHAR = undefined;
    var line_index: MD_SIZE = 0;

    // White space with up to one line break.
    while (off < lines[line_index].end and ISWHITESPACE(ctx, off))
        off += 1;
    if (off >= lines[line_index].end) {
        line_index += 1;
        if (line_index >= n_lines)
            return FALSE;
        off = lines[line_index].beg;
    }
    if (off == beg)
        return FALSE;

    p_beg_line_index.* = line_index;

    // First char determines how to detect end of it.
    switch (CH(ctx, off)) {
        '"' => closer_char = '"',
        '\'' => closer_char = '\'',
        '(' => closer_char = ')',
        else => return FALSE,
    }
    off += 1;

    p_contents_beg.* = off;

    while (line_index < n_lines) {
        const line_end = lines[line_index].end;

        while (off < line_end) {
            if (CH(ctx, off) == '\\' and off + 1 < ctx.size and (ISPUNCT(ctx, off + 1) or ISNEWLINE(ctx, off + 1))) {
                off += 1;
            } else if (CH(ctx, off) == closer_char) {
                // Success.
                p_contents_end.* = off;
                p_end.* = off + 1;
                p_end_line_index.* = line_index;
                return TRUE;
            } else if (closer_char == ')' and CH(ctx, off) == '(') {
                // ()-style title cannot contain an unescaped '('.
                return FALSE;
            }

            off += 1;
        }

        line_index += 1;
    }

    return FALSE;
}

// Faithful port of md_is_link_reference_definition (md4x.c ~2212). Returns 0 if
// not a ref-def, N>0 (number of lines) if it is, -1 on OOM.
fn md_is_link_reference_definition(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE) c_int {
    var label_contents_beg: OFF = undefined;
    var label_contents_end: OFF = undefined;
    var label_contents_line_index: MD_SIZE = undefined;
    var label_is_multiline: bool = false;
    var dest_contents_beg: OFF = undefined;
    var dest_contents_end: OFF = undefined;
    var title_contents_beg: OFF = undefined;
    var title_contents_end: OFF = undefined;
    var title_contents_line_index: MD_SIZE = undefined;
    var title_is_multiline: bool = false;
    var off: OFF = undefined;
    var line_index: MD_SIZE = 0;
    var tmp_line_index: MD_SIZE = undefined;
    var def: ?*MD_REF_DEF = null;
    var ret: c_int = 0;

    // Link label.
    if (md_is_link_label(ctx, lines, n_lines, lines[0].beg, &off, &label_contents_line_index, &line_index, &label_contents_beg, &label_contents_end) == 0)
        return FALSE;
    label_is_multiline = (label_contents_line_index != line_index);

    // Colon.
    if (off >= lines[line_index].end or CH(ctx, off) != ':')
        return FALSE;
    off += 1;

    // Optional white space with up to one line break.
    while (off < lines[line_index].end and ISWHITESPACE(ctx, off))
        off += 1;
    if (off >= lines[line_index].end) {
        line_index += 1;
        if (line_index >= n_lines)
            return FALSE;
        off = lines[line_index].beg;
    }

    // Link destination.
    if (md_is_link_destination(ctx, off, lines[line_index].end, &off, &dest_contents_beg, &dest_contents_end) == 0)
        return FALSE;

    // (Optional) title. Only a title if nothing more follows on its last line.
    if (md_is_link_title(ctx, lines + line_index, n_lines - line_index, off, &off, &title_contents_line_index, &tmp_line_index, &title_contents_beg, &title_contents_end) != 0 and
        off >= lines[line_index + tmp_line_index].end)
    {
        title_is_multiline = (tmp_line_index != title_contents_line_index);
        title_contents_line_index += line_index;
        line_index += tmp_line_index;
    } else {
        // Not a title.
        title_is_multiline = false;
        title_contents_beg = off;
        title_contents_end = off;
        title_contents_line_index = 0;
    }

    // Nothing more can follow on the last line.
    if (off < lines[line_index].end)
        return FALSE;

    // So, it _is_ a reference definition. Remember it.
    if (ctx.n_ref_defs >= ctx.alloc_ref_defs) {
        ctx.alloc_ref_defs = if (ctx.alloc_ref_defs > 0)
            ctx.alloc_ref_defs + @divTrunc(ctx.alloc_ref_defs, 2)
        else
            16;
        const new_defs: [*c]MD_REF_DEF = @ptrCast(@alignCast(std.c.realloc(ctx.ref_defs, @as(usize, @intCast(ctx.alloc_ref_defs)) * @sizeOf(MD_REF_DEF))));
        if (new_defs == null) {
            md_log(ctx, "realloc() failed.");
            // ret stays 0 → abort.
            return md_is_link_reference_definition_abort(def, ret);
        }
        ctx.ref_defs = new_defs;
    }
    def = @as(*MD_REF_DEF, @ptrCast(&ctx.ref_defs[@intCast(ctx.n_ref_defs)]));
    @memset(std.mem.asBytes(def.?), 0);

    if (label_is_multiline) {
        ret = md_merge_lines_alloc(ctx, label_contents_beg, label_contents_end, lines + label_contents_line_index, n_lines - label_contents_line_index, ' ', &def.?.label, &def.?.label_size);
        if (ret < 0) return md_is_link_reference_definition_abort(def, ret);
        def.?.label_needs_free = true;
    } else {
        def.?.label = @constCast(STR(ctx, label_contents_beg));
        def.?.label_size = label_contents_end - label_contents_beg;
    }

    if (title_is_multiline) {
        ret = md_merge_lines_alloc(ctx, title_contents_beg, title_contents_end, lines + title_contents_line_index, n_lines - title_contents_line_index, '\n', &def.?.title, &def.?.title_size);
        if (ret < 0) return md_is_link_reference_definition_abort(def, ret);
        def.?.title_needs_free = true;
    } else {
        def.?.title = @constCast(STR(ctx, title_contents_beg));
        def.?.title_size = title_contents_end - title_contents_beg;
    }

    def.?.dest_beg = dest_contents_beg;
    def.?.dest_end = dest_contents_end;

    // Success.
    ctx.n_ref_defs += 1;
    return @as(c_int, @intCast(line_index)) + 1;
}

// The C `abort:` cleanup for md_is_link_reference_definition. Factored out since
// Zig has no goto; only the realloc/merge-lines paths can reach it (with ret<=0).
fn md_is_link_reference_definition_abort(def: ?*MD_REF_DEF, ret: c_int) c_int {
    if (def) |d| {
        if (d.label_needs_free) std.c.free(d.label);
        if (d.title_needs_free) std.c.free(d.title);
    }
    return ret;
}

// Faithful port of md_is_link_reference (md4x.c ~2334).
fn md_is_link_reference(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, beg_in: OFF, end_in: OFF, attr: *MD_LINK_ATTR) c_int {
    var beg = beg_in;
    var end = end_in;
    var label: [*c]CHAR = undefined;
    var label_size: SZ = undefined;
    var ret: c_int = FALSE;

    // MD_ASSERT(CH(beg) == '[' || CH(beg) == '!');  MD_ASSERT(CH(end-1) == ']');
    if (ctx.max_ref_def_output == 0)
        return FALSE;

    beg += if (CH(ctx, beg) == '!') @as(OFF, 2) else 1;
    end -= 1;

    // Find lines corresponding to beg/end positions.
    const beg_line = md_lookup_line(beg, lines, n_lines, null);
    const is_multiline = (end > beg_line.end);

    if (is_multiline) {
        const beg_line_idx: usize = (@intFromPtr(beg_line) - @intFromPtr(lines)) / @sizeOf(MD_LINE);
        ret = md_merge_lines_alloc(ctx, beg, end, beg_line, @intCast(n_lines - @as(MD_SIZE, @intCast(beg_line_idx))), ' ', &label, &label_size);
        if (ret < 0) return ret;
        ret = FALSE;
    } else {
        label = @constCast(STR(ctx, beg));
        label_size = end - beg;
    }

    const def = md_lookup_ref_def(ctx, label, label_size);
    if (def) |d| {
        attr.dest_beg = d.dest_beg;
        attr.dest_end = d.dest_end;
        attr.title = d.title;
        attr.title_size = d.title_size;
        attr.title_needs_free = FALSE;
    }

    if (is_multiline)
        std.c.free(label);

    if (def) |d| {
        // See https://github.com/mity/md4c/issues/238
        const output_size_estimation: MD_SIZE = d.label_size + d.title_size + d.dest_end - d.dest_beg;
        if (output_size_estimation < ctx.max_ref_def_output) {
            ctx.max_ref_def_output -= output_size_estimation;
            ret = TRUE;
        } else {
            md_log(ctx, "Too many link reference definition instantiations.");
            ctx.max_ref_def_output = 0;
        }
    }

    return ret;
}

// Faithful port of md_is_inline_link_spec (md4x.c ~2394).
fn md_is_inline_link_spec(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, beg: OFF, p_end: *OFF, attr: *MD_LINK_ATTR) c_int {
    var line_index: MD_SIZE = 0;
    var tmp_line_index: MD_SIZE = undefined;
    var title_contents_beg: OFF = undefined;
    var title_contents_end: OFF = undefined;
    var title_contents_line_index: MD_SIZE = undefined;
    var title_is_multiline: bool = undefined;
    var off = beg;
    var ret: c_int = FALSE;

    _ = md_lookup_line(off, lines, n_lines, &line_index);

    // MD_ASSERT(CH(off) == '(');
    off += 1;

    // Optional white space with up to one line break.
    while (off < lines[line_index].end and ISWHITESPACE(ctx, off))
        off += 1;
    if (off >= lines[line_index].end and (off >= ctx.size or ISNEWLINE(ctx, off))) {
        line_index += 1;
        if (line_index >= n_lines)
            return FALSE;
        off = lines[line_index].beg;
    }

    // Link destination may be omitted, but only when not also having a title.
    if (off < ctx.size and CH(ctx, off) == ')') {
        attr.dest_beg = off;
        attr.dest_end = off;
        attr.title = null;
        attr.title_size = 0;
        attr.title_needs_free = FALSE;
        off += 1;
        p_end.* = off;
        return TRUE;
    }

    // Link destination.
    if (md_is_link_destination(ctx, off, lines[line_index].end, &off, &attr.dest_beg, &attr.dest_end) == 0)
        return FALSE;

    // (Optional) title.
    if (md_is_link_title(ctx, lines + line_index, n_lines - line_index, off, &off, &title_contents_line_index, &tmp_line_index, &title_contents_beg, &title_contents_end) != 0) {
        title_is_multiline = (tmp_line_index != title_contents_line_index);
        title_contents_line_index += line_index;
        line_index += tmp_line_index;
    } else {
        // Not a title.
        title_is_multiline = false;
        title_contents_beg = off;
        title_contents_end = off;
        title_contents_line_index = 0;
    }

    // Optional whitespace followed with final ')'.
    while (off < lines[line_index].end and ISWHITESPACE(ctx, off))
        off += 1;
    if (off >= lines[line_index].end) {
        line_index += 1;
        if (line_index >= n_lines)
            return FALSE;
        off = lines[line_index].beg;
    }
    if (CH(ctx, off) != ')')
        return ret; // goto abort (ret == FALSE here)
    off += 1;

    if (title_contents_beg >= title_contents_end) {
        attr.title = null;
        attr.title_size = 0;
        attr.title_needs_free = FALSE;
    } else if (!title_is_multiline) {
        attr.title = @constCast(STR(ctx, title_contents_beg));
        attr.title_size = title_contents_end - title_contents_beg;
        attr.title_needs_free = FALSE;
    } else {
        ret = md_merge_lines_alloc(ctx, title_contents_beg, title_contents_end, lines + title_contents_line_index, n_lines - title_contents_line_index, '\n', &attr.title, &attr.title_size);
        if (ret < 0) return ret;
        attr.title_needs_free = TRUE;
    }

    p_end.* = off;
    ret = TRUE;
    return ret;
}

// ============================================================================
//  Recognizing `<...>` Autolinks (pure recognizers; permissive autolinks live
//  in the inline mark engine — Pass C — because they need ctx->marks).
// ============================================================================

// Faithful port of md_is_autolink_uri (md4x.c ~2951).
fn md_is_autolink_uri(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off = beg + 1;

    // MD_ASSERT(CH(beg) == '<');

    // Scheme.
    if (off >= max_end or !ISASCII(ctx, off))
        return FALSE;
    off += 1;
    while (true) {
        if (off >= max_end)
            return FALSE;
        if (off - beg > 32)
            return FALSE;
        if (CH(ctx, off) == ':' and off - beg >= 3)
            break;
        if (!ISALNUM(ctx, off) and CH(ctx, off) != '+' and CH(ctx, off) != '-' and CH(ctx, off) != '.')
            return FALSE;
        off += 1;
    }

    // Path after the scheme.
    while (off < max_end and CH(ctx, off) != '>') {
        if (ISWHITESPACE(ctx, off) or ISCNTRL(ctx, off) or CH(ctx, off) == '<')
            return FALSE;
        off += 1;
    }

    if (off >= max_end)
        return FALSE;

    // MD_ASSERT(CH(off) == '>');
    p_end.* = off + 1;
    return TRUE;
}

// Faithful port of md_is_autolink_email (md4x.c ~2989).
fn md_is_autolink_email(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off = beg + 1;
    var label_len: c_int = undefined;

    // MD_ASSERT(CH(beg) == '<');

    // Username (before '@').
    while (off < max_end and (ISALNUM(ctx, off) or ISANYOF(ctx, off, ".!#$%&'*+/=?^_`{|}~-")))
        off += 1;
    if (off <= beg + 1)
        return FALSE;

    // '@'
    if (off >= max_end or CH(ctx, off) != '@')
        return FALSE;
    off += 1;

    // '.'-delimited labels: each 1-63 alnum or '-', '-' not first/last.
    label_len = 0;
    while (off < max_end) {
        if (ISALNUM(ctx, off))
            label_len += 1
        else if (CH(ctx, off) == '-' and label_len > 0)
            label_len += 1
        else if (CH(ctx, off) == '.' and label_len > 0 and CH(ctx, off - 1) != '-')
            label_len = 0
        else
            break;

        if (label_len > 63)
            return FALSE;

        off += 1;
    }

    if (label_len <= 0 or off >= max_end or CH(ctx, off) != '>' or CH(ctx, off - 1) == '-')
        return FALSE;

    p_end.* = off + 1;
    return TRUE;
}

// Faithful port of md_is_autolink (md4x.c ~3040).
fn md_is_autolink(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF, p_missing_mailto: *c_int) c_int {
    if (md_is_autolink_uri(ctx, beg, max_end, p_end) != 0) {
        p_missing_mailto.* = FALSE;
        return TRUE;
    }

    if (md_is_autolink_email(ctx, beg, max_end, p_end) != 0) {
        p_missing_mailto.* = TRUE;
        return TRUE;
    }

    return FALSE;
}

// ============================================================================
//  Pass C — Raw HTML recognizers (needed by md_collect_marks). These are
//  shared with Pass D block analysis (HTML block type 7) but only depend on
//  char helpers + md_ascii_eq + md_lookup_line, so they live here.
// ============================================================================

// Faithful port of md_is_html_tag (md4x.c ~1131). n_lines == 0 => whole tag
// must be on one line (block-start probe).
fn md_is_html_tag(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var attr_state: c_int = undefined;
    var off: OFF = beg;
    var line_end: OFF = if (n_lines > 0) lines[0].end else ctx.size;
    var line_index: MD_SIZE = 0;

    if (off + 1 >= line_end) return FALSE;
    off += 1;

    attr_state = 0;

    if (CH(ctx, off) == '/') {
        attr_state = -1;
        off += 1;
    }

    // Tag name.
    if (off >= line_end or !ISALPHA(ctx, off)) return FALSE;
    off += 1;
    while (off < line_end and (ISALNUM(ctx, off) or CH(ctx, off) == '-')) off += 1;

    while (true) {
        while (off < line_end and !ISNEWLINE(ctx, off)) {
            if (attr_state > 40) {
                if (attr_state == 41 and (ISBLANK(ctx, off) or ISANYOF(ctx, off, "\"'=<>`"))) {
                    attr_state = 0;
                    off -= 1; // Put the char back for re-inspection.
                } else if (attr_state == 42 and CH(ctx, off) == '\'') {
                    attr_state = 0;
                } else if (attr_state == 43 and CH(ctx, off) == '"') {
                    attr_state = 0;
                }
                off += 1;
            } else if (ISWHITESPACE(ctx, off)) {
                if (attr_state == 0) attr_state = 1;
                off += 1;
            } else if (attr_state <= 2 and CH(ctx, off) == '>') {
                // End.
                if (off >= max_end) return FALSE;
                p_end.* = off + 1;
                return TRUE;
            } else if (attr_state <= 2 and CH(ctx, off) == '/' and off + 1 < line_end and CH(ctx, off + 1) == '>') {
                // End with digraph '/>'.
                off += 1;
                if (off >= max_end) return FALSE;
                p_end.* = off + 1;
                return TRUE;
            } else if ((attr_state == 1 or attr_state == 2) and (ISALPHA(ctx, off) or CH(ctx, off) == '_' or CH(ctx, off) == ':')) {
                off += 1;
                while (off < line_end and (ISALNUM(ctx, off) or ISANYOF(ctx, off, "_.:-"))) off += 1;
                attr_state = 2;
            } else if (attr_state == 2 and CH(ctx, off) == '=') {
                off += 1;
                attr_state = 3;
            } else if (attr_state == 3) {
                if (CH(ctx, off) == '"') {
                    attr_state = 43;
                } else if (CH(ctx, off) == '\'') {
                    attr_state = 42;
                } else if (!ISANYOF(ctx, off, "\"'=<>`") and !ISNEWLINE(ctx, off)) {
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
        if (n_lines == 0) return FALSE;

        line_index += 1;
        if (line_index >= n_lines) return FALSE;

        off = lines[line_index].beg;
        line_end = lines[line_index].end;

        if (attr_state == 0 or attr_state == 41) attr_state = 1;

        if (off >= max_end) return FALSE;
    }
}

// Faithful port of md_scan_for_html_closer (md4x.c ~1249).
fn md_scan_for_html_closer(ctx: *MD_CTX, str: [*c]const CHAR, len: MD_SIZE, lines: [*c]const MD_LINE, n_lines: MD_SIZE, beg: OFF, max_end: OFF, p_end: *OFF, p_scan_horizon: *OFF) c_int {
    var off: OFF = beg;
    var line_index: MD_SIZE = 0;

    if (off < p_scan_horizon.* and p_scan_horizon.* >= max_end -% len) {
        return FALSE;
    }

    while (true) {
        while (off + len <= lines[line_index].end and off + len <= max_end) {
            if (md_ascii_eq(STR(ctx, off), str, len) != 0) {
                p_end.* = off + len;
                return TRUE;
            }
            off += 1;
        }

        line_index += 1;
        if (off >= max_end or line_index >= n_lines) {
            p_scan_horizon.* = off;
            return FALSE;
        }

        off = lines[line_index].beg;
    }
}

fn md_is_html_comment(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off: OFF = beg;
    if (off + 4 >= lines[0].end) return FALSE;
    if (CH(ctx, off + 1) != '!' or CH(ctx, off + 2) != '-' or CH(ctx, off + 3) != '-') return FALSE;
    off += 2; // Skip only "<!" so we accept "<!-->" or "<!--->".
    return md_scan_for_html_closer(ctx, "-->", 3, lines, n_lines, off, max_end, p_end, &ctx.html_comment_horizon);
}

fn md_is_html_processing_instruction(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off: OFF = beg;
    if (off + 2 >= lines[0].end) return FALSE;
    if (CH(ctx, off + 1) != '?') return FALSE;
    off += 2;
    return md_scan_for_html_closer(ctx, "?>", 2, lines, n_lines, off, max_end, p_end, &ctx.html_proc_instr_horizon);
}

fn md_is_html_declaration(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off: OFF = beg;
    if (off + 2 >= lines[0].end) return FALSE;
    if (CH(ctx, off + 1) != '!') return FALSE;
    off += 2;
    if (off >= lines[0].end or !ISALPHA(ctx, off)) return FALSE;
    off += 1;
    while (off < lines[0].end and ISALPHA(ctx, off)) off += 1;
    return md_scan_for_html_closer(ctx, ">", 1, lines, n_lines, off, max_end, p_end, &ctx.html_decl_horizon);
}

fn md_is_html_cdata(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    const open_str = "<![CDATA[";
    const open_size: SZ = open_str.len;
    var off: OFF = beg;
    if (off + open_size >= lines[0].end) return FALSE;
    if (std.mem.eql(u8, @as([*]const u8, @ptrCast(STR(ctx, off)))[0..open_size], open_str) == false) return FALSE;
    off += open_size;
    return md_scan_for_html_closer(ctx, "]]>", 3, lines, n_lines, off, max_end, p_end, &ctx.html_cdata_horizon);
}

fn md_is_html_any(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    if (md_is_html_tag(ctx, lines, n_lines, beg, max_end, p_end) != 0) return TRUE;
    if (md_is_html_comment(ctx, lines, n_lines, beg, max_end, p_end) != 0) return TRUE;
    if (md_is_html_processing_instruction(ctx, lines, n_lines, beg, max_end, p_end) != 0) return TRUE;
    if (md_is_html_declaration(ctx, lines, n_lines, beg, max_end, p_end) != 0) return TRUE;
    if (md_is_html_cdata(ctx, lines, n_lines, beg, max_end, p_end) != 0) return TRUE;
    return FALSE;
}

// ============================================================================
//  Pass C — Inline mark-resolution engine
// ============================================================================

// opener_stacks[] index constants (mirroring the C #defines on MD_CTX).
const ASTERISK_OPENERS_oo_mod3_0: usize = 0;
const UNDERSCORE_OPENERS_oo_mod3_0: usize = 6;
const TILDE_OPENERS_1: usize = 12;
const TILDE_OPENERS_2: usize = 13;
const BRACKET_OPENERS: usize = 14;
const DOLLAR_OPENERS: usize = 15;

// md4x.c ~2609. Returns the base index into ctx.opener_stacks for the given
// emphasis char + flags (applying the EMPH_OC offset of +3 and the mod3 offset).
fn md_emph_stack_index(ch: CHAR, flags: u8) usize {
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

inline fn md_emph_stack(ctx: *MD_CTX, ch: CHAR, flags: u8) *MD_MARKSTACK {
    return &ctx.opener_stacks[md_emph_stack_index(ch, flags)];
}

// md4x.c ~2633. Returns the opener stack that owns the given mark.
fn md_opener_stack(ctx: *MD_CTX, mark_index: c_int) *MD_MARKSTACK {
    const mark = &ctx.marks[@intCast(mark_index)];
    switch (mark.ch) {
        '*', '_' => return md_emph_stack(ctx, mark.ch, mark.flags),
        '~' => return if (mark.end - mark.beg == 1) &ctx.opener_stacks[TILDE_OPENERS_1] else &ctx.opener_stacks[TILDE_OPENERS_2],
        '!', '[' => return &ctx.opener_stacks[BRACKET_OPENERS],
        else => unreachable,
    }
}

// md4x.c ~2651. Grow ctx.marks and return a pointer to the new slot, or null on OOM.
fn md_add_mark(ctx: *MD_CTX) [*c]MD_MARK {
    if (ctx.n_marks >= ctx.alloc_marks) {
        ctx.alloc_marks = if (ctx.alloc_marks > 0)
            ctx.alloc_marks + @divTrunc(ctx.alloc_marks, 2)
        else
            64;
        const new_marks = c_realloc_array(MD_MARK, ctx.marks, @intCast(ctx.alloc_marks));
        if (new_marks == null) {
            md_log(ctx, "realloc() failed.");
            return null;
        }
        ctx.marks = new_marks;
    }
    const slot = &ctx.marks[@intCast(ctx.n_marks)];
    ctx.n_marks += 1;
    return slot;
}

// ADD_MARK(ch, beg, end, flags): allocate+init a mark. On OOM sets ret=-1 and
// signals abort via returning false (caller must `goto abort`).
inline fn addMark(ctx: *MD_CTX, ch: CHAR, beg: OFF, end: OFF, flags: u8) ?[*c]MD_MARK {
    const mark = md_add_mark(ctx);
    if (mark == null) return null;
    mark.*.beg = beg;
    mark.*.end = end;
    mark.*.prev = -1;
    mark.*.next = -1;
    mark.*.ch = ch;
    mark.*.flags = flags;
    return mark;
}

inline fn md_mark_stack_push(ctx: *MD_CTX, stack: *MD_MARKSTACK, mark_index: c_int) void {
    ctx.marks[@intCast(mark_index)].next = stack.top;
    stack.top = mark_index;
}

inline fn md_mark_stack_pop(ctx: *MD_CTX, stack: *MD_MARKSTACK) c_int {
    const top = stack.top;
    if (top >= 0) stack.top = ctx.marks[@intCast(top)].next;
    return top;
}

// md_mark_store_ptr/get_ptr (md4x.c ~2712): a void* is memcpy'd over the first
// sizeof(void*) bytes of the mark (beg+end). We replicate by writing the
// pointer's bits into beg/end. Only valid for 'D' dummy marks.
inline fn md_mark_store_ptr(ctx: *MD_CTX, mark_index: c_int, ptr: ?*anyopaque) void {
    const mark = &ctx.marks[@intCast(mark_index)];
    var p = ptr;
    const dst = @as([*]u8, @ptrCast(mark))[0..@sizeOf(?*anyopaque)];
    const src = @as([*]const u8, @ptrCast(&p))[0..@sizeOf(?*anyopaque)];
    @memcpy(dst, src);
}

inline fn md_mark_get_ptr(ctx: *MD_CTX, mark_index: c_int) ?*anyopaque {
    const mark = &ctx.marks[@intCast(mark_index)];
    var ptr: ?*anyopaque = undefined;
    const src = @as([*]const u8, @ptrCast(mark))[0..@sizeOf(?*anyopaque)];
    @memcpy(@as([*]u8, @ptrCast(&ptr))[0..@sizeOf(?*anyopaque)], src);
    return ptr;
}

inline fn md_resolve_range(ctx: *MD_CTX, opener_index: c_int, closer_index: c_int) void {
    const opener = &ctx.marks[@intCast(opener_index)];
    const closer = &ctx.marks[@intCast(closer_index)];
    opener.next = closer_index;
    closer.prev = opener_index;
    opener.flags |= MD_MARK_OPENER | MD_MARK_RESOLVED;
    closer.flags |= MD_MARK_CLOSER | MD_MARK_RESOLVED;
}

const MD_ROLLBACK_CROSSING: c_int = 0;
const MD_ROLLBACK_ALL: c_int = 1;

// md4x.c ~2764.
fn md_rollback(ctx: *MD_CTX, opener_index: c_int, closer_index: c_int, how: c_int) void {
    var i: usize = 0;
    while (i < ctx.opener_stacks.len) : (i += 1) {
        const stack = &ctx.opener_stacks[i];
        while (stack.top >= opener_index)
            _ = md_mark_stack_pop(ctx, stack);
    }

    if (how == MD_ROLLBACK_ALL) {
        var j: c_int = opener_index + 1;
        while (j < closer_index) : (j += 1) {
            ctx.marks[@intCast(j)].ch = 'D';
            ctx.marks[@intCast(j)].flags = 0;
        }
    }
}

// md4x.c ~2783.
fn md_build_mark_char_map(ctx: *MD_CTX) void {
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
fn md_is_code_span(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, beg: OFF, opener: *MD_MARK, closer: *MD_MARK, last_potential_closers: *[CODESPAN_MARK_MAXLEN]OFF, p_reached_paragraph_end: *c_int) c_int {
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
    while (opener_end < line_end and CH(ctx, opener_end) == '`') opener_end += 1;
    has_space_after_opener = @intFromBool(opener_end < line_end and CH(ctx, opener_end) == ' ');
    has_eol_after_opener = @intFromBool(opener_end == line_end);

    opener.end = opener_end;

    mark_len = opener_end - opener_beg;
    if (mark_len > CODESPAN_MARK_MAXLEN) return FALSE;

    if (last_potential_closers[mark_len - 1] >= lines[n_lines - 1].end or
        (p_reached_paragraph_end.* != 0 and last_potential_closers[mark_len - 1] < opener_end))
        return FALSE;

    closer_beg = opener_end;
    closer_end = opener_end;

    while (true) {
        while (closer_beg < line_end and CH(ctx, closer_beg) != '`') {
            if (CH(ctx, closer_beg) != ' ') has_only_space = FALSE;
            closer_beg += 1;
        }
        closer_end = closer_beg;
        while (closer_end < line_end and CH(ctx, closer_end) == '`') closer_end += 1;

        if (closer_end - closer_beg == mark_len) {
            has_space_before_closer = @intFromBool(closer_beg > lines[line_index].beg and CH(ctx, closer_beg - 1) == ' ');
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
            if (line_index >= n_lines) {
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
            while (closer_beg < ctx.size and ISBLANK(ctx, closer_beg)) closer_beg += 1;
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
fn md_collect_marks(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, table_mode: c_int) c_int {
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

    while (line_index < n_lines) : (line_index += 1) {
        var line: [*c]const MD_LINE = &lines[line_index];
        var off: OFF = line.*.beg;

        scan: while (true) {
            // IS_MARK_CHAR(off) for 8-bit encodings: mark_char_map[(unsigned char)CH(off)].
            const IS_MARK_CHAR = struct {
                inline fn f(cx: *MD_CTX, o: OFF) bool {
                    return cx.mark_char_map[@as(u8, @bitCast(CH(cx, o)))] != 0;
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

            const ch = CH(ctx, off);

            // Backslash escape.
            if (ch == '\\' and off + 1 < ctx.size and (ISPUNCT(ctx, off + 1) or ISNEWLINE(ctx, off + 1))) {
                if (!ISNEWLINE(ctx, off + 1) or line_index + 1 < n_lines) {
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

                while (tmp < line.*.end and CH(ctx, tmp) == ch) tmp += 1;

                if (off == line.*.beg or ISUNICODEWHITESPACEBEFORE(ctx, off))
                    left_level = 0
                else if (ISUNICODEPUNCTBEFORE(ctx, off))
                    left_level = 1
                else
                    left_level = 2;

                if (tmp == line.*.end or ISUNICODEWHITESPACE(ctx, tmp))
                    right_level = 0
                else if (ISUNICODEPUNCT(ctx, tmp))
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

                const is_code_span = md_is_code_span(ctx, line, n_lines - line_index, off, &opener, &closer, &codespan_last_potential_closers, &codespan_scanned_till_paragraph_end);
                if (is_code_span != 0) {
                    if (addMark(ctx, opener.ch, opener.beg, opener.end, opener.flags) == null) {
                        ret = -1;
                        return ret;
                    }
                    if (addMark(ctx, closer.ch, closer.beg, closer.end, closer.flags) == null) {
                        ret = -1;
                        return ret;
                    }
                    md_resolve_range(ctx, ctx.n_marks - 2, ctx.n_marks - 1);
                    off = closer.end;
                    if (off > line.*.end) {
                        line = md_lookup_line(off, lines, n_lines, &line_index);
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
                if (ctx.n_marks > 0 and ctx.marks[@intCast(ctx.n_marks - 1)].ch == '&') {
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
                    const is_html = md_is_html_any(ctx, line, n_lines - line_index, off, lines[n_lines - 1].end, &html_end);
                    if (is_html != 0) {
                        if (addMark(ctx, '<', off, off, MD_MARK_OPENER | MD_MARK_RESOLVED) == null) {
                            ret = -1;
                            return ret;
                        }
                        if (addMark(ctx, '>', html_end, html_end, MD_MARK_CLOSER | MD_MARK_RESOLVED) == null) {
                            ret = -1;
                            return ret;
                        }
                        ctx.marks[@intCast(ctx.n_marks - 2)].next = ctx.n_marks - 1;
                        ctx.marks[@intCast(ctx.n_marks - 1)].prev = ctx.n_marks - 2;
                        off = html_end;
                        if (off > line.*.end) {
                            line = md_lookup_line(off, lines, n_lines, &line_index);
                        }
                        continue :scan;
                    }
                }

                var autolink_end: OFF = undefined;
                var missing_mailto: c_int = undefined;
                const is_autolink = md_is_autolink(ctx, off, lines[n_lines - 1].end, &autolink_end, &missing_mailto);
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
                    ctx.marks[@intCast(ctx.n_marks - 2)].next = ctx.n_marks - 1;
                    ctx.marks[@intCast(ctx.n_marks - 1)].prev = ctx.n_marks - 2;
                    off = autolink_end;
                    continue :scan;
                }

                off += 1;
                continue :scan;
            }

            // Potential link or its part.
            if (ch == '[' or (ch == '!' and off + 1 < line.*.end and CH(ctx, off + 1) == '[')) {
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
                if (line.*.beg + 1 <= off and ISALNUM(ctx, off - 1) and off + 3 < line.*.end and ISALNUM(ctx, off + 1)) {
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
                        off + 1 < line.*.end and ISALPHA(ctx, off + 1) and
                        (off == line.*.beg or !ISALNUM(ctx, off - 1)))
                    {
                        var name_end: OFF = off + 2;
                        var name_has_hyphen: c_int = 0;
                        while (name_end < line.*.end and (ISALNUM(ctx, name_end) or CH(ctx, name_end) == '-')) {
                            if (CH(ctx, name_end) == '-') name_has_hyphen = 1;
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
                            if (comp_end < line.*.end and CH(ctx, comp_end) == '[') {
                                var bracket_depth: c_int = 1;
                                var scan_off: OFF = comp_end + 1;
                                content_beg = scan_off;
                                while (scan_off < line.*.end and bracket_depth > 0) {
                                    if (CH(ctx, scan_off) == '[') bracket_depth += 1 else if (CH(ctx, scan_off) == ']') bracket_depth -= 1;
                                    if (bracket_depth > 0) scan_off += 1;
                                }
                                if (bracket_depth == 0) {
                                    has_content = 1;
                                    content_end = scan_off;
                                    comp_end = scan_off + 1;
                                }
                            }

                            // Optional {props}.
                            if (comp_end < line.*.end and CH(ctx, comp_end) == '{') {
                                var brace_depth: c_int = 1;
                                var scan_off: OFF = comp_end + 1;
                                props_beg = scan_off;
                                while (scan_off < line.*.end and brace_depth > 0) {
                                    if (CH(ctx, scan_off) == '{') brace_depth += 1 else if (CH(ctx, scan_off) == '}') brace_depth -= 1;
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
                                const opener_index = ctx.n_marks - 1;
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
                                ctx.marks[@intCast(ctx.n_marks - 3)].next = ctx.n_marks - 1;
                                ctx.marks[@intCast(ctx.n_marks - 1)].prev = ctx.n_marks - 3;
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

                        if (line.*.beg + scheme_size <= off and md_ascii_eq(STR(ctx, off - scheme_size), scheme, scheme_size) != 0 and
                            off + 1 + suffix_size < line.*.end and md_ascii_eq(STR(ctx, off + 1), suffix, suffix_size) != 0)
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
                if (line.*.beg + 3 <= off and md_ascii_eq(STR(ctx, off - 3), "www", 3) != 0 and
                    (off - 3 == line.*.beg or ISUNICODEWHITESPACEBEFORE(ctx, off - 3) or ISUNICODEPUNCTBEFORE(ctx, off - 3)))
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
                while (tmp < line.*.end and CH(ctx, tmp) == ch) tmp += 1;

                if (tmp - off <= 2) {
                    var flags: u8 = MD_MARK_POTENTIAL_OPENER | MD_MARK_POTENTIAL_CLOSER;
                    if (off > line.*.beg and !ISUNICODEWHITESPACEBEFORE(ctx, off) and !ISUNICODEPUNCTBEFORE(ctx, off))
                        flags &= ~MD_MARK_POTENTIAL_OPENER;
                    if (tmp < line.*.end and !ISUNICODEWHITESPACE(ctx, tmp) and !ISUNICODEPUNCT(ctx, tmp))
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
                while (tmp < line.*.end and ISWHITESPACE(ctx, tmp)) tmp += 1;
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
            while (insert_pos < ctx.n_marks) : (insert_pos += 1) {
                if (ctx.marks[@intCast(insert_pos)].beg >= cbeg) break;
            }

            {
                const new_mark = md_add_mark(ctx);
                if (new_mark == null) {
                    ret = -1;
                    return ret;
                }
                if (insert_pos < ctx.n_marks - 1) {
                    const dst = &ctx.marks[@intCast(insert_pos + 1)];
                    const srcp = &ctx.marks[@intCast(insert_pos)];
                    const count: usize = @intCast(ctx.n_marks - 1 - insert_pos);
                    std.mem.copyBackwards(MD_MARK, @as([*]MD_MARK, @ptrCast(dst))[0..count], @as([*]const MD_MARK, @ptrCast(srcp))[0..count]);
                }
            }
            ctx.marks[@intCast(insert_pos)].beg = cbeg;
            ctx.marks[@intCast(insert_pos)].end = cend;
            ctx.marks[@intCast(insert_pos)].ch = 'C';
            ctx.marks[@intCast(insert_pos)].flags = MD_MARK_CLOSER | MD_MARK_RESOLVED;
            ctx.marks[@intCast(insert_pos)].prev = -1;
            ctx.marks[@intCast(insert_pos)].next = -1;

            var jj: c_int = 0;
            while (jj < ctx.n_marks) : (jj += 1) {
                if (jj == insert_pos) continue;
                if (ctx.marks[@intCast(jj)].prev >= insert_pos) ctx.marks[@intCast(jj)].prev += 1;
                if (ctx.marks[@intCast(jj)].next >= insert_pos) ctx.marks[@intCast(jj)].next += 1;
            }
            if (opener_index >= insert_pos) opener_index += 1;
            {
                var k: c_int = i + 1;
                while (k < n_deferred_comp_closers) : (k += 1) {
                    if (deferred_comp_closers[@intCast(k)].opener_index >= insert_pos)
                        deferred_comp_closers[@intCast(k)].opener_index += 1;
                }
            }
            ctx.marks[@intCast(opener_index)].next = insert_pos;
            ctx.marks[@intCast(insert_pos)].prev = opener_index;
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
fn md_analyze_bracket(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks[@intCast(mark_index)];

    if (mark.flags & MD_MARK_POTENTIAL_OPENER != 0) {
        if (ctx.opener_stacks[BRACKET_OPENERS].top >= 0)
            ctx.marks[@intCast(ctx.opener_stacks[BRACKET_OPENERS].top)].flags |= MD_MARK_HASNESTEDBRACKETS;
        md_mark_stack_push(ctx, &ctx.opener_stacks[BRACKET_OPENERS], mark_index);
        return;
    }

    if (ctx.opener_stacks[BRACKET_OPENERS].top >= 0) {
        const opener_index = md_mark_stack_pop(ctx, &ctx.opener_stacks[BRACKET_OPENERS]);
        const opener = &ctx.marks[@intCast(opener_index)];

        opener.next = mark_index;
        mark.prev = opener_index;

        if (ctx.unresolved_link_tail >= 0)
            ctx.marks[@intCast(ctx.unresolved_link_tail)].prev = opener_index
        else
            ctx.unresolved_link_head = opener_index;
        ctx.unresolved_link_tail = opener_index;
        opener.prev = -1;
    }
}

// md4x.c ~3677.
fn md_resolve_links(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE) c_int {
    var opener_index = ctx.unresolved_link_head;
    var last_link_beg: OFF = 0;
    var last_link_end: OFF = 0;
    var last_img_beg: OFF = 0;
    var last_img_end: OFF = 0;

    while (opener_index >= 0) {
        const opener = &ctx.marks[@intCast(opener_index)];
        const closer_index = opener.next;
        const closer = &ctx.marks[@intCast(closer_index)];
        var next_index = opener.prev;
        var next_opener: ?*MD_MARK = null;
        var next_closer: ?*MD_MARK = null;
        var attr: MD_LINK_ATTR = .{};
        var is_link: c_int = FALSE;

        if (next_index >= 0) {
            next_opener = &ctx.marks[@intCast(next_index)];
            next_closer = &ctx.marks[@intCast(next_opener.?.next)];
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
                const m = &ctx.marks[@intCast(delim_index)];
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
                    if (ISNEWLINE(ctx, off)) {
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
                    md_analyze_link_contents(ctx, lines, n_lines, delim_index + 1, closer_index);

                opener_index = next_opener.?.prev;
                continue;
            }
        }

        if (next_opener != null and next_opener.?.beg == closer.end) {
            if (next_closer.?.beg > closer.end + 1) {
                // Might be full reference link.
                if (next_opener.?.flags & MD_MARK_HASNESTEDBRACKETS == 0)
                    is_link = md_is_link_reference(ctx, lines, n_lines, next_opener.?.beg, next_closer.?.end, &attr);
            } else {
                // Might be shortcut reference link.
                if (opener.flags & MD_MARK_HASNESTEDBRACKETS == 0)
                    is_link = md_is_link_reference(ctx, lines, n_lines, opener.beg, closer.end, &attr);
            }

            if (is_link < 0) return -1;

            if (is_link != 0) {
                closer.end = next_closer.?.end;
                next_index = ctx.marks[@intCast(next_index)].prev;
            }
        } else {
            if (closer.end < ctx.size and CH(ctx, closer.end) == '(') {
                // Might be inline link.
                var inline_link_end: OFF = OFF_MAX;
                is_link = md_is_inline_link_spec(ctx, lines, n_lines, closer.end, &inline_link_end, &attr);
                if (is_link < 0) return -1;

                if (is_link != 0) {
                    var i: c_int = closer_index + 1;
                    while (i < ctx.n_marks) {
                        const m = &ctx.marks[@intCast(i)];
                        if (m.beg >= inline_link_end) break;
                        if ((m.flags & (MD_MARK_OPENER | MD_MARK_RESOLVED)) == (MD_MARK_OPENER | MD_MARK_RESOLVED)) {
                            if (ctx.marks[@intCast(m.next)].beg >= inline_link_end) {
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
                    is_link = md_is_link_reference(ctx, lines, n_lines, opener.beg, closer.end, &attr);
                if (is_link < 0) return -1;
            }

            if (is_link == 0 and (ctx.parser.flags & c.MD_FLAG_ATTRIBUTES != 0) and opener.ch == '[') {
                // Might be a [text]{attrs} span.
                if (closer.end < ctx.size and CH(ctx, closer.end) == '{') {
                    var scan: OFF = closer.end + 1;
                    var depth: c_int = 1;
                    while (scan < ctx.size and depth > 0) {
                        if (CH(ctx, scan) == '{') depth += 1 else if (CH(ctx, scan) == '}') depth -= 1;
                        scan += 1;
                    }
                    if (depth == 0) {
                        is_link = TRUE;
                        ctx.marks[@intCast(opener_index + 1)].ch = 'S';
                        ctx.marks[@intCast(opener_index + 1)].beg = closer.end + 1;
                        ctx.marks[@intCast(opener_index + 1)].end = scan - 1;
                        closer.end = scan;
                    }
                }
            }
        }

        if (is_link != 0) {
            opener.flags |= MD_MARK_OPENER | MD_MARK_RESOLVED;
            closer.flags |= MD_MARK_CLOSER | MD_MARK_RESOLVED;

            if (ctx.marks[@intCast(opener_index + 1)].ch == 'S') {
                md_analyze_link_contents(ctx, lines, n_lines, opener_index + 1, closer_index);
            } else {
                ctx.marks[@intCast(opener_index + 1)].beg = attr.dest_beg;
                ctx.marks[@intCast(opener_index + 1)].end = attr.dest_end;

                md_mark_store_ptr(ctx, opener_index + 2, attr.title);
                if (attr.title_needs_free != 0)
                    md_mark_stack_push(ctx, &ctx.ptr_stack, opener_index + 2);
                ctx.marks[@intCast(opener_index + 2)].prev = @bitCast(attr.title_size);

                if (opener.ch == '[') {
                    last_link_beg = opener.beg;
                    last_link_end = closer.end;
                } else {
                    last_img_beg = opener.beg;
                    last_img_end = closer.end;
                }

                md_analyze_link_contents(ctx, lines, n_lines, opener_index + 1, closer_index);

                if (ctx.parser.flags & c.MD_FLAG_PERMISSIVEAUTOLINKS != 0) {
                    var first_nested_i: c_int = opener_index + 1;
                    while (ctx.marks[@intCast(first_nested_i)].ch == 'D' and first_nested_i < closer_index) first_nested_i += 1;

                    // NOTE: the C loop condition tests first_nested->ch (md4c quirk); preserved verbatim.
                    var last_nested_i: c_int = closer_index - 1;
                    while (ctx.marks[@intCast(first_nested_i)].ch == 'D' and last_nested_i > opener_index) last_nested_i -= 1;

                    const first_nested = &ctx.marks[@intCast(first_nested_i)];
                    const last_nested = &ctx.marks[@intCast(last_nested_i)];

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
fn md_analyze_entity(ctx: *MD_CTX, mark_index: c_int) void {
    const opener = &ctx.marks[@intCast(mark_index)];
    var off: OFF = undefined;

    if (mark_index + 1 >= ctx.n_marks) return;
    const closer = &ctx.marks[@intCast(mark_index + 1)];
    if (closer.ch != ';') return;

    if (md_is_entity(ctx, opener.beg, closer.end, &off) != 0) {
        md_resolve_range(ctx, mark_index, mark_index + 1);
        opener.end = closer.end;
    }
}

// md4x.c ~4005.
fn md_analyze_table_cell_boundary(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks[@intCast(mark_index)];
    mark.flags |= MD_MARK_RESOLVED;
    mark.next = -1;

    if (ctx.table_cell_boundaries_head < 0)
        ctx.table_cell_boundaries_head = mark_index
    else
        ctx.marks[@intCast(ctx.table_cell_boundaries_tail)].next = mark_index;
    ctx.table_cell_boundaries_tail = mark_index;
    ctx.n_table_cell_boundaries += 1;
}

// md4x.c ~4024. Split a longer mark into two; the new mark takes `n` chars.
fn md_split_emph_mark(ctx: *MD_CTX, mark_index: c_int, n: SZ) c_int {
    const mark = &ctx.marks[@intCast(mark_index)];
    const new_mark_index: c_int = mark_index + @as(c_int, @intCast(mark.end - mark.beg - n));
    const dummy = &ctx.marks[@intCast(new_mark_index)];

    dummy.* = mark.*;
    mark.end -= n;
    dummy.beg = mark.end;

    return new_mark_index;
}

// md4x.c ~4041.
fn md_analyze_emph(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks[@intCast(mark_index)];

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
                const m = &ctx.marks[@intCast(m_index)];
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
fn md_analyze_tilde(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks[@intCast(mark_index)];
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
fn md_analyze_dollar(ctx: *MD_CTX, mark_index: c_int) void {
    const mark = &ctx.marks[@intCast(mark_index)];

    if ((mark.flags & MD_MARK_POTENTIAL_CLOSER != 0) and ctx.opener_stacks[DOLLAR_OPENERS].top >= 0) {
        const opener = &ctx.marks[@intCast(ctx.opener_stacks[DOLLAR_OPENERS].top)];
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
fn md_scan_left_for_resolved_mark(ctx: *MD_CTX, mark_from: [*c]MD_MARK, off: OFF, p_cursor: ?*[*c]MD_MARK) [*c]MD_MARK {
    var mark = mark_from;
    while (@intFromPtr(mark) >= @intFromPtr(ctx.marks)) : (mark -= 1) {
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
fn md_scan_right_for_resolved_mark(ctx: *MD_CTX, mark_from: [*c]MD_MARK, off: OFF, p_cursor: ?*[*c]MD_MARK) [*c]MD_MARK {
    var mark = mark_from;
    const end_ptr = ctx.marks + @as(usize, @intCast(ctx.n_marks));
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
fn md_analyze_permissive_autolink(ctx: *MD_CTX, mark_index: c_int) void {
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

    const opener = &ctx.marks[@intCast(mark_index)];
    const closer = &ctx.marks[@intCast(mark_index + 1)]; // The dummy.
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
            if (ISALNUM(ctx, beg - 1)) {
                beg -= 1;
            } else if (beg >= line_beg + 2 and ISALNUM(ctx, beg - 2) and
                ISANYOF(ctx, beg - 1, ".-_+") and
                md_scan_left_for_resolved_mark(ctx, left_cursor, beg - 1, &left_cursor) == null and
                ISALNUM(ctx, beg))
            {
                beg -= 1;
            } else {
                break;
            }
        }
        if (beg == opener.beg) return; // empty user name
    }

    if (beg == line_beg or ISUNICODEWHITESPACEBEFORE(ctx, beg) or ISANYOF(ctx, beg - 1, "({[")) {
        left_boundary_ok = TRUE;
    } else if (ISANYOF(ctx, beg - 1, "*_~")) {
        const left_mark = md_scan_left_for_resolved_mark(ctx, left_cursor, beg - 1, &left_cursor);
        if (left_mark != null and (left_mark.*.flags & MD_MARK_OPENER != 0)) left_boundary_ok = TRUE;
    }
    if (left_boundary_ok == FALSE) return;

    var i: usize = 0;
    while (i < URL_MAP.len) : (i += 1) {
        var n_components: c_int = 0;
        var n_open_brackets: c_int = 0;

        if (URL_MAP[i].start_char != 0) {
            if (end >= line_end or CH(ctx, end) != URL_MAP[i].start_char) continue;
            if (URL_MAP[i].min_components > 0 and (end + 1 >= line_end or !ISALNUM(ctx, end + 1))) continue;
            end += 1;
        }

        while (end < line_end) {
            if (ISALNUM(ctx, end)) {
                if (n_components == 0) n_components += 1;
                end += 1;
            } else if (end < line_end and
                ISANYOF(ctx, end, URL_MAP[i].allowed_nonalnum_chars) and
                md_scan_right_for_resolved_mark(ctx, right_cursor, end, &right_cursor) == null and
                ((end > line_beg and (ISALNUM(ctx, end - 1) or CH(ctx, end - 1) == ')')) or CH(ctx, end) == '(') and
                ((end + 1 < line_end and (ISALNUM(ctx, end + 1) or CH(ctx, end + 1) == '(')) or CH(ctx, end) == ')'))
            {
                if (CH(ctx, end) == URL_MAP[i].delim_char) n_components += 1;

                if (CH(ctx, end) == '(') {
                    n_open_brackets += 1;
                } else if (CH(ctx, end) == ')') {
                    if (n_open_brackets <= 0) break;
                    n_open_brackets -= 1;
                }
                end += 1;
            } else {
                break;
            }
        }

        if (end < line_end and URL_MAP[i].optional_end_char != 0 and CH(ctx, end) == URL_MAP[i].optional_end_char)
            end += 1;

        if (n_components < URL_MAP[i].min_components or n_open_brackets != 0) return;

        if (opener.ch == '@') break; // e-mail wants only the host
    }

    if (end == line_end or ISUNICODEWHITESPACE(ctx, end) or ISANYOF(ctx, end, ")}].!?,;")) {
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

const MD_ANALYZE_NOSKIP_EMPH: u8 = 0x01;

// md4x.c ~4344.
fn md_analyze_marks(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, mark_beg: c_int, mark_end: c_int, mark_chars: [*:0]const u8, flags: u8) void {
    _ = n_lines;
    var i: c_int = mark_beg;
    var last_end: OFF = lines[0].beg;

    while (i < mark_end) {
        const mark = &ctx.marks[@intCast(i)];

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
                last_end = ctx.marks[@intCast(mark.next)].end
            else
                last_end = mark.end;
        }

        i += 1;
    }
}

// md4x.c ~4410.
fn md_push_inline_attr(ctx: *MD_CTX, closer_index: c_int, attrs_beg: OFF, attrs_end: OFF) c_int {
    if (ctx.n_inline_attrs >= ctx.alloc_inline_attrs) {
        const new_alloc: c_int = if (ctx.alloc_inline_attrs > 0)
            ctx.alloc_inline_attrs + @divTrunc(ctx.alloc_inline_attrs, 2)
        else
            8;
        const new_arr = c_realloc_array(MD_INLINE_ATTR_INFO, ctx.inline_attrs, @intCast(new_alloc));
        if (new_arr == null) {
            md_log(ctx, "realloc() failed.");
            return -1;
        }
        ctx.inline_attrs = new_arr;
        ctx.alloc_inline_attrs = new_alloc;
    }
    ctx.inline_attrs[@intCast(ctx.n_inline_attrs)] = .{
        .closer_index = closer_index,
        .attrs_beg = attrs_beg,
        .attrs_end = attrs_end,
        .skip_end = attrs_end + 1,
    };
    ctx.n_inline_attrs += 1;
    return 0;
}

// md4x.c ~4436.
fn md_find_inline_attr(ctx: *MD_CTX, closer_index: c_int, raw: *[*c]const CHAR, size: *SZ, skip_end: ?*OFF) c_int {
    if (skip_end != null) skip_end.?.* = 0;
    var i: c_int = 0;
    while (i < ctx.n_inline_attrs) : (i += 1) {
        if (ctx.inline_attrs[@intCast(i)].closer_index == closer_index) {
            raw.* = STR(ctx, ctx.inline_attrs[@intCast(i)].attrs_beg);
            size.* = ctx.inline_attrs[@intCast(i)].attrs_end - ctx.inline_attrs[@intCast(i)].attrs_beg;
            if (skip_end != null) skip_end.?.* = ctx.inline_attrs[@intCast(i)].skip_end;
            return 1;
        }
    }
    return 0;
}

// md4x.c ~4454.
fn md_resolve_attrs(ctx: *MD_CTX) c_int {
    var ret: c_int = 0;

    if (ctx.parser.flags & c.MD_FLAG_ATTRIBUTES == 0) return 0;

    ctx.n_inline_attrs = 0;

    var i: c_int = 0;
    while (i < ctx.n_marks) : (i += 1) {
        const mark = &ctx.marks[@intCast(i)];

        if (mark.flags & MD_MARK_RESOLVED == 0) continue;
        if (mark.flags & MD_MARK_CLOSER == 0) continue;
        if (mark.ch == 'C') continue;
        if (mark.ch == 'D') continue;
        if (mark.ch != '*' and mark.ch != '_' and mark.ch != '`' and mark.ch != '~' and mark.ch != ']') continue;

        if (mark.ch == ']') {
            const opener_index = mark.prev;
            if (opener_index >= 0) {
                const opener = &ctx.marks[@intCast(opener_index)];
                if (opener_index + 1 < ctx.n_marks and ctx.marks[@intCast(opener_index + 1)].ch == 'S') continue;
                if (opener.ch == '[' and opener.end - opener.beg >= 2 and mark.end - mark.beg >= 2) continue;
            }
        }

        if (mark.end >= ctx.size or CH(ctx, mark.end) != '{') continue;

        var scan: OFF = mark.end + 1;
        var depth: c_int = 1;
        while (scan < ctx.size and depth > 0) {
            if (CH(ctx, scan) == '{') depth += 1 else if (CH(ctx, scan) == '}') depth -= 1;
            scan += 1;
        }
        if (depth != 0) continue;

        const attrs_beg = mark.end + 1;
        ret = md_push_inline_attr(ctx, i, attrs_beg, scan - 1);
        if (ret != 0) return ret;

        if (mark.ch != '*' and mark.ch != '_') mark.end = scan;
    }

    return ret;
}

// md4x.c ~4538.
fn md_analyze_inlines(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, table_mode: c_int) c_int {
    var ret: c_int = 0;

    ctx.n_marks = 0;

    ret = md_collect_marks(ctx, lines, n_lines, table_mode);
    if (ret != 0) return ret;

    // (1) Links.
    md_analyze_marks(ctx, lines, n_lines, 0, ctx.n_marks, "[]!", 0);
    ret = md_resolve_links(ctx, lines, n_lines);
    if (ret != 0) return ret;
    ctx.opener_stacks[BRACKET_OPENERS].top = -1;
    ctx.unresolved_link_head = -1;
    ctx.unresolved_link_tail = -1;

    if (table_mode != 0) {
        // (2) Table cell boundaries.
        ctx.n_table_cell_boundaries = 0;
        md_analyze_marks(ctx, lines, n_lines, 0, ctx.n_marks, "|", 0);
        return ret;
    }

    // (3) Emphasis/strong; permissive autolinks.
    md_analyze_link_contents(ctx, lines, n_lines, 0, ctx.n_marks);

    // (4) Trailing {attrs}.
    ret = md_resolve_attrs(ctx);
    if (ret != 0) return ret;

    return ret;
}

// md4x.c ~4574.
fn md_analyze_link_contents(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE, mark_beg: c_int, mark_end: c_int) void {
    md_analyze_marks(ctx, lines, n_lines, mark_beg, mark_end, "&", 0);
    md_analyze_marks(ctx, lines, n_lines, mark_beg, mark_end, "*_~$", 0);

    if (ctx.parser.flags & c.MD_FLAG_PERMISSIVEAUTOLINKS != 0) {
        md_analyze_marks(ctx, lines, n_lines, mark_beg, mark_end, "@:.", MD_ANALYZE_NOSKIP_EMPH);
    }

    var i: usize = 0;
    while (i < ctx.opener_stacks.len) : (i += 1) ctx.opener_stacks[i].top = -1;
}

// ---- Span enter/leave helpers + emission (md4x.c ~4594..5197) ----

inline fn mdEnterSpan(ctx: *MD_CTX, ty: c.MD_SPANTYPE, detail: ?*anyopaque) c_int {
    const ret = ctx.parser.enter_span.?(ty, detail, ctx.userdata);
    if (ret != 0) md_log(ctx, "Aborted from enter_span() callback.");
    return ret;
}

inline fn mdLeaveSpan(ctx: *MD_CTX, ty: c.MD_SPANTYPE, detail: ?*anyopaque) c_int {
    const ret = ctx.parser.leave_span.?(ty, detail, ctx.userdata);
    if (ret != 0) md_log(ctx, "Aborted from leave_span() callback.");
    return ret;
}

inline fn mdText(ctx: *MD_CTX, ty: c.MD_TEXTTYPE, str: [*c]const CHAR, size: SZ) c_int {
    if (size > 0) {
        const ret = ctx.parser.text.?(ty, str, size, ctx.userdata);
        if (ret != 0) {
            md_log(ctx, "Aborted from text() callback.");
            return ret;
        }
    }
    return 0;
}

// md4x.c ~4594.
fn md_enter_leave_span_a(ctx: *MD_CTX, enter: c_int, ty: c.MD_SPANTYPE, dest: [*c]const CHAR, dest_size: SZ, is_autolink: c_int, title: [*c]const CHAR, title_size: SZ) c_int {
    var href_build: MD_ATTRIBUTE_BUILD = .{};
    var title_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.MD_SPAN_A_DETAIL = std.mem.zeroes(c.MD_SPAN_A_DETAIL);
    var ret: c_int = 0;

    ret = md_build_attribute(ctx, dest, dest_size, if (is_autolink != 0) MD_BUILD_ATTR_NO_ESCAPES else 0, &det.href, &href_build);
    if (ret == 0) {
        ret = md_build_attribute(ctx, title, title_size, 0, &det.title, &title_build);
    }
    if (ret == 0) {
        det.is_autolink = is_autolink;
        ret = if (enter != 0) mdEnterSpan(ctx, ty, &det) else mdLeaveSpan(ctx, ty, &det);
    }

    md_free_attribute(ctx, &href_build);
    md_free_attribute(ctx, &title_build);
    return ret;
}

// md4x.c ~4623.
fn md_enter_leave_span_wikilink(ctx: *MD_CTX, enter: c_int, target: [*c]const CHAR, target_size: SZ) c_int {
    var target_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.MD_SPAN_WIKILINK_DETAIL = std.mem.zeroes(c.MD_SPAN_WIKILINK_DETAIL);
    var ret: c_int = 0;

    ret = md_build_attribute(ctx, target, target_size, 0, &det.target, &target_build);
    if (ret == 0) {
        ret = if (enter != 0) mdEnterSpan(ctx, c.MD_SPAN_WIKILINK, &det) else mdLeaveSpan(ctx, c.MD_SPAN_WIKILINK, &det);
    }

    md_free_attribute(ctx, &target_build);
    return ret;
}

// md4x.c ~4643.
fn md_enter_leave_span_component(ctx: *MD_CTX, enter: c_int, tag: [*c]const CHAR, tag_size: SZ, raw_props: [*c]const CHAR, raw_props_size: SZ) c_int {
    var tag_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.MD_SPAN_COMPONENT_DETAIL = std.mem.zeroes(c.MD_SPAN_COMPONENT_DETAIL);
    var ret: c_int = 0;

    ret = md_build_attribute(ctx, tag, tag_size, 0, &det.tag_name, &tag_build);
    if (ret == 0) {
        det.raw_props = raw_props;
        det.raw_props_size = raw_props_size;
        ret = if (enter != 0) mdEnterSpan(ctx, c.MD_SPAN_COMPONENT, &det) else mdLeaveSpan(ctx, c.MD_SPAN_COMPONENT, &det);
    }

    md_free_attribute(ctx, &tag_build);
    return ret;
}

// md4x.c ~4669.
fn md_enter_leave_span_a_with_attrs(ctx: *MD_CTX, enter: c_int, ty: c.MD_SPANTYPE, dest: [*c]const CHAR, dest_size: SZ, is_autolink: c_int, title: [*c]const CHAR, title_size: SZ, raw_attrs: [*c]const CHAR, raw_attrs_size: SZ) c_int {
    var href_build: MD_ATTRIBUTE_BUILD = .{};
    var title_build: MD_ATTRIBUTE_BUILD = .{};
    var det: c.MD_SPAN_A_DETAIL = std.mem.zeroes(c.MD_SPAN_A_DETAIL);
    var ret: c_int = 0;

    ret = md_build_attribute(ctx, dest, dest_size, if (is_autolink != 0) MD_BUILD_ATTR_NO_ESCAPES else 0, &det.href, &href_build);
    if (ret == 0) {
        ret = md_build_attribute(ctx, title, title_size, 0, &det.title, &title_build);
    }
    if (ret == 0) {
        det.is_autolink = is_autolink;
        det.raw_attrs = raw_attrs;
        det.raw_attrs_size = raw_attrs_size;
        ret = if (enter != 0) mdEnterSpan(ctx, ty, &det) else mdLeaveSpan(ctx, ty, &det);
    }

    md_free_attribute(ctx, &href_build);
    md_free_attribute(ctx, &title_build);
    return ret;
}

// md4x.c ~4700.
fn md_enter_leave_span_span(ctx: *MD_CTX, enter: c_int, raw_attrs: [*c]const CHAR, raw_attrs_size: SZ) c_int {
    var det: c.MD_SPAN_SPAN_DETAIL = std.mem.zeroes(c.MD_SPAN_SPAN_DETAIL);
    det.raw_attrs = raw_attrs;
    det.raw_attrs_size = raw_attrs_size;
    return if (enter != 0) mdEnterSpan(ctx, c.MD_SPAN_SPAN, &det) else mdLeaveSpan(ctx, c.MD_SPAN_SPAN, &det);
}

// md4x.c ~4721. Render the output per the analyzed ctx.marks.
fn md_process_inlines(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE) c_int {
    var text_type: c.MD_TEXTTYPE = undefined;
    var line: [*c]const MD_LINE = lines;
    var mark: [*c]MD_MARK = undefined;
    var off: OFF = lines[0].beg;
    const end: OFF = lines[n_lines - 1].end;
    var tmp: OFF = undefined;
    var attr_skip_to: OFF = 0;
    var enforce_hardbreak: c_int = 0;
    var ret: c_int = 0;

    mark = ctx.marks;
    while (mark.*.flags & MD_MARK_RESOLVED == 0) mark += 1;

    text_type = c.MD_TEXT_NORMAL;

    main: while (true) {
        tmp = if (line.*.end < mark.*.beg) line.*.end else mark.*.beg;
        if (tmp > off) {
            ret = mdText(ctx, text_type, STR(ctx, off), tmp - off);
            if (ret != 0) return ret;
            off = tmp;
        }

        if (off >= mark.*.beg) {
            switch (mark.*.ch) {
                '\\' => {
                    if (ISNEWLINE(ctx, mark.*.beg + 1)) {
                        enforce_hardbreak = 1;
                    } else {
                        ret = mdText(ctx, text_type, STR(ctx, mark.*.beg + 1), 1);
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
                        _ = md_find_inline_attr(ctx, @intCast((@intFromPtr(mark) - @intFromPtr(ctx.marks)) / @sizeOf(MD_MARK)), &raw_a, &raw_a_sz, null);

                    if (mark.*.flags & MD_MARK_OPENER != 0) {
                        if (raw_a != null) {
                            var det: c.MD_SPAN_ATTRS_DETAIL = .{ .raw_attrs = raw_a, .raw_attrs_size = raw_a_sz };
                            ret = mdEnterSpan(ctx, c.MD_SPAN_CODE, &det);
                        } else {
                            ret = mdEnterSpan(ctx, c.MD_SPAN_CODE, null);
                        }
                        if (ret != 0) return ret;
                        text_type = c.MD_TEXT_CODE;
                    } else {
                        if (raw_a != null) {
                            var det: c.MD_SPAN_ATTRS_DETAIL = .{ .raw_attrs = raw_a, .raw_attrs_size = raw_a_sz };
                            ret = mdLeaveSpan(ctx, c.MD_SPAN_CODE, &det);
                        } else {
                            ret = mdLeaveSpan(ctx, c.MD_SPAN_CODE, null);
                        }
                        if (ret != 0) return ret;
                        text_type = c.MD_TEXT_NORMAL;
                    }
                },

                '_' => {
                    if (ctx.parser.flags & c.MD_FLAG_UNDERLINE != 0) {
                        var raw_a: [*c]const CHAR = null;
                        var raw_a_sz: SZ = 0;
                        if (mark.*.flags & MD_MARK_OPENER != 0)
                            _ = md_find_inline_attr(ctx, mark.*.next, &raw_a, &raw_a_sz, null)
                        else
                            _ = md_find_inline_attr(ctx, @intCast((@intFromPtr(mark) - @intFromPtr(ctx.marks)) / @sizeOf(MD_MARK)), &raw_a, &raw_a_sz, &attr_skip_to);

                        if (mark.*.flags & MD_MARK_OPENER != 0) {
                            var first: c_int = 1;
                            while (off < mark.*.end) {
                                if (first != 0 and raw_a != null) {
                                    var det: c.MD_SPAN_ATTRS_DETAIL = .{ .raw_attrs = raw_a, .raw_attrs_size = raw_a_sz };
                                    ret = mdEnterSpan(ctx, c.MD_SPAN_U, &det);
                                } else {
                                    ret = mdEnterSpan(ctx, c.MD_SPAN_U, null);
                                }
                                if (ret != 0) return ret;
                                first = 0;
                                off += 1;
                            }
                        } else {
                            const count: c_int = @intCast(mark.*.end - off);
                            var idx: c_int = 0;
                            while (off < mark.*.end) {
                                if (idx == count - 1 and raw_a != null) {
                                    var det: c.MD_SPAN_ATTRS_DETAIL = .{ .raw_attrs = raw_a, .raw_attrs_size = raw_a_sz };
                                    ret = mdLeaveSpan(ctx, c.MD_SPAN_U, &det);
                                } else {
                                    ret = mdLeaveSpan(ctx, c.MD_SPAN_U, null);
                                }
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
                        _ = md_find_inline_attr(ctx, @intCast((@intFromPtr(mark) - @intFromPtr(ctx.marks)) / @sizeOf(MD_MARK)), &raw_a, &raw_a_sz, null);

                    if (mark.*.flags & MD_MARK_OPENER != 0) {
                        if (raw_a != null) {
                            var det: c.MD_SPAN_ATTRS_DETAIL = .{ .raw_attrs = raw_a, .raw_attrs_size = raw_a_sz };
                            ret = mdEnterSpan(ctx, c.MD_SPAN_DEL, &det);
                        } else {
                            ret = mdEnterSpan(ctx, c.MD_SPAN_DEL, null);
                        }
                    } else {
                        if (raw_a != null) {
                            var det: c.MD_SPAN_ATTRS_DETAIL = .{ .raw_attrs = raw_a, .raw_attrs_size = raw_a_sz };
                            ret = mdLeaveSpan(ctx, c.MD_SPAN_DEL, &det);
                        } else {
                            ret = mdLeaveSpan(ctx, c.MD_SPAN_DEL, null);
                        }
                    }
                    if (ret != 0) return ret;
                },

                '$' => {
                    if (mark.*.flags & MD_MARK_OPENER != 0) {
                        ret = mdEnterSpan(ctx, if ((mark.*.end - off) % 2 != 0) c.MD_SPAN_LATEXMATH else c.MD_SPAN_LATEXMATH_DISPLAY, null);
                        if (ret != 0) return ret;
                        text_type = c.MD_TEXT_LATEXMATH;
                    } else {
                        ret = mdLeaveSpan(ctx, if ((mark.*.end - off) % 2 != 0) c.MD_SPAN_LATEXMATH else c.MD_SPAN_LATEXMATH_DISPLAY, null);
                        if (ret != 0) return ret;
                        text_type = c.MD_TEXT_NORMAL;
                    }
                },

                '[', '!', ']' => {
                    const opener: [*c]MD_MARK = if (mark.*.ch != ']') mark else &ctx.marks[@intCast(mark.*.prev)];
                    const closer: [*c]MD_MARK = &ctx.marks[@intCast(opener.*.next)];

                    if ((opener.*.ch == '[' and closer.*.ch == ']') and
                        opener.*.end - opener.*.beg >= 2 and
                        closer.*.end - closer.*.beg >= 2)
                    {
                        const has_label = (opener.*.end - opener.*.beg > 2);
                        const target_sz: SZ = if (has_label) opener.*.end - (opener.*.beg + 2) else closer.*.beg - opener.*.end;

                        ret = md_enter_leave_span_wikilink(ctx, @intFromBool(mark.*.ch != ']'), if (has_label) STR(ctx, opener.*.beg + 2) else STR(ctx, opener.*.end), target_sz);
                        if (ret != 0) return ret;
                    } else {
                        const dest_mark: [*c]MD_MARK = opener + 1;
                        const title_mark: [*c]MD_MARK = opener + 2;

                        if (dest_mark.*.ch == 'S') {
                            const raw_a = STR(ctx, dest_mark.*.beg);
                            const raw_a_sz = dest_mark.*.end - dest_mark.*.beg;
                            ret = md_enter_leave_span_span(ctx, @intFromBool(mark.*.ch != ']'), raw_a, raw_a_sz);
                            if (ret != 0) return ret;

                            if (mark.*.ch == ']') {
                                while (mark.*.end > line.*.end and @intFromPtr(line) < @intFromPtr(lines + n_lines - 1)) line += 1;
                            }
                        } else {
                            var raw_a: [*c]const CHAR = null;
                            var raw_a_sz: SZ = 0;
                            const closer_idx: c_int = @intCast((@intFromPtr(closer) - @intFromPtr(ctx.marks)) / @sizeOf(MD_MARK));
                            _ = md_find_inline_attr(ctx, closer_idx, &raw_a, &raw_a_sz, null);

                            const title_ptr: [*c]const CHAR = @ptrCast(@alignCast(md_mark_get_ptr(ctx, @intCast((@intFromPtr(title_mark) - @intFromPtr(ctx.marks)) / @sizeOf(MD_MARK)))));
                            const title_sz: SZ = @bitCast(title_mark.*.prev);

                            if (raw_a != null) {
                                ret = md_enter_leave_span_a_with_attrs(ctx, @intFromBool(mark.*.ch != ']'), if (opener.*.ch == '!') c.MD_SPAN_IMG else c.MD_SPAN_A, STR(ctx, dest_mark.*.beg), dest_mark.*.end - dest_mark.*.beg, FALSE, title_ptr, title_sz, raw_a, raw_a_sz);
                            } else {
                                ret = md_enter_leave_span_a(ctx, @intFromBool(mark.*.ch != ']'), if (opener.*.ch == '!') c.MD_SPAN_IMG else c.MD_SPAN_A, STR(ctx, dest_mark.*.beg), dest_mark.*.end - dest_mark.*.beg, FALSE, title_ptr, title_sz);
                            }
                            if (ret != 0) return ret;

                            if (mark.*.ch == ']') {
                                while (mark.*.end > line.*.end and @intFromPtr(line) < @intFromPtr(lines + n_lines - 1)) line += 1;
                            }
                        }
                    }
                },

                '<', '>' => {
                    if (mark.*.flags & MD_MARK_AUTOLINK == 0) {
                        // Raw HTML.
                        if (mark.*.flags & MD_MARK_OPENER != 0)
                            text_type = c.MD_TEXT_HTML
                        else
                            text_type = c.MD_TEXT_NORMAL;
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
                    ret = mdText(ctx, c.MD_TEXT_ENTITY, STR(ctx, mark.*.beg), mark.*.end - mark.*.beg);
                    if (ret != 0) return ret;
                },

                'C' => {
                    const opener: [*c]MD_MARK = if (mark.*.flags & MD_MARK_OPENER != 0) mark else &ctx.marks[@intCast(mark.*.prev)];
                    const closer: [*c]MD_MARK = &ctx.marks[@intCast(opener.*.next)];
                    const props_mark: [*c]MD_MARK = opener + 1;
                    const tag_str = STR(ctx, opener.*.beg + 1);
                    var name_end_off: OFF = opener.*.beg + 1;
                    var raw_props: [*c]const CHAR = null;
                    var raw_props_size: SZ = 0;

                    while (name_end_off < opener.*.end and (ISALNUM(ctx, name_end_off) or CH(ctx, name_end_off) == '-')) name_end_off += 1;
                    const tag_size: SZ = name_end_off - (opener.*.beg + 1);

                    if (props_mark.*.ch == 'D' and props_mark.*.end > props_mark.*.beg) {
                        raw_props = STR(ctx, props_mark.*.beg);
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
                    ret = mdText(ctx, c.MD_TEXT_NULLCHAR, "", 1);
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

            if (text_type == c.MD_TEXT_CODE or text_type == c.MD_TEXT_LATEXMATH) {
                tmp = off;
                while (off < ctx.size and ISBLANK(ctx, off)) off += 1;
                if (off > tmp) {
                    ret = mdText(ctx, text_type, STR(ctx, tmp), off - tmp);
                    if (ret != 0) return ret;
                }
                if (off == line.*.end) {
                    ret = mdText(ctx, text_type, " ", 1);
                    if (ret != 0) return ret;
                }
            } else if (text_type == c.MD_TEXT_HTML) {
                tmp = off;
                while (tmp < end and ISBLANK(ctx, tmp)) tmp += 1;
                if (tmp > off) {
                    ret = mdText(ctx, c.MD_TEXT_HTML, STR(ctx, off), tmp - off);
                    if (ret != 0) return ret;
                }
                ret = mdText(ctx, c.MD_TEXT_HTML, "\n", 1);
                if (ret != 0) return ret;
            } else {
                var break_type: c.MD_TEXTTYPE = c.MD_TEXT_SOFTBR;

                if (text_type == c.MD_TEXT_NORMAL) {
                    if (enforce_hardbreak != 0 or (ctx.parser.flags & c.MD_FLAG_HARD_SOFT_BREAKS != 0)) {
                        break_type = c.MD_TEXT_BR;
                    } else {
                        while (off < ctx.size and ISBLANK(ctx, off)) off += 1;
                        if (off >= line.*.end + 2 and CH(ctx, off - 2) == ' ' and CH(ctx, off - 1) == ' ' and ISNEWLINE(ctx, off))
                            break_type = c.MD_TEXT_BR;
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
fn emitEmphasis(ctx: *MD_CTX, mark: [*c]MD_MARK, off_p: *OFF, attr_skip_to: *OFF) c_int {
    var ret: c_int = 0;
    var raw_a: [*c]const CHAR = null;
    var raw_a_sz: SZ = 0;
    if (mark.*.flags & MD_MARK_OPENER != 0)
        _ = md_find_inline_attr(ctx, mark.*.next, &raw_a, &raw_a_sz, null)
    else
        _ = md_find_inline_attr(ctx, @intCast((@intFromPtr(mark) - @intFromPtr(ctx.marks)) / @sizeOf(MD_MARK)), &raw_a, &raw_a_sz, attr_skip_to);

    var off = off_p.*;
    if (mark.*.flags & MD_MARK_OPENER != 0) {
        var first: c_int = 1;
        if ((mark.*.end - off) % 2 != 0) {
            if (first != 0 and raw_a != null) {
                var det: c.MD_SPAN_ATTRS_DETAIL = .{ .raw_attrs = raw_a, .raw_attrs_size = raw_a_sz };
                ret = mdEnterSpan(ctx, c.MD_SPAN_EM, &det);
            } else {
                ret = mdEnterSpan(ctx, c.MD_SPAN_EM, null);
            }
            if (ret != 0) {
                off_p.* = off;
                return ret;
            }
            first = 0;
            off += 1;
        }
        while (off + 1 < mark.*.end) {
            if (first != 0 and raw_a != null) {
                var det: c.MD_SPAN_ATTRS_DETAIL = .{ .raw_attrs = raw_a, .raw_attrs_size = raw_a_sz };
                ret = mdEnterSpan(ctx, c.MD_SPAN_STRONG, &det);
            } else {
                ret = mdEnterSpan(ctx, c.MD_SPAN_STRONG, null);
            }
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
            if (has_em == 0 and si == n_strong and raw_a != null) {
                var det: c.MD_SPAN_ATTRS_DETAIL = .{ .raw_attrs = raw_a, .raw_attrs_size = raw_a_sz };
                ret = mdLeaveSpan(ctx, c.MD_SPAN_STRONG, &det);
            } else {
                ret = mdLeaveSpan(ctx, c.MD_SPAN_STRONG, null);
            }
            if (ret != 0) {
                off_p.* = off;
                return ret;
            }
            off += 2;
        }
        if (has_em != 0) {
            if (raw_a != null) {
                var det: c.MD_SPAN_ATTRS_DETAIL = .{ .raw_attrs = raw_a, .raw_attrs_size = raw_a_sz };
                ret = mdLeaveSpan(ctx, c.MD_SPAN_EM, &det);
            } else {
                ret = mdLeaveSpan(ctx, c.MD_SPAN_EM, null);
            }
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
fn emitPermissiveAutolink(ctx: *MD_CTX, mark: [*c]MD_MARK, off: OFF) c_int {
    var ret: c_int = 0;
    const opener: [*c]MD_MARK = if (mark.*.flags & MD_MARK_OPENER != 0) mark else &ctx.marks[@intCast(mark.*.prev)];
    const closer: [*c]MD_MARK = &ctx.marks[@intCast(opener.*.next)];
    var dest: [*c]const CHAR = STR(ctx, opener.*.end);
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
        ret = md_enter_leave_span_a(ctx, @intFromBool(mark.*.flags & MD_MARK_OPENER != 0), c.MD_SPAN_A, dest, dest_size, TRUE, null, 0);
    return ret;
}

// ============================================================================
//  Pass D — Block / line analysis (md4x.c ~5984..7859)
// ============================================================================
//
// Block accumulation, container push/pop, the line classifier, and the
// HTML-block start/end conditions that feed it. md_process_block /
// md_process_all_blocks / md_process_line / md_process_doc / md_parse glue is
// Pass E. Reference C = the FIXED src/md4x.c.

const TABLE_MAXCOLCOUNT: c_uint = 128; // md4x.c #define (DoS cap).

// `MD_MIN` for unsigned values.
inline fn MIN_u(a: c_uint, b: c_uint) c_uint {
    return if (a < b) a else b;
}

// --- block-bytes growable buffer ---------------------------------------------

// md_push_block_bytes (md4x.c ~5984). Returns a raw pointer into ctx.block_bytes,
// or null on OOM (mirroring C's NULL). Fixes ctx.current_block after realloc.
fn md_push_block_bytes(ctx: *MD_CTX, n_bytes: c_int) ?*anyopaque {
    if (ctx.n_block_bytes + n_bytes > ctx.alloc_block_bytes) {
        ctx.alloc_block_bytes = if (ctx.alloc_block_bytes > 0)
            ctx.alloc_block_bytes + @divTrunc(ctx.alloc_block_bytes, 2)
        else
            512;
        const new_block_bytes = std.c.realloc(ctx.block_bytes, @intCast(ctx.alloc_block_bytes));
        if (new_block_bytes == null) {
            md_log(ctx, "realloc() failed.");
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

fn md_start_new_block(ctx: *MD_CTX, line: *const MD_LINE_ANALYSIS) c_int {
    // MD_ASSERT(ctx->current_block == NULL);
    const block_raw = md_push_block_bytes(ctx, @sizeOf(MD_BLOCK));
    if (block_raw == null)
        return -1;
    const block: *MD_BLOCK = @ptrCast(@alignCast(block_raw));

    switch (line.type) {
        .MD_LINE_HR => block.setType(c.MD_BLOCK_HR),
        .MD_LINE_ATXHEADER, .MD_LINE_SETEXTHEADER => block.setType(c.MD_BLOCK_H),
        .MD_LINE_FENCEDCODE, .MD_LINE_INDENTEDCODE => block.setType(c.MD_BLOCK_CODE),
        .MD_LINE_TEXT => block.setType(c.MD_BLOCK_P),
        .MD_LINE_HTML => block.setType(c.MD_BLOCK_HTML),
        .MD_LINE_FRONTMATTER => block.setType(c.MD_BLOCK_FRONTMATTER),
        // MD_LINE_BLANK / SETEXTUNDERLINE / TABLEUNDERLINE / default: MD_UNREACHABLE.
        else => unreachable,
    }

    block.bits.flags = 0;
    block.bits.data = @truncate(line.data);
    block.n_lines = 0;

    ctx.current_block = block;
    return 0;
}

// Eat from start of current (textual) block any reference definitions.
fn md_consume_link_reference_definitions(ctx: *MD_CTX) c_int {
    const lines: [*c]MD_LINE = @ptrCast(@alignCast(ctx.current_block + 1));
    const n_lines: MD_SIZE = ctx.current_block.*.n_lines;
    var n: MD_SIZE = 0;

    while (n < n_lines) {
        const n_link_ref_lines = md_is_link_reference_definition(ctx, lines + n, n_lines - n);
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

fn md_end_current_block(ctx: *MD_CTX) c_int {
    var ret: c_int = 0;

    if (ctx.current_block == null)
        return ret;

    // Check whether there is a reference definition.
    if (ctx.current_block.*.getType() == c.MD_BLOCK_P or
        (ctx.current_block.*.getType() == c.MD_BLOCK_H and (ctx.current_block.*.bits.flags & MD_BLOCK_SETEXT_HEADER != 0)))
    {
        const lines: [*c]MD_LINE = @ptrCast(@alignCast(ctx.current_block + 1));
        if (lines[0].beg < ctx.size and CH(ctx, lines[0].beg) == '[') {
            ret = md_consume_link_reference_definitions(ctx);
            if (ret < 0) return ret;
            if (ctx.current_block == null)
                return ret;
        }
    }

    if (ctx.current_block.*.getType() == c.MD_BLOCK_H and (ctx.current_block.*.bits.flags & MD_BLOCK_SETEXT_HEADER != 0)) {
        const n_lines: MD_SIZE = ctx.current_block.*.n_lines;

        if (n_lines > 1) {
            // Get rid of the underline.
            ctx.current_block.*.n_lines -= 1;
            ctx.n_block_bytes -= @sizeOf(MD_LINE);
        } else {
            // Only the underline has left after eating the ref. defs.
            ctx.current_block.*.setType(c.MD_BLOCK_P);
            return 0;
        }
    }

    // Mark we are not building any block anymore.
    ctx.current_block = null;

    return ret;
}

fn md_add_line_into_current_block(ctx: *MD_CTX, analysis: *const MD_LINE_ANALYSIS) c_int {
    // MD_ASSERT(ctx->current_block != NULL);
    const bt = ctx.current_block.*.getType();
    if (bt == c.MD_BLOCK_CODE or bt == c.MD_BLOCK_HTML or bt == c.MD_BLOCK_FRONTMATTER) {
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

fn md_push_container_bytes(ctx: *MD_CTX, ty: c.MD_BLOCKTYPE, start: c_uint, data: c_uint, flags: c_uint) c_int {
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

fn md_push_block_component_info(ctx: *MD_CTX, colon_count: c_uint, name_beg: OFF, name_end: OFF, props_beg: OFF, props_end: OFF, title_beg: OFF, title_end: OFF) c_int {
    if (ctx.n_block_components >= ctx.alloc_block_components) {
        const new_alloc: c_int = if (ctx.alloc_block_components > 0)
            ctx.alloc_block_components + @divTrunc(ctx.alloc_block_components, 2)
        else
            16;
        const new_arr = c_realloc_array(MD_BLOCK_COMPONENT_INFO, ctx.block_component_info, @intCast(new_alloc));
        if (new_arr == null) {
            md_log(ctx, "realloc() failed.");
            return -1;
        }
        ctx.block_component_info = new_arr;
        ctx.alloc_block_components = new_alloc;
    }

    const idx = ctx.n_block_components;
    ctx.n_block_components += 1;
    const e = &ctx.block_component_info[@intCast(idx)];
    e.colon_count = colon_count;
    e.name_beg = name_beg;
    e.name_end = name_end;
    e.props_beg = props_beg;
    e.props_end = props_end;
    e.title_beg = title_beg;
    e.title_end = title_end;
    return idx;
}

fn md_push_slot_info(ctx: *MD_CTX, name_beg: OFF, name_end: OFF) c_int {
    if (ctx.n_slots >= ctx.alloc_slots) {
        const new_alloc: c_int = if (ctx.alloc_slots > 0)
            ctx.alloc_slots + @divTrunc(ctx.alloc_slots, 2)
        else
            16;
        const new_arr = c_realloc_array(MD_SLOT_INFO, ctx.slot_info, @intCast(new_alloc));
        if (new_arr == null) {
            md_log(ctx, "realloc() failed.");
            return -1;
        }
        ctx.slot_info = new_arr;
        ctx.alloc_slots = new_alloc;
    }

    const idx = ctx.n_slots;
    ctx.n_slots += 1;
    ctx.slot_info[@intCast(idx)].name_beg = name_beg;
    ctx.slot_info[@intCast(idx)].name_end = name_end;
    return idx;
}

fn md_push_block_alert_info(ctx: *MD_CTX, type_beg: OFF, type_end: OFF) c_int {
    if (ctx.n_block_alerts >= ctx.alloc_block_alerts) {
        const new_alloc: c_int = if (ctx.alloc_block_alerts > 0)
            ctx.alloc_block_alerts + @divTrunc(ctx.alloc_block_alerts, 2)
        else
            16;
        const new_arr = c_realloc_array(MD_BLOCK_ALERT_INFO, ctx.block_alert_info, @intCast(new_alloc));
        if (new_arr == null) {
            md_log(ctx, "realloc() failed.");
            return -1;
        }
        ctx.block_alert_info = new_arr;
        ctx.alloc_block_alerts = new_alloc;
    }

    const idx = ctx.n_block_alerts;
    ctx.n_block_alerts += 1;
    ctx.block_alert_info[@intCast(idx)].type_beg = type_beg;
    ctx.block_alert_info[@intCast(idx)].type_end = type_end;
    return idx;
}

// --- line classification helpers ---------------------------------------------

fn md_is_hr_line(ctx: *MD_CTX, beg: OFF, p_end: *OFF, p_killer: *OFF) c_int {
    var off: OFF = beg + 1;
    var n: c_int = 1;

    while (off < ctx.size and (CH(ctx, off) == CH(ctx, beg) or CH(ctx, off) == ' ' or CH(ctx, off) == '\t')) {
        if (CH(ctx, off) == CH(ctx, beg))
            n += 1;
        off += 1;
    }

    if (n < 3) {
        p_killer.* = off;
        return FALSE;
    }

    // Nothing else can be present on the line.
    if (off < ctx.size and !ISNEWLINE(ctx, off)) {
        p_killer.* = off;
        return FALSE;
    }

    p_end.* = off;
    return TRUE;
}

fn md_is_atxheader_line(ctx: *MD_CTX, beg: OFF, p_beg: *OFF, p_end: *OFF, p_level: *c_uint) c_int {
    var off: OFF = beg + 1;

    while (off < ctx.size and CH(ctx, off) == '#' and off - beg < 7)
        off += 1;
    const n: OFF = off - beg;

    if (n > 6)
        return FALSE;
    p_level.* = n;

    if ((ctx.parser.flags & c.MD_FLAG_PERMISSIVEATXHEADERS == 0) and off < ctx.size and
        !ISBLANK(ctx, off) and !ISNEWLINE(ctx, off))
        return FALSE;

    while (off < ctx.size and ISBLANK(ctx, off))
        off += 1;
    p_beg.* = off;
    p_end.* = off;
    return TRUE;
}

fn md_is_setext_underline(ctx: *MD_CTX, beg: OFF, p_end: *OFF, p_level: *c_uint) c_int {
    var off: OFF = beg + 1;

    while (off < ctx.size and CH(ctx, off) == CH(ctx, beg))
        off += 1;

    // Optionally, space(s) or tabs can follow.
    while (off < ctx.size and ISBLANK(ctx, off))
        off += 1;

    // But nothing more is allowed on the line.
    if (off < ctx.size and !ISNEWLINE(ctx, off))
        return FALSE;

    p_level.* = if (CH(ctx, beg) == '=') 1 else 2;
    p_end.* = off;
    return TRUE;
}

fn md_is_table_underline(ctx: *MD_CTX, beg: OFF, p_end: *OFF, p_col_count: *c_uint) c_int {
    var off: OFF = beg;
    var found_pipe: c_int = FALSE;
    var col_count: c_uint = 0;

    if (off < ctx.size and CH(ctx, off) == '|') {
        found_pipe = TRUE;
        off += 1;
        while (off < ctx.size and ISWHITESPACE(ctx, off))
            off += 1;
    }

    while (true) {
        var delimited: c_int = FALSE;

        // Cell underline ("-----", ":----", "----:" or ":----:")
        if (off < ctx.size and CH(ctx, off) == ':')
            off += 1;
        if (off >= ctx.size or CH(ctx, off) != '-')
            return FALSE;
        while (off < ctx.size and CH(ctx, off) == '-')
            off += 1;
        if (off < ctx.size and CH(ctx, off) == ':')
            off += 1;

        col_count += 1;
        if (col_count > TABLE_MAXCOLCOUNT) {
            md_log(ctx, "Suppressing table (column_count > TABLE_MAXCOLCOUNT)");
            return FALSE;
        }

        // Pipe delimiter (optional at the end of line).
        while (off < ctx.size and ISWHITESPACE(ctx, off))
            off += 1;
        if (off < ctx.size and CH(ctx, off) == '|') {
            delimited = TRUE;
            found_pipe = TRUE;
            off += 1;
            while (off < ctx.size and ISWHITESPACE(ctx, off))
                off += 1;
        }

        // Success, if we reach end of line.
        if (off >= ctx.size or ISNEWLINE(ctx, off))
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

fn md_is_opening_code_fence(ctx: *MD_CTX, beg: OFF, p_end: *OFF) c_int {
    var off: OFF = beg;

    while (off < ctx.size and CH(ctx, off) == CH(ctx, beg))
        off += 1;

    // Fence must have at least three characters.
    if (off - beg < 3)
        return FALSE;

    ctx.code_fence_length = off - beg;

    // Optionally, space(s) can follow.
    while (off < ctx.size and CH(ctx, off) == ' ')
        off += 1;

    // Optionally, an info string can follow.
    while (off < ctx.size and !ISNEWLINE(ctx, off)) {
        // Backtick-based fence must not contain '`' in the info string.
        if (CH(ctx, beg) == '`' and CH(ctx, off) == '`')
            return FALSE;
        off += 1;
    }

    p_end.* = off;
    return TRUE;
}

fn md_is_closing_code_fence(ctx: *MD_CTX, ch: CHAR, beg: OFF, p_end: *OFF) c_int {
    var off: OFF = beg;
    var ret: c_int = FALSE;

    // Closing fence must have at least the same length and use same char.
    while (off < ctx.size and CH(ctx, off) == ch)
        off += 1;
    if (off - beg < ctx.code_fence_length) {
        // goto out;
        p_end.* = off;
        return ret;
    }

    // Optionally, space(s) can follow
    while (off < ctx.size and CH(ctx, off) == ' ')
        off += 1;

    // But nothing more is allowed on the line.
    if (off < ctx.size and !ISNEWLINE(ctx, off)) {
        p_end.* = off;
        return ret;
    }

    ret = TRUE;

    // Note we set *p_end even on failure.
    p_end.* = off;
    return ret;
}

// --- HTML block start/end conditions -----------------------------------------

const TAG = struct {
    name: [*c]const CHAR,
    len: u8,
};
inline fn mkTag(comptime name: []const u8) TAG {
    return .{ .name = @ptrCast(name.ptr), .len = name.len };
}

const t1 = [_]TAG{ mkTag("pre"), mkTag("script"), mkTag("style"), mkTag("textarea") };

const a6 = [_]TAG{ mkTag("address"), mkTag("article"), mkTag("aside") };
const b6 = [_]TAG{ mkTag("base"), mkTag("basefont"), mkTag("blockquote"), mkTag("body") };
const c6 = [_]TAG{ mkTag("caption"), mkTag("center"), mkTag("col"), mkTag("colgroup") };
const d6 = [_]TAG{ mkTag("dd"), mkTag("details"), mkTag("dialog"), mkTag("dir"), mkTag("div"), mkTag("dl"), mkTag("dt") };
const f6 = [_]TAG{ mkTag("fieldset"), mkTag("figcaption"), mkTag("figure"), mkTag("footer"), mkTag("form"), mkTag("frame"), mkTag("frameset") };
const h6 = [_]TAG{ mkTag("h1"), mkTag("h2"), mkTag("h3"), mkTag("h4"), mkTag("h5"), mkTag("h6"), mkTag("head"), mkTag("header"), mkTag("hr"), mkTag("html") };
const tag_i6 = [_]TAG{mkTag("iframe")};
const l6 = [_]TAG{ mkTag("legend"), mkTag("li"), mkTag("link") };
const m6 = [_]TAG{ mkTag("main"), mkTag("menu"), mkTag("menuitem") };
const n6 = [_]TAG{ mkTag("nav"), mkTag("noframes") };
const o6 = [_]TAG{ mkTag("ol"), mkTag("optgroup"), mkTag("option") };
const p6 = [_]TAG{ mkTag("p"), mkTag("param") };
const s6 = [_]TAG{ mkTag("search"), mkTag("section"), mkTag("summary") };
const t6 = [_]TAG{ mkTag("table"), mkTag("tbody"), mkTag("td"), mkTag("tfoot"), mkTag("th"), mkTag("thead"), mkTag("title"), mkTag("tr"), mkTag("track") };
const tag_u6 = [_]TAG{mkTag("ul")};
const xx = [_]TAG{};

const map6 = [26][]const TAG{
    &a6, &b6, &c6, &d6, &xx, &f6, &xx, &h6,     &tag_i6, &xx, &xx, &l6, &m6,
    &n6, &o6, &p6, &xx, &xx, &s6, &t6, &tag_u6, &xx,     &xx, &xx, &xx, &xx,
};

// Returns type of the raw HTML block, or FALSE (0) if not an HTML block.
fn md_is_html_block_start_condition(ctx: *MD_CTX, beg: OFF) c_int {
    var off: OFF = beg + 1;

    // Check for type 1: <script, <pre, or <style
    for (t1) |tag| {
        if (off + tag.len <= ctx.size) {
            if (md_ascii_case_eq(STR(ctx, off), tag.name, tag.len) != 0)
                return 1;
        }
    }

    // Check for type 2: <!--
    if (off + 3 < ctx.size and CH(ctx, off) == '!' and CH(ctx, off + 1) == '-' and CH(ctx, off + 2) == '-')
        return 2;

    // Check for type 3: <?
    if (off < ctx.size and CH(ctx, off) == '?')
        return 3;

    // Check for type 4 or 5: <!
    if (off < ctx.size and CH(ctx, off) == '!') {
        // Type 4: <! followed by uppercase letter (C tests ISASCII here).
        if (off + 1 < ctx.size and ISASCII(ctx, off + 1))
            return 4;

        // Type 5: <![CDATA[
        if (off + 8 < ctx.size) {
            if (md_ascii_eq(STR(ctx, off), "![CDATA[", 8) != 0)
                return 5;
        }
    }

    // Check for type 6: Many possible starting tags.
    if (off + 1 < ctx.size and (ISALPHA(ctx, off) or (CH(ctx, off) == '/' and ISALPHA(ctx, off + 1)))) {
        if (CH(ctx, off) == '/')
            off += 1;

        const slot: usize = if (ISUPPER(ctx, off)) @intCast(uval(CH(ctx, off)) - 'A') else @intCast(uval(CH(ctx, off)) - 'a');
        const tags = map6[slot];

        for (tags) |tag| {
            if (off + tag.len <= ctx.size) {
                if (md_ascii_case_eq(STR(ctx, off), tag.name, tag.len) != 0) {
                    const tmp: OFF = off + tag.len;
                    if (tmp >= ctx.size)
                        return 6;
                    if (ISBLANK(ctx, tmp) or ISNEWLINE(ctx, tmp) or CH(ctx, tmp) == '>')
                        return 6;
                    if (tmp + 1 < ctx.size and CH(ctx, tmp) == '/' and CH(ctx, tmp + 1) == '>')
                        return 6;
                    break;
                }
            }
        }
    }

    // Check for type 7: any COMPLETE other opening or closing tag.
    if (off + 1 < ctx.size) {
        var end: OFF = undefined;

        if (md_is_html_tag(ctx, null, 0, beg, ctx.size, &end) != 0) {
            // Only optional whitespace and new line may follow.
            while (end < ctx.size and ISWHITESPACE(ctx, end))
                end += 1;
            if (end >= ctx.size or ISNEWLINE(ctx, end))
                return 7;
        }
    }

    return FALSE;
}

// Case-sensitive check whether substring 'what' is between 'beg' and EOL.
fn md_line_contains(ctx: *MD_CTX, beg: OFF, what: [*c]const CHAR, what_len: SZ, p_end: *OFF) c_int {
    var i: OFF = beg;
    while (i + what_len < ctx.size) : (i += 1) {
        if (ISNEWLINE(ctx, i))
            break;
        if (memcmp(STR(ctx, i), what, what_len) == 0) {
            p_end.* = i + what_len;
            return TRUE;
        }
    }

    p_end.* = i;
    return FALSE;
}

fn md_is_html_block_end_condition(ctx: *MD_CTX, beg: OFF, p_end: *OFF) c_int {
    switch (ctx.html_block_type) {
        1 => {
            var off: OFF = beg;

            while (off + 1 < ctx.size and !ISNEWLINE(ctx, off)) {
                if (CH(ctx, off) == '<' and CH(ctx, off + 1) == '/') {
                    for (t1) |tag| {
                        if (off + 2 + tag.len < ctx.size) {
                            if (md_ascii_case_eq(STR(ctx, off + 2), tag.name, tag.len) != 0 and
                                CH(ctx, off + 2 + tag.len) == '>')
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
            if (beg >= ctx.size or ISNEWLINE(ctx, beg)) {
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
fn md_is_block_component_opener(ctx: *MD_CTX, off_in: OFF, p_name_beg: *OFF, p_name_end: *OFF, p_props_beg: *OFF, p_props_end: *OFF, p_title_beg: *OFF, p_title_end: *OFF, p_end: *OFF) c_uint {
    var off: OFF = off_in;
    const start: OFF = off;

    while (off < ctx.size and CH(ctx, off) == ':')
        off += 1;
    const colon_count: c_uint = off - start;
    if (colon_count < 2)
        return 0;

    // Optional whitespace between colons and name.
    while (off < ctx.size and ISBLANK(ctx, off))
        off += 1;

    // Component name must start with a letter.
    if (off >= ctx.size or !ISALPHA(ctx, off))
        return 0;

    p_name_beg.* = off;
    while (off < ctx.size and (ISALNUM(ctx, off) or CH(ctx, off) == '-'))
        off += 1;
    p_name_end.* = off;

    if (p_name_end.* == p_name_beg.*)
        return 0;

    p_props_beg.* = 0;
    p_props_end.* = 0;
    p_title_beg.* = 0;
    p_title_end.* = 0;

    // Skip whitespace after name.
    while (off < ctx.size and ISBLANK(ctx, off))
        off += 1;

    // Check for {props} immediately after name.
    if (off < ctx.size and CH(ctx, off) == '{') {
        const brace_start: OFF = off + 1;
        var j: OFF = brace_start;
        while (j < ctx.size and !ISNEWLINE(ctx, j) and CH(ctx, j) != '}')
            j += 1;
        if (j < ctx.size and CH(ctx, j) == '}') {
            p_props_beg.* = brace_start;
            p_props_end.* = j;
            off = j + 1;
        }
    } else if (off < ctx.size and !ISNEWLINE(ctx, off)) {
        // Title text: everything until '{' or end of line.
        const title_start: OFF = off;
        while (off < ctx.size and !ISNEWLINE(ctx, off) and CH(ctx, off) != '{')
            off += 1;

        // Trim trailing whitespace from title.
        {
            var title_end: OFF = off;
            while (title_end > title_start and ISBLANK_(CH(ctx, title_end - 1)))
                title_end -= 1;
            if (title_end > title_start) {
                p_title_beg.* = title_start;
                p_title_end.* = title_end;
            }
        }

        // Check for {props} after title.
        if (off < ctx.size and CH(ctx, off) == '{') {
            const brace_start: OFF = off + 1;
            var j: OFF = brace_start;
            while (j < ctx.size and !ISNEWLINE(ctx, j) and CH(ctx, j) != '}')
                j += 1;
            if (j < ctx.size and CH(ctx, j) == '}') {
                p_props_beg.* = brace_start;
                p_props_end.* = j;
                off = j + 1;
            }
        }
    }

    // Only whitespace allowed after.
    while (off < ctx.size and ISBLANK(ctx, off))
        off += 1;
    if (off < ctx.size and !ISNEWLINE(ctx, off))
        return 0;

    p_end.* = off;
    return colon_count;
}

// :: (with only whitespace after). Returns colon count (>=2) or 0.
fn md_is_block_component_closer(ctx: *MD_CTX, off_in: OFF, p_end: *OFF) c_uint {
    var off: OFF = off_in;
    const start: OFF = off;

    while (off < ctx.size and CH(ctx, off) == ':')
        off += 1;
    const colon_count: c_uint = off - start;
    if (colon_count < 2)
        return 0;

    // Must not be followed by a name (that would be an opener).
    if (off < ctx.size and ISALPHA(ctx, off))
        return 0;

    // Only whitespace allowed after.
    while (off < ctx.size and ISBLANK(ctx, off))
        off += 1;
    if (off < ctx.size and !ISNEWLINE(ctx, off))
        return 0;

    p_end.* = off;
    return colon_count;
}

// #slot-name (within a block component). Returns 1 on success, 0 on failure.
fn md_is_slot_opener(ctx: *MD_CTX, off_in: OFF, p_name_beg: *OFF, p_name_end: *OFF, p_end: *OFF) c_int {
    var off: OFF = off_in;

    if (off >= ctx.size or CH(ctx, off) != '#')
        return 0;
    off += 1;

    // Slot name must start with a letter.
    if (off >= ctx.size or !ISALPHA(ctx, off))
        return 0;

    p_name_beg.* = off;
    while (off < ctx.size and (ISALNUM(ctx, off) or CH(ctx, off) == '-'))
        off += 1;
    p_name_end.* = off;

    // Only whitespace allowed after.
    while (off < ctx.size and ISBLANK(ctx, off))
        off += 1;
    if (off < ctx.size and !ISNEWLINE(ctx, off))
        return 0;

    p_end.* = off;
    return 1;
}

// --- container push/pop ------------------------------------------------------

fn md_is_container_compatible(pivot_p: [*c]const MD_CONTAINER, container_p: [*c]const MD_CONTAINER) c_int {
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

fn md_push_container(ctx: *MD_CTX, container: *const MD_CONTAINER) c_int {
    if (ctx.n_containers >= ctx.alloc_containers) {
        ctx.alloc_containers = if (ctx.alloc_containers > 0)
            ctx.alloc_containers + @divTrunc(ctx.alloc_containers, 2)
        else
            16;
        const new_containers = c_realloc_array(MD_CONTAINER, ctx.containers, @intCast(ctx.alloc_containers));
        if (new_containers == null) {
            md_log(ctx, "realloc() failed.");
            return -1;
        }
        ctx.containers = new_containers;
    }

    ctx.containers[@intCast(ctx.n_containers)] = container.*;
    ctx.n_containers += 1;
    return 0;
}

fn md_enter_child_containers(ctx: *MD_CTX, n_children: c_int) c_int {
    var ret: c_int = 0;

    var i: c_int = ctx.n_containers - n_children;
    while (i < ctx.n_containers) : (i += 1) {
        const cont = &ctx.containers[@intCast(i)];
        var is_ordered_list: c_int = FALSE;

        switch (cont.ch) {
            ')', '.' => {
                is_ordered_list = TRUE;
                // MD_FALLTHROUGH to bullet handling.
                _ = md_end_current_block(ctx);
                cont.block_byte_off = @intCast(ctx.n_block_bytes);

                ret = md_push_container_bytes(ctx, if (is_ordered_list != 0) c.MD_BLOCK_OL else c.MD_BLOCK_UL, cont.start, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, c.MD_BLOCK_LI, cont.task_mark_off, if (cont.is_task != 0) @intCast(uval(CH(ctx, cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            '-', '+', '*' => {
                // Remember offset in block_bytes so we can revisit if loose.
                _ = md_end_current_block(ctx);
                cont.block_byte_off = @intCast(ctx.n_block_bytes);

                ret = md_push_container_bytes(ctx, if (is_ordered_list != 0) c.MD_BLOCK_OL else c.MD_BLOCK_UL, cont.start, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, c.MD_BLOCK_LI, cont.task_mark_off, if (cont.is_task != 0) @intCast(uval(CH(ctx, cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            '>' => {
                if (cont.is_alert != 0)
                    ret = md_push_container_bytes(ctx, c.MD_BLOCK_ALERT, 0, cont.start, MD_BLOCK_CONTAINER_OPENER)
                else
                    ret = md_push_container_bytes(ctx, c.MD_BLOCK_QUOTE, 0, 0, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            ':' => {
                ret = md_push_container_bytes(ctx, c.MD_BLOCK_COMPONENT, 0, cont.start, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            '#' => {
                ret = md_push_container_bytes(ctx, c.MD_BLOCK_TEMPLATE, 0, cont.start, MD_BLOCK_CONTAINER_OPENER);
                if (ret < 0) return ret;
            },
            else => unreachable,
        }
    }

    return ret;
}

fn md_leave_child_containers(ctx: *MD_CTX, n_keep: c_int) c_int {
    var ret: c_int = 0;

    while (ctx.n_containers > n_keep) {
        const cont = &ctx.containers[@intCast(ctx.n_containers - 1)];
        var is_ordered_list: c_int = FALSE;

        switch (cont.ch) {
            ')', '.' => {
                is_ordered_list = TRUE;
                ret = md_push_container_bytes(ctx, c.MD_BLOCK_LI, cont.task_mark_off, if (cont.is_task != 0) @intCast(uval(CH(ctx, cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, if (is_ordered_list != 0) c.MD_BLOCK_OL else c.MD_BLOCK_UL, 0, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
            },
            '-', '+', '*' => {
                ret = md_push_container_bytes(ctx, c.MD_BLOCK_LI, cont.task_mark_off, if (cont.is_task != 0) @intCast(uval(CH(ctx, cont.task_mark_off))) else 0, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
                ret = md_push_container_bytes(ctx, if (is_ordered_list != 0) c.MD_BLOCK_OL else c.MD_BLOCK_UL, 0, @intCast(uval(cont.ch)), MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
            },
            '>' => {
                if (cont.is_alert != 0)
                    ret = md_push_container_bytes(ctx, c.MD_BLOCK_ALERT, 0, cont.start, MD_BLOCK_CONTAINER_CLOSER)
                else
                    ret = md_push_container_bytes(ctx, c.MD_BLOCK_QUOTE, 0, 0, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
            },
            ':' => {
                ret = md_push_container_bytes(ctx, c.MD_BLOCK_COMPONENT, 0, cont.start, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
                ctx.block_component_nesting -= 1;
            },
            '#' => {
                ret = md_push_container_bytes(ctx, c.MD_BLOCK_TEMPLATE, 0, cont.start, MD_BLOCK_CONTAINER_CLOSER);
                if (ret < 0) return ret;
            },
            else => unreachable,
        }

        ctx.n_containers -= 1;
    }

    return ret;
}

fn md_is_container_mark(ctx: *MD_CTX, indent: c_uint, beg: OFF, p_end: *OFF, p_container: *MD_CONTAINER) c_int {
    var off: OFF = beg;

    if (off >= ctx.size or indent >= ctx.code_indent_offset)
        return FALSE;

    // Check for block quote mark.
    if (CH(ctx, off) == '>') {
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
    if (ISANYOF(ctx, off, "-+*") and (off + 1 >= ctx.size or ISBLANK(ctx, off + 1) or ISNEWLINE(ctx, off + 1))) {
        p_container.ch = CH(ctx, off);
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
    while (off < max_end and ISDIGIT(ctx, off)) {
        p_container.start = p_container.start * 10 + uval(CH(ctx, off)) - '0';
        off += 1;
    }
    if (off > beg and
        off < ctx.size and
        (CH(ctx, off) == '.' or CH(ctx, off) == ')') and
        (off + 1 >= ctx.size or ISBLANK(ctx, off + 1) or ISNEWLINE(ctx, off + 1)))
    {
        p_container.ch = CH(ctx, off);
        p_container.is_loose = FALSE;
        p_container.is_task = FALSE;
        p_container.mark_indent = indent;
        p_container.contents_indent = indent + off - beg + 1;
        p_end.* = off + 1;
        return TRUE;
    }

    return FALSE;
}

fn md_line_indentation(ctx: *MD_CTX, total_indent: c_uint, beg: OFF, p_end: *OFF) c_uint {
    var off: OFF = beg;
    var indent: c_uint = total_indent;

    while (off < ctx.size and ISBLANK(ctx, off)) {
        if (CH(ctx, off) == '\t')
            indent = (indent + 4) & ~@as(c_uint, 3)
        else
            indent += 1;
        off += 1;
    }

    p_end.* = off;
    return indent - total_indent;
}

const md_dummy_blank_line = MD_LINE_ANALYSIS{ .type = .MD_LINE_BLANK, .data = 0, .enforce_new_block = 0, .beg = 0, .end = 0, .indent = 0 };

// Analyze type of the line and find some of its properties. Main input for
// determining type and boundaries of a block (md4x.c ~7096).
fn md_analyze_line(ctx: *MD_CTX, beg: OFF, p_end: *OFF, pivot_line_in: *const MD_LINE_ANALYSIS, line: *MD_LINE_ANALYSIS) c_int {
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
    while (n_parents < ctx.n_containers) {
        const cont = &ctx.containers[@intCast(n_parents)];

        if (cont.ch == '>' and line.indent < ctx.code_indent_offset and
            off < ctx.size and CH(ctx, off) == '>')
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

    if (off >= ctx.size or ISNEWLINE(ctx, off)) {
        // Blank line does not need any real indentation to be nested inside a
        // list, block component, or template slot.
        if (n_brothers + n_children == 0) {
            while (n_parents < ctx.n_containers and ctx.containers[@intCast(n_parents)].ch != '>' and
                ctx.containers[@intCast(n_parents)].ch != ':' and
                ctx.containers[@intCast(n_parents)].ch != '#')
                n_parents += 1;
        }
    }

    classify: while (true) {
        // Check whether we are frontmatter continuation.
        if (pivot_line.type == .MD_LINE_FRONTMATTER) {
            line.beg = off;

            // Check for closing --- fence.
            if (line.indent < ctx.code_indent_offset and
                off < ctx.size and CH(ctx, off) == '-')
            {
                var tmp: OFF = off;
                while (tmp < ctx.size and CH(ctx, tmp) == '-')
                    tmp += 1;
                if (tmp - off >= 3) {
                    // Only spaces allowed after the dashes.
                    while (tmp < ctx.size and CH(ctx, tmp) == ' ')
                        tmp += 1;
                    if (tmp >= ctx.size or ISNEWLINE(ctx, tmp)) {
                        line.type = .MD_LINE_BLANK;
                        if (pivot_line.data == 2) {
                            // Component frontmatter: mark container as done.
                            var i: c_int = ctx.n_containers - 1;
                            while (i >= 0) : (i -= 1) {
                                if (ctx.containers[@intCast(i)].ch == ':') {
                                    ctx.containers[@intCast(i)].comp_fm_state = 2;
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

            line.type = .MD_LINE_FRONTMATTER;
            line.data = pivot_line.data;
            n_parents = ctx.n_containers;
            break :classify;
        }

        // Check whether we are fenced code continuation.
        if (pivot_line.type == .MD_LINE_FENCEDCODE) {
            line.beg = off;

            // Another MD_LINE_FENCEDCODE unless closing fence (→ MD_LINE_BLANK).
            if (line.indent < ctx.code_indent_offset) {
                if (md_is_closing_code_fence(ctx, CH(ctx, pivot_line.beg), off, &off) != 0) {
                    line.type = .MD_LINE_BLANK;
                    ctx.last_line_has_list_loosening_effect = FALSE;
                    break :classify;
                }
            }

            // Change indentation accordingly to the initial code fence.
            if (n_parents == ctx.n_containers) {
                if (line.indent > pivot_line.indent)
                    line.indent -= pivot_line.indent
                else
                    line.indent = 0;

                line.type = .MD_LINE_FENCEDCODE;
                break :classify;
            }
        }

        // Check whether we are HTML block continuation.
        if (pivot_line.type == .MD_LINE_HTML and ctx.html_block_type > 0) {
            if (n_parents < ctx.n_containers) {
                // HTML block ends implicitly when enclosing container ends.
                ctx.html_block_type = 0;
            } else {
                const html_block_type = md_is_html_block_end_condition(ctx, off, &off);
                if (html_block_type > 0) {
                    // MD_ASSERT(html_block_type == ctx->html_block_type);
                    ctx.html_block_type = 0;

                    // Some end conditions serve as blank lines.
                    if (html_block_type == 6 or html_block_type == 7) {
                        line.type = .MD_LINE_BLANK;
                        line.indent = 0;
                        break :classify;
                    }
                }

                line.type = .MD_LINE_HTML;
                n_parents = ctx.n_containers;
                break :classify;
            }
        }

        // Check for block component closer (::).
        if ((ctx.parser.flags & c.MD_FLAG_COMPONENTS != 0) and ctx.block_component_nesting > 0 and
            (line.indent < ctx.code_indent_offset or inside_component != 0) and off < ctx.size and CH(ctx, off) == ':')
        {
            var tmp: OFF = undefined;
            const closer_colons = md_is_block_component_closer(ctx, off, &tmp);
            if (closer_colons > 0) {
                // Find the innermost open block component with matching colon count.
                var i: c_int = ctx.n_containers - 1;
                var matched: c_int = 0;
                while (i >= 0) : (i -= 1) {
                    if (ctx.containers[@intCast(i)].ch == ':' and ctx.containers[@intCast(i)].colon_count <= closer_colons) {
                        // Close this component and everything inside it.
                        if (n_children == 0) {
                            ret = md_leave_child_containers(ctx, i);
                            if (ret < 0) return ret;
                        }

                        line.type = .MD_LINE_BLANK;
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
            pivot_line.type != .MD_LINE_TEXT and
            off < ctx.size and CH(ctx, off) == '#')
        {
            var name_beg: OFF = undefined;
            var name_end: OFF = undefined;
            var slot_end: OFF = undefined;
            if (md_is_slot_opener(ctx, off, &name_beg, &name_end, &slot_end) != 0) {
                const slot_idx = md_push_slot_info(ctx, name_beg, name_end);
                if (slot_idx < 0) {
                    ret = -1;
                    return ret;
                }

                // Close any existing template container within the component.
                {
                    var i: c_int = ctx.n_containers - 1;
                    while (i >= 0) : (i -= 1) {
                        if (ctx.containers[@intCast(i)].ch == '#') {
                            if (n_children == 0) {
                                ret = md_leave_child_containers(ctx, i);
                                if (ret < 0) return ret;
                            }
                            break;
                        }
                        // Stop at component boundary.
                        if (ctx.containers[@intCast(i)].ch == ':')
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
                ret = md_push_container(ctx, &container);
                if (ret < 0) return ret;

                off = slot_end;
                line.type = .MD_LINE_BLANK;
                break :classify;
            }
        }

        // Check for blank line.
        if (off >= ctx.size or ISNEWLINE(ctx, off)) {
            if (pivot_line.type == .MD_LINE_INDENTEDCODE and n_parents == ctx.n_containers) {
                line.type = .MD_LINE_INDENTEDCODE;
                if (line.indent > ctx.code_indent_offset)
                    line.indent -= ctx.code_indent_offset
                else
                    line.indent = 0;
                ctx.last_line_has_list_loosening_effect = FALSE;
            } else {
                line.type = .MD_LINE_BLANK;
                ctx.last_line_has_list_loosening_effect = @intFromBool(n_parents > 0 and
                    n_brothers + n_children == 0 and
                    ctx.containers[@intCast(n_parents - 1)].ch != '>');

                // See https://github.com/mity/md4c/issues/6 — empty list item
                // not on its first line forces list end on next non-blank line.
                if (n_parents > 0 and ctx.containers[@intCast(n_parents - 1)].ch != '>' and
                    n_brothers + n_children == 0 and ctx.current_block == null and
                    ctx.n_block_bytes > @as(c_int, @sizeOf(MD_BLOCK)))
                {
                    const top_block: *MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + @as(usize, @intCast(ctx.n_block_bytes - @sizeOf(MD_BLOCK)))));
                    if (top_block.getType() == c.MD_BLOCK_LI)
                        ctx.last_list_item_starts_with_two_blank_lines = TRUE;
                }
            }
            break :classify;
        } else {
            // 2nd half of the hack: 2nd blank line at list item start forces end.
            if (ctx.last_list_item_starts_with_two_blank_lines != 0) {
                if (n_parents > 0 and n_parents == ctx.n_containers and
                    ctx.containers[@intCast(n_parents - 1)].ch != '>' and
                    n_brothers + n_children == 0 and ctx.current_block == null and
                    ctx.n_block_bytes > @as(c_int, @sizeOf(MD_BLOCK)))
                {
                    const top_block: *MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + @as(usize, @intCast(ctx.n_block_bytes - @sizeOf(MD_BLOCK)))));
                    if (top_block.getType() == c.MD_BLOCK_LI) {
                        n_parents -= 1;

                        line.indent = total_indent;
                        if (n_parents > 0)
                            line.indent -= MIN_u(line.indent, ctx.containers[@intCast(n_parents - 1)].contents_indent);
                    }
                }

                ctx.last_list_item_starts_with_two_blank_lines = FALSE;
            }
            ctx.last_line_has_list_loosening_effect = FALSE;
        }

        // Check for alert syntax > [!TYPE] inside a newly opened blockquote.
        if ((ctx.parser.flags & c.MD_FLAG_ALERTS != 0) and n_children > 0 and
            line.indent < ctx.code_indent_offset and
            off < ctx.size and CH(ctx, off) == '[')
        {
            const last_cont: c_int = ctx.n_containers - 1;
            if (last_cont >= 0 and ctx.containers[@intCast(last_cont)].ch == '>' and
                ctx.containers[@intCast(last_cont)].is_alert == 0)
            {
                var tmp: OFF = off + 1;
                if (tmp < ctx.size and CH(ctx, tmp) == '!') {
                    tmp += 1;
                    const type_beg: OFF = tmp;
                    while (tmp < ctx.size and (ISALPHA(ctx, tmp) or ISDIGIT(ctx, tmp) or CH(ctx, tmp) == '-' or CH(ctx, tmp) == '_'))
                        tmp += 1;
                    const type_end: OFF = tmp;
                    if (type_end > type_beg and tmp < ctx.size and CH(ctx, tmp) == ']') {
                        tmp += 1;
                        while (tmp < ctx.size and ISBLANK(ctx, tmp))
                            tmp += 1;
                        if (tmp >= ctx.size or ISNEWLINE(ctx, tmp)) {
                            const alert_idx = md_push_block_alert_info(ctx, type_beg, type_end);
                            if (alert_idx < 0) {
                                ret = -1;
                                return ret;
                            }
                            ctx.containers[@intCast(last_cont)].is_alert = TRUE;
                            ctx.containers[@intCast(last_cont)].start = @intCast(alert_idx);
                            line.type = .MD_LINE_BLANK;
                            break :classify;
                        }
                    }
                }
            }
        }

        // Check whether we are Setext underline.
        if (line.indent < ctx.code_indent_offset and pivot_line.type == .MD_LINE_TEXT and
            off < ctx.size and ISANYOF2(ctx, off, '=', '-') and
            (n_parents == ctx.n_containers))
        {
            var level: c_uint = undefined;

            if (md_is_setext_underline(ctx, off, &off, &level) != 0) {
                line.type = .MD_LINE_SETEXTUNDERLINE;
                line.data = level;
                break :classify;
            }
        }

        // Check for frontmatter opening at the very start of the document.
        if ((ctx.parser.flags & c.MD_FLAG_FRONTMATTER != 0) and
            ctx.frontmatter_state == 0 and
            line.indent < ctx.code_indent_offset and n_parents == 0 and
            off < ctx.size and CH(ctx, off) == '-')
        {
            var tmp: OFF = off;
            while (tmp < ctx.size and CH(ctx, tmp) == '-')
                tmp += 1;
            if (tmp - off >= 3) {
                while (tmp < ctx.size and CH(ctx, tmp) == ' ')
                    tmp += 1;
                if (tmp >= ctx.size or ISNEWLINE(ctx, tmp)) {
                    if (beg == 0) {
                        line.type = .MD_LINE_FRONTMATTER;
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
            var comp_i: c_int = ctx.n_containers - 1;
            while (comp_i >= 0) : (comp_i -= 1) {
                if (ctx.containers[@intCast(comp_i)].ch == ':')
                    break;
            }
            if (comp_i >= 0 and ctx.containers[@intCast(comp_i)].comp_fm_state == 0) {
                var found_opener: c_int = FALSE;
                if (line.indent < ctx.code_indent_offset and
                    off < ctx.size and CH(ctx, off) == '-')
                {
                    var tmp: OFF = off;
                    while (tmp < ctx.size and CH(ctx, tmp) == '-')
                        tmp += 1;
                    if (tmp - off >= 3) {
                        while (tmp < ctx.size and CH(ctx, tmp) == ' ')
                            tmp += 1;
                        if (tmp >= ctx.size or ISNEWLINE(ctx, tmp)) {
                            ctx.containers[@intCast(comp_i)].comp_fm_state = 1;
                            line.type = .MD_LINE_FRONTMATTER;
                            line.data = 2; // 2 = component frontmatter
                            line.enforce_new_block = TRUE;
                            found_opener = TRUE;
                        }
                    }
                }
                if (found_opener != 0)
                    break :classify;
                // First non-blank line is not ---; disable component frontmatter.
                ctx.containers[@intCast(comp_i)].comp_fm_state = 2;
            }
        }

        // Check for thematic break line.
        if (line.indent < ctx.code_indent_offset and
            off < ctx.size and off >= hr_killer and
            ISANYOF(ctx, off, "-_*"))
        {
            if (md_is_hr_line(ctx, off, &off, &hr_killer) != 0) {
                line.type = .MD_LINE_HR;
                break :classify;
            }
        }

        // Check for "brother" container (another list item in started list).
        if (n_parents < ctx.n_containers and n_brothers + n_children == 0) {
            var tmp: OFF = undefined;

            if (md_is_container_mark(ctx, line.indent, off, &tmp, &container) != 0 and
                md_is_container_compatible(&ctx.containers[@intCast(n_parents)], &container) != 0)
            {
                pivot_line = &md_dummy_blank_line;

                off = tmp;

                total_indent += container.contents_indent - container.mark_indent;
                line.indent = md_line_indentation(ctx, total_indent, off, &off);
                total_indent += line.indent;
                line.beg = off;

                // Some of the following whitespace still belongs to the mark.
                if (off >= ctx.size or ISNEWLINE(ctx, off)) {
                    container.contents_indent += 1;
                } else if (line.indent <= ctx.code_indent_offset) {
                    container.contents_indent += line.indent;
                    line.indent = 0;
                } else {
                    container.contents_indent += 1;
                    line.indent -= 1;
                }

                ctx.containers[@intCast(n_parents)].mark_indent = container.mark_indent;
                ctx.containers[@intCast(n_parents)].contents_indent = container.contents_indent;

                n_brothers += 1;
                continue :classify;
            }
        }

        // Check for indented code (cannot interrupt a paragraph; disabled
        // inside block components).
        if (line.indent >= ctx.code_indent_offset and inside_component == 0 and (pivot_line.type != .MD_LINE_TEXT)) {
            line.type = .MD_LINE_INDENTEDCODE;
            line.indent -= ctx.code_indent_offset;
            line.data = 0;
            break :classify;
        }

        // Check for block component opener (::name or ::name{props}).
        if ((ctx.parser.flags & c.MD_FLAG_COMPONENTS != 0) and
            (line.indent < ctx.code_indent_offset or inside_component != 0) and
            pivot_line.type != .MD_LINE_TEXT and
            off < ctx.size and CH(ctx, off) == ':')
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
                const comp_idx = md_push_block_component_info(ctx, colon_count, name_beg, name_end, props_beg, props_end, title_beg, title_end);
                if (comp_idx < 0) {
                    ret = -1;
                    return ret;
                }

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
                ret = md_push_container(ctx, &container);
                if (ret < 0) return ret;
                ctx.block_component_nesting += 1;

                off = comp_end;
                line.type = .MD_LINE_BLANK;
                break :classify;
            }
        }

        // Check for start of a new container block.
        if (line.indent < ctx.code_indent_offset and
            md_is_container_mark(ctx, line.indent, off, &off, &container) != 0)
        {
            if (pivot_line.type == .MD_LINE_TEXT and n_parents == ctx.n_containers and
                (off >= ctx.size or ISNEWLINE(ctx, off)) and container.ch != '>')
            {
                // Noop. List mark + blank line cannot interrupt a paragraph.
            } else if (pivot_line.type == .MD_LINE_TEXT and n_parents == ctx.n_containers and
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
                if (off >= ctx.size or ISNEWLINE(ctx, off)) {
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
                ret = md_push_container(ctx, &container);
                if (ret < 0) return ret;
                continue :classify;
            }
        }

        // Check whether we are table continuation.
        if (pivot_line.type == .MD_LINE_TABLE and n_parents == ctx.n_containers) {
            line.type = .MD_LINE_TABLE;
            break :classify;
        }

        // Check for ATX header.
        if (line.indent < ctx.code_indent_offset and
            off < ctx.size and CH(ctx, off) == '#')
        {
            var level: c_uint = undefined;

            if (md_is_atxheader_line(ctx, off, &line.beg, &off, &level) != 0) {
                line.type = .MD_LINE_ATXHEADER;
                line.data = level;
                break :classify;
            }
        }

        // Check whether we are starting code fence.
        if (line.indent < ctx.code_indent_offset and
            off < ctx.size and ISANYOF2(ctx, off, '`', '~'))
        {
            if (md_is_opening_code_fence(ctx, off, &off) != 0) {
                line.type = .MD_LINE_FENCEDCODE;
                line.data = 1;
                line.enforce_new_block = TRUE;
                break :classify;
            }
        }

        // Check for start of raw HTML block.
        if (off < ctx.size and CH(ctx, off) == '<' and
            (ctx.parser.flags & c.MD_FLAG_NOHTMLBLOCKS == 0))
        {
            ctx.html_block_type = md_is_html_block_start_condition(ctx, off);

            // HTML block type 7 cannot interrupt paragraph.
            if (ctx.html_block_type == 7 and pivot_line.type == .MD_LINE_TEXT)
                ctx.html_block_type = 0;

            if (ctx.html_block_type > 0) {
                // The line itself also may immediately close the block.
                if (md_is_html_block_end_condition(ctx, off, &off) == ctx.html_block_type) {
                    ctx.html_block_type = 0;
                }

                line.enforce_new_block = TRUE;
                line.type = .MD_LINE_HTML;
                break :classify;
            }
        }

        // Check for table underline.
        if ((ctx.parser.flags & c.MD_FLAG_TABLES != 0) and pivot_line.type == .MD_LINE_TEXT and
            off < ctx.size and ISANYOF3(ctx, off, '|', '-', ':') and
            n_parents == ctx.n_containers)
        {
            var col_count: c_uint = undefined;

            if (ctx.current_block != null and ctx.current_block.*.n_lines == 1 and
                md_is_table_underline(ctx, off, &off, &col_count) != 0)
            {
                line.data = col_count;
                line.type = .MD_LINE_TABLEUNDERLINE;
                break :classify;
            }
        }

        // By default, we are normal text line.
        line.type = .MD_LINE_TEXT;
        if (pivot_line.type == .MD_LINE_TEXT and n_brothers + n_children == 0) {
            // Lazy continuation.
            n_parents = ctx.n_containers;
        }

        // Check for task mark.
        if ((ctx.parser.flags & c.MD_FLAG_TASKLISTS != 0) and n_brothers + n_children > 0 and
            ISANYOF_(ctx.containers[@intCast(ctx.n_containers - 1)].ch, "-+*.)"))
        {
            var tmp: OFF = off;

            while (tmp < ctx.size and tmp < off + 3 and ISBLANK(ctx, tmp))
                tmp += 1;
            if (tmp + 2 < ctx.size and CH(ctx, tmp) == '[' and
                ISANYOF(ctx, tmp + 1, "xX ") and CH(ctx, tmp + 2) == ']' and
                (tmp + 3 == ctx.size or ISBLANK(ctx, tmp + 3) or ISNEWLINE(ctx, tmp + 3)))
            {
                const task_container = if (n_children > 0) &ctx.containers[@intCast(ctx.n_containers - 1)] else &container;
                task_container.is_task = TRUE;
                task_container.task_mark_off = tmp + 1;
                off = tmp + 3;
                while (off < ctx.size and ISWHITESPACE(ctx, off))
                    off += 1;
                line.beg = off;
            }
        }

        break :classify;
    }

    // Scan for end of the line.
    if (ctx.doc_ends_with_newline != 0 and off < ctx.size) {
        while (true) {
            off += @intCast(strcspn(STR(ctx, off), "\r\n"));

            // strcspn() can stop on zero terminator; it can appear anywhere.
            if (CH(ctx, off) == 0)
                off += 1
            else
                break;
        }
    } else {
        // Optimization: Use some loop unrolling.
        while (off + 3 < ctx.size and !ISNEWLINE(ctx, off + 0) and !ISNEWLINE(ctx, off + 1) and
            !ISNEWLINE(ctx, off + 2) and !ISNEWLINE(ctx, off + 3))
            off += 4;
        while (off < ctx.size and !ISNEWLINE(ctx, off))
            off += 1;
    }

    // Set end of the line.
    line.end = off;

    // But for ATX header, exclude the optional trailing mark.
    if (line.type == .MD_LINE_ATXHEADER) {
        var tmp: OFF = line.end;
        while (tmp > line.beg and ISBLANK(ctx, tmp - 1))
            tmp -= 1;
        while (tmp > line.beg and CH(ctx, tmp - 1) == '#')
            tmp -= 1;
        if (tmp == line.beg or ISBLANK(ctx, tmp - 1) or (ctx.parser.flags & c.MD_FLAG_PERMISSIVEATXHEADERS != 0))
            line.end = tmp;
    }

    // Trim trailing spaces.
    if (line.type != .MD_LINE_INDENTEDCODE and line.type != .MD_LINE_FENCEDCODE and line.type != .MD_LINE_HTML) {
        while (line.end > line.beg and ISBLANK(ctx, line.end - 1))
            line.end -= 1;
    }

    // Eat also the new line.
    if (off < ctx.size and CH(ctx, off) == '\r')
        off += 1;
    if (off < ctx.size and CH(ctx, off) == '\n')
        off += 1;

    p_end.* = off;

    // If we belong to a list after seeing a blank line, the list is loose.
    if (prev_line_has_list_loosening_effect != 0 and line.type != .MD_LINE_BLANK and n_parents + n_brothers > 0) {
        const cont = &ctx.containers[@intCast(n_parents + n_brothers - 1)];
        if (cont.ch != '>') {
            const block: *MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + cont.block_byte_off));
            block.bits.flags |= @as(u8, @truncate(MD_BLOCK_LOOSE_LIST));
        }
    }

    // Leave any containers we are not part of anymore.
    if (n_children == 0 and n_parents + n_brothers < ctx.n_containers) {
        ret = md_leave_child_containers(ctx, n_parents + n_brothers);
        if (ret < 0) return ret;
    }

    // Enter any container we found a mark for.
    if (n_brothers > 0) {
        // MD_ASSERT(n_brothers == 1);
        ret = md_push_container_bytes(ctx, c.MD_BLOCK_LI, ctx.containers[@intCast(n_parents)].task_mark_off, if (ctx.containers[@intCast(n_parents)].is_task != 0) @intCast(uval(CH(ctx, ctx.containers[@intCast(n_parents)].task_mark_off))) else 0, MD_BLOCK_CONTAINER_CLOSER);
        if (ret < 0) return ret;
        ret = md_push_container_bytes(ctx, c.MD_BLOCK_LI, container.task_mark_off, if (container.is_task != 0) @intCast(uval(CH(ctx, container.task_mark_off))) else 0, MD_BLOCK_CONTAINER_OPENER);
        if (ret < 0) return ret;
        ctx.containers[@intCast(n_parents)].is_task = container.is_task;
        ctx.containers[@intCast(n_parents)].task_mark_off = container.task_mark_off;
    }

    if (n_children > 0) {
        ret = md_enter_child_containers(ctx, n_children);
        if (ret < 0) return ret;
    }

    return ret;
}

// ----------------------------------------------------------------------------
// libc malloc/realloc wrappers used where md4c relies on realloc(NULL,…) and
// freeing pointers across allocations whose previous size is not tracked in a
// Zig slice. These mirror the C runtime exactly (the C parser uses raw
// malloc/realloc/free for these attribute build buffers).
// ----------------------------------------------------------------------------
// NOTE: these return a plain `[*c]T`, which is itself nullable — callers check
// `== null` (mirroring C's `malloc`/`realloc` returning a possibly-NULL pointer).
// Do NOT wrap in `?[*c]T`: an optional C-pointer is a malformed type in Zig and
// produces garbage payloads (observed via valgrind as uninitialised reads).
fn c_malloc_array(comptime T: type, count: usize) [*c]T {
    if (count == 0) {
        // C: malloc(0) is impl-defined; md4c only mallocs raw_size>0 here.
        return @ptrCast(@alignCast(std.c.malloc(0)));
    }
    return @ptrCast(@alignCast(std.c.malloc(count * @sizeOf(T))));
}

fn c_realloc_array(comptime T: type, old: [*c]T, count: usize) [*c]T {
    return @ptrCast(@alignCast(std.c.realloc(old, count * @sizeOf(T))));
}

// ============================================================================
//  Subsystem E — block processing + md_process_line/doc + md_parse glue.
// ============================================================================

// Block-level enter/leave helpers mirroring MD_ENTER_BLOCK / MD_LEAVE_BLOCK.
inline fn mdEnterBlock(ctx: *MD_CTX, ty: c.MD_BLOCKTYPE, detail: ?*anyopaque) c_int {
    const ret = ctx.parser.enter_block.?(ty, detail, ctx.userdata);
    if (ret != 0) md_log(ctx, "Aborted from enter_block() callback.");
    return ret;
}

inline fn mdLeaveBlock(ctx: *MD_CTX, ty: c.MD_BLOCKTYPE, detail: ?*anyopaque) c_int {
    const ret = ctx.parser.leave_block.?(ty, detail, ctx.userdata);
    if (ret != 0) md_log(ctx, "Aborted from leave_block() callback.");
    return ret;
}

// MD_TEXT_INSECURE — NUL-replacement text emission (md4x.c ~543).
inline fn mdTextInsecure(ctx: *MD_CTX, ty: c.MD_TEXTTYPE, str: [*c]const CHAR, size: SZ) c_int {
    if (size > 0) {
        const ret = md_text_with_null_replacement(ctx, ty, str, size);
        if (ret != 0) {
            md_log(ctx, "Aborted from text() callback.");
            return ret;
        }
    }
    return 0;
}

// md4x.c ~5205.
fn md_analyze_table_alignment(ctx: *MD_CTX, beg: OFF, end: OFF, align_arr: [*c]c.MD_ALIGN, n_align_in: c_int) void {
    const align_map = [_]c.MD_ALIGN{ c.MD_ALIGN_DEFAULT, c.MD_ALIGN_LEFT, c.MD_ALIGN_RIGHT, c.MD_ALIGN_CENTER };
    var off: OFF = beg;
    var n_align = n_align_in;
    var ai: usize = 0;

    while (n_align > 0) {
        var index: usize = 0; // index into align_map[]

        while (CH(ctx, off) != '-') off += 1;
        if (off > beg and CH(ctx, off - 1) == ':') index |= 1;
        while (off < end and CH(ctx, off) == '-') off += 1;
        if (off < end and CH(ctx, off) == ':') index |= 2;

        align_arr[ai] = align_map[index];
        ai += 1;
        n_align -= 1;
    }
}

// md4x.c ~5232.
fn md_process_table_cell(ctx: *MD_CTX, cell_type: c.MD_BLOCKTYPE, align_val: c.MD_ALIGN, beg_in: OFF, end_in: OFF) c_int {
    var line: MD_LINE = undefined;
    var det: c.MD_BLOCK_TD_DETAIL = undefined;
    var ret: c_int = 0;
    var beg = beg_in;
    var end = end_in;

    while (beg < end and ISWHITESPACE(ctx, beg)) beg += 1;
    while (end > beg and ISWHITESPACE(ctx, end - 1)) end -= 1;

    det.@"align" = align_val;
    line.beg = beg;
    line.end = end;

    ret = mdEnterBlock(ctx, cell_type, &det);
    if (ret < 0) return ret;
    ret = md_process_normal_block_contents(ctx, @ptrCast(&line), 1);
    if (ret < 0) return ret;
    ret = mdLeaveBlock(ctx, cell_type, &det);
    if (ret < 0) return ret;
    return ret;
}

// md4x.c ~5256.
fn md_process_table_row(ctx: *MD_CTX, cell_type: c.MD_BLOCKTYPE, beg: OFF, end: OFF, align_arr: [*c]const c.MD_ALIGN, col_count: c_int) c_int {
    var line: MD_LINE = undefined;
    var pipe_offs: [*c]OFF = null;
    var ret: c_int = 0;

    line.beg = beg;
    line.end = end;

    // Break the line into table cells by identifying pipe characters.
    ret = md_analyze_inlines(ctx, @ptrCast(&line), 1, TRUE);
    if (ret < 0) {
        ctx.table_cell_boundaries_head = -1;
        ctx.table_cell_boundaries_tail = -1;
        return ret;
    }

    const n: c_int = ctx.n_table_cell_boundaries + 2;
    pipe_offs = @ptrCast(@alignCast(std.c.malloc(@as(usize, @intCast(n)) * @sizeOf(OFF))));
    if (pipe_offs == null) {
        md_log(ctx, "malloc() failed.");
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
    if (ret < 0) {
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
fn md_process_table_block_contents(ctx: *MD_CTX, col_count: c_int, lines: [*c]const MD_LINE, n_lines: MD_SIZE) c_int {
    var align_arr: [*c]c.MD_ALIGN = null;
    var ret: c_int = 0;

    align_arr = @ptrCast(@alignCast(std.c.malloc(@as(usize, @intCast(col_count)) * @sizeOf(c.MD_ALIGN))));
    if (align_arr == null) {
        md_log(ctx, "malloc() failed.");
        return -1;
    }

    md_analyze_table_alignment(ctx, lines[1].beg, lines[1].end, align_arr, col_count);

    ret = mdEnterBlock(ctx, c.MD_BLOCK_THEAD, null);
    if (ret < 0) {
        std.c.free(align_arr);
        return ret;
    }
    ret = md_process_table_row(ctx, c.MD_BLOCK_TH, lines[0].beg, lines[0].end, align_arr, col_count);
    if (ret < 0) {
        std.c.free(align_arr);
        return ret;
    }
    ret = mdLeaveBlock(ctx, c.MD_BLOCK_THEAD, null);
    if (ret < 0) {
        std.c.free(align_arr);
        return ret;
    }

    if (n_lines > 2) {
        ret = mdEnterBlock(ctx, c.MD_BLOCK_TBODY, null);
        if (ret < 0) {
            std.c.free(align_arr);
            return ret;
        }
        var line_index: MD_SIZE = 2;
        while (line_index < n_lines) : (line_index += 1) {
            ret = md_process_table_row(ctx, c.MD_BLOCK_TD, lines[line_index].beg, lines[line_index].end, align_arr, col_count);
            if (ret < 0) {
                std.c.free(align_arr);
                return ret;
            }
        }
        ret = mdLeaveBlock(ctx, c.MD_BLOCK_TBODY, null);
        if (ret < 0) {
            std.c.free(align_arr);
            return ret;
        }
    }

    std.c.free(align_arr);
    return ret;
}

// md4x.c ~5394.
fn md_process_normal_block_contents(ctx: *MD_CTX, lines: [*c]const MD_LINE, n_lines: MD_SIZE) c_int {
    var ret: c_int = md_analyze_inlines(ctx, lines, n_lines, FALSE);
    if (ret >= 0) ret = md_process_inlines(ctx, lines, n_lines);

    // Free any temporary memory blocks stored within some dummy marks.
    var i: c_int = ctx.ptr_stack.top;
    while (i >= 0) : (i = ctx.marks[@intCast(i)].next) {
        std.c.free(md_mark_get_ptr(ctx, i));
    }
    ctx.ptr_stack.top = -1;

    return ret;
}

// md4x.c ~5412.
fn md_process_verbatim_block_contents(ctx: *MD_CTX, text_type: c.MD_TEXTTYPE, lines: [*c]const MD_VERBATIMLINE, n_lines: MD_SIZE) c_int {
    const indent_chunk_str: [*:0]const CHAR = "                ";
    const indent_chunk_size: SZ = 16;
    var ret: c_int = 0;

    var line_index: MD_SIZE = 0;
    while (line_index < n_lines) : (line_index += 1) {
        const line = &lines[line_index];
        var indent: c_int = @intCast(line.indent);

        // Output code indentation.
        while (indent > @as(c_int, @intCast(indent_chunk_size))) {
            ret = mdText(ctx, text_type, indent_chunk_str, indent_chunk_size);
            if (ret < 0) return ret;
            indent -= @intCast(indent_chunk_size);
        }
        if (indent > 0) {
            ret = mdText(ctx, text_type, indent_chunk_str, @intCast(indent));
            if (ret < 0) return ret;
        }

        // Output the code line itself.
        ret = mdTextInsecure(ctx, text_type, STR(ctx, line.beg), line.end - line.beg);
        if (ret < 0) return ret;

        // Enforce end-of-line.
        ret = mdText(ctx, text_type, "\n", 1);
        if (ret < 0) return ret;
    }

    return ret;
}

// md4x.c ~5446.
fn md_process_code_block_contents(ctx: *MD_CTX, is_fenced: c_int, lines_in: [*c]const MD_VERBATIMLINE, n_lines_in: MD_SIZE) c_int {
    var lines = lines_in;
    var n_lines = n_lines_in;

    if (is_fenced != 0) {
        // Skip the first line in case of fenced code: It is the fence.
        lines += 1;
        n_lines -= 1;
    } else {
        // Ignore blank lines at start/end of indented code block.
        while (n_lines > 0 and lines[0].beg == lines[0].end) {
            lines += 1;
            n_lines -= 1;
        }
        while (n_lines > 0 and lines[n_lines - 1].beg == lines[n_lines - 1].end) {
            n_lines -= 1;
        }
    }

    if (n_lines == 0) return 0;

    return md_process_verbatim_block_contents(ctx, c.MD_TEXT_CODE, lines, n_lines);
}

// md4x.c ~5473. Parse highlight ranges string (e.g. "1-3,5,7") into expanded
// array. Returns heap-allocated array (null on empty/error) and sets out_count.
fn md_parse_highlights(str: [*c]const CHAR, size: SZ, out_count: *c_uint) [*c]c_uint {
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
fn md_setup_fenced_code_detail(ctx: *MD_CTX, block: *const MD_BLOCK, det: *c.MD_BLOCK_CODE_DETAIL, info_build: *MD_ATTRIBUTE_BUILD, lang_build: *MD_ATTRIBUTE_BUILD, filename_build: *MD_ATTRIBUTE_BUILD) c_int {
    const fence_line: *const MD_VERBATIMLINE = @ptrCast(@alignCast(@as([*]const MD_BLOCK, @ptrCast(block)) + 1));
    var beg: OFF = fence_line.beg;
    var end: OFF = fence_line.end;
    const fence_ch: CHAR = CH(ctx, fence_line.beg);
    var ret: c_int = 0;

    // Skip the fence itself.
    while (beg < ctx.size and CH(ctx, beg) == fence_ch) beg += 1;
    // Trim initial spaces.
    while (beg < ctx.size and CH(ctx, beg) == ' ') beg += 1;
    // Trim trailing spaces.
    while (end > beg and CH(ctx, end - 1) == ' ') end -= 1;

    // Build info string attribute (full info string).
    ret = md_build_attribute(ctx, STR(ctx, beg), end - beg, 0, &det.info, info_build);
    if (ret < 0) return ret;

    // Build lang attribute (first word of info string).
    var lang_end: OFF = beg;
    while (lang_end < end and !ISWHITESPACE(ctx, lang_end)) lang_end += 1;
    ret = md_build_attribute(ctx, STR(ctx, beg), lang_end - beg, 0, &det.lang, lang_build);
    if (ret < 0) return ret;

    det.fence_char = fence_ch;

    // Parse extended metadata from the rest of the info string (after lang).
    var rest_beg: OFF = lang_end;
    while (rest_beg < end and ISWHITESPACE(ctx, rest_beg)) rest_beg += 1;

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
                if (CH(ctx, i) == '[') {
                    fn_open = i;
                    var jj: OFF = i + 1;
                    while (jj < end) : (jj += 1) {
                        if (CH(ctx, jj) == '\\' and jj + 1 < end) {
                            jj += 1; // skip escaped char
                        } else if (CH(ctx, jj) == ']') {
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
                if (CH(ctx, i) == '{') {
                    hl_open = i;
                    var jj: OFF = i + 1;
                    while (jj < end) : (jj += 1) {
                        if (CH(ctx, jj) == '}') {
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
            ret = md_build_attribute(ctx, STR(ctx, fn_beg), fn_end - fn_beg, 0, &det.filename, filename_build);
            if (ret < 0) return ret;
        }

        // Parse highlights into expanded integer array.
        if (has_highlights != 0 and hl_end > hl_beg) {
            det.highlights = md_parse_highlights(STR(ctx, hl_beg), hl_end - hl_beg, &det.highlight_count);
        }

        // Build meta from remaining text (exclude [..] and {..} regions).
        {
            var meta_len: SZ = 0;
            const meta_buf: [*c]CHAR = @ptrCast(@alignCast(std.c.malloc(@as(usize, end - rest_beg + 1) * @sizeOf(CHAR))));
            if (meta_buf == null) {
                md_log(ctx, "malloc() failed.");
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
                meta_buf[meta_len] = CH(ctx, pos);
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
                    md_log(ctx, "malloc() failed.");
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

    return ret;
}

// md4x.c ~5714.
fn md_process_leaf_block(ctx: *MD_CTX, block: *const MD_BLOCK) c_int {
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

    if (ctx.n_containers == 0)
        is_in_tight_list = false
    else
        is_in_tight_list = (ctx.containers[@intCast(ctx.n_containers - 1)].is_loose == 0);

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
    }

    // Process the block contents according to its type.
    switch (btype) {
        c.MD_BLOCK_HR => {},
        c.MD_BLOCK_CODE => ret = md_process_code_block_contents(ctx, @intFromBool(block.bits.data != 0), @ptrCast(@alignCast(block_lines + 1)), block.n_lines),
        c.MD_BLOCK_HTML => ret = md_process_verbatim_block_contents(ctx, c.MD_TEXT_HTML, @ptrCast(@alignCast(block_lines + 1)), block.n_lines),
        c.MD_BLOCK_FRONTMATTER => {
            // Skip the opening fence line (first line is the --- opener).
            const vlines: [*c]const MD_VERBATIMLINE = @ptrCast(@alignCast(block_lines + 1));
            ret = md_process_verbatim_block_contents(ctx, c.MD_TEXT_NORMAL, vlines + 1, block.n_lines - 1);
        },
        c.MD_BLOCK_TABLE => ret = md_process_table_block_contents(ctx, @intCast(block.bits.data), @ptrCast(@alignCast(block_lines + 1)), block.n_lines),
        else => ret = md_process_normal_block_contents(ctx, @ptrCast(@alignCast(block_lines + 1)), block.n_lines),
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
fn md_process_all_blocks(ctx: *MD_CTX) c_int {
    var byte_off: c_int = 0;
    var ret: c_int = 0;
    var comp_name_build: MD_ATTRIBUTE_BUILD = .{};
    var clean_component_detail: bool = false;

    // ctx.containers now is reused for tracking loose/tight lists.
    ctx.n_containers = 0;

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
                if (comp_idx >= 0 and comp_idx < ctx.n_block_components) {
                    const info = &ctx.block_component_info[@intCast(comp_idx)];
                    const name_beg = info.name_beg;
                    const name_end = info.name_end;
                    const props_beg = info.props_beg;
                    const props_end = info.props_end;
                    const t_beg = info.title_beg;
                    const t_end = info.title_end;

                    comp_name_build = .{};
                    ret = md_build_attribute(ctx, STR(ctx, name_beg), name_end - name_beg, 0, &det.component.tag_name, &comp_name_build);
                    if (ret < 0) {
                        md_free_attribute(ctx, &comp_name_build);
                        return ret;
                    }
                    clean_component_detail = true;

                    if (props_beg > 0 and props_end > props_beg) {
                        det.component.raw_props = STR(ctx, props_beg);
                        det.component.raw_props_size = props_end - props_beg;
                    }
                    if (t_beg > 0 and t_end > t_beg) {
                        det.component.title = STR(ctx, t_beg);
                        det.component.title_size = t_end - t_beg;
                    }
                }
            },
            c.MD_BLOCK_TEMPLATE => {
                const slot_idx: c_int = @intCast(block.bits.data);
                if (slot_idx >= 0 and slot_idx < ctx.n_slots) {
                    const info = &ctx.slot_info[@intCast(slot_idx)];
                    const name_beg = info.name_beg;
                    const name_end = info.name_end;

                    comp_name_build = .{};
                    ret = md_build_attribute(ctx, STR(ctx, name_beg), name_end - name_beg, 0, &det.tmpl.name, &comp_name_build);
                    if (ret < 0) {
                        md_free_attribute(ctx, &comp_name_build);
                        return ret;
                    }
                    clean_component_detail = true;
                }
            },
            c.MD_BLOCK_ALERT => {
                const alert_idx: c_int = @intCast(block.bits.data);
                if (alert_idx >= 0 and alert_idx < ctx.n_block_alerts) {
                    const info = &ctx.block_alert_info[@intCast(alert_idx)];
                    const type_beg = info.type_beg;
                    const type_end = info.type_end;

                    comp_name_build = .{};
                    ret = md_build_attribute(ctx, STR(ctx, type_beg), type_end - type_beg, 0, &det.alert.type_name, &comp_name_build);
                    if (ret < 0) {
                        md_free_attribute(ctx, &comp_name_build);
                        return ret;
                    }
                    clean_component_detail = true;
                }
            },
            else => {},
        }

        if ((block.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER))) != 0) {
            if ((block.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER_CLOSER))) != 0) {
                ret = mdLeaveBlock(ctx, btype, &det);
                if (ret < 0) {
                    if (clean_component_detail) md_free_attribute(ctx, &comp_name_build);
                    return ret;
                }

                if (btype == c.MD_BLOCK_UL or btype == c.MD_BLOCK_OL or btype == c.MD_BLOCK_QUOTE or btype == c.MD_BLOCK_COMPONENT or btype == c.MD_BLOCK_TEMPLATE or btype == c.MD_BLOCK_ALERT)
                    ctx.n_containers -= 1;
            }

            if ((block.bits.flags & @as(u8, @truncate(MD_BLOCK_CONTAINER_OPENER))) != 0) {
                ret = mdEnterBlock(ctx, btype, &det);
                if (ret < 0) {
                    if (clean_component_detail) md_free_attribute(ctx, &comp_name_build);
                    return ret;
                }

                if (btype == c.MD_BLOCK_UL or btype == c.MD_BLOCK_OL) {
                    ctx.containers[@intCast(ctx.n_containers)].is_loose = @intCast(block.bits.flags & @as(u8, @truncate(MD_BLOCK_LOOSE_LIST)));
                    ctx.n_containers += 1;
                } else if (btype == c.MD_BLOCK_QUOTE or btype == c.MD_BLOCK_ALERT) {
                    ctx.containers[@intCast(ctx.n_containers)].is_loose = @intFromBool(TRUE != 0);
                    ctx.n_containers += 1;
                } else if (btype == c.MD_BLOCK_COMPONENT) {
                    ctx.containers[@intCast(ctx.n_containers)].is_loose = @intFromBool(TRUE != 0);
                    ctx.n_containers += 1;
                } else if (btype == c.MD_BLOCK_TEMPLATE) {
                    ctx.containers[@intCast(ctx.n_containers)].is_loose = @intFromBool(TRUE != 0);
                    ctx.n_containers += 1;
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
fn md_process_line(ctx: *MD_CTX, p_pivot_line: *[*c]const MD_LINE_ANALYSIS, line: *MD_LINE_ANALYSIS) c_int {
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
fn md_process_doc(ctx: *MD_CTX) c_int {
    var pivot_line: [*c]const MD_LINE_ANALYSIS = &md_dummy_blank_line;
    // Zero-initialize the line analysis buffers (matches the FIXED md4x.c
    // memset). md_analyze_line may leave fields unwritten on certain
    // orphaned-component / setext-underline edge cases.
    var line_buf = [2]MD_LINE_ANALYSIS{ .{}, .{} };
    var line: *MD_LINE_ANALYSIS = &line_buf[0];
    var off: OFF = 0;
    var ret: c_int = 0;

    ret = mdEnterBlock(ctx, c.MD_BLOCK_DOC, null);
    if (ret < 0) return ret;

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
    if (ret < 0) return ret;

    return ret;
}

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
    std.c.free(@ptrCast(ctx.slot_info));
    std.c.free(@ptrCast(ctx.block_alert_info));
    std.c.free(ctx.inline_attrs);

    return ret;
}

// ============================================================================
//  Suppress "unused" for foundation helpers consumed by later passes. These
//  reference-only declarations keep the file warning-clean while the rest of
//  the parser is ported. (No runtime effect.)
// ============================================================================
comptime {
    _ = &CH;
    _ = &STR;
    _ = &ISANYOF;
    _ = &ISANYOF2;
    _ = &ISANYOF3;
    _ = &ISASCII;
    _ = &ISBLANK;
    _ = &ISNEWLINE;
    _ = &ISWHITESPACE;
    _ = &ISCNTRL;
    _ = &ISPUNCT;
    _ = &ISUPPER;
    _ = &ISLOWER;
    _ = &ISALPHA;
    _ = &ISDIGIT;
    _ = &ISXDIGIT;
    _ = &ISALNUM;
    _ = &md_ascii_case_eq;
    _ = &md_ascii_eq;
    _ = &md_text_with_null_replacement;
    _ = &md_temp_buffer;
    _ = &md_get_unicode_fold_info;
    _ = &md_decode_unicode;
    _ = &ISUNICODEWHITESPACE;
    _ = &ISUNICODEWHITESPACEBEFORE;
    _ = &ISUNICODEPUNCT;
    _ = &ISUNICODEPUNCTBEFORE;
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

    var ret = md_analyze_inlines(&ctx, lines, n_lines, FALSE);
    if (ret == 0) ret = md_process_inlines(&ctx, lines, n_lines);

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
            ctx.n_block_components,                         ctx.n_slots,
            ctx.n_block_alerts,
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
    std.c.free(@ptrCast(ctx.slot_info));
    std.c.free(@ptrCast(ctx.block_alert_info));
    md_free_ref_defs(&ctx);
    md_free_ref_def_hashtable(&ctx);
    std.c.free(ctx.buffer);
    std.c.free(ctx.marks);
    std.c.free(ctx.inline_attrs);
    return ret;
}

test "unicode classifiers wired to tables" {
    // ASCII fast-path sanity.
    try std.testing.expectEqual(@as(c_int, 1), md_is_unicode_whitespace(' '));
    try std.testing.expectEqual(@as(c_int, 0), md_is_unicode_whitespace('a'));
    try std.testing.expectEqual(@as(c_int, 1), md_is_unicode_punct('!'));
    // Non-ASCII via tables.
    try std.testing.expectEqual(@as(c_int, 1), md_is_unicode_whitespace(0x00a0)); // NBSP
    try std.testing.expectEqual(@as(c_int, 1), md_is_unicode_punct(0x2010)); // hyphen
    try std.testing.expectEqual(@as(c_int, 0), md_is_unicode_punct(0x0041)); // 'A' not punct
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
