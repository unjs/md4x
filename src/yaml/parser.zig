//! Port of libyaml's `src/parser.c`: the event state machine that turns the
//! scanner's token stream into the event stream `yaml_parser_parse` hands out.
//!
//! The grammar it implements, verbatim from the C's header comment:
//!
//!     stream               ::= STREAM-START implicit_document? explicit_document* STREAM-END
//!     implicit_document    ::= block_node DOCUMENT-END*
//!     explicit_document    ::= DIRECTIVE* DOCUMENT-START block_node? DOCUMENT-END*
//!     block_node_or_indentless_sequence    ::=
//!                              ALIAS
//!                              | properties (block_content | indentless_block_sequence)?
//!                              | block_content
//!                              | indentless_block_sequence
//!     block_node           ::= ALIAS | properties block_content? | block_content
//!     flow_node            ::= ALIAS | properties flow_content? | flow_content
//!     properties           ::= TAG ANCHOR? | ANCHOR TAG?
//!     block_content        ::= block_collection | flow_collection | SCALAR
//!     flow_content         ::= flow_collection | SCALAR
//!     block_collection     ::= block_sequence | block_mapping
//!     flow_collection      ::= flow_sequence | flow_mapping
//!     block_sequence       ::= BLOCK-SEQUENCE-START (BLOCK-ENTRY block_node?)* BLOCK-END
//!     indentless_sequence  ::= (BLOCK-ENTRY block_node?)+
//!     block_mapping        ::= BLOCK-MAPPING_START
//!                              ((KEY block_node_or_indentless_sequence?)?
//!                              (VALUE block_node_or_indentless_sequence?)?)*
//!                              BLOCK-END
//!     flow_sequence        ::= FLOW-SEQUENCE-START
//!                              (flow_sequence_entry FLOW-ENTRY)*
//!                              flow_sequence_entry?
//!                              FLOW-SEQUENCE-END
//!     flow_sequence_entry  ::= flow_node | KEY flow_node? (VALUE flow_node?)?
//!     flow_mapping         ::= FLOW-MAPPING-START
//!                              (flow_mapping_entry FLOW-ENTRY)*
//!                              flow_mapping_entry?
//!                              FLOW-MAPPING-END
//!     flow_mapping_entry   ::= flow_node | KEY flow_node? (VALUE flow_node?)?
//!
//! # Ownership
//!
//! `SKIP_TOKEN` does NOT destroy the token it steps over: a state that consumes
//! a scalar/anchor/tag/alias token takes its owned strings into the event first,
//! and the queue slot is simply left behind. That is why every string this file
//! reads out of a token is moved, never copied, and why the error paths free
//! exactly what they took (the C's `goto error` labels; `errdefer` here).
//!
//! The one exception is `%TAG`: `processDirectives` both COPIES the directive
//! into `parser.tag_directives` (which owns its copy until the document ends)
//! and MOVES the token's strings into the document-start event's own list.

const std = @import("std");
const mem = @import("mem.zig");
const types = @import("types.zig");
const scanner = @import("scanner.zig");

const Parser = types.Parser;
const Event = types.Event;
const Token = types.Token;
const Mark = types.Mark;
const Error = types.Error;
const TagDirective = types.TagDirective;
const VersionDirective = types.VersionDirective;

// ---- Token queue access (the PEEK_TOKEN / SKIP_TOKEN macros) ----

/// `PEEK_TOKEN(parser)`: the token at the head of the queue, fetching more when
/// none is available.
///
/// The C hands back `NULL` when `yaml_parser_fetch_more_tokens` fails, and every
/// caller answers that with `return 0`; here the failure propagates as the error
/// it already is, so the caller's `if (!token) return 0` disappears into `try`.
///
/// The returned pointer is into `parser.tokens`' allocation: it must NOT be held
/// across another `peekToken`, which can grow (and therefore move) the queue.
fn peekToken(p: *Parser) Error!*Token {
    if (!p.token_available) try scanner.fetchMoreTokens(p);
    return p.tokens.at(0);
}

/// `SKIP_TOKEN(parser)`: drop the head token (must follow a `peekToken`).
///
/// Note the head token is not deleted — see this file's header on ownership.
fn skipToken(p: *Parser) void {
    p.token_available = false;
    p.tokens_parsed += 1;
    p.stream_end_produced = p.tokens.at(0).data == .stream_end;
    _ = p.tokens.dequeue();
}

// ---- C-string views of owned strings ----

