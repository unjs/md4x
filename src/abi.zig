//! Zig-native ABI type definitions for the MD4X parser.
//!
//! This module replaces the former C headers `md4x.h` and `entity.h` as the
//! single source of truth for the shared parser types, enums, flags, and the
//! `Parser` callback table. The parser (`src/parser/types.zig`) and every
//! renderer import it as `c`.
//!
//! The type/enum/flag declarations started life as a verbatim transcription of
//! `zig translate-c md4x.h`. Phase 4c of `PLAN.md` idiomatized them, so they
//! bear no resemblance to what `@cImport("md4x.h")` produced any more:
//!
//! - **Step 2:** the SAX **detail** types are ordinary Zig structs with
//!   compiler-chosen layout. Their string/array members are **slices** with
//!   exact lengths (`text`, `meta`, `highlights`, `raw_attrs`, `raw_props`,
//!   `title`, `substr_types`, `substr_offsets`) instead of `[*c]` pointer +
//!   separate `*_size`/`*_count` field, and their genuinely two-state
//!   `c_int` members (`is_tight`, `is_task`, `is_autolink`) are `bool`.
//!   An absent value is the **empty** slice — the parser never distinguished a
//!   null pointer from a zero length, and no consumer does either.
//! - **Steps 3-5:** `MD_BLOCKTYPE` / `MD_SPANTYPE` / `MD_TEXTTYPE` / `MD_ALIGN`
//!   are real Zig enums (`BlockType` / `SpanType` / `TextType` / `Align`); the
//!   detail structs are reachable only through the tagged unions `BlockDetail`
//!   and `SpanDetail`, so a renderer resolves them with an exhaustive `switch`
//!   rather than an unchecked `@ptrCast` of a `?*anyopaque`. `MD_PARSER`
//!   (`extern struct`, `callconv(.c)` callbacks, `abi_version`, `syntax`,
//!   the `MD_RENDERER` alias) is replaced by the plain Zig `Parser` struct.
//!
//! The enums keep the **numeric values and declaration order** of the C
//! enumerations they replace (`enum(c_uint)`, implicit ordinals), so any
//! accidental numeric dependency is preserved.
//!
//! `MD_CHAR` / `MD_SIZE` / `MD_OFFSET` keep their C spellings: they describe the
//! input buffer and offsets into it, which the parser indexes with `c_uint`
//! arithmetic throughout.
//!
//! **This module is a pure leaf: types only, no imports of other md4x modules.**
//! It used to also declare `md_parse` / `md_heal` / `entity_lookup` / the
//! renderer entry points as `pub extern fn`, resolved at link time against
//! separate static libs. Those now live in `src/lib.zig` as re-exports of the
//! real Zig definitions, so the units call each other directly. Do not
//! reintroduce entry-point declarations here — an import from `abi` back into
//! the parser or a renderer would make this module cyclic.

const __helpers = @import("std").zig.c_translation.helpers;

// ---------------------------------------------------------------------------
// Scalars and enums
// ---------------------------------------------------------------------------
pub const MD_CHAR = u8;
pub const MD_SIZE = c_uint;
pub const MD_OFFSET = c_uint;

/// Block types. Ordinals are the values of the former C `MD_BLOCKTYPE`.
pub const BlockType = enum(c_uint) {
    doc,
    quote,
    ul,
    ol,
    li,
    hr,
    h,
    code,
    html,
    p,
    table,
    thead,
    tbody,
    tr,
    th,
    td,
    frontmatter,
    component,
    template,
    alert,
};

/// Span types. Ordinals are the values of the former C `MD_SPANTYPE`.
pub const SpanType = enum(c_uint) {
    em,
    strong,
    a,
    img,
    code,
    del,
    latexmath,
    latexmath_display,
    wikilink,
    u,
    component,
    span,
};

/// Text-run types. Ordinals are the values of the former C `MD_TEXTTYPE`.
pub const TextType = enum(c_uint) {
    normal,
    nullchar,
    br,
    softbr,
    entity,
    code,
    html,
    latexmath,
};

