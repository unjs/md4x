//! A pure-Zig port of libyaml's parser half (reader + scanner + event state
//! machine), pinned to the upstream master commit vendored through
//! `build.zig.zon`.
//!
//! # Why
//!
//! libyaml is the only C compiled into any md4x artifact. It costs ~62 KB of
//! the wasm (~18 KB gzipped), allocates for every scalar it produces, and sits
//! outside both Zig's coverage-guided fuzzer and ReleaseSafe's checks — the one
//! region of the build where an out-of-bounds read is undefined behaviour
//! rather than a trap. Everything md4x uses from it is five functions and
//! eleven event types.
//!
//! # Parity
//!
//! This port must produce the SAME event stream as the vendored C, byte for
//! byte, for every input — that is what `parity.zig` gates and what
//! `scripts/diff-corpus.sh` gates downstream. Where the C is odd, the port is
//! odd in the same way. Improvements go in only after the differential harness
//! is green, and only with a corpus diff to justify them.
//!
//! What is NOT ported: the emitter (`src/emitter.c`, `src/writer.c`), the
//! document loader (`src/loader.c`, `src/dumper.c`) and file input. md4x
//! consumes an event stream from a byte slice and never emits or composes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const api = @import("api.zig");
const types = @import("types.zig");
const parser_impl = @import("parser.zig");

pub const mem = @import("mem.zig");
pub const chars = @import("chars.zig");

pub const Parser = types.Parser;
pub const Event = types.Event;
pub const EventData = types.EventData;
pub const EventType = types.EventType;
pub const Token = types.Token;
pub const TokenData = types.TokenData;
pub const TokenType = types.TokenType;
pub const Mark = types.Mark;
pub const Encoding = types.Encoding;
pub const ErrorType = types.ErrorType;
pub const ScalarStyle = types.ScalarStyle;
pub const SequenceStyle = types.SequenceStyle;
pub const MappingStyle = types.MappingStyle;
pub const TagDirective = types.TagDirective;
pub const VersionDirective = types.VersionDirective;
pub const Error = types.Error;

/// `yaml_parser_initialize`
pub const init = api.init;

/// `yaml_parser_delete`
pub const deinit = api.deinit;

/// `yaml_parser_set_input_string`. The input must outlive the parser.
pub const setInputString = api.setInputString;

/// `yaml_parser_parse`: produce the next event.
///
/// The C returns 0 on failure and leaves the reason in the parser; this returns
/// the error and does the same. An `error.OutOfMemory` is recorded as
/// `err = .memory` before it propagates, so a caller that only inspects the
/// parser sees exactly what libyaml would have left behind.
pub fn parse(p: *Parser, event: *Event) Error!void {
    return parser_impl.parse(p, event) catch |e| {
        if (e == error.OutOfMemory) p.err = .memory;
        return e;
    };
}

test {
    std.testing.refAllDecls(@This());
}
