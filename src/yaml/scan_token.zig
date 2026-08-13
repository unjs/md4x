//! Port of libyaml's `src/scanner.c` — the non-scalar token scanners:
//! whitespace/comment skipping, directives, anchors and tags.
//!
//! STUB — see task "Port scanner.c token scanners to Zig".

const types = @import("types.zig");
const Parser = types.Parser;
const Error = types.Error;

/// `yaml_parser_scan_to_next_token`
pub fn scanToNextToken(p: *Parser) Error!void {
    _ = p;
    @panic("TODO: port scanner.c token scanners");
}
