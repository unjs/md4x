//! Port of libyaml's `src/scanner.c` (L1938–2758) — the non-scalar token
//! scanners: whitespace/comment skipping, directives, anchors and tags.
//!
//! # Out-params
//!
//! The C helpers hand their result back through `yaml_char_t **name` /
//! `**handle` / `**prefix` / `**uri` and report success as `int`. Here they
//! **return the owned `[:0]u8` directly** — every one of them, so there is one
//! rule to remember. That is faithful because in the C not one caller inspects
//! a partially-built out-param after a failure: `*out` is assigned only on the
//! `return 1` path, and every `goto error` leaves the caller's pointer at its
//! initial `NULL`. The single genuine out-param, `yaml_parser_scan_uri_escapes`'
//! `yaml_string_t *string`, stays one (`*mem.String`) — it appends to a buffer
//! its caller keeps scanning into.
//!
//! The C's `goto error;` blocks free the half-built `yaml_string_t`; here that
//! is `errdefer string.deinit(p.alloc)` on the owning local. `toOwned` empties
//! the `String`, so the errdefer is a no-op once the bytes belong to a token.

const std = @import("std");
const mem = @import("mem.zig");
const types = @import("types.zig");
const Parser = types.Parser;
const Token = types.Token;
const TokenType = types.TokenType;
const Mark = types.Mark;
const Error = types.Error;

/// `yaml_parser_scan_to_next_token`: eat whitespaces and comments until the
/// next token is found.
pub fn scanToNextToken(p: *Parser) Error!void {
    // Until the next token is not found.
    while (true) {
        // Allow the BOM mark to start a line.
        try p.cache(1);

        if (p.mark.column == 0 and p.isBom()) p.skip();

        // Eat whitespaces.
        //
        // Tabs are allowed:
        //
        //  - in the flow context;
        //  - in the block context, but not at the beginning of the line or
        //  after '-', '?', or ':' (complex value).
        try p.cache(1);

        while (p.check(' ') or
            ((p.flow_level != 0 or !p.simple_key_allowed) and p.check('\t')))
        {
            p.skip();
            try p.cache(1);
        }

        // Eat a comment until a line break.
        if (p.check('#')) {
            while (!p.isBreakz()) {
                p.skip();
                try p.cache(1);
            }
        }

        // If it is a line break, eat it.
        if (p.isBreak()) {
            try p.cache(2);
            p.skipLine();

            // In the block context, a new line may start a simple key.
            if (p.flow_level == 0) {
                p.simple_key_allowed = true;
            }
        } else {
            // We have found a token.
            break;
        }
    }
}

/// `yaml_parser_scan_directive`: scan a YAML-DIRECTIVE or TAG-DIRECTIVE token.
///
/// Scope:
///
///     %YAML    1.1    # a comment \n
///     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
///     %TAG    !yaml!  tag:yaml.org,2002:  \n
///     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
pub fn scanDirective(p: *Parser, token: *Token) Error!void {
    // Eat '%'.
    const start_mark = p.mark;

    p.skip();

    // Scan the directive name.
    const name = try scanDirectiveName(p, start_mark);
    // The C's `error:` label and its `return 1` path both `yaml_free(name)`.
    defer p.alloc.free(name);

    // Held as locals rather than read back out of `token`, because the C frees
    // them at `error:` even after `TAG_DIRECTIVE_TOKEN_INIT` has taken the
    // pointers — a failed `scan_directive`'s token is discarded by its caller.
    var handle: ?[:0]u8 = null;
    var prefix: ?[:0]u8 = null;
    errdefer {
        if (prefix) |x| p.alloc.free(x);
        if (handle) |x| p.alloc.free(x);
    }

    // Is it a YAML directive?
    if (std.mem.eql(u8, name, "YAML")) {
        // Scan the VERSION directive value.
        const version = try scanVersionDirectiveValue(p, start_mark);

        const end_mark = p.mark;

        // Create a VERSION-DIRECTIVE token.
        token.* = .{
            .data = .{ .version_directive = .{ .major = version.major, .minor = version.minor } },
            .start_mark = start_mark,
            .end_mark = end_mark,
        };
    }

    // Is it a TAG directive?
    else if (std.mem.eql(u8, name, "TAG")) {
        // Scan the TAG directive value.
        const value = try scanTagDirectiveValue(p, start_mark);
        handle = value.handle;
        prefix = value.prefix;

        const end_mark = p.mark;

        // Create a TAG-DIRECTIVE token.
        token.* = .{
            .data = .{ .tag_directive = .{ .handle = value.handle, .prefix = value.prefix } },
            .start_mark = start_mark,
            .end_mark = end_mark,
        };
    }

    // Unknown directive.
    else {
        return p.setScannerError(
            "while scanning a directive",
            start_mark,
            "found unknown directive name",
        );
    }

    // Eat the rest of the line including any comments.
    try p.cache(1);

    while (p.isBlank()) {
        p.skip();
        try p.cache(1);
    }

    if (p.check('#')) {
        while (!p.isBreakz()) {
            p.skip();
            try p.cache(1);
        }
    }

    // Check if we are at the end of the line.
    if (!p.isBreakz()) {
        return p.setScannerError(
            "while scanning a directive",
            start_mark,
            "did not find expected comment or line break",
        );
    }

    // Eat a line break.
    if (p.isBreak()) {
        try p.cache(2);
        p.skipLine();
    }
}

