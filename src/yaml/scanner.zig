//! Port of libyaml's `src/scanner.c` (L749–1937) — the driver half: the token
//! queue, the simple-key machinery, indent/flow-level bookkeeping, and every
//! `fetch_*` function. The token scanners themselves live in `scan_token.zig`
//! and `scan_scalar.zig`.
//!
//! # The token model
//!
//! The scanner turns the input stream into tokens; `parser.zig` turns those
//! into events. Two of the scanner's jobs are genuinely clever, and both live
//! in this file:
//!
//! **Block collection start.** BLOCK-SEQUENCE-START / BLOCK-MAPPING-START and
//! BLOCK-END are YAML's INDENT/DEDENT. `rollIndent` pushes the current
//! indentation and emits the opening token when the column increases;
//! `unrollIndent` pops levels and emits BLOCK-END for each while the recorded
//! indent exceeds the current column. A collection may also start mid-line
//! (`- - item`, `- key: value`), which is why `rollIndent` can *insert* its
//! token into the middle of the queue instead of appending it — see
//! `fetchValue`. A sequence nested directly in a block mapping
//! (`key:\n- item`) is deliberately not indented and produces no
//! BLOCK-SEQUENCE-START at all.
//!
//! **Simple keys.** A key written without the `?` indicator is only recognised
//! as a key once its `:` is reached, which is *after* the key's own tokens have
//! been queued. So every position that could start a simple key is recorded
//! (`saveSimpleKey`), and when the `:` arrives `fetchValue` inserts a KEY token
//! back at the recorded queue position. The specification bounds how far that
//! rewind can reach: a simple key is limited to a single line and to 1024
//! characters, which is what `staleSimpleKeys` enforces — and what lets
//! `fetchMoreTokens` decide when the head of the queue is finally safe to hand
//! to the parser.
//!
//! `yaml_parser_scan` — libyaml's public single-token API — is deliberately not
//! ported: md4x consumes events, and nothing in this port calls it.

const std = @import("std");

const types = @import("types.zig");
const scan_token = @import("scan_token.zig");
const scan_scalar = @import("scan_scalar.zig");

const Parser = types.Parser;
const Token = types.Token;
const TokenData = types.TokenData;
const TokenType = types.TokenType;
const SimpleKey = types.SimpleKey;
const Mark = types.Mark;
const Error = types.Error;

// ---- High-level token API ----

/// `yaml_parser_fetch_more_tokens`: ensure the token queue holds at least one
/// token that can be returned to the parser.
pub fn fetchMoreTokens(p: *Parser) Error!void {
    // While we need more tokens to fetch, do it.
    while (true) {
        var need_more_tokens = false;

        if (p.tokens.isEmpty()) {
            // Queue is empty.
            need_more_tokens = true;
        } else {
            // A potential simple key may still occupy the head position, in
            // which case a KEY token could yet have to be inserted before it.
            try staleSimpleKeys(p);

            for (p.simple_keys.slice()) |simple_key| {
                if (simple_key.possible and simple_key.token_number == p.tokens_parsed) {
                    need_more_tokens = true;
                    break;
                }
            }
        }

        if (!need_more_tokens) break;

        try fetchNextToken(p);
    }

    p.token_available = true;
}

