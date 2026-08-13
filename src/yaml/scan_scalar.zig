//! Port of libyaml's `src/scanner.c` — the scalar scanners: block (literal and
//! folded), flow (single- and double-quoted) and plain.
//!
//! STUB — see task "Port scanner.c scalar scanners to Zig".

const types = @import("types.zig");
const Parser = types.Parser;
const Error = types.Error;
const Token = types.Token;

/// `yaml_parser_scan_plain_scalar`
pub fn scanPlainScalar(p: *Parser, token: *Token) Error!void {
    _ = p;
    _ = token;
    @panic("TODO: port scanner.c scalar scanners");
}