/// The `strlen` view of an owned string.
///
/// libyaml compares, measures and copies these with `strcmp` / `strlen` /
/// `yaml_strdup`, all of which stop at the first NUL. A tag URI may legally
/// contain one (`%00` survives `yaml_parser_scan_uri_escapes`), so measuring
/// these with the slice length instead would make the port disagree with the C
/// on exactly those inputs — the tag it builds would be longer.
inline fn cstr(s: [:0]const u8) [:0]const u8 {
    return std.mem.sliceTo(s, 0);
}

/// The C's `!*s`: empty by NUL terminator, not by slice length.
inline fn isEmptyCStr(s: [:0]const u8) bool {
    return s.len == 0 or s[0] == 0;
}

// ---- Public entry point ----

/// `yaml_parser_parse`: get the next event.
pub fn parse(p: *Parser, event: *Event) Error!void {
    // Erase the event object.

    event.* = .{};

    // No events after the end of the stream or error.

    if (p.stream_end_produced or p.err != .none or p.state == .end) {
        return;
    }

    // Generate the next event.

    return stateMachine(p, event);
}

/// The state dispatcher (`yaml_parser_state_machine`).
fn stateMachine(p: *Parser, event: *Event) Error!void {
    return switch (p.state) {
        .stream_start => parseStreamStart(p, event),
        .implicit_document_start => parseDocumentStart(p, event, true),
        .document_start => parseDocumentStart(p, event, false),
        .document_content => parseDocumentContent(p, event),
        .document_end => parseDocumentEnd(p, event),
        .block_node => parseNode(p, event, true, false),
        .block_node_or_indentless_sequence => parseNode(p, event, true, true),
        .flow_node => parseNode(p, event, false, false),
        .block_sequence_first_entry => parseBlockSequenceEntry(p, event, true),
        .block_sequence_entry => parseBlockSequenceEntry(p, event, false),
        .indentless_sequence_entry => parseIndentlessSequenceEntry(p, event),
        .block_mapping_first_key => parseBlockMappingKey(p, event, true),
        .block_mapping_key => parseBlockMappingKey(p, event, false),
        .block_mapping_value => parseBlockMappingValue(p, event),
        .flow_sequence_first_entry => parseFlowSequenceEntry(p, event, true),
        .flow_sequence_entry => parseFlowSequenceEntry(p, event, false),
        .flow_sequence_entry_mapping_key => parseFlowSequenceEntryMappingKey(p, event),
        .flow_sequence_entry_mapping_value => parseFlowSequenceEntryMappingValue(p, event),
        .flow_sequence_entry_mapping_end => parseFlowSequenceEntryMappingEnd(p, event),
        .flow_mapping_first_key => parseFlowMappingKey(p, event, true),
        .flow_mapping_key => parseFlowMappingKey(p, event, false),
        .flow_mapping_value => parseFlowMappingValue(p, event, false),
        .flow_mapping_empty_value => parseFlowMappingValue(p, event, true),
        // The C's `default:` arm — reached only for YAML_PARSE_END_STATE, which
        // `parse` above has already returned on. Upstream writes `assert(1)`
        // (a no-op) and returns failure without recording a reason.
        .end => unreachable,
    };
}

// ---- States ----

/// Parse the production:
///
///     stream   ::= STREAM-START implicit_document? explicit_document* STREAM-END
///                  ************
fn parseStreamStart(p: *Parser, event: *Event) Error!void {
    const token = try peekToken(p);

    if (token.data != .stream_start) {
        return p.setParserError("did not find expected <stream-start>", token.start_mark);
    }

    p.state = .implicit_document_start;
    event.* = .{
        .data = .{ .stream_start = .{ .encoding = token.data.stream_start.encoding } },
        .start_mark = token.start_mark,
        .end_mark = token.start_mark,
    };
    skipToken(p);
}