/// `yaml_parser_fetch_next_token`: the dispatcher for the token fetchers.
fn fetchNextToken(p: *Parser) Error!void {
    // Ensure that the buffer is initialized.
    try p.cache(1);

    // Check if we just started scanning.  Fetch STREAM-START then.
    if (!p.stream_start_produced) return fetchStreamStart(p);

    // Eat whitespaces and comments until we reach the next token.
    try scan_token.scanToNextToken(p);

    // Remove obsolete potential simple keys.
    try staleSimpleKeys(p);

    // Check the indentation level against the current column.
    try unrollIndent(p, @intCast(p.mark.column));

    // Ensure that the buffer contains at least 4 characters.  4 is the length
    // of the longest indicators ('--- ' and '... ').
    try p.cache(4);

    // Is it the end of the stream?
    if (p.isZ()) return fetchStreamEnd(p);

    // Is it a directive?
    if (p.mark.column == 0 and p.check('%')) return fetchDirective(p);

    // Is it the document start indicator?
    if (p.mark.column == 0 and
        p.checkAt('-', 0) and p.checkAt('-', 1) and p.checkAt('-', 2) and
        p.isBlankzAt(3))
    {
        return fetchDocumentIndicator(p, .document_start);
    }

    // Is it the document end indicator?
    if (p.mark.column == 0 and
        p.checkAt('.', 0) and p.checkAt('.', 1) and p.checkAt('.', 2) and
        p.isBlankzAt(3))
    {
        return fetchDocumentIndicator(p, .document_end);
    }

    // Is it the flow sequence start indicator?
    if (p.check('[')) return fetchFlowCollectionStart(p, .flow_sequence_start);

    // Is it the flow mapping start indicator?
    if (p.check('{')) return fetchFlowCollectionStart(p, .flow_mapping_start);

    // Is it the flow sequence end indicator?
    if (p.check(']')) return fetchFlowCollectionEnd(p, .flow_sequence_end);

    // Is it the flow mapping end indicator?
    if (p.check('}')) return fetchFlowCollectionEnd(p, .flow_mapping_end);

    // Is it the flow entry indicator?
    if (p.check(',')) return fetchFlowEntry(p);

    // Is it the block entry indicator?
    if (p.check('-') and p.isBlankzAt(1)) return fetchBlockEntry(p);

    // Is it the key indicator?
    if (p.check('?') and (p.flow_level != 0 or p.isBlankzAt(1))) return fetchKey(p);

    // Is it the value indicator?
    if (p.check(':') and (p.flow_level != 0 or p.isBlankzAt(1))) return fetchValue(p);

    // Is it an alias?
    if (p.check('*')) return fetchAnchor(p, .alias);

    // Is it an anchor?
    if (p.check('&')) return fetchAnchor(p, .anchor);

    // Is it a tag?
    if (p.check('!')) return fetchTag(p);

    // Is it a literal scalar?
    if (p.check('|') and p.flow_level == 0) return fetchBlockScalar(p, true);

    // Is it a folded scalar?
    if (p.check('>') and p.flow_level == 0) return fetchBlockScalar(p, false);

    // Is it a single-quoted scalar?
    if (p.check('\'')) return fetchFlowScalar(p, true);

    // Is it a double-quoted scalar?
    if (p.check('"')) return fetchFlowScalar(p, false);

    // Is it a plain scalar?
    //
    // A plain scalar may start with any non-blank characters except
    //
    //      '-', '?', ':', ',', '[', ']', '{', '}',
    //      '#', '&', '*', '!', '|', '>', '\'', '\"',
    //      '%', '@', '`'.
    //
    // In the block context (and, for the '-' indicator, in the flow context
    // too), it may also start with the characters
    //
    //      '-', '?', ':'
    //
    // if it is followed by a non-space character.
    //
    // The last rule is more restrictive than the specification requires.
    if (!(p.isBlankz() or p.check('-') or
        p.check('?') or p.check(':') or
        p.check(',') or p.check('[') or
        p.check(']') or p.check('{') or
        p.check('}') or p.check('#') or
        p.check('&') or p.check('*') or
        p.check('!') or p.check('|') or
        p.check('>') or p.check('\'') or
        p.check('"') or p.check('%') or
        p.check('@') or p.check('`')) or
        (p.check('-') and !p.isBlankAt(1)) or
        (p.flow_level == 0 and
            (p.check('?') or p.check(':')) and !p.isBlankzAt(1)))
    {
        return fetchPlainScalar(p);
    }

    // If we don't determine the token type so far, it is an error.
    return p.setScannerError(
        "while scanning for the next token",
        p.mark,
        "found character that cannot start any token",
    );
}

// ---- Potential simple keys ----

/// `yaml_parser_stale_simple_keys`: drop the recorded positions that can no
/// longer contain a simple key.
fn staleSimpleKeys(p: *Parser) Error!void {
    // Check for a potential simple key for each flow level.
    for (p.simple_keys.slice()) |*simple_key| {
        // The specification requires that a simple key
        //
        //  - is limited to a single line,
        //  - is shorter than 1024 characters.
        if (simple_key.possible and
            (simple_key.mark.line < p.mark.line or
                simple_key.mark.index + 1024 < p.mark.index))
        {
            // Check if the potential simple key to be removed is required.
            if (simple_key.required) {
                return p.setScannerError(
                    "while scanning a simple key",
                    simple_key.mark,
                    "could not find expected ':'",
                );
            }

            simple_key.possible = false;
        }
    }
}

