//! Types for the libyaml port: the enums from `include/yaml.h`, the token and
//! event records, and `Parser` itself (`yaml_parser_t`) with the scanner's
//! cursor macros as methods.
//!
//! # How the C maps onto this file
//!
//! | C                                          | Zig                                        |
//! | ------------------------------------------ | ------------------------------------------ |
//! | `int f(...)` — 1 ok / 0 fail               | `fn f(...) Error!void`                     |
//! | `if (!f(...)) return 0;`                   | `try f(...);`                              |
//! | `return 1;`                                | `return;`                                  |
//! | `return 0;` (after setting an error)       | `return error.Yaml;`                       |
//! | `goto error;` + cleanup                    | `errdefer` on the owning local             |
//! | `token->type == YAML_KEY_TOKEN`            | `token.data == .key`                       |
//! | `token->data.scalar.length`                | `token.data.scalar.value.len`              |
//! | `parser->buffer` predicates (`IS_*`)       | `parser.isBlankz()`, `parser.check('-')`   |
//! | `CACHE(parser, n)`                         | `try parser.cache(n)`                      |
//! | `SKIP(parser)` / `SKIP_LINE(parser)`       | `parser.skip()` / `parser.skipLine()`      |
//! | `READ(parser, s)` / `READ_LINE(parser, s)` | `try parser.read(&s)` / `readLine(&s)`     |
//! | `PUSH(parser, stack, v)`                   | `try stack.push(parser.alloc, v)`          |
//! | `STACK_LIMIT(parser, stack, n)`            | `stack.underLimit(n)`                      |
//!
//! # Deliberate deviations from libyaml
//!
//! - **String input only.** `yaml_parser_set_input_file` and the generic
//!   read-handler entry point are not ported: md4x hands the parser a byte
//!   slice, and the wasm build has no filesystem. The read-handler indirection
//!   itself is kept, because `reader.zig` is a 1:1 port of `src/reader.c`.
//! - **`MAX_NESTING_LEVEL` is a parser field, not a process-global.** Upstream
//!   spells it as a mutable global with a non-thread-safe setter
//!   (`yaml_set_max_nest_level`). Here it is `Parser.max_nest_level`, so two
//!   parsers on two threads cannot fight over it.
//! - **No document/alias state.** `parser->document` and `parser->aliases`
//!   belong to `src/loader.c`, which is not ported — md4x consumes events, and
//!   never composes a document tree.
//! - **Scalar values are sentinel slices.** A YAML scalar may legally contain
//!   NUL, so libyaml carries an explicit `length` beside the pointer. A
//!   `[:0]u8` carries the exact length in `.len` AND keeps the terminator the
//!   C-shaped consumers want, so the separate field is dropped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = @import("mem.zig");
const chars = @import("chars.zig");

pub const Buffer = mem.Buffer;
pub const String = mem.String;
pub const Stack = mem.Stack;
pub const Queue = mem.Queue;

/// Every failure path in the port.
///
/// `error.Yaml` means a reader/scanner/parser error was recorded on the parser
/// (`err`, `problem`, `problem_mark`) — the C's `return 0` after a
/// `set_*_error` call. `error.OutOfMemory` is the C's `YAML_MEMORY_ERROR`; the
/// public entry point stamps `err = .memory` when it catches one, so callers
/// see the same parser state either way.
pub const Error = error{Yaml} || Allocator.Error;

// ---- Enums (include/yaml.h) ----

pub const Encoding = enum(u8) { any, utf8, utf16le, utf16be };

pub const ErrorType = enum(u8) { none, memory, reader, scanner, parser, composer, writer, emitter };

pub const ScalarStyle = enum(u8) { any, plain, single_quoted, double_quoted, literal, folded };

pub const SequenceStyle = enum(u8) { any, block, flow };

pub const MappingStyle = enum(u8) { any, block, flow };

pub const TokenType = enum(u8) {
    none,
    stream_start,
    stream_end,
    version_directive,
    tag_directive,
    document_start,
    document_end,
    block_sequence_start,
    block_mapping_start,
    block_end,
    flow_sequence_start,
    flow_sequence_end,
    flow_mapping_start,
    flow_mapping_end,
    block_entry,
    flow_entry,
    key,
    value,
    alias,
    anchor,
    tag,
    scalar,
};