/// Table cell alignment. Ordinals are the values of the former C `MD_ALIGN`.
pub const Align = enum(c_uint) {
    default,
    left,
    center,
    right,
};

// ---------------------------------------------------------------------------
// SAX detail types
// ---------------------------------------------------------------------------

/// String attribute for non-text-flow content (URLs, titles, info strings, …).
/// Such content may still mix normal text with entities and NUL characters, so
/// it is described as a run of substrings rather than one flat string.
///
/// Invariants, all guaranteed by `md_build_attribute`:
///
/// - `substr_types.len == substr_offsets.len - 1` (the offsets array carries a
///   final terminator entry), except for the fully-empty attribute where both
///   are empty.
/// - `substr_offsets[0] == 0` and `substr_offsets[substr_types.len] == size()`.
/// - only `.normal`, `.entity` and `.nullchar` appear in `substr_types`.
///
/// An unset attribute is the default value: an empty `text` with empty tables.
pub const Attribute = struct {
    text: []const MD_CHAR = &.{},
    substr_types: []const TextType = &.{},
    substr_offsets: []const MD_OFFSET = &.{},

    /// Byte length of `text`, as the `MD_SIZE` the offset tables are expressed in.
    pub fn size(self: Attribute) MD_SIZE {
        return @intCast(self.text.len);
    }
};

pub const BlockUlDetail = struct {
    /// True for a tight list, false for a loose one.
    is_tight: bool = false,
    /// Bullet character: '-', '+' or '*'.
    mark: MD_CHAR = 0,
};

pub const BlockOlDetail = struct {
    start: c_uint = 0,
    /// True for a tight list, false for a loose one.
    is_tight: bool = false,
    /// '.' or ')'.
    mark_delimiter: MD_CHAR = 0,
};

pub const BlockLiDetail = struct {
    /// Can be true only with MD_FLAG_TASKLISTS.
    is_task: bool = false,
    /// 'x', 'X' or ' ' when `is_task`.
    task_mark: MD_CHAR = 0,
    /// Offset of the character between '[' and ']'.
    task_mark_offset: MD_OFFSET = 0,
};

pub const BlockHDetail = struct {
    level: c_uint = 0,
};

pub const BlockCodeDetail = struct {
    info: Attribute = .{},
    lang: Attribute = .{},
    /// Fence character, or zero for an indented code block.
    fence_char: MD_CHAR = 0,
    /// `[filename]` from the info string.
    filename: Attribute = .{},
    /// Raw metadata remainder of the info string. Empty when absent. The
    /// backing allocation carries a trailing NUL one byte past `meta.len`.
    meta: []const MD_CHAR = &.{},
    /// Expanded line numbers from `{1-3,5}`. Empty when absent.
    highlights: []const c_uint = &.{},
};

pub const BlockTableDetail = struct {
    col_count: c_uint = 0,
    head_row_count: c_uint = 0,
    body_row_count: c_uint = 0,
};

pub const BlockTdDetail = struct {
    @"align": Align = .default,
};

pub const BlockComponentDetail = struct {
    /// Component name (e.g. "alert", "card").
    tag_name: Attribute = .{},
    /// Raw props from `{...}`. Empty when absent.
    raw_props: []const MD_CHAR = &.{},
    /// Title after the name (e.g. "STOP" in `:::danger STOP`). Empty when absent.
    title: []const MD_CHAR = &.{},
};

pub const BlockTemplateDetail = struct {
    /// Slot name (e.g. "header", "footer").
    name: Attribute = .{},
};

pub const BlockAlertDetail = struct {
    /// Alert type (e.g. "NOTE", "WARNING").
    type_name: Attribute = .{},
};

pub const SpanADetail = struct {
    href: Attribute = .{},
    title: Attribute = .{},
    /// Raw attrs from a trailing `{...}`. Empty when absent.
    raw_attrs: []const MD_CHAR = &.{},
    is_autolink: bool = false,
};