/// Parse the productions:
///
///     implicit_document    ::= block_node DOCUMENT-END*
///                              *
///     explicit_document    ::= DIRECTIVE* DOCUMENT-START block_node? DOCUMENT-END*
///                              *************************
fn parseDocumentStart(p: *Parser, event: *Event, implicit: bool) Error!void {
    var version_directive: ?*VersionDirective = null;
    var tag_directives: []TagDirective = &.{};
    // The C's `error:` label. Both locals are cleared once the event owns them,
    // exactly where the C nulls them after `DOCUMENT_START_EVENT_INIT`.
    errdefer {
        if (version_directive) |vd| p.alloc.destroy(vd);
        for (tag_directives) |*td| td.deinit(p.alloc);
        if (tag_directives.len != 0) p.alloc.free(tag_directives);
    }

    var token = try peekToken(p);

    // Parse extra document end indicators.

    if (!implicit) {
        while (token.data == .document_end) {
            skipToken(p);
            token = try peekToken(p);
        }
    }

    // Parse an implicit document.

    if (implicit and token.data != .version_directive and
        token.data != .tag_directive and token.data != .document_start and
        token.data != .stream_end)
    {
        try processDirectives(p, null);
        try p.states.push(p.alloc, .document_end);
        p.state = .block_node;
        event.* = .{
            .data = .{ .document_start = .{
                .version_directive = null,
                .tag_directives = &.{},
                .implicit = true,
            } },
            .start_mark = token.start_mark,
            .end_mark = token.start_mark,
        };
        return;
    }

    // Parse an explicit document.

    else if (token.data != .stream_end) {
        const start_mark = token.start_mark;
        var directives: Directives = .{};
        try processDirectives(p, &directives);
        version_directive = directives.version_directive;
        tag_directives = directives.tag_directives;
        token = try peekToken(p);
        if (token.data != .document_start) {
            return p.setParserError(
                "did not find expected <document start>",
                token.start_mark,
            );
        }
        try p.states.push(p.alloc, .document_end);
        p.state = .document_content;
        const end_mark = token.end_mark;
        event.* = .{
            .data = .{ .document_start = .{
                .version_directive = version_directive,
                .tag_directives = tag_directives,
                .implicit = false,
            } },
            .start_mark = start_mark,
            .end_mark = end_mark,
        };
        skipToken(p);
        version_directive = null;
        tag_directives = &.{};
        return;
    }

    // Parse the stream end.

    else {
        p.state = .end;
        event.* = .{
            .data = .stream_end,
            .start_mark = token.start_mark,
            .end_mark = token.end_mark,
        };
        skipToken(p);
        return;
    }
}

/// Parse the productions:
///
///     explicit_document    ::= DIRECTIVE* DOCUMENT-START block_node? DOCUMENT-END*
///                                                        ***********
fn parseDocumentContent(p: *Parser, event: *Event) Error!void {
    const token = try peekToken(p);

    if (token.data == .version_directive or token.data == .tag_directive or
        token.data == .document_start or token.data == .document_end or
        token.data == .stream_end)
    {
        p.state = p.states.pop();
        return processEmptyScalar(p, event, token.start_mark);
    } else {
        return parseNode(p, event, true, false);
    }
}

/// Parse the productions:
///
///     implicit_document    ::= block_node DOCUMENT-END*
///                                         *************
///     explicit_document    ::= DIRECTIVE* DOCUMENT-START block_node? DOCUMENT-END*
///                                                                    *************
fn parseDocumentEnd(p: *Parser, event: *Event) Error!void {
    var implicit = true;

    const token = try peekToken(p);

    const start_mark = token.start_mark;
    var end_mark = token.start_mark;

    if (token.data == .document_end) {
        end_mark = token.end_mark;
        skipToken(p);
        implicit = false;
    }

    while (!p.tag_directives.isEmpty()) {
        var tag_directive = p.tag_directives.pop();
        tag_directive.deinit(p.alloc);
    }

    p.state = .document_start;
    event.* = .{
        .data = .{ .document_end = .{ .implicit = implicit } },
        .start_mark = start_mark,
        .end_mark = end_mark,
    };
}

