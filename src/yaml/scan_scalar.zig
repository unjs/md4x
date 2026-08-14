//! Port of libyaml's `src/scanner.c` (L2759–3616) — the scalar scanners: block
//! (literal and folded), flow (single- and double-quoted) and plain.
//!
//! The C's `goto error` cleanup blocks become `errdefer` / `defer` on the
//! owning `mem.String` locals: `string` is handed to the token on success, so
//! it is `errdefer`ed, while the three fold buffers are freed on both paths and
//! so are `defer`ed. `toOwned` empties the `String`, which is why the errdefer
//! is a no-op once ownership has moved.
//!
//! Every `STRING_EXTEND` call site is kept exactly where the C has it: the
//! macro's guarantee of five spare zero bytes past the write cursor is the only
//! reason a scalar value ends up NUL-terminated, and the widest single write
//! below (the `\U` escape) is four bytes.

const types = @import("types.zig");
const mem = @import("mem.zig");

const Parser = types.Parser;
const Token = types.Token;
const Error = types.Error;
const Mark = types.Mark;
const String = mem.String;

/// `(int)parser->mark.column`.
///
/// `mark.column` is a `size_t` and every indentation comparison in this file
/// casts it to `int` first. The cast is spelled as a bit-truncation rather than
/// an `@intCast` so that a column past `INT_MAX` wraps the way the C does
/// instead of trapping in ReleaseSafe — a trap on an input the oracle survives
/// is a parity failure of its own.
inline fn markColumn(p: *const Parser) i32 {
    return @bitCast(@as(u32, @truncate(p.mark.column)));
}

/// `yaml_parser_scan_block_scalar`. `literal` picks `|` over `>`.
pub fn scanBlockScalar(p: *Parser, token: *Token, literal: bool) Error!void {
    var end_mark: Mark = undefined;
    var chomping: i32 = 0;
    var increment: i32 = 0;
    var indent: i32 = 0;
    var leading_blank = false;
    var trailing_blank = false;

    var string = try String.init(p.alloc, mem.INITIAL_STRING_SIZE);
    errdefer string.deinit(p.alloc);
    // Pooled on the parser rather than malloced per token — see
    // `Parser.scratch_leading_break`. `clear` on entry is what makes reuse
    // equivalent to the C's fresh `STRING_INIT`.
    const leading_break = &p.scratch_leading_break;
    leading_break.clear();
    const trailing_breaks = &p.scratch_trailing_breaks;
    trailing_breaks.clear();

    // Eat the indicator '|' or '>'.

    const start_mark = p.mark;

    p.skip();

    // Scan the additional block scalar indicators.

    try p.cache(1);

    // Check for a chomping indicator.

    if (p.check('+') or p.check('-')) {
        // Set the chomping method and eat the indicator.

        chomping = if (p.check('+')) 1 else -1;

        p.skip();

        // Check for an indentation indicator.

        try p.cache(1);

        if (p.isDigit()) {
            // Check that the indentation is greater than 0.

            if (p.check('0')) {
                return p.setScannerError(
                    "while scanning a block scalar",
                    start_mark,
                    "found an indentation indicator equal to 0",
                );
            }

            // Get the indentation level and eat the indicator.

            increment = p.asDigit();

            p.skip();
        }
    }

    // Do the same as above, but in the opposite order.

    else if (p.isDigit()) {
        if (p.check('0')) {
            return p.setScannerError(
                "while scanning a block scalar",
                start_mark,
                "found an indentation indicator equal to 0",
            );
        }

        increment = p.asDigit();

        p.skip();

        try p.cache(1);

        if (p.check('+') or p.check('-')) {
            chomping = if (p.check('+')) 1 else -1;

            p.skip();
        }
    }

    // Eat whitespaces and comments to the end of the line.

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
            "while scanning a block scalar",
            start_mark,
            "did not find expected comment or line break",
        );
    }

    // Eat a line break.

    if (p.isBreak()) {
        try p.cache(2);
        p.skipLine();
    }

    end_mark = p.mark;

    // Set the indentation level if it was specified.

    if (increment != 0) {
        // `+%`: the C adds two `int`s and lets a pathological indentation
        // overflow wrap (UB there, wrapping in practice). Wrapping explicitly
        // keeps ReleaseSafe from turning that into a trap.
        indent = if (p.indent >= 0) p.indent +% increment else increment;
    }

    // Scan the leading line breaks and determine the indentation level if needed.

    try scanBlockScalarBreaks(p, &indent, trailing_breaks, start_mark, &end_mark);

    // Scan the block scalar content.

    try p.cache(1);

    while (markColumn(p) == indent and !p.isZ()) {
        //
        // We are at the beginning of a non-empty line.
        //

        // Is it a trailing whitespace?

        trailing_blank = p.isBlank();

        // Check if we need to fold the leading line break.
        //
        // `leading_break.buf[0]` is the C's `*leading_break.start`: the read is
        // in bounds even when the string is empty because the allocation is
        // never zero-length and every byte past the cursor is zero. JOIN only
        // rewinds the source cursor, so a byte joined away is still readable
        // here — exactly as in the C.

        if (!literal and leading_break.buf[0] == '\n' and !leading_blank and !trailing_blank) {
            // Do we need to join the lines by space?

            if (trailing_breaks.buf[0] == '\x00') {
                try string.extend(p.alloc);
                string.putAssumeCapacity(' ');
            }

            leading_break.clear();
        } else {
            try string.join(p.alloc, leading_break);
            leading_break.clear();
        }

        // Append the remaining line breaks.

        try string.join(p.alloc, trailing_breaks);
        trailing_breaks.clear();

        // Is it a leading whitespace?

        leading_blank = p.isBlank();

        // Consume the current line.

        while (!p.isBreakz()) {
            try p.read(&string);
            try p.cache(1);
        }

        // Consume the line break.

        try p.cache(2);

        try p.readLine(leading_break);

        // Eat the following indentation spaces and line breaks.

        try scanBlockScalarBreaks(p, &indent, trailing_breaks, start_mark, &end_mark);
    }

    // Chomp the tail.

    if (chomping != -1) {
        try string.join(p.alloc, leading_break);
    }
    if (chomping == 1) {
        try string.join(p.alloc, trailing_breaks);
    }

    // Create a token.

    token.* = .{
        .data = .{ .scalar = .{
            .value = try string.toOwned(p.alloc),
            .style = if (literal) .literal else .folded,
        } },
        .start_mark = start_mark,
        .end_mark = end_mark,
    };
}