pub const SpanImgDetail = struct {
    src: Attribute = .{},
    title: Attribute = .{},
    /// Raw attrs from a trailing `{...}`. Empty when absent.
    raw_attrs: []const MD_CHAR = &.{},
};

pub const SpanWikilinkDetail = struct {
    target: Attribute = .{},
};

pub const SpanComponentDetail = struct {
    /// Component name (e.g. "badge", "icon-star").
    tag_name: Attribute = .{},
    /// Raw props from `{...}`. Empty when absent.
    raw_props: []const MD_CHAR = &.{},
};

/// Trailing `{...}` attributes on em/strong/code/del/u. An **empty**
/// `raw_attrs` means "no attributes" — before Phase 4c step 3 the parser
/// signalled that by handing the callback a null detail pointer instead, but
/// no consumer ever distinguished the two (every guard was
/// `detail != null and raw_attrs.len > 0`), so the null case is gone.
pub const SpanAttrsDetail = struct {
    raw_attrs: []const MD_CHAR = &.{},
};

pub const SpanSpanDetail = struct {
    /// Raw attrs from `{...}`. Empty for `{}`.
    raw_attrs: []const MD_CHAR = &.{},
};

/// The detail handed to `enter_block` / `leave_block`, tagged by `BlockType`.
/// Arms whose block type carries no detail are `void`.
pub const BlockDetail = union(BlockType) {
    doc: void,
    quote: void,
    ul: BlockUlDetail,
    ol: BlockOlDetail,
    li: BlockLiDetail,
    hr: void,
    h: BlockHDetail,
    code: BlockCodeDetail,
    html: void,
    p: void,
    table: BlockTableDetail,
    thead: void,
    tbody: void,
    tr: void,
    th: BlockTdDetail,
    td: BlockTdDetail,
    frontmatter: void,
    component: BlockComponentDetail,
    template: BlockTemplateDetail,
    alert: BlockAlertDetail,

    /// The all-defaults value of the arm selected by `ty`. The emission path
    /// uses it to materialize a detail for a block whose type is only known at
    /// runtime, then fills in the fields the type actually carries.
    pub fn default(ty: BlockType) BlockDetail {
        return switch (ty) {
            inline else => |t| @unionInit(BlockDetail, @tagName(t), defaultPayload(TagPayload(BlockDetail, t))),
        };
    }
};

/// The detail handed to `enter_span` / `leave_span`, tagged by `SpanType`.
/// Arms whose span type carries no detail are `void`.
pub const SpanDetail = union(SpanType) {
    em: SpanAttrsDetail,
    strong: SpanAttrsDetail,
    a: SpanADetail,
    img: SpanImgDetail,
    code: SpanAttrsDetail,
    del: SpanAttrsDetail,
    latexmath: void,
    latexmath_display: void,
    wikilink: SpanWikilinkDetail,
    u: SpanAttrsDetail,
    component: SpanComponentDetail,
    span: SpanSpanDetail,
};

/// Local `std.meta.TagPayload` / default-value helpers. Spelled out here so
/// this module keeps its "no imports" property beyond the translate-c helper.
fn TagPayload(comptime U: type, comptime tag: @typeInfo(U).@"union".tag_type.?) type {
    for (@typeInfo(U).@"union".fields) |f| {
        if (@field(@typeInfo(U).@"union".tag_type.?, f.name) == tag) return f.type;
    }
    unreachable;
}

fn defaultPayload(comptime T: type) T {
    return if (T == void) {} else T{};
}

// ---------------------------------------------------------------------------
// The callback table
// ---------------------------------------------------------------------------

/// A callback's abort code. `0` continues the parse; non-zero aborts the
/// enclosing emitter.
///
/// **Abort contract (md4c parity — pinned by the abort matrix in
/// `src/md4x.zig`, do not change):** `md_parse` propagates a NEGATIVE code
/// verbatim as its own return value, but returns `0` for a POSITIVE one (the
/// positive code stops emission, is never caught by an internal `< 0` boundary,
/// and is then overwritten by a subsequent `leave_*` returning 0). OOM and a
/// callback returning `-1` are deliberately unified as `-1`.
///
/// This is why the callbacks return a plain integer rather than a Zig error
/// union (PLAN.md §8.2): the contract has to carry an arbitrary caller-chosen
/// i32 through, and OOM must stay indistinguishable from `-1`.
pub const CallbackResult = i32;