/// Parse the productions:
///
///     block_node_or_indentless_sequence    ::=
///                              ALIAS
///                              *****
///                              | properties (block_content | indentless_block_sequence)?
///                                **********  *
///                              | block_content | indentless_block_sequence
///                                *
///     block_node           ::= ALIAS
///                              *****
///                              | properties block_content?
///                                ********** *
///                              | block_content
///                                *
///     flow_node            ::= ALIAS
///                              *****
///                              | properties flow_content?
///                                ********** *
///                              | flow_content
///                                *
///     properties           ::= TAG ANCHOR? | ANCHOR TAG?
///                              *************************
///     block_content        ::= block_collection | flow_collection | SCALAR
///                                                                   ******
///     flow_content         ::= flow_collection | SCALAR
///                                                ******
fn parseNode(p: *Parser, event: *Event, block: bool, indentless_sequence: bool) Error!void {
    var anchor: ?[:0]u8 = null;
    var tag_handle: ?[:0]u8 = null;
    var tag_suffix: ?[:0]u8 = null;
    var tag: ?[:0]u8 = null;
    // The C leaves `tag_mark` uninitialised and only reads it on the path that
    // saw a TAG token; a zero mark keeps that read defined here.
    var tag_mark: Mark = .{};
    // The C's `error:` label.
    errdefer {
        if (anchor) |v| p.alloc.free(v);
        if (tag_handle) |v| p.alloc.free(v);
        if (tag_suffix) |v| p.alloc.free(v);
        if (tag) |v| p.alloc.free(v);
    }

    var token = try peekToken(p);

    if (token.data == .alias) {
        p.state = p.states.pop();
        event.* = .{
            .data = .{ .alias = .{ .anchor = token.data.alias.value } },
            .start_mark = token.start_mark,
            .end_mark = token.end_mark,
        };
        skipToken(p);
        return;
    }

    const start_mark = token.start_mark;
    var end_mark = token.start_mark;

    if (token.data == .anchor) {
        anchor = token.data.anchor.value;
        end_mark = token.end_mark;
        skipToken(p);
        token = try peekToken(p);
        if (token.data == .tag) {
            tag_handle = token.data.tag.handle;
            tag_suffix = token.data.tag.suffix;
            tag_mark = token.start_mark;
            end_mark = token.end_mark;
            skipToken(p);
            token = try peekToken(p);
        }
    } else if (token.data == .tag) {
        tag_handle = token.data.tag.handle;
        tag_suffix = token.data.tag.suffix;
        tag_mark = token.start_mark;
        end_mark = token.end_mark;
        skipToken(p);
        token = try peekToken(p);
        if (token.data == .anchor) {
            anchor = token.data.anchor.value;
            end_mark = token.end_mark;
            skipToken(p);
            token = try peekToken(p);
        }
    }

    if (tag_handle) |handle| {
        if (isEmptyCStr(handle)) {
            tag = tag_suffix;
            p.alloc.free(handle);
            tag_handle = null;
            tag_suffix = null;
        } else {
            for (p.tag_directives.slice()) |*tag_directive| {
                if (std.mem.eql(u8, cstr(tag_directive.handle), cstr(handle))) {
                    const prefix = cstr(tag_directive.prefix);
                    const suffix = cstr(tag_suffix.?);
                    const joined = try p.alloc.allocSentinel(u8, prefix.len + suffix.len, 0);
                    @memcpy(joined[0..prefix.len], prefix);
                    @memcpy(joined[prefix.len..], suffix);
                    tag = joined;
                    p.alloc.free(handle);
                    p.alloc.free(tag_suffix.?);
                    tag_handle = null;
                    tag_suffix = null;
                    break;
                }
            }
            if (tag == null) {
                return p.setParserErrorContext(
                    "while parsing a node",
                    start_mark,
                    "found undefined tag handle",
                    tag_mark,
                );
            }
        }
    }

    const implicit = tag == null or isEmptyCStr(tag.?);

    if (indentless_sequence and token.data == .block_entry) {
        end_mark = token.end_mark;
        p.state = .indentless_sequence_entry;
        event.* = .{
            .data = .{ .sequence_start = .{
                .anchor = anchor,
                .tag = tag,
                .implicit = implicit,
                .style = .block,
            } },
            .start_mark = start_mark,
            .end_mark = end_mark,
        };
        return;
    } else {
        if (token.data == .scalar) {
            var plain_implicit = false;
            var quoted_implicit = false;
            end_mark = token.end_mark;
            if ((token.data.scalar.style == .plain and tag == null) or
                (tag != null and std.mem.eql(u8, cstr(tag.?), "!")))
            {
                plain_implicit = true;
            } else if (tag == null) {
                quoted_implicit = true;
            }
            p.state = p.states.pop();
            event.* = .{
                .data = .{ .scalar = .{
                    .anchor = anchor,
                    .tag = tag,
                    .value = token.data.scalar.value,
                    .plain_implicit = plain_implicit,
                    .quoted_implicit = quoted_implicit,
                    .style = token.data.scalar.style,
                } },
                .start_mark = start_mark,
                .end_mark = end_mark,
            };
            skipToken(p);
            return;
        } else if (token.data == .flow_sequence_start) {
            end_mark = token.end_mark;
            p.state = .flow_sequence_first_entry;
            event.* = .{
                .data = .{ .sequence_start = .{
                    .anchor = anchor,
                    .tag = tag,
                    .implicit = implicit,
                    .style = .flow,
                } },
                .start_mark = start_mark,
                .end_mark = end_mark,
            };
            return;
        } else if (token.data == .flow_mapping_start) {
            end_mark = token.end_mark;
            p.state = .flow_mapping_first_key;
            event.* = .{
                .data = .{ .mapping_start = .{
                    .anchor = anchor,
                    .tag = tag,
                    .implicit = implicit,
                    .style = .flow,
                } },
                .start_mark = start_mark,
                .end_mark = end_mark,
            };
            return;
        } else if (block and token.data == .block_sequence_start) {
            end_mark = token.end_mark;
            p.state = .block_sequence_first_entry;
            event.* = .{
                .data = .{ .sequence_start = .{
                    .anchor = anchor,
                    .tag = tag,
                    .implicit = implicit,
                    .style = .block,
                } },
                .start_mark = start_mark,
                .end_mark = end_mark,
            };
            return;
        } else if (block and token.data == .block_mapping_start) {
            end_mark = token.end_mark;
            p.state = .block_mapping_first_key;
            event.* = .{
                .data = .{ .mapping_start = .{
                    .anchor = anchor,
                    .tag = tag,
                    .implicit = implicit,
                    .style = .block,
                } },
                .start_mark = start_mark,
                .end_mark = end_mark,
            };
            return;
        } else if (anchor != null or tag != null) {
            // The C's `YAML_MALLOC(1); value[0] = '\0'` — a zero-length
            // sentinel slice is the same one owned byte.
            const value = try p.alloc.allocSentinel(u8, 0, 0);
            p.state = p.states.pop();
            event.* = .{
                .data = .{ .scalar = .{
                    .anchor = anchor,
                    .tag = tag,
                    .value = value,
                    .plain_implicit = implicit,
                    .quoted_implicit = false,
                    .style = .plain,
                } },
                .start_mark = start_mark,
                .end_mark = end_mark,
            };
            return;
        } else {
            return p.setParserErrorContext(
                if (block) "while parsing a block node" else "while parsing a flow node",
                start_mark,
                "did not find expected node content",
                token.start_mark,
            );
        }
    }
}