pub const EventType = enum(u8) {
    none,
    stream_start,
    stream_end,
    document_start,
    document_end,
    alias,
    scalar,
    sequence_start,
    sequence_end,
    mapping_start,
    mapping_end,
};

pub const ParserState = enum(u8) {
    stream_start,
    implicit_document_start,
    document_start,
    document_content,
    document_end,
    block_node,
    block_node_or_indentless_sequence,
    flow_node,
    block_sequence_first_entry,
    block_sequence_entry,
    indentless_sequence_entry,
    block_mapping_first_key,
    block_mapping_key,
    block_mapping_value,
    flow_sequence_first_entry,
    flow_sequence_entry,
    flow_sequence_entry_mapping_key,
    flow_sequence_entry_mapping_value,
    flow_sequence_entry_mapping_end,
    flow_mapping_first_key,
    flow_mapping_key,
    flow_mapping_value,
    flow_mapping_empty_value,
    end,
};

// ---- Records ----

/// `yaml_mark_t`
pub const Mark = struct {
    index: usize = 0,
    line: usize = 0,
    column: usize = 0,
};

/// `yaml_version_directive_t`
pub const VersionDirective = struct {
    major: i32,
    minor: i32,
};

/// `yaml_tag_directive_t` — both strings are owned.
pub const TagDirective = struct {
    handle: [:0]u8,
    prefix: [:0]u8,

    pub fn deinit(self: *TagDirective, alloc: Allocator) void {
        alloc.free(self.handle);
        alloc.free(self.prefix);
    }
};

/// `yaml_simple_key_t`
pub const SimpleKey = struct {
    possible: bool = false,
    required: bool = false,
    token_number: usize = 0,
    mark: Mark = .{},
};

/// `yaml_token_t`. The C's `type` field is this union's tag: write
/// `token.data == .key` where the C writes `token->type == YAML_KEY_TOKEN`.
pub const Token = struct {
    data: TokenData = .none,
    start_mark: Mark = .{},
    end_mark: Mark = .{},

    pub fn getType(self: *const Token) TokenType {
        return self.data;
    }

    /// `yaml_token_delete`
    pub fn deinit(self: *Token, alloc: Allocator) void {
        switch (self.data) {
            .tag_directive => |*d| {
                alloc.free(d.handle);
                alloc.free(d.prefix);
            },
            .alias => |*d| alloc.free(d.value),
            .anchor => |*d| alloc.free(d.value),
            .tag => |*d| {
                alloc.free(d.handle);
                alloc.free(d.suffix);
            },
            .scalar => |*d| alloc.free(d.value),
            else => {},
        }
        self.* = .{};
    }
};

pub const TokenData = union(TokenType) {
    none,
    stream_start: struct { encoding: Encoding },
    stream_end,
    version_directive: struct { major: i32, minor: i32 },
    tag_directive: struct { handle: [:0]u8, prefix: [:0]u8 },
    document_start,
    document_end,
    block_sequence_start,
    block_mapping_start,
    block_end,
    flow_sequence_start,
    flow_sequence_end,
    flow_mapping_start,
    flow_mapping_end,
    block_entry,
    flow_entry,
    key,
    value,
    alias: struct { value: [:0]u8 },
    anchor: struct { value: [:0]u8 },
    tag: struct { handle: [:0]u8, suffix: [:0]u8 },
    scalar: struct { value: [:0]u8, style: ScalarStyle },
};

/// `yaml_event_t`. As with `Token`, the C's `type` field is the union tag.
pub const Event = struct {
    data: EventData = .none,
    start_mark: Mark = .{},
    end_mark: Mark = .{},

    pub fn getType(self: *const Event) EventType {
        return self.data;
    }

    /// `yaml_event_delete`
    pub fn deinit(self: *Event, alloc: Allocator) void {
        switch (self.data) {
            .document_start => |*d| {
                if (d.version_directive) |vd| alloc.destroy(vd);
                for (d.tag_directives) |*td| td.deinit(alloc);
                if (d.tag_directives.len != 0) alloc.free(d.tag_directives);
            },
            .alias => |*d| alloc.free(d.anchor),
            .scalar => |*d| {
                if (d.anchor) |a| alloc.free(a);
                if (d.tag) |t| alloc.free(t);
                alloc.free(d.value);
            },
            .sequence_start => |*d| {
                if (d.anchor) |a| alloc.free(a);
                if (d.tag) |t| alloc.free(t);
            },
            .mapping_start => |*d| {
                if (d.anchor) |a| alloc.free(a);
                if (d.tag) |t| alloc.free(t);
            },
            else => {},
        }
        self.* = .{};
    }
};