/// `yaml_parser_save_simple_key`: record the current position as a possible
/// simple key, if one may start here.
fn saveSimpleKey(p: *Parser) Error!void {
    // A simple key is required at the current position if the scanner is in
    // the block context and the current column coincides with the indentation
    // level.
    //
    // The C compares `parser->indent` (int, possibly -1) against
    // `(ptrdiff_t)parser->mark.column`; the non-negative guard below is that
    // same comparison without a cast that could trap.
    const required = p.flow_level == 0 and
        p.indent >= 0 and @as(usize, @intCast(p.indent)) == p.mark.column;

    // If the current position may start a simple key, save it.
    if (p.simple_key_allowed) {
        const simple_key: SimpleKey = .{
            .possible = true,
            .required = required,
            .token_number = p.tokens_parsed + p.tokens.count(),
            .mark = p.mark,
        };

        try removeSimpleKey(p);

        p.simple_keys.top().* = simple_key;
    }
}

/// `yaml_parser_remove_simple_key`: drop the potential simple key at the
/// current flow level.
fn removeSimpleKey(p: *Parser) Error!void {
    const simple_key = p.simple_keys.top();

    if (simple_key.possible) {
        // If the key is required, it is an error.
        if (simple_key.required) {
            return p.setScannerError(
                "while scanning a simple key",
                simple_key.mark,
                "could not find expected ':'",
            );
        }
    }

    // Remove the key from the stack.
    simple_key.possible = false;
}

/// `yaml_parser_increase_flow_level`: enter a flow collection and reset the
/// simple key list for the new level.
fn increaseFlowLevel(p: *Parser) Error!void {
    // Reset the simple key on the next level.
    try p.simple_keys.push(p.alloc, .{});

    // Increase the flow level.
    if (p.flow_level == std.math.maxInt(i32)) {
        p.err = .memory;
        return error.OutOfMemory;
    }

    // `STACK_LIMIT(parser, parser->indents, MAX_NESTING_LEVEL - flow_level)`.
    // Every flow level spends one unit of the same budget the indent stack
    // draws on, so the two nesting forms cannot be alternated to escape the
    // cap — this is what bounds libyaml's quadratic flow-collection behaviour.
    // The subtraction is widened rather than cast so a hostile input cannot
    // trap on it. The C's macro stamps YAML_MEMORY_ERROR on failure and
    // `set_scanner_error` immediately overwrites it, so only the scanner error
    // is ever observable.
    const limit = @as(i64, p.max_nest_level) - @as(i64, p.flow_level);
    if (limit <= 0 or !p.indents.underLimit(@intCast(limit))) {
        return p.setScannerError(
            "while increasing flow level",
            p.mark,
            "exceeded maximum nesting depth",
        );
    }

    p.flow_level += 1;
}

/// `yaml_parser_decrease_flow_level`. The C returns int, but always 1 — there
/// is no failure path, so this returns void and its callers drop the `try`.
fn decreaseFlowLevel(p: *Parser) void {
    if (p.flow_level != 0) {
        p.flow_level -= 1;
        _ = p.simple_keys.pop();
    }
}

// ---- Indentation treatment ----

/// `yaml_parser_roll_indent`: push the current indentation level and set the
/// new one when `column` exceeds it, appending (or, for `number != -1`,
/// inserting) the collection-start token.
///
/// `column` and `number` are the C's `ptrdiff_t` parameters: `number` is `-1`
/// for "append", otherwise the absolute token number to insert at.
fn rollIndent(p: *Parser, column: isize, number: isize, data: TokenData, mark: Mark) Error!void {
    // In the flow context, do nothing.
    if (p.flow_level != 0) return;

    if (@as(isize, p.indent) < column) {
        // Push the current indentation level to the stack and set the new
        // indentation level.
        try p.indents.push(p.alloc, p.indent);

        // The block-nesting half of the cap documented in `increaseFlowLevel`.
        const limit = @as(i64, p.max_nest_level) - @as(i64, p.flow_level);
        if (limit <= 0 or !p.indents.underLimit(@intCast(limit))) {
            return p.setScannerError(
                "while increasing block level",
                p.mark,
                "exceeded maximum nesting depth",
            );
        }

        if (column > std.math.maxInt(i32)) {
            p.err = .memory;
            return error.OutOfMemory;
        }

        // Cannot trap: `column > p.indent >= -1`, so `column >= 0`, and the
        // check above bounds it from the other side.
        p.indent = @intCast(column);

        // Create a token and insert it into the queue.
        const token: Token = .{ .data = data, .start_mark = mark, .end_mark = mark };

        if (number == -1) {
            try p.tokens.enqueue(p.alloc, token);
        } else {
            // `number - parser->tokens_parsed`, the C's size_t subtraction.
            // The only caller passing `number != -1` is `fetchValue` with a
            // live simple key, whose token number is by construction at or
            // after the queue head, so the difference is non-negative.
            const index = number - @as(isize, @intCast(p.tokens_parsed));
            try p.tokens.insert(p.alloc, @intCast(index), token);
        }
    }
}