/// Parse the productions:
///
///     block_sequence ::= BLOCK-SEQUENCE-START (BLOCK-ENTRY block_node?)* BLOCK-END
///                        ********************  *********** *             *********
fn parseBlockSequenceEntry(p: *Parser, event: *Event, first: bool) Error!void {
    var token: *Token = undefined;

    if (first) {
        token = try peekToken(p);
        try p.marks.push(p.alloc, token.start_mark);
        skipToken(p);
    }

    token = try peekToken(p);

    if (token.data == .block_entry) {
        const mark = token.end_mark;
        skipToken(p);
        token = try peekToken(p);
        if (token.data != .block_entry and token.data != .block_end) {
            try p.states.push(p.alloc, .block_sequence_entry);
            return parseNode(p, event, true, false);
        } else {
            p.state = .block_sequence_entry;
            return processEmptyScalar(p, event, mark);
        }
    } else if (token.data == .block_end) {
        p.state = p.states.pop();
        _ = p.marks.pop();
        event.* = .{
            .data = .sequence_end,
            .start_mark = token.start_mark,
            .end_mark = token.end_mark,
        };
        skipToken(p);
        return;
    } else {
        return p.setParserErrorContext(
            "while parsing a block collection",
            p.marks.pop(),
            "did not find expected '-' indicator",
            token.start_mark,
        );
    }
}

/// Parse the productions:
///
///     indentless_sequence  ::= (BLOCK-ENTRY block_node?)+
///                               *********** *
fn parseIndentlessSequenceEntry(p: *Parser, event: *Event) Error!void {
    var token = try peekToken(p);

    if (token.data == .block_entry) {
        const mark = token.end_mark;
        skipToken(p);
        token = try peekToken(p);
        if (token.data != .block_entry and token.data != .key and
            token.data != .value and token.data != .block_end)
        {
            try p.states.push(p.alloc, .indentless_sequence_entry);
            return parseNode(p, event, true, false);
        } else {
            p.state = .indentless_sequence_entry;
            return processEmptyScalar(p, event, mark);
        }
    } else {
        p.state = p.states.pop();
        event.* = .{
            .data = .sequence_end,
            .start_mark = token.start_mark,
            .end_mark = token.start_mark,
        };
        return;
    }
}

/// Parse the productions:
///
///     block_mapping        ::= BLOCK-MAPPING_START
///                              *******************
///                              ((KEY block_node_or_indentless_sequence?)?
///                                *** *
///                              (VALUE block_node_or_indentless_sequence?)?)*
///
///                              BLOCK-END
///                              *********
fn parseBlockMappingKey(p: *Parser, event: *Event, first: bool) Error!void {
    var token: *Token = undefined;

    if (first) {
        token = try peekToken(p);
        try p.marks.push(p.alloc, token.start_mark);
        skipToken(p);
    }

    token = try peekToken(p);

    if (token.data == .key) {
        const mark = token.end_mark;
        skipToken(p);
        token = try peekToken(p);
        if (token.data != .key and token.data != .value and token.data != .block_end) {
            try p.states.push(p.alloc, .block_mapping_value);
            return parseNode(p, event, true, true);
        } else {
            p.state = .block_mapping_value;
            return processEmptyScalar(p, event, mark);
        }
    } else if (token.data == .block_end) {
        p.state = p.states.pop();
        _ = p.marks.pop();
        event.* = .{
            .data = .mapping_end,
            .start_mark = token.start_mark,
            .end_mark = token.end_mark,
        };
        skipToken(p);
        return;
    } else {
        return p.setParserErrorContext(
            "while parsing a block mapping",
            p.marks.pop(),
            "did not find expected key",
            token.start_mark,
        );
    }
}