/// `yaml_parser_scan_directive_name`: scan the directive name.
///
/// Scope:
///
///     %YAML   1.1     # a comment \n
///      ^^^^
///     %TAG    !yaml!  tag:yaml.org,2002:  \n
///      ^^^
fn scanDirectiveName(p: *Parser, start_mark: Mark) Error![:0]u8 {
    var string = try mem.String.init(p.alloc, mem.INITIAL_STRING_SIZE);
    errdefer string.deinit(p.alloc);

    // Consume the directive name.
    try p.cache(1);

    while (p.isAlpha()) {
        try p.read(&string);
        try p.cache(1);
    }

    // Check if the name is empty.
    if (string.isEmpty()) {
        return p.setScannerError(
            "while scanning a directive",
            start_mark,
            "could not find expected directive name",
        );
    }

    // Check for an blank character after the name.
    if (!p.isBlankz()) {
        return p.setScannerError(
            "while scanning a directive",
            start_mark,
            "found unexpected non-alphabetical character",
        );
    }

    return string.toOwned(p.alloc);
}

/// `yaml_parser_scan_version_directive_value`: scan the value of
/// VERSION-DIRECTIVE.
///
/// Scope:
///
///     %YAML   1.1     # a comment \n
///          ^^^^^^
fn scanVersionDirectiveValue(p: *Parser, start_mark: Mark) Error!types.VersionDirective {
    // Eat whitespaces.
    try p.cache(1);

    while (p.isBlank()) {
        p.skip();
        try p.cache(1);
    }

    // Consume the major version number.
    const major = try scanVersionDirectiveNumber(p, start_mark);

    // Eat '.'.
    if (!p.check('.')) {
        return p.setScannerError(
            "while scanning a %YAML directive",
            start_mark,
            "did not find expected digit or '.' character",
        );
    }

    p.skip();

    // Consume the minor version number.
    const minor = try scanVersionDirectiveNumber(p, start_mark);

    return .{ .major = major, .minor = minor };
}

const MAX_NUMBER_LENGTH: usize = 9;

/// `yaml_parser_scan_version_directive_number`: scan the version number of
/// VERSION-DIRECTIVE.
///
/// Scope:
///
///     %YAML   1.1     # a comment \n
///             ^
///     %YAML   1.1     # a comment \n
///               ^
fn scanVersionDirectiveNumber(p: *Parser, start_mark: Mark) Error!i32 {
    // At most `MAX_NUMBER_LENGTH` digits are accumulated, so `value` cannot
    // exceed 999_999_999 and the multiply cannot overflow the C's `int`.
    var value: i32 = 0;
    var length: usize = 0;

    // Repeat while the next character is digit.
    try p.cache(1);

    while (p.isDigit()) {
        // Check if the number is too long.
        length += 1;
        if (length > MAX_NUMBER_LENGTH) {
            return p.setScannerError(
                "while scanning a %YAML directive",
                start_mark,
                "found extremely long version number",
            );
        }

        value = value * 10 + @as(i32, p.asDigit());

        p.skip();

        try p.cache(1);
    }

    // Check if the number was present.
    if (length == 0) {
        return p.setScannerError(
            "while scanning a %YAML directive",
            start_mark,
            "did not find expected version number",
        );
    }

    return value;
}