/// `yaml_parser_unroll_indent`: pop indentation levels until the current one is
/// less than or equal to `column`, appending a BLOCK-END token for each.
fn unrollIndent(p: *Parser, column: isize) Error!void {
    // In the flow context, do nothing.
    if (p.flow_level != 0) return;

    // Loop through the indentation levels in the stack.
    while (@as(isize, p.indent) > column) {
        // Create a token and append it to the queue.
        try p.tokens.enqueue(p.alloc, .{
            .data = .block_end,
            .start_mark = p.mark,
            .end_mark = p.mark,
        });

        // Pop the indentation level.
        p.indent = p.indents.pop();
    }
}

// ---- Token fetchers ----

/// `yaml_parser_fetch_stream_start`: initialize the scanner and produce the
/// STREAM-START token.
fn fetchStreamStart(p: *Parser) Error!void {
    // Set the initial indentation.
    p.indent = -1;

    // Initialize the simple key stack.
    try p.simple_keys.push(p.alloc, .{});

    // A simple key is allowed at the beginning of the stream.
    p.simple_key_allowed = true;

    // We have started.
    p.stream_start_produced = true;

    // Create the STREAM-START token and append it to the queue.
    try p.tokens.enqueue(p.alloc, .{
        .data = .{ .stream_start = .{ .encoding = p.encoding } },
        .start_mark = p.mark,
        .end_mark = p.mark,
    });
}

/// `yaml_parser_fetch_stream_end`: produce the STREAM-END token and shut the
/// scanner down.
fn fetchStreamEnd(p: *Parser) Error!void {
    // Force new line.
    if (p.mark.column != 0) {
        p.mark.column = 0;
        p.mark.line += 1;
    }

    // Reset the indentation level.
    try unrollIndent(p, -1);

    // Reset simple keys.
    try removeSimpleKey(p);

    p.simple_key_allowed = false;

    // Create the STREAM-END token and append it to the queue.
    try p.tokens.enqueue(p.alloc, .{
        .data = .stream_end,
        .start_mark = p.mark,
        .end_mark = p.mark,
    });
}

/// `yaml_parser_fetch_directive`: produce a VERSION-DIRECTIVE or TAG-DIRECTIVE
/// token.
fn fetchDirective(p: *Parser) Error!void {
    // Reset the indentation level.
    try unrollIndent(p, -1);

    // Reset simple keys.
    try removeSimpleKey(p);

    p.simple_key_allowed = false;

    // Create the YAML-DIRECTIVE or TAG-DIRECTIVE token.
    var token: Token = undefined;
    try scan_token.scanDirective(p, &token);

    // Append the token to the queue.
    errdefer token.deinit(p.alloc);
    try p.tokens.enqueue(p.alloc, token);
}

/// `yaml_parser_fetch_document_indicator`: produce the DOCUMENT-START or
/// DOCUMENT-END token.
fn fetchDocumentIndicator(p: *Parser, data: TokenData) Error!void {
    // Reset the indentation level.
    try unrollIndent(p, -1);

    // Reset simple keys.
    try removeSimpleKey(p);

    p.simple_key_allowed = false;

    // Consume the token.
    const start_mark = p.mark;

    p.skip();
    p.skip();
    p.skip();

    const end_mark = p.mark;

    // Create the DOCUMENT-START or DOCUMENT-END token and append it.
    try p.tokens.enqueue(p.alloc, .{
        .data = data,
        .start_mark = start_mark,
        .end_mark = end_mark,
    });
}

/// `yaml_parser_fetch_flow_collection_start`: produce the FLOW-SEQUENCE-START
/// or FLOW-MAPPING-START token.
fn fetchFlowCollectionStart(p: *Parser, data: TokenData) Error!void {
    // The indicators '[' and '{' may start a simple key.
    try saveSimpleKey(p);

    // Increase the flow level.
    try increaseFlowLevel(p);

    // A simple key may follow the indicators '[' and '{'.
    p.simple_key_allowed = true;

    // Consume the token.
    const start_mark = p.mark;
    p.skip();
    const end_mark = p.mark;

    // Create the FLOW-SEQUENCE-START of FLOW-MAPPING-START token and append it.
    try p.tokens.enqueue(p.alloc, .{
        .data = data,
        .start_mark = start_mark,
        .end_mark = end_mark,
    });
}

