//! Parser lifecycle: `yaml_parser_initialize`, `yaml_parser_delete` and
//! `yaml_parser_set_input_string` from libyaml's `src/api.c`.
//!
//! The allocation helpers those functions lean on (`yaml_string_extend`,
//! `yaml_stack_extend`, `yaml_queue_extend`) live in `mem.zig`; the token and
//! event destructors are methods on `Token` / `Event` in `types.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = @import("mem.zig");
const types = @import("types.zig");

const Parser = types.Parser;

/// `yaml_parser_initialize`.
///
/// Unlike the C, the buffers and stacks are allocated up front and the whole
/// object is returned by value; a failure part-way through unwinds through
/// `errdefer` rather than the C's shared `error:` label.
pub fn init(alloc: Allocator) Allocator.Error!Parser {
    var p: Parser = .{ .alloc = alloc };
    errdefer deinit(&p);

    p.raw_buffer = try mem.Buffer.init(alloc, mem.INPUT_RAW_BUFFER_SIZE);
    p.buffer = try mem.Buffer.init(alloc, mem.INPUT_BUFFER_SIZE);
    p.tokens = try types.Queue(types.Token).init(alloc, mem.INITIAL_QUEUE_SIZE);
    p.indents = try types.Stack(i32).init(alloc, mem.INITIAL_STACK_SIZE);
    p.simple_keys = try types.Stack(types.SimpleKey).init(alloc, mem.INITIAL_STACK_SIZE);
    p.states = try types.Stack(types.ParserState).init(alloc, mem.INITIAL_STACK_SIZE);
    p.marks = try types.Stack(types.Mark).init(alloc, mem.INITIAL_STACK_SIZE);
    p.tag_directives = try types.Stack(types.TagDirective).init(alloc, mem.INITIAL_STACK_SIZE);
    p.scratch_leading_break = try mem.String.init(alloc, mem.INITIAL_STRING_SIZE);
    p.scratch_trailing_breaks = try mem.String.init(alloc, mem.INITIAL_STRING_SIZE);
    p.scratch_whitespaces = try mem.String.init(alloc, mem.INITIAL_STRING_SIZE);

    return p;
}

/// `yaml_parser_delete`. Safe to call on a partly initialised parser.
pub fn deinit(p: *Parser) void {
    const alloc = p.alloc;

    p.raw_buffer.deinit(alloc);
    p.buffer.deinit(alloc);

    while (!p.tokens.isEmpty()) {
        var token = p.tokens.dequeue();
        token.deinit(alloc);
    }
    p.tokens.deinit(alloc);

    p.indents.deinit(alloc);
    p.simple_keys.deinit(alloc);
    p.states.deinit(alloc);
    p.marks.deinit(alloc);

    while (!p.tag_directives.isEmpty()) {
        var td = p.tag_directives.pop();
        td.deinit(alloc);
    }
    p.tag_directives.deinit(alloc);
    p.scratch_leading_break.deinit(alloc);
    p.scratch_trailing_breaks.deinit(alloc);
    p.scratch_whitespaces.deinit(alloc);

    p.* = .{ .alloc = alloc };
}

/// `yaml_parser_set_input_string`. The input must outlive the parser.
pub fn setInputString(p: *Parser, input: []const u8) void {
    std.debug.assert(p.read_handler == null); // the source can only be set once
    p.read_handler = stringReadHandler;
    p.input = input;
    p.input_pos = 0;
}

/// `yaml_string_read_handler`
fn stringReadHandler(p: *Parser, buf: []u8, size_read: *usize) bool {
    const remaining = p.input.len - p.input_pos;
    if (remaining == 0) {
        size_read.* = 0;
        return true;
    }
    const n = @min(buf.len, remaining);
    @memcpy(buf[0..n], p.input[p.input_pos..][0..n]);
    p.input_pos += n;
    size_read.* = n;
    return true;
}