/// Parse the productions:
///
///     block_mapping        ::= BLOCK-MAPPING_START
///
///                              ((KEY block_node_or_indentless_sequence?)?
///
///                              (VALUE block_node_or_indentless_sequence?)?)*
///                               ***** *
///                              BLOCK-END
fn parseBlockMappingValue(p: *Parser, event: *Event) Error!void {
    var token = try peekToken(p);

    if (token.data == .value) {
        const mark = token.end_mark;
        skipToken(p);
        token = try peekToken(p);
        if (token.data != .key and token.data != .value and token.data != .block_end) {
            try p.states.push(p.alloc, .block_mapping_key);
            return parseNode(p, event, true, true);
        } else {
            p.state = .block_mapping_key;
            return processEmptyScalar(p, event, mark);
        }
    } else {
        p.state = .block_mapping_key;
        return processEmptyScalar(p, event, token.start_mark);
    }
}

/// Parse the productions:
///
///     flow_sequence        ::= FLOW-SEQUENCE-START
///                              *******************
///                              (flow_sequence_entry FLOW-ENTRY)*
///                               *                   **********
///                              flow_sequence_entry?
///                              *
///                              FLOW-SEQUENCE-END
///                              *****************
///     flow_sequence_entry  ::= flow_node | KEY flow_node? (VALUE flow_node?)?
///                              *
fn parseFlowSequenceEntry(p: *Parser, event: *Event, first: bool) Error!void {
    var token: *Token = undefined;

    if (first) {
        token = try peekToken(p);
        try p.marks.push(p.alloc, token.start_mark);
        skipToken(p);
    }

    token = try peekToken(p);

    if (token.data != .flow_sequence_end) {
        if (!first) {
            if (token.data == .flow_entry) {
                skipToken(p);
                token = try peekToken(p);
            } else {
                return p.setParserErrorContext(
                    "while parsing a flow sequence",
                    p.marks.pop(),
                    "did not find expected ',' or ']'",
                    token.start_mark,
                );
            }
        }

        if (token.data == .key) {
            p.state = .flow_sequence_entry_mapping_key;
            event.* = .{
                .data = .{ .mapping_start = .{
                    .anchor = null,
                    .tag = null,
                    .implicit = true,
                    .style = .flow,
                } },
                .start_mark = token.start_mark,
                .end_mark = token.end_mark,
            };
            skipToken(p);
            return;
        } else if (token.data != .flow_sequence_end) {
            try p.states.push(p.alloc, .flow_sequence_entry);
            return parseNode(p, event, false, false);
        }
    }

    p.state = p.states.pop();
    _ = p.marks.pop();
    event.* = .{
        .data = .sequence_end,
        .start_mark = token.start_mark,
        .end_mark = token.end_mark,
    };
    skipToken(p);
}

/// Parse the productions:
///
///     flow_sequence_entry  ::= flow_node | KEY flow_node? (VALUE flow_node?)?
///                                          *** *
fn parseFlowSequenceEntryMappingKey(p: *Parser, event: *Event) Error!void {
    const token = try peekToken(p);

    if (token.data != .value and token.data != .flow_entry and
        token.data != .flow_sequence_end)
    {
        try p.states.push(p.alloc, .flow_sequence_entry_mapping_value);
        return parseNode(p, event, false, false);
    } else if (token.data == .flow_sequence_end) {
        // Upstream master added this arm: a `]` closing a `? key` entry must
        // NOT be consumed here — the empty value is emitted at the entry's
        // start mark and the `]` is left for the mapping-end state.
        const mark = token.start_mark;
        p.state = .flow_sequence_entry_mapping_value;
        return processEmptyScalar(p, event, mark);
    } else {
        const mark = token.end_mark;
        skipToken(p);
        p.state = .flow_sequence_entry_mapping_value;
        return processEmptyScalar(p, event, mark);
    }
}

