//! MD4X library root.
//!
//! Aggregates the parser, the entity table, and every renderer into ONE Zig
//! module so that each artifact (CLI, WASM, NAPI, fuzz harness) imports a single
//! thing and the pieces call each other by **direct Zig call**.
//!
//! Before this, each unit was compiled as its own static library and they found
//! each other through C-ABI symbols: the definitions were `export fn ...
//! callconv(.c)` and `abi.zig` re-declared them `pub extern fn`, resolved at
//! link time. That worked, but it froze an internal C calling convention for no
//! reason once the *external* C ABI was dropped — and it made de-externing the
//! SAX interface impossible, since a direct Zig call requires the caller and
//! callee to live in one compilation.
//!
//! Now `abi.zig` holds only types/enums/flags (a pure leaf module) and the
//! function declarations live here as re-exports of the real definitions.
//! Consumers that need a specific unit may also import it directly — the
//! renderers import the parser and entity table that way.
//!
//! The definitions still carry `export` + `callconv(.c)`; removing that is
//! Phase 4b. Keeping it here is harmless (one artifact, one definition of each
//! symbol) and keeps this step's diff to the build graph and the import wiring.

const parser = @import("md4x.zig");
const entity = @import("entity.zig");
const html = @import("renderers/md4x-html.zig");
const ast = @import("renderers/md4x-ast.zig");
const ansi = @import("renderers/md4x-ansi.zig");
const text = @import("renderers/md4x-text.zig");
const meta = @import("renderers/md4x-meta.zig");
const markdown = @import("renderers/md4x-markdown.zig");
const heal = @import("renderers/md4x-heal.zig");

/// Shared MD_* types, enums, and flags.
pub const abi = @import("abi");

// --- Parser + entity table ---
pub const md_parse = parser.md_parse;
pub const entity_lookup = entity.entity_lookup;

// --- Renderers ---
pub const MD_HTML_OPTS = html.MD_HTML_OPTS;
pub const md_html = html.md_html;
pub const md_html_ex = html.md_html_ex;
pub const md_ast = ast.md_ast;
pub const md_ansi = ansi.md_ansi;
pub const md_text = text.md_text;
pub const md_meta = meta.md_meta;
pub const md_markdown = markdown.md_markdown;
pub const md_heal = heal.md_heal;

comptime {
    // Force the symbols into the artifact even when a consumer references only
    // some of them (e.g. the CLI does not call md_meta, but the WASM build does
    // and both go through this root).
    _ = parser;
    _ = entity;
    _ = html;
    _ = ast;
    _ = ansi;
    _ = text;
    _ = meta;
    _ = markdown;
    _ = heal;
}
