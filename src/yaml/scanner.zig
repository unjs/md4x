//! Port of libyaml's `src/scanner.c` — the driver half: the token queue, the
//! simple-key machinery, indent/flow-level bookkeeping, and every `fetch_*`
//! function.
//!
//! STUB — see task "Port scanner.c driver to Zig".

const types = @import("types.zig");
const Parser = types.Parser;
const Error = types.Error;

/// `yaml_parser_fetch_more_tokens`
pub fn fetchMoreTokens(p: *Parser) Error!void {
    _ = p;
    @panic("TODO: port scanner.c");
}