/// Parse the productions:
///
///     flow_sequence_entry  ::= flow_node | KEY flow_node? (VALUE flow_node?)?
///                                                          ***** *
fn parseFlowSequenceEntryMappingValue(p: *Parser, event: *Event) Error!void {
    var token = try peekToken(p);

    if (token.data == .value) {
        skipToken(p);
        token = try peekToken(p);
        if (token.data != .flow_entry and token.data != .flow_sequence_end) {
            try p.states.push(p.alloc, .flow_sequence_entry_mapping_end);
            return parseNode(p, event, false, false);
        }
    }
    p.state = .flow_sequence_entry_mapping_end;
    return processEmptyScalar(p, event, token.start_mark);
}

/// Parse the productions:
///
///     flow_sequence_entry  ::= flow_node | KEY flow_node? (VALUE flow_node?)?
///                                                                          *
fn parseFlowSequenceEntryMappingEnd(p: *Parser, event: *Event) Error!void {
    const token = try peekToken(p);

    p.state = .flow_sequence_entry;

    event.* = .{
        .data = .mapping_end,
        .start_mark = token.start_mark,
        .end_mark = token.start_mark,
    };
}

/// Parse the productions:
///
///     flow_mapping         ::= FLOW-MAPPING-START
///                              ******************
///                              (flow_mapping_entry FLOW-ENTRY)*
///                               *                  **********
///                              flow_mapping_entry?
///                              ******************
///                              FLOW-MAPPING-END
///                              ****************
///     flow_mapping_entry   ::= flow_node | KEY flow_node? (VALUE flow_node?)?
///                              *           *** *
fn parseFlowMappingKey(p: *Parser, event: *Event, first: bool) Error!void {
    var token: *Token = undefined;

    if (first) {
        token = try peekToken(p);
        try p.marks.push(p.alloc, token.start_mark);
        skipToken(p);
    }

    token = try peekToken(p);

    if (token.data != .flow_mapping_end) {
        if (!first) {
            if (token.data == .flow_entry) {
                skipToken(p);
                token = try peekToken(p);
            } else {
                return p.setParserErrorContext(
                    "while parsing a flow mapping",
                    p.marks.pop(),
                    "did not find expected ',' or '}'",
                    token.start_mark,
                );
            }
        }

        if (token.data == .key) {
            skipToken(p);
            token = try peekToken(p);
            if (token.data != .value and token.data != .flow_entry and
                token.data != .flow_mapping_end)
            {
                try p.states.push(p.alloc, .flow_mapping_value);
                return parseNode(p, event, false, false);
            } else {
                p.state = .flow_mapping_value;
                return processEmptyScalar(p, event, token.start_mark);
            }
        } else if (token.data != .flow_mapping_end) {
            try p.states.push(p.alloc, .flow_mapping_empty_value);
            return parseNode(p, event, false, false);
        }
    }

    p.state = p.states.pop();
    _ = p.marks.pop();
    event.* = .{
        .data = .mapping_end,
        .start_mark = token.start_mark,
        .end_mark = token.end_mark,
    };
    skipToken(p);
}

/// Parse the productions:
///
///     flow_mapping_entry   ::= flow_node | KEY flow_node? (VALUE flow_node?)?
///                                       *                  ***** *
fn parseFlowMappingValue(p: *Parser, event: *Event, empty: bool) Error!void {
    var token = try peekToken(p);

    if (empty) {
        p.state = .flow_mapping_key;
        return processEmptyScalar(p, event, token.start_mark);
    }

    if (token.data == .value) {
        skipToken(p);
        token = try peekToken(p);
        if (token.data != .flow_entry and token.data != .flow_mapping_end) {
            try p.states.push(p.alloc, .flow_mapping_key);
            return parseNode(p, event, false, false);
        }
    }

    p.state = .flow_mapping_key;
    return processEmptyScalar(p, event, token.start_mark);
}

// ---- Utility functions ----

/// `yaml_parser_process_empty_scalar`: generate an empty scalar event.
fn processEmptyScalar(p: *Parser, event: *Event, mark: Mark) Error!void {
    // `YAML_MALLOC(1); value[0] = '\0'` — one owned byte, zero of them written.
    const value = try p.alloc.allocSentinel(u8, 0, 0);

    event.* = .{
        .data = .{ .scalar = .{
            .anchor = null,
            .tag = null,
            .value = value,
            .plain_implicit = true,
            .quoted_implicit = false,
            .style = .plain,
        } },
        .start_mark = mark,
        .end_mark = mark,
    };
}

/// The C's `version_directive_ref` / `tag_directives_start_ref` /
/// `tag_directives_end_ref` out-parameters, as one optional record: passing
/// `null` to `processDirectives` is the C's "all three refs are NULL", which
/// means "apply the directives but throw the parsed values away".
const Directives = struct {
    version_directive: ?*VersionDirective = null,
    /// Owned by the caller; empty when the document declared no `%TAG`.
    tag_directives: []TagDirective = &.{},
};