/// Parser flags + the SAX callback table. A plain Zig struct: no `extern`, no
/// `callconv(.c)`, and no `abi_version` / `syntax` / `MD_RENDERER` alias — all
/// three were vestiges of the dropped external C ABI.
///
/// Details are passed by **const pointer**: the unions are large and this is a
/// hot path. The type tag lives in the union, so there is no separate type
/// parameter — recover it with `switch (detail.*)`.
///
/// **The five SAX callbacks are REQUIRED** — non-optional, with no default
/// (PLAN.md item 11). The emission path calls all five unconditionally, so a
/// nullable field there was a null-function-pointer call: a Debug panic and
/// ReleaseFast UB. Non-optional turns that into a compile error, which is why
/// `Parser{}` / `md_parse(text, size, &.{}, null)` no longer type-checks — an
/// incomplete table is now unrepresentable rather than merely undefined.
/// `debug_log` stays optional: it is genuinely optional and is the one field
/// the parser guards (`MD_CTX.log`).
pub const Parser = struct {
    /// Bitmask of `MD_FLAG_*` values.
    flags: c_uint = 0,
    enter_block: *const fn (*const BlockDetail, ?*anyopaque) CallbackResult,
    leave_block: *const fn (*const BlockDetail, ?*anyopaque) CallbackResult,
    enter_span: *const fn (*const SpanDetail, ?*anyopaque) CallbackResult,
    leave_span: *const fn (*const SpanDetail, ?*anyopaque) CallbackResult,
    text: *const fn (TextType, []const MD_CHAR, ?*anyopaque) CallbackResult,
    /// Optional diagnostic sink; `MD_*_FLAG_DEBUG` wires it to stderr.
    debug_log: ?*const fn ([]const u8, ?*anyopaque) void = null,
};

pub const MD_FLAG_COLLAPSEWHITESPACE = @as(c_int, 0x0001);
pub const MD_FLAG_PERMISSIVEATXHEADERS = @as(c_int, 0x0002);
pub const MD_FLAG_PERMISSIVEURLAUTOLINKS = @as(c_int, 0x0004);
pub const MD_FLAG_PERMISSIVEEMAILAUTOLINKS = @as(c_int, 0x0008);
pub const MD_FLAG_NOINDENTEDCODEBLOCKS = @as(c_int, 0x0010);
pub const MD_FLAG_NOHTMLBLOCKS = @as(c_int, 0x0020);
pub const MD_FLAG_NOHTMLSPANS = @as(c_int, 0x0040);
pub const MD_FLAG_TABLES = @as(c_int, 0x0100);
pub const MD_FLAG_STRIKETHROUGH = @as(c_int, 0x0200);
pub const MD_FLAG_PERMISSIVEWWWAUTOLINKS = @as(c_int, 0x0400);
pub const MD_FLAG_TASKLISTS = @as(c_int, 0x0800);
pub const MD_FLAG_LATEXMATHSPANS = @as(c_int, 0x1000);
pub const MD_FLAG_WIKILINKS = @as(c_int, 0x2000);
pub const MD_FLAG_UNDERLINE = @as(c_int, 0x4000);
pub const MD_FLAG_HARD_SOFT_BREAKS = __helpers.promoteIntLiteral(c_int, 0x8000, .hex);
pub const MD_FLAG_FRONTMATTER = __helpers.promoteIntLiteral(c_int, 0x10000, .hex);
pub const MD_FLAG_COMPONENTS = __helpers.promoteIntLiteral(c_int, 0x20000, .hex);
pub const MD_FLAG_ATTRIBUTES = __helpers.promoteIntLiteral(c_int, 0x40000, .hex);
pub const MD_FLAG_ALERTS = __helpers.promoteIntLiteral(c_int, 0x80000, .hex);
pub const MD_FLAG_PERMISSIVEAUTOLINKS = (MD_FLAG_PERMISSIVEEMAILAUTOLINKS | MD_FLAG_PERMISSIVEURLAUTOLINKS) | MD_FLAG_PERMISSIVEWWWAUTOLINKS;
pub const MD_FLAG_NOHTML = MD_FLAG_NOHTMLBLOCKS | MD_FLAG_NOHTMLSPANS;
pub const MD_DIALECT_COMMONMARK = @as(c_int, 0);
pub const MD_DIALECT_GITHUB = (((MD_FLAG_PERMISSIVEAUTOLINKS | MD_FLAG_TABLES) | MD_FLAG_STRIKETHROUGH) | MD_FLAG_TASKLISTS) | MD_FLAG_ALERTS;
pub const MD_DIALECT_ALL = (((((((((MD_FLAG_PERMISSIVEAUTOLINKS | MD_FLAG_TABLES) | MD_FLAG_STRIKETHROUGH) | MD_FLAG_TASKLISTS) | MD_FLAG_LATEXMATHSPANS) | MD_FLAG_WIKILINKS) | MD_FLAG_UNDERLINE) | MD_FLAG_FRONTMATTER) | MD_FLAG_COMPONENTS) | MD_FLAG_ATTRIBUTES) | MD_FLAG_ALERTS;