/// `yaml_parser_fetch_flow_collection_end`: produce the FLOW-SEQUENCE-END or
/// FLOW-MAPPING-END token.
fn fetchFlowCollectionEnd(p: *Parser, data: TokenData) Error!void {
    // Reset any potential simple key on the current flow level.
    try removeSimpleKey(p);

    // Decrease the flow level.
    decreaseFlowLevel(p);

    // No simple keys after the indicators ']' and '}'.
    p.simple_key_allowed = false;

    // Consume the token.
    const start_mark = p.mark;
    p.skip();
    const end_mark = p.mark;

    // Create the FLOW-SEQUENCE-END of FLOW-MAPPING-END token and append it.
    try p.tokens.enqueue(p.alloc, .{
        .data = data,
        .start_mark = start_mark,
        .end_mark = end_mark,
    });
}

/// `yaml_parser_fetch_flow_entry`: produce the FLOW-ENTRY token.
fn fetchFlowEntry(p: *Parser) Error!void {
    // Reset any potential simple keys on the current flow level.
    try removeSimpleKey(p);

    // Simple keys are allowed after ','.
    p.simple_key_allowed = true;

    // Consume the token.
    const start_mark = p.mark;
    p.skip();
    const end_mark = p.mark;

    // Create the FLOW-ENTRY token and append it to the queue.
    try p.tokens.enqueue(p.alloc, .{
        .data = .flow_entry,
        .start_mark = start_mark,
        .end_mark = end_mark,
    });
}

/// `yaml_parser_fetch_block_entry`: produce the BLOCK-ENTRY token.
fn fetchBlockEntry(p: *Parser) Error!void {
    // Check if the scanner is in the block context.
    if (p.flow_level == 0) {
        // Check if we are allowed to start a new entry.
        if (!p.simple_key_allowed) {
            return p.setScannerError(
                null,
                p.mark,
                "block sequence entries are not allowed in this context",
            );
        }

        // Add the BLOCK-SEQUENCE-START token if needed.
        try rollIndent(p, @intCast(p.mark.column), -1, .block_sequence_start, p.mark);
    } else {
        // It is an error for the '-' indicator to occur in the flow context,
        // but we let the Parser detect and report about it because the Parser
        // is able to point to the context.
    }

    // Reset any potential simple keys on the current flow level.
    try removeSimpleKey(p);

    // Simple keys are allowed after '-'.
    p.simple_key_allowed = true;

    // Consume the token.
    const start_mark = p.mark;
    p.skip();
    const end_mark = p.mark;

    // Create the BLOCK-ENTRY token and append it to the queue.
    try p.tokens.enqueue(p.alloc, .{
        .data = .block_entry,
        .start_mark = start_mark,
        .end_mark = end_mark,
    });
}

/// `yaml_parser_fetch_key`: produce the KEY token.
fn fetchKey(p: *Parser) Error!void {
    // In the block context, additional checks are required.
    if (p.flow_level == 0) {
        // Check if we are allowed to start a new key (not necessary simple).
        if (!p.simple_key_allowed) {
            return p.setScannerError(
                null,
                p.mark,
                "mapping keys are not allowed in this context",
            );
        }

        // Add the BLOCK-MAPPING-START token if needed.
        try rollIndent(p, @intCast(p.mark.column), -1, .block_mapping_start, p.mark);
    }

    // Reset any potential simple keys on the current flow level.
    try removeSimpleKey(p);

    // Simple keys are allowed after '?' in the block context.
    p.simple_key_allowed = p.flow_level == 0;

    // Consume the token.
    const start_mark = p.mark;
    p.skip();
    const end_mark = p.mark;

    // Create the KEY token and append it to the queue.
    try p.tokens.enqueue(p.alloc, .{
        .data = .key,
        .start_mark = start_mark,
        .end_mark = end_mark,
    });
}