pub const EventData = union(EventType) {
    none,
    stream_start: struct { encoding: Encoding },
    stream_end,
    document_start: struct {
        version_directive: ?*VersionDirective,
        /// Owned; empty when the document declared no `%TAG`.
        tag_directives: []TagDirective,
        implicit: bool,
    },
    document_end: struct { implicit: bool },
    alias: struct { anchor: [:0]u8 },
    scalar: struct {
        anchor: ?[:0]u8,
        tag: ?[:0]u8,
        value: [:0]u8,
        plain_implicit: bool,
        quoted_implicit: bool,
        style: ScalarStyle,
    },
    sequence_start: struct {
        anchor: ?[:0]u8,
        tag: ?[:0]u8,
        implicit: bool,
        style: SequenceStyle,
    },
    sequence_end,
    mapping_start: struct {
        anchor: ?[:0]u8,
        tag: ?[:0]u8,
        implicit: bool,
        style: MappingStyle,
    },
    mapping_end,
};

/// `yaml_read_handler_t`: fill `buf`, report how much was written through
/// `size_read`, and return false only on a genuine read failure (end of input
/// is `size_read.* == 0` with a true return).
pub const ReadHandler = *const fn (parser: *Parser, buf: []u8, size_read: *usize) bool;

// ---- Parser ----

