// MD4X parser — internal types module.
//
// Holds the shared @cImport, ABI scalar aliases, MD_CTX, and every internal
// struct / enum / flag constant the parser passes between its subsystem
// modules. Extracted verbatim from the monolithic src/md4x.zig (pure refactor —
// no logic change). See AGENTS.md.

const std = @import("std");
const util = @import("util.zig");

pub const c = @cImport({
    @cInclude("md4x.h");
    @cInclude("entity.h");
});

pub const c_allocator = std.heap.c_allocator;

// "These are omnipresent so lets save some typing." (md4x.c) ABI scalar aliases.
pub const CHAR = c.MD_CHAR; // == c_char (signed char, 8-bit)
pub const SZ = c.MD_SIZE; // == c_uint (32-bit)
pub const OFF = c.MD_OFFSET; // == c_uint (32-bit)
pub const MD_SIZE = c.MD_SIZE; // explicit alias used in a few signatures

// SZ_MAX / OFF_MAX (UTF-8 build: 32-bit unsigned).
pub const SZ_MAX: SZ = std.math.maxInt(SZ);
pub const OFF_MAX: OFF = std.math.maxInt(OFF);

pub const TRUE: c_int = 1;
pub const FALSE: c_int = 0;

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
pub const MD_BLOCK_CONTAINER_OPENER: c_uint = 0x01;
pub const MD_BLOCK_CONTAINER_CLOSER: c_uint = 0x02;
pub const MD_BLOCK_CONTAINER: c_uint = (MD_BLOCK_CONTAINER_OPENER | MD_BLOCK_CONTAINER_CLOSER);
pub const MD_BLOCK_LOOSE_LIST: c_uint = 0x04;
pub const MD_BLOCK_SETEXT_HEADER: c_uint = 0x08;

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
// Internal-only (never crosses the C ABI, never stored in block_bytes); drop
// `extern` so the compiler may lay out / pad the fields optimally.
pub const MD_CONTAINER = struct {
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
pub const MD_MARK_POTENTIAL_OPENER: u8 = 0x01; // Maybe opener.
pub const MD_MARK_POTENTIAL_CLOSER: u8 = 0x02; // Maybe closer.
pub const MD_MARK_OPENER: u8 = 0x04; // Definitely opener.
pub const MD_MARK_CLOSER: u8 = 0x08; // Definitely closer.
pub const MD_MARK_RESOLVED: u8 = 0x10; // Resolved in any definite way.

// Mark flags specific for various mark types (they share bits).
pub const MD_MARK_EMPH_OC: u8 = 0x20; // Opener/closer mixed candidate ("rule of 3").
pub const MD_MARK_EMPH_MOD3_0: u8 = 0x40;
pub const MD_MARK_EMPH_MOD3_1: u8 = 0x80;
pub const MD_MARK_EMPH_MOD3_2: u8 = (0x40 | 0x80);
pub const MD_MARK_EMPH_MOD3_MASK: u8 = (0x40 | 0x80);
pub const MD_MARK_AUTOLINK: u8 = 0x20; // Distinguisher for '<', '>'.
pub const MD_MARK_AUTOLINK_MISSING_MAILTO: u8 = 0x40;
pub const MD_MARK_VALIDPERMISSIVEAUTOLINK: u8 = 0x20; // For permissive autolinks.
pub const MD_MARK_HASNESTEDBRACKETS: u8 = 0x20; // For '[' to rule out invalid labels early.

pub const CODESPAN_MARK_MAXLEN: usize = 32;

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

    // Character accessors. `CH(off)` / `STR(off)` from md4x.c operate on the
    // enclosing `ctx`; here they are methods on *const MD_CTX.
    // NOTE: ctx.text is `char*`; in classification we always reinterpret as the
    // unsigned byte value to match the C `(unsigned)(ch)` casts.
    pub inline fn ch(self: *const MD_CTX, off: OFF) CHAR {
        return self.text[off];
    }
    pub inline fn str(self: *const MD_CTX, off: OFF) [*c]const CHAR {
        return self.text + off;
    }

    // Offset-based character-class predicates (PLAN 8.7): methods on *const
    // MD_CTX that read ctx.text[off] (or decode the UTF-8 codepoint there) and
    // delegate to the pure `IS*_(ch)` / md_is_unicode_* helpers in util.zig.
    // The `IS*_` helpers stay free functions taking a raw CHAR — they mirror
    // md4c's macros and are kept for upstream cross-reference (PLAN 8.6).
    pub inline fn isAnyOf(self: *const MD_CTX, off: OFF, palette: [*:0]const u8) bool {
        return util.ISANYOF_(self.ch(off), palette);
    }
    pub inline fn isAnyOf2(self: *const MD_CTX, off: OFF, ch1: CHAR, ch2: CHAR) bool {
        return util.ISANYOF2_(self.ch(off), ch1, ch2);
    }
    pub inline fn isAnyOf3(self: *const MD_CTX, off: OFF, ch1: CHAR, ch2: CHAR, ch3: CHAR) bool {
        return util.ISANYOF3_(self.ch(off), ch1, ch2, ch3);
    }
    pub inline fn isAscii(self: *const MD_CTX, off: OFF) bool {
        return util.ISASCII_(self.ch(off));
    }
    pub inline fn isBlank(self: *const MD_CTX, off: OFF) bool {
        return util.ISBLANK_(self.ch(off));
    }
    pub inline fn isNewline(self: *const MD_CTX, off: OFF) bool {
        return util.ISNEWLINE_(self.ch(off));
    }
    pub inline fn isWhitespace(self: *const MD_CTX, off: OFF) bool {
        return util.ISWHITESPACE_(self.ch(off));
    }
    pub inline fn isCntrl(self: *const MD_CTX, off: OFF) bool {
        return util.ISCNTRL_(self.ch(off));
    }
    pub inline fn isPunct(self: *const MD_CTX, off: OFF) bool {
        return util.ISPUNCT_(self.ch(off));
    }
    pub inline fn isUpper(self: *const MD_CTX, off: OFF) bool {
        return util.ISUPPER_(self.ch(off));
    }
    pub inline fn isLower(self: *const MD_CTX, off: OFF) bool {
        return util.ISLOWER_(self.ch(off));
    }
    pub inline fn isAlpha(self: *const MD_CTX, off: OFF) bool {
        return util.ISALPHA_(self.ch(off));
    }
    pub inline fn isDigit(self: *const MD_CTX, off: OFF) bool {
        return util.ISDIGIT_(self.ch(off));
    }
    pub inline fn isXdigit(self: *const MD_CTX, off: OFF) bool {
        return util.ISXDIGIT_(self.ch(off));
    }
    pub inline fn isAlnum(self: *const MD_CTX, off: OFF) bool {
        return util.ISALNUM_(self.ch(off));
    }
    pub inline fn isUnicodeWhitespace(self: *const MD_CTX, off: OFF) bool {
        return util.md_is_unicode_whitespace(util.md_decode_utf8(self.str(off), self.size - off, null));
    }
    pub inline fn isUnicodeWhitespaceBefore(self: *const MD_CTX, off: OFF) bool {
        return util.md_is_unicode_whitespace(util.md_decode_utf8_before(self, off));
    }
    pub inline fn isUnicodePunct(self: *const MD_CTX, off: OFF) bool {
        return util.md_is_unicode_punct(util.md_decode_utf8(self.str(off), self.size - off, null));
    }
    pub inline fn isUnicodePunctBefore(self: *const MD_CTX, off: OFF) bool {
        return util.md_is_unicode_punct(util.md_decode_utf8_before(self, off));
    }

    // `MD_LOG(msg)` — call ctx->parser.debug_log if set. The C macro reads `ctx`
    // from the enclosing scope; here it is a method on *MD_CTX.
    pub inline fn log(self: *MD_CTX, msg: [*:0]const u8) void {
        if (self.parser.debug_log) |cb| {
            cb(msg, self.userdata);
        }
    }
};