/// `yaml_parser_scan_block_scalar_breaks`: scan indentation spaces and line
/// breaks for a block scalar, determining the indentation level if needed.
fn scanBlockScalarBreaks(
    p: *Parser,
    indent: *i32,
    breaks: *String,
    start_mark: Mark,
    end_mark: *Mark,
) Error!void {
    var max_indent: i32 = 0;

    end_mark.* = p.mark;

    // Eat the indentation spaces and line breaks.

    while (true) {
        // Eat the indentation spaces.

        try p.cache(1);

        while ((indent.* == 0 or markColumn(p) < indent.*) and p.isSpace()) {
            p.skip();
            try p.cache(1);
        }

        if (markColumn(p) > max_indent)
            max_indent = markColumn(p);

        // Check for a tab character messing the indentation.

        if ((indent.* == 0 or markColumn(p) < indent.*) and p.isTab()) {
            return p.setScannerError(
                "while scanning a block scalar",
                start_mark,
                "found a tab character where an indentation space is expected",
            );
        }

        // Have we found a non-empty line?

        if (!p.isBreak()) break;

        // Consume the line break.

        try p.cache(2);
        try p.readLine(breaks);
        end_mark.* = p.mark;
    }

    // Determine the indentation level if needed.

    if (indent.* == 0) {
        indent.* = max_indent;
        // `+%` for the same reason as in scanBlockScalar: the C's `int` add is
        // allowed to wrap rather than trap.
        if (indent.* < p.indent +% 1)
            indent.* = p.indent +% 1;
        if (indent.* < 1)
            indent.* = 1;
    }
}