/// The two owned strings `yaml_parser_scan_tag_directive_value` writes through
/// its `**handle` / `**prefix` out-params.
const TagDirectiveValue = struct {
    handle: [:0]u8,
    prefix: [:0]u8,
};

/// `yaml_parser_scan_tag_directive_value`: scan the value of a TAG-DIRECTIVE
/// token.
///
/// Scope:
///
///     %TAG    !yaml!  tag:yaml.org,2002:  \n
///         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
fn scanTagDirectiveValue(p: *Parser, start_mark: Mark) Error!TagDirectiveValue {
    // Eat whitespaces.
    try p.cache(1);

    while (p.isBlank()) {
        p.skip();
        try p.cache(1);
    }

    // Scan a handle.
    const handle_value = try scanTagHandle(p, true, start_mark);
    errdefer p.alloc.free(handle_value);

    // Expect a whitespace.
    try p.cache(1);

    if (!p.isBlank()) {
        return p.setScannerError(
            "while scanning a %TAG directive",
            start_mark,
            "did not find expected whitespace",
        );
    }

    // Eat whitespaces.
    while (p.isBlank()) {
        p.skip();
        try p.cache(1);
    }

    // Scan a prefix.
    const prefix_value = try scanTagUri(p, true, true, null, start_mark);
    errdefer p.alloc.free(prefix_value);

    // Expect a whitespace or line break.
    try p.cache(1);

    if (!p.isBlankz()) {
        return p.setScannerError(
            "while scanning a %TAG directive",
            start_mark,
            "did not find expected whitespace or line break",
        );
    }

    return .{ .handle = handle_value, .prefix = prefix_value };
}

/// `yaml_parser_scan_anchor`. `kind` is `.anchor` or `.alias`.
pub fn scanAnchor(p: *Parser, token: *Token, kind: TokenType) Error!void {
    var length: usize = 0;
    var string = try mem.String.init(p.alloc, mem.INITIAL_STRING_SIZE);
    errdefer string.deinit(p.alloc);

    // Eat the indicator character.
    const start_mark = p.mark;

    p.skip();

    // Consume the value.
    try p.cache(1);

    while (p.isAlpha()) {
        try p.read(&string);
        try p.cache(1);
        length += 1;
    }

    const end_mark = p.mark;

    // Check if length of the anchor is greater than 0 and it is followed by
    // a whitespace character or one of the indicators:
    //
    //      '?', ':', ',', ']', '}', '%', '@', '`'.
    if (length == 0 or !(p.isBlankz() or p.check('?') or
        p.check(':') or p.check(',') or
        p.check(']') or p.check('}') or
        p.check('%') or p.check('@') or
        p.check('`')))
    {
        return p.setScannerError(
            if (kind == .anchor) "while scanning an anchor" else "while scanning an alias",
            start_mark,
            "did not find expected alphabetic or numeric character",
        );
    }

    // Create a token.
    const value = try string.toOwned(p.alloc);

    if (kind == .anchor) {
        token.* = .{
            .data = .{ .anchor = .{ .value = value } },
            .start_mark = start_mark,
            .end_mark = end_mark,
        };
    } else {
        token.* = .{
            .data = .{ .alias = .{ .value = value } },
            .start_mark = start_mark,
            .end_mark = end_mark,
        };
    }
}