// ---------------------------------------------------------------------------
// Renderer ABI types + flag values (formerly the md4x-*.h headers). The entry
// points themselves are Zig functions re-exported by lib.zig.
// ---------------------------------------------------------------------------
/// Output sink handed to every renderer entry point.
pub const ProcessOutput = ?*const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) void;

/// Output sink for `md_heal` (heal predates the MD_CHAR typedef and uses
/// `const char*` / `unsigned` directly).
pub const HealProcessOutput = ?*const fn ([*c]const u8, c_uint, ?*anyopaque) void;

pub const MD_HTML_FLAG_DEBUG: c_uint = 0x0001;
pub const MD_HTML_FLAG_VERBATIM_ENTITIES: c_uint = 0x0002;
pub const MD_HTML_FLAG_SKIP_UTF8_BOM: c_uint = 0x0004;
pub const MD_HTML_FLAG_FULL_HTML: c_uint = 0x0008;
pub const MD_HTML_FLAG_CODE_META: c_uint = 0x0010;
pub const MD_HTML_FLAG_HEAL: c_uint = 0x0100;

pub const MD_ANSI_FLAG_DEBUG: c_uint = 0x0001;
pub const MD_ANSI_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
pub const MD_ANSI_FLAG_NO_COLOR: c_uint = 0x0004;
pub const MD_ANSI_FLAG_CODE_META: c_uint = 0x0008;
pub const MD_ANSI_FLAG_SHOW_URLS: c_uint = 0x0010;
pub const MD_ANSI_FLAG_SHOW_FRONTMATTER: c_uint = 0x0020;
pub const MD_ANSI_FLAG_HEAL: c_uint = 0x0100;

pub const MD_AST_FLAG_DEBUG: c_uint = 0x0001;
pub const MD_AST_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
pub const MD_AST_FLAG_HEAL: c_uint = 0x0100;

pub const MD_TEXT_FLAG_DEBUG: c_uint = 0x0001;
pub const MD_TEXT_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
pub const MD_TEXT_FLAG_HEAL: c_uint = 0x0100;

pub const MD_MARKDOWN_FLAG_DEBUG: c_uint = 0x0001;
pub const MD_MARKDOWN_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
pub const MD_MARKDOWN_FLAG_HEAL: c_uint = 0x0100;

pub const MD_META_FLAG_DEBUG: c_uint = 0x0001;
pub const MD_META_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
pub const MD_META_FLAG_HEAL: c_uint = 0x0100;