/// `yaml_parser_scan_flow_scalar`. `single` picks `'` over `"`.
pub fn scanFlowScalar(p: *Parser, token: *Token, single: bool) Error!void {
    // The C leaves `leading_blanks` uninitialized here; every iteration of the
    // content loop assigns it before the first read, so a definite `false` is
    // value-identical and keeps the Zig free of undefined reads.
    var leading_blanks = false;

    var string = try String.init(p.alloc, mem.INITIAL_STRING_SIZE);
    errdefer string.deinit(p.alloc);
    // Pooled on the parser rather than malloced per token — see
    // `Parser.scratch_leading_break`. `clear` on entry is what makes reuse
    // equivalent to the C's fresh `STRING_INIT`.
    const leading_break = &p.scratch_leading_break;
    leading_break.clear();
    const trailing_breaks = &p.scratch_trailing_breaks;
    trailing_breaks.clear();
    const whitespaces = &p.scratch_whitespaces;
    whitespaces.clear();

    // Eat the left quote.

    const start_mark = p.mark;

    p.skip();

    // Consume the content of the quoted scalar.

    while (true) {
        // Check that there are no document indicators at the beginning of the line.

        try p.cache(4);

        if (p.mark.column == 0 and
            ((p.checkAt('-', 0) and p.checkAt('-', 1) and p.checkAt('-', 2)) or
                (p.checkAt('.', 0) and p.checkAt('.', 1) and p.checkAt('.', 2))) and
            p.isBlankzAt(3))
        {
            return p.setScannerError(
                "while scanning a quoted scalar",
                start_mark,
                "found unexpected document indicator",
            );
        }

        // Check for EOF.

        if (p.isZ()) {
            return p.setScannerError(
                "while scanning a quoted scalar",
                start_mark,
                "found unexpected end of stream",
            );
        }

        // Consume non-blank characters.

        try p.cache(2);

        leading_blanks = false;

        while (!p.isBlankz()) {
            // Check for an escaped single quote.

            if (single and p.checkAt('\'', 0) and p.checkAt('\'', 1)) {
                try string.extend(p.alloc);
                string.putAssumeCapacity('\'');
                p.skip();
                p.skip();
            }

            // Check for the right quote.

            else if (p.check(if (single) '\'' else '"')) {
                break;
            }

            // Check for an escaped line break.

            else if (!single and p.check('\\') and p.isBreakAt(1)) {
                try p.cache(3);
                p.skip();
                p.skipLine();
                leading_blanks = true;
                break;
            }

            // Check for an escape sequence.

            else if (!single and p.check('\\')) {
                var code_length: usize = 0;

                try string.extend(p.alloc);

                // Check the escape character.

                switch (p.buffer.at(1)) {
                    '0' => string.putAssumeCapacity('\x00'),

                    'a' => string.putAssumeCapacity('\x07'),

                    'b' => string.putAssumeCapacity('\x08'),

                    't', '\t' => string.putAssumeCapacity('\x09'),

                    'n' => string.putAssumeCapacity('\x0A'),

                    'v' => string.putAssumeCapacity('\x0B'),

                    'f' => string.putAssumeCapacity('\x0C'),

                    'r' => string.putAssumeCapacity('\x0D'),

                    'e' => string.putAssumeCapacity('\x1B'),

                    ' ' => string.putAssumeCapacity('\x20'),

                    '"' => string.putAssumeCapacity('"'),

                    '/' => string.putAssumeCapacity('/'),

                    '\\' => string.putAssumeCapacity('\\'),

                    'N' => { // NEL (#x85)
                        string.putAssumeCapacity('\xC2');
                        string.putAssumeCapacity('\x85');
                    },

                    '_' => { // #xA0
                        string.putAssumeCapacity('\xC2');
                        string.putAssumeCapacity('\xA0');
                    },

                    'L' => { // LS (#x2028)
                        string.putAssumeCapacity('\xE2');
                        string.putAssumeCapacity('\x80');
                        string.putAssumeCapacity('\xA8');
                    },

                    'P' => { // PS (#x2029)
                        string.putAssumeCapacity('\xE2');
                        string.putAssumeCapacity('\x80');
                        string.putAssumeCapacity('\xA9');
                    },

                    'x' => code_length = 2,

                    'u' => code_length = 4,

                    'U' => code_length = 8,

                    else => return p.setScannerError(
                        "while parsing a quoted scalar",
                        start_mark,
                        "found unknown escape character",
                    ),
                }

                p.skip();
                p.skip();

                // Consume an arbitrary escape code.

                if (code_length != 0) {
                    var value: u32 = 0;

                    // Scan the character value.

                    try p.cache(code_length);

                    var k: usize = 0;
                    while (k < code_length) : (k += 1) {
                        if (!p.isHexAt(k)) {
                            return p.setScannerError(
                                "while parsing a quoted scalar",
                                start_mark,
                                "did not find expected hexdecimal number",
                            );
                        }
                        value = (value << 4) + p.asHexAt(k);
                    }

                    // Check the value and write the character.

                    if ((value >= 0xD800 and value <= 0xDFFF) or value > 0x10FFFF) {
                        return p.setScannerError(
                            "while parsing a quoted scalar",
                            start_mark,
                            "found invalid Unicode character escape code",
                        );
                    }

                    // The `@truncate`s below are the C's implicit narrowing to
                    // `yaml_char_t` on assignment; the surrounding range checks
                    // already make every one of them exact.

                    if (value <= 0x7F) {
                        string.putAssumeCapacity(@truncate(value));
                    } else if (value <= 0x7FF) {
                        string.putAssumeCapacity(@truncate(0xC0 + (value >> 6)));
                        string.putAssumeCapacity(@truncate(0x80 + (value & 0x3F)));
                    } else if (value <= 0xFFFF) {
                        string.putAssumeCapacity(@truncate(0xE0 + (value >> 12)));
                        string.putAssumeCapacity(@truncate(0x80 + ((value >> 6) & 0x3F)));
                        string.putAssumeCapacity(@truncate(0x80 + (value & 0x3F)));
                    } else {
                        string.putAssumeCapacity(@truncate(0xF0 + (value >> 18)));
                        string.putAssumeCapacity(@truncate(0x80 + ((value >> 12) & 0x3F)));
                        string.putAssumeCapacity(@truncate(0x80 + ((value >> 6) & 0x3F)));
                        string.putAssumeCapacity(@truncate(0x80 + (value & 0x3F)));
                    }

                    // Advance the pointer.

                    k = 0;
                    while (k < code_length) : (k += 1) {
                        p.skip();
                    }
                }
            } else {
                // It is a non-escaped non-blank character.

                try p.read(&string);
            }

            try p.cache(2);
        }

        // Check if we are at the end of the scalar.

        // Fix for crash uninitialized value crash
        // Credit for the bug and input is to OSS Fuzz
        // Credit for the fix to Alex Gaynor
        try p.cache(1);
        if (p.check(if (single) '\'' else '"'))
            break;

        // Consume blank characters.

        try p.cache(1);

        while (p.isBlank() or p.isBreak()) {
            if (p.isBlank()) {
                // Consume a space or a tab character.

                if (!leading_blanks) {
                    try p.read(whitespaces);
                } else {
                    p.skip();
                }
            } else {
                try p.cache(2);

                // Check if it is a first line break.

                if (!leading_blanks) {
                    whitespaces.clear();
                    try p.readLine(leading_break);
                    leading_blanks = true;
                } else {
                    try p.readLine(trailing_breaks);
                }
            }
            try p.cache(1);
        }

        // Join the whitespaces or fold line breaks.

        if (leading_blanks) {
            // Do we need to fold line breaks?

            if (leading_break.buf[0] == '\n') {
                if (trailing_breaks.buf[0] == '\x00') {
                    try string.extend(p.alloc);
                    string.putAssumeCapacity(' ');
                } else {
                    try string.join(p.alloc, trailing_breaks);
                    trailing_breaks.clear();
                }
                leading_break.clear();
            } else {
                try string.join(p.alloc, leading_break);
                try string.join(p.alloc, trailing_breaks);
                leading_break.clear();
                trailing_breaks.clear();
            }
        } else {
            try string.join(p.alloc, whitespaces);
            whitespaces.clear();
        }
    }

    // Eat the right quote.

    p.skip();

    const end_mark = p.mark;

    // Create a token.

    token.* = .{
        .data = .{ .scalar = .{
            .value = try string.toOwned(p.alloc),
            .style = if (single) .single_quoted else .double_quoted,
        } },
        .start_mark = start_mark,
        .end_mark = end_mark,
    };
}