/// `yaml_parser_scan_tag`: scan a TAG token.
pub fn scanTag(p: *Parser, token: *Token) Error!void {
    // Nullable locals mirroring the C's `handle` / `suffix`, so the errdefer
    // frees exactly what the `error:` label frees at each point.
    var handle: ?[:0]u8 = null;
    var suffix: ?[:0]u8 = null;
    errdefer {
        if (handle) |x| p.alloc.free(x);
        if (suffix) |x| p.alloc.free(x);
    }

    const start_mark = p.mark;

    // Check if the tag is in the canonical form.
    try p.cache(2);

    if (p.checkAt('<', 1)) {
        // Set the handle to ''
        handle = try p.alloc.allocSentinel(u8, 0, 0);

        // Eat '!<'
        p.skip();
        p.skip();

        // Consume the tag value.
        suffix = try scanTagUri(p, true, false, null, start_mark);

        // Check for '>' and eat it.
        if (!p.check('>')) {
            return p.setScannerError(
                "while scanning a tag",
                start_mark,
                "did not find the expected '>'",
            );
        }

        p.skip();
    } else {
        // The tag has either the '!suffix' or the '!handle!suffix' form.

        // First, try to scan a handle.
        handle = try scanTagHandle(p, false, start_mark);

        // Check if it is, indeed, handle.
        //
        // `scanTagHandle` always copies at least the leading '!' and can never
        // copy a NUL, so the C's `handle[1] != '\0'` and
        // `handle[strlen(handle)-1]` are exactly `len > 1` and `handle[len-1]`.
        const h = handle.?;
        if (h[0] == '!' and h.len > 1 and h[h.len - 1] == '!') {
            // Scan the suffix now.
            suffix = try scanTagUri(p, false, false, null, start_mark);
        } else {
            // It wasn't a handle after all.  Scan the rest of the tag.
            suffix = try scanTagUri(p, false, false, h, start_mark);

            // Set the handle to '!'.
            p.alloc.free(h);
            handle = null;
            const excl = try p.alloc.allocSentinel(u8, 1, 0);
            excl[0] = '!';
            handle = excl;

            // A special case: the '!' tag.  Set the handle to '' and the
            // suffix to '!'.
            //
            // `.ptr[0]` and not `[0]`: a `%00` escape makes an empty-looking
            // suffix that is NOT zero-length, and for a zero-length suffix
            // `.ptr[0]` reads the sentinel — which is what the C reads too.
            if (suffix.?.ptr[0] == 0) {
                const tmp = handle.?;
                handle = suffix.?;
                suffix = tmp;
            }
        }
    }

    // Check the character which ends the tag.
    try p.cache(1);

    if (!p.isBlankz()) {
        if (p.flow_level == 0 or !p.check(',')) {
            return p.setScannerError(
                "while scanning a tag",
                start_mark,
                "did not find expected whitespace or line break",
            );
        }
    }

    const end_mark = p.mark;

    // Create a token.
    token.* = .{
        .data = .{ .tag = .{ .handle = handle.?, .suffix = suffix.? } },
        .start_mark = start_mark,
        .end_mark = end_mark,
    };
}

/// `yaml_parser_scan_tag_handle`: scan a tag handle.
fn scanTagHandle(p: *Parser, directive: bool, start_mark: Mark) Error![:0]u8 {
    var string = try mem.String.init(p.alloc, mem.INITIAL_STRING_SIZE);
    errdefer string.deinit(p.alloc);

    // Check the initial '!' character.
    try p.cache(1);

    if (!p.check('!')) {
        return p.setScannerError(
            if (directive) "while scanning a tag directive" else "while scanning a tag",
            start_mark,
            "did not find expected '!'",
        );
    }

    // Copy the '!' character.
    try p.read(&string);

    // Copy all subsequent alphabetical and numerical characters.
    try p.cache(1);

    while (p.isAlpha()) {
        try p.read(&string);
        try p.cache(1);
    }

    // Check if the trailing character is '!' and copy it.
    if (p.check('!')) {
        try p.read(&string);
    } else {
        // It's either the '!' tag or not really a tag handle.  If it's a %TAG
        // directive, it's an error.  If it's a tag token, it must be a part of
        // URI.
        //
        // `string.buf[1]` is in bounds and zero-filled past the write cursor,
        // so this is the C's `string.start[1] == '\0'` byte for byte.
        if (directive and !(string.buf[0] == '!' and string.buf[1] == 0)) {
            return p.setScannerError(
                "while parsing a tag directive",
                start_mark,
                "did not find expected '!'",
            );
        }
    }

    return string.toOwned(p.alloc);
}

