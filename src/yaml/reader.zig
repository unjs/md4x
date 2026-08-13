//! Port of libyaml's `src/reader.c`: encoding detection and the decode of the
//! raw input into the parser's character buffer.
//!
//! STUB — see task "Port reader.c to Zig".

const types = @import("types.zig");
const Parser = types.Parser;
const Error = types.Error;

/// `yaml_parser_update_buffer`: ensure the buffer holds at least `length`
/// characters at the cursor.
pub fn updateBuffer(p: *Parser, length: usize) Error!void {
    _ = p;
    _ = length;
    @panic("TODO: port reader.c");
}
