//! Zig-native ABI type definitions for the MD4X parser.
//!
//! This module replaces the former C headers `md4x.h` and `entity.h` as the
//! single source of truth for the shared MD_* types, enums, flags, the
//! MD_PARSER struct, and the cross-module function declarations. The parser
//! (`src/parser/types.zig`) and every renderer import it as `c` so that the
//! pre-existing `c.MD_*` / `c.entity_lookup` / `c.md_parse` / `c.md_heal`
//! references keep resolving unchanged.
//!
//! The type/struct/flag declarations below are a verbatim transcription of
//! `zig translate-c md4x.h`, so they are byte-for-byte layout-identical to what
//! `@cImport("md4x.h")` produced — the C ABI shape is preserved exactly.
//! `md_parse`, `md_heal`, and `entity_lookup` are declared `extern` (resolved at
//! link time against the parser / heal / entity static libs), mirroring the old
//! header prototypes.

const __helpers = @import("std").zig.c_translation.helpers;

// ---------------------------------------------------------------------------
// From md4x.h (verbatim translate-c output)
// ---------------------------------------------------------------------------
pub const MD_CHAR = u8;
pub const MD_SIZE = c_uint;
pub const MD_OFFSET = c_uint;
pub const MD_BLOCK_DOC: c_int = 0;
pub const MD_BLOCK_QUOTE: c_int = 1;
pub const MD_BLOCK_UL: c_int = 2;
pub const MD_BLOCK_OL: c_int = 3;
pub const MD_BLOCK_LI: c_int = 4;
pub const MD_BLOCK_HR: c_int = 5;
pub const MD_BLOCK_H: c_int = 6;
pub const MD_BLOCK_CODE: c_int = 7;
pub const MD_BLOCK_HTML: c_int = 8;
pub const MD_BLOCK_P: c_int = 9;
pub const MD_BLOCK_TABLE: c_int = 10;
pub const MD_BLOCK_THEAD: c_int = 11;
pub const MD_BLOCK_TBODY: c_int = 12;
pub const MD_BLOCK_TR: c_int = 13;
pub const MD_BLOCK_TH: c_int = 14;
pub const MD_BLOCK_TD: c_int = 15;
pub const MD_BLOCK_FRONTMATTER: c_int = 16;
pub const MD_BLOCK_COMPONENT: c_int = 17;
pub const MD_BLOCK_TEMPLATE: c_int = 18;
pub const MD_BLOCK_ALERT: c_int = 19;
pub const enum_MD_BLOCKTYPE = c_uint;
pub const MD_BLOCKTYPE = enum_MD_BLOCKTYPE;
pub const MD_SPAN_EM: c_int = 0;
pub const MD_SPAN_STRONG: c_int = 1;
pub const MD_SPAN_A: c_int = 2;
pub const MD_SPAN_IMG: c_int = 3;
pub const MD_SPAN_CODE: c_int = 4;
pub const MD_SPAN_DEL: c_int = 5;
pub const MD_SPAN_LATEXMATH: c_int = 6;
pub const MD_SPAN_LATEXMATH_DISPLAY: c_int = 7;
pub const MD_SPAN_WIKILINK: c_int = 8;
pub const MD_SPAN_U: c_int = 9;
pub const MD_SPAN_COMPONENT: c_int = 10;
pub const MD_SPAN_SPAN: c_int = 11;
pub const enum_MD_SPANTYPE = c_uint;
pub const MD_SPANTYPE = enum_MD_SPANTYPE;
pub const MD_TEXT_NORMAL: c_int = 0;
pub const MD_TEXT_NULLCHAR: c_int = 1;
pub const MD_TEXT_BR: c_int = 2;
pub const MD_TEXT_SOFTBR: c_int = 3;
pub const MD_TEXT_ENTITY: c_int = 4;
pub const MD_TEXT_CODE: c_int = 5;
pub const MD_TEXT_HTML: c_int = 6;
pub const MD_TEXT_LATEXMATH: c_int = 7;
pub const enum_MD_TEXTTYPE = c_uint;
pub const MD_TEXTTYPE = enum_MD_TEXTTYPE;
pub const MD_ALIGN_DEFAULT: c_int = 0;
pub const MD_ALIGN_LEFT: c_int = 1;
pub const MD_ALIGN_CENTER: c_int = 2;
pub const MD_ALIGN_RIGHT: c_int = 3;
pub const enum_MD_ALIGN = c_uint;
pub const MD_ALIGN = enum_MD_ALIGN;
pub const struct_MD_ATTRIBUTE = extern struct {
    text: [*c]const MD_CHAR = null,
    size: MD_SIZE = 0,
    substr_types: [*c]const MD_TEXTTYPE = null,
    substr_offsets: [*c]const MD_OFFSET = null,
};
pub const MD_ATTRIBUTE = struct_MD_ATTRIBUTE;
pub const struct_MD_BLOCK_UL_DETAIL = extern struct {
    is_tight: c_int = 0,
    mark: MD_CHAR = 0,
};
pub const MD_BLOCK_UL_DETAIL = struct_MD_BLOCK_UL_DETAIL;
pub const struct_MD_BLOCK_OL_DETAIL = extern struct {
    start: c_uint = 0,
    is_tight: c_int = 0,
    mark_delimiter: MD_CHAR = 0,
};
pub const MD_BLOCK_OL_DETAIL = struct_MD_BLOCK_OL_DETAIL;
pub const struct_MD_BLOCK_LI_DETAIL = extern struct {
    is_task: c_int = 0,
    task_mark: MD_CHAR = 0,
    task_mark_offset: MD_OFFSET = 0,
};
pub const MD_BLOCK_LI_DETAIL = struct_MD_BLOCK_LI_DETAIL;
pub const struct_MD_BLOCK_H_DETAIL = extern struct {
    level: c_uint = 0,
};
pub const MD_BLOCK_H_DETAIL = struct_MD_BLOCK_H_DETAIL;
pub const struct_MD_BLOCK_CODE_DETAIL = extern struct {
    info: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
    lang: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
    fence_char: MD_CHAR = 0,
    filename: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
    meta: [*c]const MD_CHAR = null,
    meta_size: MD_SIZE = 0,
    highlights: [*c]const c_uint = null,
    highlight_count: c_uint = 0,
};
pub const MD_BLOCK_CODE_DETAIL = struct_MD_BLOCK_CODE_DETAIL;
pub const struct_MD_BLOCK_TABLE_DETAIL = extern struct {
    col_count: c_uint = 0,
    head_row_count: c_uint = 0,
    body_row_count: c_uint = 0,
};
pub const MD_BLOCK_TABLE_DETAIL = struct_MD_BLOCK_TABLE_DETAIL;
pub const struct_MD_BLOCK_TD_DETAIL = extern struct {
    @"align": MD_ALIGN = @import("std").mem.zeroes(MD_ALIGN),
};
pub const MD_BLOCK_TD_DETAIL = struct_MD_BLOCK_TD_DETAIL;
pub const struct_MD_SPAN_A_DETAIL = extern struct {
    href: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
    title: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
    raw_attrs: [*c]const MD_CHAR = null,
    raw_attrs_size: MD_SIZE = 0,
    is_autolink: c_int = 0,
};
pub const MD_SPAN_A_DETAIL = struct_MD_SPAN_A_DETAIL;
pub const struct_MD_SPAN_IMG_DETAIL = extern struct {
    src: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
    title: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
    raw_attrs: [*c]const MD_CHAR = null,
    raw_attrs_size: MD_SIZE = 0,
};
pub const MD_SPAN_IMG_DETAIL = struct_MD_SPAN_IMG_DETAIL;
pub const struct_MD_SPAN_WIKILINK = extern struct {
    target: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
};
pub const MD_SPAN_WIKILINK_DETAIL = struct_MD_SPAN_WIKILINK;
pub const struct_MD_SPAN_COMPONENT_DETAIL = extern struct {
    tag_name: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
    raw_props: [*c]const MD_CHAR = null,
    raw_props_size: MD_SIZE = 0,
};
pub const MD_SPAN_COMPONENT_DETAIL = struct_MD_SPAN_COMPONENT_DETAIL;
pub const struct_MD_BLOCK_COMPONENT_DETAIL = extern struct {
    tag_name: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
    raw_props: [*c]const MD_CHAR = null,
    raw_props_size: MD_SIZE = 0,
    title: [*c]const MD_CHAR = null,
    title_size: MD_SIZE = 0,
};
pub const MD_BLOCK_COMPONENT_DETAIL = struct_MD_BLOCK_COMPONENT_DETAIL;
pub const struct_MD_BLOCK_TEMPLATE_DETAIL = extern struct {
    name: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
};
pub const MD_BLOCK_TEMPLATE_DETAIL = struct_MD_BLOCK_TEMPLATE_DETAIL;
pub const struct_MD_BLOCK_ALERT_DETAIL = extern struct {
    type_name: MD_ATTRIBUTE = @import("std").mem.zeroes(MD_ATTRIBUTE),
};
pub const MD_BLOCK_ALERT_DETAIL = struct_MD_BLOCK_ALERT_DETAIL;
pub const struct_MD_SPAN_ATTRS_DETAIL = extern struct {
    raw_attrs: [*c]const MD_CHAR = null,
    raw_attrs_size: MD_SIZE = 0,
};
pub const MD_SPAN_ATTRS_DETAIL = struct_MD_SPAN_ATTRS_DETAIL;
pub const struct_MD_SPAN_SPAN_DETAIL = extern struct {
    raw_attrs: [*c]const MD_CHAR = null,
    raw_attrs_size: MD_SIZE = 0,
};
pub const MD_SPAN_SPAN_DETAIL = struct_MD_SPAN_SPAN_DETAIL;
pub const struct_MD_PARSER = extern struct {
    abi_version: c_uint = 0,
    flags: c_uint = 0,
    enter_block: ?*const fn (MD_BLOCKTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = null,
    leave_block: ?*const fn (MD_BLOCKTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = null,
    enter_span: ?*const fn (MD_SPANTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = null,
    leave_span: ?*const fn (MD_SPANTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = null,
    text: ?*const fn (MD_TEXTTYPE, [*c]const MD_CHAR, MD_SIZE, ?*anyopaque) callconv(.c) c_int = null,
    debug_log: ?*const fn ([*c]const u8, ?*anyopaque) callconv(.c) void = null,
    syntax: ?*const fn () callconv(.c) void = null,
};
pub const MD_PARSER = struct_MD_PARSER;
pub const MD_RENDERER = MD_PARSER;

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
// Cross-module function declarations (resolved at link time).
// `md_parse` was declared by md4x.h; `md_heal` by md4x-heal.h.
// ---------------------------------------------------------------------------
pub extern fn md_parse(text: [*c]const MD_CHAR, size: MD_SIZE, parser: [*c]const MD_PARSER, userdata: ?*anyopaque) c_int;
pub extern fn md_heal(input: [*c]const u8, input_size: c_uint, process_output: ?*const fn ([*c]const u8, c_uint, ?*anyopaque) callconv(.c) void, userdata: ?*anyopaque) c_int;

// ---------------------------------------------------------------------------
// From entity.h — HTML entity lookup. Layout-compatible with entity.zig's
// `ENTITY` (the `.name` field is unused by consumers; only `.codepoints` is
// read). `entity_lookup` is resolved at link time against the entity lib.
// ---------------------------------------------------------------------------
pub const struct_ENTITY_tag = extern struct {
    name: [*:0]const u8,
    codepoints: [2]c_uint,
};
pub const ENTITY = struct_ENTITY_tag;
pub extern fn entity_lookup(name: [*c]const u8, name_size: usize) [*c]const ENTITY;

// ---------------------------------------------------------------------------
// Renderer ABIs (formerly the md4x-*.h headers). Entry points are resolved at
// link time against the renderer static libs. Flag values mirror the headers.
// ---------------------------------------------------------------------------
const ProcessOutput = ?*const fn ([*c]const MD_CHAR, MD_SIZE, ?*anyopaque) callconv(.c) void;

pub const MD_HTML_OPTS = extern struct {
    title: [*c]const u8 = null,
    css_url: [*c]const u8 = null,
};

pub extern fn md_html(input: [*c]const MD_CHAR, input_size: MD_SIZE, process_output: ProcessOutput, userdata: ?*anyopaque, parser_flags: c_uint, renderer_flags: c_uint) c_int;
pub extern fn md_html_ex(input: [*c]const MD_CHAR, input_size: MD_SIZE, process_output: ProcessOutput, userdata: ?*anyopaque, parser_flags: c_uint, renderer_flags: c_uint, opts: [*c]const MD_HTML_OPTS) c_int;
pub extern fn md_ast(input: [*c]const MD_CHAR, input_size: MD_SIZE, process_output: ProcessOutput, userdata: ?*anyopaque, parser_flags: c_uint, renderer_flags: c_uint) c_int;
pub extern fn md_ansi(input: [*c]const MD_CHAR, input_size: MD_SIZE, process_output: ProcessOutput, userdata: ?*anyopaque, parser_flags: c_uint, renderer_flags: c_uint) c_int;
pub extern fn md_text(input: [*c]const MD_CHAR, input_size: MD_SIZE, process_output: ProcessOutput, userdata: ?*anyopaque, parser_flags: c_uint, renderer_flags: c_uint) c_int;
pub extern fn md_markdown(input: [*c]const MD_CHAR, input_size: MD_SIZE, process_output: ProcessOutput, userdata: ?*anyopaque, parser_flags: c_uint, renderer_flags: c_uint) c_int;
pub extern fn md_meta(input: [*c]const MD_CHAR, input_size: MD_SIZE, process_output: ProcessOutput, userdata: ?*anyopaque, parser_flags: c_uint, renderer_flags: c_uint) c_int;

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