/// `yaml_parser_scan_tag_uri`: scan a tag.
///
/// `head`, when given, is the handle a caller already scanned and now wants
/// folded into the front of the URI. Two of the C's quirks are load-bearing and
/// kept as they are:
///
///  - the leading '!' of `head` is deliberately NOT copied (see the C comment
///    below), so a one-character head contributes no bytes at all;
///  - `length` starts at `strlen(head)`, not at 0, so it doubles as the
///    "did we see anything?" flag — a non-empty head therefore satisfies the
///    final emptiness check even when the scan loop matched nothing.
fn scanTagUri(
    p: *Parser,
    uri_char: bool,
    directive: bool,
    head: ?[:0]const u8,
    start_mark: Mark,
) Error![:0]u8 {
    // `head` is always a handle built by `scanTagHandle`, which cannot contain
    // a NUL, so `.len` is `strlen(head)`.
    var length: usize = if (head) |h| h.len else 0;
    var string = try mem.String.init(p.alloc, mem.INITIAL_STRING_SIZE);
    errdefer string.deinit(p.alloc);

    // Resize the string to include the head.
    while (string.buf.len <= length) try string.grow(p.alloc);

    // Copy the head if needed.
    //
    // Note that we don't copy the leading '!' character.
    if (length > 1) {
        @memcpy(string.buf[0 .. length - 1], head.?[1..length]);
        string.len += length - 1;
    }

    // Scan the tag.
    try p.cache(1);

    // The set of characters that may appear in URI is as follows:
    //
    //      '0'-'9', 'A'-'Z', 'a'-'z', '_', '-', ';', '/', '?', ':', '@', '&',
    //      '=', '+', '$', '.', '!', '~', '*', '\'', '(', ')', '%'.
    //
    // If we are inside a verbatim tag <...> (parameter uri_char is true)
    // then also the following flow indicators are allowed:
    //      ',', '[', ']'
    while (p.isAlpha() or p.check(';') or
        p.check('/') or p.check('?') or
        p.check(':') or p.check('@') or
        p.check('&') or p.check('=') or
        p.check('+') or p.check('$') or
        p.check('.') or p.check('%') or
        p.check('!') or p.check('~') or
        p.check('*') or p.check('\'') or
        p.check('(') or p.check(')') or
        (uri_char and (p.check(',') or
            p.check('[') or p.check(']'))))
    {
        // Check if it is a URI-escape sequence.
        if (p.check('%')) {
            try string.extend(p.alloc);

            try scanUriEscapes(p, directive, start_mark, &string);
        } else {
            try p.read(&string);
        }

        length += 1;
        try p.cache(1);
    }

    // Check if the tag is non-empty.
    if (length == 0) {
        // Dead store in the C too — the string is deleted right after — but it
        // is kept so an OOM here still reports a memory error, not a scanner
        // one, exactly as upstream does.
        try string.extend(p.alloc);

        return p.setScannerError(
            if (directive) "while parsing a %TAG directive" else "while parsing a tag",
            start_mark,
            "did not find expected tag URI",
        );
    }

    return string.toOwned(p.alloc);
}

/// `yaml_parser_scan_uri_escapes`: decode an URI-escape sequence corresponding
/// to a single UTF-8 character.
///
/// Appends to `string` without extending it: the caller runs one
/// `STRING_EXTEND` before the call, which leaves at least five spare bytes, and
/// a UTF-8 sequence is at most four octets long.
fn scanUriEscapes(p: *Parser, directive: bool, start_mark: Mark, string: *mem.String) Error!void {
    var width: usize = 0;

    // Decode the required number of characters.
    while (true) {
        // Check for a URI-escaped octet.
        try p.cache(3);

        if (!(p.check('%') and p.isHexAt(1) and p.isHexAt(2))) {
            return p.setScannerError(
                if (directive) "while parsing a %TAG directive" else "while parsing a tag",
                start_mark,
                "did not find URI escaped octet",
            );
        }

        // Get the octet.
        const octet: u8 = (p.asHexAt(1) << 4) + p.asHexAt(2);

        // If it is the leading octet, determine the length of the UTF-8 sequence.
        if (width == 0) {
            width = if (octet & 0x80 == 0x00)
                1
            else if (octet & 0xE0 == 0xC0)
                2
            else if (octet & 0xF0 == 0xE0)
                3
            else if (octet & 0xF8 == 0xF0)
                4
            else
                0;
            if (width == 0) {
                return p.setScannerError(
                    if (directive) "while parsing a %TAG directive" else "while parsing a tag",
                    start_mark,
                    "found an incorrect leading UTF-8 octet",
                );
            }
        } else {
            // Check if the trailing octet is correct.
            if (octet & 0xC0 != 0x80) {
                return p.setScannerError(
                    if (directive) "while parsing a %TAG directive" else "while parsing a tag",
                    start_mark,
                    "found an incorrect trailing UTF-8 octet",
                );
            }
        }

        // Copy the octet and move the pointers.
        string.putAssumeCapacity(octet);
        p.skip();
        p.skip();
        p.skip();

        // `while (--width)`
        width -= 1;
        if (width == 0) break;
    }
}
