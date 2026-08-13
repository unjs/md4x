//! Port of libyaml's `src/parser.c`: the event state machine.
//!
//! STUB — see task "Port parser.c state machine to Zig".

const types = @import("types.zig");
const Parser = types.Parser;
const Event = types.Event;
const Error = types.Error;

/// `yaml_parser_parse`
///
/// Until the state machine lands this reports a parser error rather than
/// panicking, so `zig build yaml-parity` stays runnable and shows the port's
/// progress as a shrinking diff instead of a crash.
pub fn parse(p: *Parser, event: *Event) Error!void {
    _ = event;
    return p.setParserError("port not implemented", p.mark);
}