/// `yaml_parser_process_directives`: consume the `%YAML` / `%TAG` tokens in
/// front of a document and install them on the parser.
fn processDirectives(p: *Parser, out: ?*Directives) Error!void {
    const default_tag_directives = [_]struct { handle: [:0]const u8, prefix: [:0]const u8 }{
        .{ .handle = "!", .prefix = "!" },
        .{ .handle = "!!", .prefix = "tag:yaml.org,2002:" },
    };

    var version_directive: ?*VersionDirective = null;
    var tag_directives: types.Stack(TagDirective) = .empty;
    // The C's `error:` label.
    errdefer {
        if (version_directive) |vd| p.alloc.destroy(vd);
        while (!tag_directives.isEmpty()) {
            var tag_directive = tag_directives.pop();
            tag_directive.deinit(p.alloc);
        }
        tag_directives.deinit(p.alloc);
    }

    tag_directives = try types.Stack(TagDirective).init(p.alloc, mem.INITIAL_STACK_SIZE);

    var token = try peekToken(p);

    while (token.data == .version_directive or token.data == .tag_directive) {
        switch (token.data) {
            .version_directive => |directive| {
                if (version_directive != null) {
                    return p.setParserError(
                        "found duplicate %YAML directive",
                        token.start_mark,
                    );
                }
                if (directive.major != 1 or
                    (directive.minor != 1 and directive.minor != 2))
                {
                    return p.setParserError(
                        "found incompatible YAML document",
                        token.start_mark,
                    );
                }
                const new_directive = try p.alloc.create(VersionDirective);
                new_directive.* = .{ .major = directive.major, .minor = directive.minor };
                version_directive = new_directive;
            },
            .tag_directive => |directive| {
                // `value` aliases the token's strings; `appendTagDirective`
                // copies them for the parser, and the push below MOVES the
                // originals into the list the document-start event will own.
                const value: TagDirective = .{
                    .handle = directive.handle,
                    .prefix = directive.prefix,
                };
                try appendTagDirective(p, value.handle, value.prefix, false, token.start_mark);
                try tag_directives.push(p.alloc, value);
            },
            else => unreachable,
        }

        skipToken(p);
        token = try peekToken(p);
    }

    for (default_tag_directives) |default_tag_directive| {
        try appendTagDirective(
            p,
            default_tag_directive.handle,
            default_tag_directive.prefix,
            true,
            token.start_mark,
        );
    }

    if (out) |ref| {
        if (tag_directives.isEmpty()) {
            tag_directives.deinit(p.alloc);
            ref.* = .{ .version_directive = version_directive, .tag_directives = &.{} };
        } else {
            // The C hands out `stack.start .. stack.top` and lets the event free
            // `start`. A Zig allocator frees by exact length, so the spare
            // capacity is trimmed here — the event's `deinit` frees the slice it
            // was given.
            const owned = try p.alloc.realloc(tag_directives.buf, tag_directives.len);
            tag_directives = .empty;
            ref.* = .{ .version_directive = version_directive, .tag_directives = owned };
        }
        version_directive = null;
    } else {
        tag_directives.deinit(p.alloc);
        if (version_directive) |vd| p.alloc.destroy(vd);
        version_directive = null;
    }
}

/// `yaml_parser_append_tag_directive`: append a tag directive to the parser's
/// directive stack, copying both strings.
///
/// The C takes a `yaml_tag_directive_t` by value; the two strings are passed
/// separately here because the default table's entries are string literals,
/// which cannot be spelled as a `TagDirective` (whose fields are owned, mutable
/// `[:0]u8`). Upstream casts the const away instead.
fn appendTagDirective(
    p: *Parser,
    handle: [:0]const u8,
    prefix: [:0]const u8,
    allow_duplicates: bool,
    mark: Mark,
) Error!void {
    for (p.tag_directives.slice()) |*tag_directive| {
        if (std.mem.eql(u8, cstr(handle), cstr(tag_directive.handle))) {
            if (allow_duplicates) return;
            return p.setParserError("found duplicate %TAG directive", mark);
        }
    }

    // `yaml_strdup` measures with `strlen`, so an embedded NUL truncates the
    // copy — see `cstr`.
    const copy_handle = try p.alloc.dupeZ(u8, cstr(handle));
    errdefer p.alloc.free(copy_handle);
    const copy_prefix = try p.alloc.dupeZ(u8, cstr(prefix));
    errdefer p.alloc.free(copy_prefix);

    try p.tag_directives.push(p.alloc, .{ .handle = copy_handle, .prefix = copy_prefix });
}