/// `yaml_parser_fetch_value`: produce the VALUE token — and, when it closes a
/// simple key, the KEY token that was not recognisable until now.
fn fetchValue(p: *Parser) Error!void {
    // Stable across the calls below: only `increaseFlowLevel` pushes onto
    // `simple_keys`, and nothing here does.
    const simple_key = p.simple_keys.top();

    // Have we found a simple key?
    if (simple_key.possible) {
        // Create the KEY token and insert it into the queue.
        const token: Token = .{
            .data = .key,
            .start_mark = simple_key.mark,
            .end_mark = simple_key.mark,
        };

        try p.tokens.insert(p.alloc, simple_key.token_number - p.tokens_parsed, token);

        // In the block context, we may need to add the BLOCK-MAPPING-START
        // token.
        try rollIndent(
            p,
            @intCast(simple_key.mark.column),
            @intCast(simple_key.token_number),
            .block_mapping_start,
            simple_key.mark,
        );

        // Remove the simple key.
        simple_key.possible = false;

        // A simple key cannot follow another simple key.
        p.simple_key_allowed = false;
    } else {
        // The ':' indicator follows a complex key.

        // In the block context, extra checks are required.
        if (p.flow_level == 0) {
            // Check if we are allowed to start a complex value.
            if (!p.simple_key_allowed) {
                return p.setScannerError(
                    null,
                    p.mark,
                    "mapping values are not allowed in this context",
                );
            }

            // Add the BLOCK-MAPPING-START token if needed.
            try rollIndent(p, @intCast(p.mark.column), -1, .block_mapping_start, p.mark);
        }

        // Simple keys after ':' are allowed in the block context.
        p.simple_key_allowed = p.flow_level == 0;
    }

    // Consume the token.
    const start_mark = p.mark;
    p.skip();
    const end_mark = p.mark;

    // Create the VALUE token and append it to the queue.
    try p.tokens.enqueue(p.alloc, .{
        .data = .value,
        .start_mark = start_mark,
        .end_mark = end_mark,
    });
}

/// `yaml_parser_fetch_anchor`: produce the ALIAS or ANCHOR token.
fn fetchAnchor(p: *Parser, kind: TokenType) Error!void {
    // An anchor or an alias could be a simple key.
    try saveSimpleKey(p);

    // A simple key cannot follow an anchor or an alias.
    p.simple_key_allowed = false;

    // Create the ALIAS or ANCHOR token and append it to the queue.
    var token: Token = undefined;
    try scan_token.scanAnchor(p, &token, kind);

    errdefer token.deinit(p.alloc);
    try p.tokens.enqueue(p.alloc, token);
}

/// `yaml_parser_fetch_tag`: produce the TAG token.
fn fetchTag(p: *Parser) Error!void {
    // A tag could be a simple key.
    try saveSimpleKey(p);

    // A simple key cannot follow a tag.
    p.simple_key_allowed = false;

    // Create the TAG token and append it to the queue.
    var token: Token = undefined;
    try scan_token.scanTag(p, &token);

    errdefer token.deinit(p.alloc);
    try p.tokens.enqueue(p.alloc, token);
}

/// `yaml_parser_fetch_block_scalar`: produce the SCALAR(...,literal) or
/// SCALAR(...,folded) token.
fn fetchBlockScalar(p: *Parser, literal: bool) Error!void {
    // Remove any potential simple keys.
    try removeSimpleKey(p);

    // A simple key may follow a block scalar.
    p.simple_key_allowed = true;

    // Create the SCALAR token and append it to the queue.
    var token: Token = undefined;
    try scan_scalar.scanBlockScalar(p, &token, literal);

    errdefer token.deinit(p.alloc);
    try p.tokens.enqueue(p.alloc, token);
}

/// `yaml_parser_fetch_flow_scalar`: produce the SCALAR(...,single-quoted) or
/// SCALAR(...,double-quoted) token.
fn fetchFlowScalar(p: *Parser, single: bool) Error!void {
    // A plain scalar could be a simple key.
    try saveSimpleKey(p);

    // A simple key cannot follow a flow scalar.
    p.simple_key_allowed = false;

    // Create the SCALAR token and append it to the queue.
    var token: Token = undefined;
    try scan_scalar.scanFlowScalar(p, &token, single);

    errdefer token.deinit(p.alloc);
    try p.tokens.enqueue(p.alloc, token);
}

/// `yaml_parser_fetch_plain_scalar`: produce the SCALAR(...,plain) token.
fn fetchPlainScalar(p: *Parser) Error!void {
    // A plain scalar could be a simple key.
    try saveSimpleKey(p);

    // A simple key cannot follow a flow scalar.
    p.simple_key_allowed = false;

    // Create the SCALAR token and append it to the queue.
    var token: Token = undefined;
    try scan_scalar.scanPlainScalar(p, &token);

    errdefer token.deinit(p.alloc);
    try p.tokens.enqueue(p.alloc, token);
}