/// `yaml_parser_t`.
pub const Parser = struct {
    /// Every allocation in the port goes through this (.agents/conventions.md
    /// — no `std.c.malloc`), so the OOM sweep can inject failure everywhere.
    alloc: Allocator,

    // Error handling
    err: ErrorType = .none,
    problem: ?[]const u8 = null,
    problem_offset: usize = 0,
    problem_value: i32 = -1,
    problem_mark: Mark = .{},
    context: ?[]const u8 = null,
    context_mark: Mark = .{},

    // Reader stuff
    read_handler: ?ReadHandler = null,
    /// The whole string input and how much of it the handler has consumed.
    input: []const u8 = &.{},
    input_pos: usize = 0,
    eof: bool = false,
    buffer: Buffer = .{},
    unread: usize = 0,
    raw_buffer: Buffer = .{},
    encoding: Encoding = .any,
    offset: usize = 0,
    mark: Mark = .{},

    // Scanner stuff
    stream_start_produced: bool = false,
    stream_end_produced: bool = false,
    flow_level: i32 = 0,
    tokens: Queue(Token) = .empty,
    tokens_parsed: usize = 0,
    token_available: bool = false,
    indents: Stack(i32) = .empty,
    indent: i32 = -1,
    simple_key_allowed: bool = false,
    simple_keys: Stack(SimpleKey) = .empty,

    // Parser stuff
    states: Stack(ParserState) = .empty,
    state: ParserState = .stream_start,
    marks: Stack(Mark) = .empty,
    tag_directives: Stack(TagDirective) = .empty,

    /// Upstream's `MAX_NESTING_LEVEL` (default 1000), moved off the process
    /// global. Each nesting level costs a stack entry and one more entry for
    /// every per-token sweep over `simple_keys`, so this is what bounds
    /// libyaml's quadratic flow-collection behaviour.
    max_nest_level: i32 = 1000,

    // ---- Error reporting ----

    /// `yaml_parser_set_reader_error`
    pub fn setReaderError(self: *Parser, problem: []const u8, offset: usize, value: i32) Error {
        self.err = .reader;
        self.problem = problem;
        self.problem_offset = offset;
        self.problem_value = value;
        return error.Yaml;
    }

    /// `yaml_parser_set_scanner_error`
    pub fn setScannerError(self: *Parser, context: ?[]const u8, context_mark: Mark, problem: []const u8) Error {
        self.err = .scanner;
        self.context = context;
        self.context_mark = context_mark;
        self.problem = problem;
        self.problem_mark = self.mark;
        return error.Yaml;
    }

    /// `yaml_parser_set_parser_error`
    pub fn setParserError(self: *Parser, problem: []const u8, problem_mark: Mark) Error {
        self.err = .parser;
        self.problem = problem;
        self.problem_mark = problem_mark;
        return error.Yaml;
    }

    /// `yaml_parser_set_parser_error_context`
    pub fn setParserErrorContext(
        self: *Parser,
        context: []const u8,
        context_mark: Mark,
        problem: []const u8,
        problem_mark: Mark,
    ) Error {
        self.err = .parser;
        self.context = context;
        self.context_mark = context_mark;
        self.problem = problem;
        self.problem_mark = problem_mark;
        return error.Yaml;
    }

    // ---- Cursor macros (src/scanner.c) ----

    /// `CACHE(parser, length)`: make sure at least `length` characters are
    /// decoded and available at the cursor.
    ///
    /// `inline` here is load-bearing, and is the one exception to the "let LLVM
    /// decide" rule the rest of these wrappers follow. The C is a macro whose
    /// hot half is a single compare; leaving this a call let LLVM inline the
    /// COLD half — the whole of `updateBuffer` — into this function instead,
    /// which made the result too big to inline into the ~11M call sites a parse
    /// makes. `updateBuffer` is `noinline` for the same reason, from the other
    /// side. Splitting them this way was worth 10% of a parse and cost 711
    /// bytes of wasm; folding them back together undoes both.
    pub inline fn cache(self: *Parser, length: usize) Error!void {
        if (self.unread >= length) return;
        return @import("reader.zig").updateBuffer(self, length);
    }

    /// `SKIP(parser)`: step over one character.
    pub fn skip(self: *Parser) void {
        self.mark.index += 1;
        self.mark.column += 1;
        self.unread -= 1;
        self.buffer.pos += chars.width(&self.buffer);
    }

    /// `SKIP_LINE(parser)`: step over one line break, whatever its spelling.
    pub fn skipLine(self: *Parser) void {
        if (chars.isCrlf(&self.buffer)) {
            self.mark.index += 2;
            self.mark.column = 0;
            self.mark.line += 1;
            self.unread -= 2;
            self.buffer.pos += 2;
        } else if (chars.isBreak(&self.buffer)) {
            self.mark.index += 1;
            self.mark.column = 0;
            self.mark.line += 1;
            self.unread -= 1;
            self.buffer.pos += chars.width(&self.buffer);
        }
    }

    /// `READ(parser, string)`: copy one character into `s` and step over it.
    pub fn read(self: *Parser, s: *String) Error!void {
        try s.extend(self.alloc);
        const w = chars.width(&self.buffer);
        var i: usize = 0;
        while (i < w) : (i += 1) s.putAssumeCapacity(self.buffer.at(i));
        self.buffer.pos += w;
        self.mark.index += 1;
        self.mark.column += 1;
        self.unread -= 1;
    }

    /// `READ_LINE(parser, string)`: copy one line break into `s`, normalising
    /// CR, CRLF and NEL to LF while leaving LS and PS as they are.
    pub fn readLine(self: *Parser, s: *String) Error!void {
        try s.extend(self.alloc);
        const b = &self.buffer;
        if (chars.checkAt(b, '\r', 0) and chars.checkAt(b, '\n', 1)) {
            // CR LF -> LF
            s.putAssumeCapacity('\n');
            b.pos += 2;
            self.mark.index += 2;
            self.mark.column = 0;
            self.mark.line += 1;
            self.unread -= 2;
        } else if (chars.checkAt(b, '\r', 0) or chars.checkAt(b, '\n', 0)) {
            // CR|LF -> LF
            s.putAssumeCapacity('\n');
            b.pos += 1;
            self.mark.index += 1;
            self.mark.column = 0;
            self.mark.line += 1;
            self.unread -= 1;
        } else if (chars.checkAt(b, 0xC2, 0) and chars.checkAt(b, 0x85, 1)) {
            // NEL -> LF
            s.putAssumeCapacity('\n');
            b.pos += 2;
            self.mark.index += 1;
            self.mark.column = 0;
            self.mark.line += 1;
            self.unread -= 1;
        } else if (chars.checkAt(b, 0xE2, 0) and chars.checkAt(b, 0x80, 1) and
            (chars.checkAt(b, 0xA8, 2) or chars.checkAt(b, 0xA9, 2)))
        {
            // LS|PS -> LS|PS
            s.putAssumeCapacity(b.at(0));
            s.putAssumeCapacity(b.at(1));
            s.putAssumeCapacity(b.at(2));
            b.pos += 3;
            self.mark.index += 1;
            self.mark.column = 0;
            self.mark.line += 1;
            self.unread -= 1;
        }
    }

    // ---- Character predicates over the cursor ----

    pub fn check(self: *const Parser, octet: u8) bool {
        return chars.check(&self.buffer, octet);
    }
    pub fn checkAt(self: *const Parser, octet: u8, offset: usize) bool {
        return chars.checkAt(&self.buffer, octet, offset);
    }
    pub fn isAlpha(self: *const Parser) bool {
        return chars.isAlpha(&self.buffer);
    }
    pub fn isAlphaAt(self: *const Parser, offset: usize) bool {
        return chars.isAlphaAt(&self.buffer, offset);
    }
    pub fn isDigit(self: *const Parser) bool {
        return chars.isDigit(&self.buffer);
    }
    pub fn isDigitAt(self: *const Parser, offset: usize) bool {
        return chars.isDigitAt(&self.buffer, offset);
    }
    pub fn asDigit(self: *const Parser) u8 {
        return chars.asDigit(&self.buffer);
    }
    pub fn isHex(self: *const Parser) bool {
        return chars.isHex(&self.buffer);
    }
    pub fn isHexAt(self: *const Parser, offset: usize) bool {
        return chars.isHexAt(&self.buffer, offset);
    }
    pub fn asHexAt(self: *const Parser, offset: usize) u8 {
        return chars.asHexAt(&self.buffer, offset);
    }
    pub fn isAscii(self: *const Parser) bool {
        return chars.isAscii(&self.buffer);
    }
    pub fn isPrintable(self: *const Parser) bool {
        return chars.isPrintable(&self.buffer);
    }
    pub fn isZ(self: *const Parser) bool {
        return chars.isZ(&self.buffer);
    }
    pub fn isZAt(self: *const Parser, offset: usize) bool {
        return chars.isZAt(&self.buffer, offset);
    }
    pub fn isBom(self: *const Parser) bool {
        return chars.isBom(&self.buffer);
    }
    pub fn isSpace(self: *const Parser) bool {
        return chars.isSpace(&self.buffer);
    }
    pub fn isSpaceAt(self: *const Parser, offset: usize) bool {
        return chars.isSpaceAt(&self.buffer, offset);
    }
    pub fn isTab(self: *const Parser) bool {
        return chars.isTab(&self.buffer);
    }
    pub fn isBlank(self: *const Parser) bool {
        return chars.isBlank(&self.buffer);
    }
    pub fn isBlankAt(self: *const Parser, offset: usize) bool {
        return chars.isBlankAt(&self.buffer, offset);
    }
    pub fn isBreak(self: *const Parser) bool {
        return chars.isBreak(&self.buffer);
    }
    pub fn isBreakAt(self: *const Parser, offset: usize) bool {
        return chars.isBreakAt(&self.buffer, offset);
    }
    pub fn isCrlf(self: *const Parser) bool {
        return chars.isCrlf(&self.buffer);
    }
    pub fn isBreakz(self: *const Parser) bool {
        return chars.isBreakz(&self.buffer);
    }
    pub fn isBreakzAt(self: *const Parser, offset: usize) bool {
        return chars.isBreakzAt(&self.buffer, offset);
    }
    pub fn isSpacez(self: *const Parser) bool {
        return chars.isSpacez(&self.buffer);
    }
    pub fn isBlankz(self: *const Parser) bool {
        return chars.isBlankz(&self.buffer);
    }
    pub fn isBlankzAt(self: *const Parser, offset: usize) bool {
        return chars.isBlankzAt(&self.buffer, offset);
    }
    pub fn width(self: *const Parser) usize {
        return chars.width(&self.buffer);
    }
};