/// `yaml_parser_scan_plain_scalar`
pub fn scanPlainScalar(p: *Parser, token: *Token) Error!void {
    var leading_blanks = false;
    // `+%`: the C's `parser->indent + 1` is an `int` add that is allowed to
    // wrap rather than trap.
    const indent: i32 = p.indent +% 1;

    var string = try String.init(p.alloc, mem.INITIAL_STRING_SIZE);
    errdefer string.deinit(p.alloc);
    // Pooled on the parser rather than malloced per token — see
    // `Parser.scratch_leading_break`. `clear` on entry is what makes reuse
    // equivalent to the C's fresh `STRING_INIT`.
    const leading_break = &p.scratch_leading_break;
    leading_break.clear();
    const trailing_breaks = &p.scratch_trailing_breaks;
    trailing_breaks.clear();
    const whitespaces = &p.scratch_whitespaces;
    whitespaces.clear();

    const start_mark = p.mark;
    var end_mark = p.mark;

    // Consume the content of the plain scalar.

    while (true) {
        // Check for a document indicator.

        try p.cache(4);

        if (p.mark.column == 0 and
            ((p.checkAt('-', 0) and p.checkAt('-', 1) and p.checkAt('-', 2)) or
                (p.checkAt('.', 0) and p.checkAt('.', 1) and p.checkAt('.', 2))) and
            p.isBlankzAt(3)) break;

        // Check for a comment.

        if (p.check('#'))
            break;

        // Consume non-blank characters.

        while (!p.isBlankz()) {
            // Check for "x:" + one of ',?[]{}' in the flow context. TODO: Fix the test "spec-08-13".
            // This is not completely according to the spec
            // See http://yaml.org/spec/1.1/#id907281 9.1.3. Plain

            if (p.flow_level != 0 and p.check(':') and
                (p.checkAt(',', 1) or
                    p.checkAt('?', 1) or
                    p.checkAt('[', 1) or
                    p.checkAt(']', 1) or
                    p.checkAt('{', 1) or
                    p.checkAt('}', 1)))
            {
                return p.setScannerError(
                    "while scanning a plain scalar",
                    start_mark,
                    "found unexpected ':'",
                );
            }

            // Check for indicators that may end a plain scalar.

            if ((p.check(':') and p.isBlankzAt(1)) or
                (p.flow_level != 0 and
                    (p.check(',') or
                        p.check('[') or
                        p.check(']') or p.check('{') or
                        p.check('}')))) break;

            // Check if we need to join whitespaces and breaks.

            if (leading_blanks or !whitespaces.isEmpty()) {
                if (leading_blanks) {
                    // Do we need to fold line breaks?

                    if (leading_break.buf[0] == '\n') {
                        if (trailing_breaks.buf[0] == '\x00') {
                            try string.extend(p.alloc);
                            string.putAssumeCapacity(' ');
                        } else {
                            try string.join(p.alloc, trailing_breaks);
                            trailing_breaks.clear();
                        }
                        leading_break.clear();
                    } else {
                        try string.join(p.alloc, leading_break);
                        try string.join(p.alloc, trailing_breaks);
                        leading_break.clear();
                        trailing_breaks.clear();
                    }

                    leading_blanks = false;
                } else {
                    try string.join(p.alloc, whitespaces);
                    whitespaces.clear();
                }
            }

            // Copy the character.

            try p.read(&string);

            end_mark = p.mark;

            try p.cache(2);
        }

        // Is it the end?

        if (!(p.isBlank() or p.isBreak()))
            break;

        // Consume blank characters.

        try p.cache(1);

        while (p.isBlank() or p.isBreak()) {
            if (p.isBlank()) {
                // Check for tab characters that abuse indentation.

                if (leading_blanks and markColumn(p) < indent and p.isTab()) {
                    return p.setScannerError(
                        "while scanning a plain scalar",
                        start_mark,
                        "found a tab character that violates indentation",
                    );
                }

                // Consume a space or a tab character.

                if (!leading_blanks) {
                    try p.read(whitespaces);
                } else {
                    p.skip();
                }
            } else {
                try p.cache(2);

                // Check if it is a first line break.

                if (!leading_blanks) {
                    whitespaces.clear();
                    try p.readLine(leading_break);
                    leading_blanks = true;
                } else {
                    try p.readLine(trailing_breaks);
                }
            }
            try p.cache(1);
        }

        // Check indentation level.

        if (p.flow_level == 0 and markColumn(p) < indent)
            break;
    }

    // Create a token.

    token.* = .{
        .data = .{ .scalar = .{
            .value = try string.toOwned(p.alloc),
            .style = .plain,
        } },
        .start_mark = start_mark,
        .end_mark = end_mark,
    };

    // Note that we change the 'simple_key_allowed' flag.

    if (leading_blanks) {
        p.simple_key_allowed = true;
    }
}
