//! Port of libyaml's `src/reader.c`: encoding detection and the decode of the
//! raw input into the parser's character buffer.
//!
//! Three functions, 1:1 with the C: `yaml_parser_determine_encoding`,
//! `yaml_parser_update_raw_buffer` and `yaml_parser_update_buffer`. The fourth,
//! `yaml_parser_set_reader_error`, is `Parser.setReaderError` in types.zig.
//!
//! The C's `start`/`pointer`/`end`/`last` pointer quad is `mem.Buffer`'s
//! `mem`/`pos`/`cap`/`last` (see mem.zig), so the pointer differences become
//! index differences:
//!
//!   raw_buffer.last - raw_buffer.pointer   ->   raw_buffer.last - raw_buffer.pos
//!   raw_buffer.end - raw_buffer.last       ->   raw_buffer.cap - raw_buffer.last
//!   raw_buffer.start == raw_buffer.pointer ->   raw_buffer.pos == 0
//!   *(buffer.last++) = value               ->   put(p, value)

const std = @import("std");
const mem = @import("mem.zig");
const types = @import("types.zig");

const Parser = types.Parser;
const Error = types.Error;

/// Byte order marks.
const BOM_UTF8 = "\xef\xbb\xbf";
const BOM_UTF16LE = "\xff\xfe";
const BOM_UTF16BE = "\xfe\xff";

/// `*(parser->buffer.last++) = octet`.
///
/// The C writes straight through `buffer.last`, leaning on the "length is
/// supposed to be significantly less than the buffer size" contract above
/// `yaml_parser_update_buffer` to keep it inside the allocation. Here the same
/// write must also stay below `cap`: the bytes from `cap` to the end of the
/// allocation are the guard chars.zig's multi-byte lookahead reads, and they
/// are only safe to read because they stay zero. The assert turns what would be
/// a silent heap overrun in the C into a trap.
inline fn put(p: *Parser, octet: u8) void {
    std.debug.assert(p.buffer.last < p.buffer.cap);
    p.buffer.mem[p.buffer.last] = octet;
    p.buffer.last += 1;
}

/// `yaml_parser_determine_encoding`: pick the input encoding from the BOM, or
/// assume UTF-8 when there is none.
fn determineEncoding(p: *Parser) Error!void {
    // Ensure that we had enough bytes in the raw buffer.

    while (!p.eof and p.raw_buffer.last - p.raw_buffer.pos < 3) {
        try updateRawBuffer(p);
    }

    // Determine the encoding.

    const rb = &p.raw_buffer;
    const avail = rb.last - rb.pos;
    const head = rb.mem[rb.pos..rb.last];

    if (avail >= 2 and std.mem.eql(u8, head[0..2], BOM_UTF16LE)) {
        p.encoding = .utf16le;
        rb.pos += 2;
        p.offset += 2;
    } else if (avail >= 2 and std.mem.eql(u8, head[0..2], BOM_UTF16BE)) {
        p.encoding = .utf16be;
        rb.pos += 2;
        p.offset += 2;
    } else if (avail >= 3 and std.mem.eql(u8, head[0..3], BOM_UTF8)) {
        p.encoding = .utf8;
        rb.pos += 3;
        p.offset += 3;
    } else {
        p.encoding = .utf8;
    }
}

/// `yaml_parser_update_raw_buffer`: slide the unread bytes down and refill.
fn updateRawBuffer(p: *Parser) Error!void {
    var size_read: usize = 0;
    const rb = &p.raw_buffer;

    // Return if the raw buffer is full.

    if (rb.pos == 0 and rb.last == rb.cap) return;

    // Return on EOF.

    if (p.eof) return;

    // Move the remaining bytes in the raw buffer to the beginning.

    if (0 < rb.pos and rb.pos < rb.last) {
        // The C's memmove: the ranges overlap whenever fewer than `pos` bytes
        // are unread, and the copy walks downwards, so copyForwards is the
        // direction-correct spelling.
        std.mem.copyForwards(u8, rb.mem[0 .. rb.last - rb.pos], rb.mem[rb.pos..rb.last]);
    }
    rb.last -= rb.pos;
    rb.pos = 0;

    // Call the read handler to fill the buffer.

    if (!p.read_handler.?(p, rb.mem[rb.last..rb.cap], &size_read)) {
        return p.setReaderError("input error", p.offset, -1);
    }
    rb.last += size_read;
    if (size_read == 0) {
        p.eof = true;
    }
}

/// `yaml_parser_update_buffer`: ensure the buffer holds at least `length`
/// characters at the cursor.
///
/// The length is supposed to be significantly less than the buffer size.
pub fn updateBuffer(p: *Parser, length: usize) Error!void {
    var first = true;

    std.debug.assert(p.read_handler != null); // Read handler must be set.

    // If the EOF flag is set and the raw buffer is empty, do nothing.

    if (p.eof and p.raw_buffer.pos == p.raw_buffer.last) return;

    // Return if the buffer contains enough characters.

    if (p.unread >= length) return;

    // Determine the input encoding if it is not known yet.

    if (p.encoding == .any) {
        try determineEncoding(p);
    }

    // Move the unread characters to the beginning of the buffer.

    const b = &p.buffer;
    if (0 < b.pos and b.pos < b.last) {
        const size = b.last - b.pos;
        std.mem.copyForwards(u8, b.mem[0..size], b.mem[b.pos..b.last]);
        b.pos = 0;
        b.last = size;
    } else if (b.pos == b.last) {
        b.pos = 0;
        b.last = 0;
    }

    // Fill the buffer until it has enough characters.

    while (p.unread < length) {

        // Fill the raw buffer if necessary.

        if (!first or p.raw_buffer.pos == p.raw_buffer.last) {
            try updateRawBuffer(p);
        }
        first = false;

        // Decode the raw buffer.

        while (p.raw_buffer.pos != p.raw_buffer.last) {
            var value: u32 = 0;
            var incomplete = false;
            var width: usize = 0;
            const raw_unread = p.raw_buffer.last - p.raw_buffer.pos;
            const raw = p.raw_buffer.mem;
            const rp = p.raw_buffer.pos;

            // Decode the next character. The labelled block is the C's
            // `switch`: `break :decode` is its `break`, leaving the switch with
            // `incomplete` set so the `if (incomplete) break` below leaves the
            // inner `while` instead.

            decode: {
                switch (p.encoding) {
                    .utf8 => {

                        // Decode a UTF-8 character. Check RFC 3629
                        // (http://www.ietf.org/rfc/rfc3629.txt) for more details.
                        //
                        // The following table (taken from the RFC) is used for
                        // decoding.
                        //
                        //    Char. number range |        UTF-8 octet sequence
                        //      (hexadecimal)    |              (binary)
                        //   --------------------+------------------------------------
                        //   0000 0000-0000 007F | 0xxxxxxx
                        //   0000 0080-0000 07FF | 110xxxxx 10xxxxxx
                        //   0000 0800-0000 FFFF | 1110xxxx 10xxxxxx 10xxxxxx
                        //   0001 0000-0010 FFFF | 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
                        //
                        // Additionally, the characters in the range 0xD800-0xDFFF
                        // are prohibited as they are reserved for use with UTF-16
                        // surrogate pairs.

                        // Determine the length of the UTF-8 sequence.

                        var octet: u8 = raw[rp];
                        width = if (octet & 0x80 == 0x00) 1 //
                            else if (octet & 0xE0 == 0xC0) 2 //
                            else if (octet & 0xF0 == 0xE0) 3 //
                            else if (octet & 0xF8 == 0xF0) 4 //
                            else 0;

                        // Check if the leading octet is valid.

                        if (width == 0) {
                            return p.setReaderError("invalid leading UTF-8 octet", p.offset, octet);
                        }

                        // Check if the raw buffer contains an incomplete character.

                        if (width > raw_unread) {
                            if (p.eof) {
                                return p.setReaderError("incomplete UTF-8 octet sequence", p.offset, -1);
                            }
                            incomplete = true;
                            break :decode;
                        }

                        // Decode the leading octet.

                        value = if (octet & 0x80 == 0x00) octet & 0x7F //
                        else if (octet & 0xE0 == 0xC0) octet & 0x1F //
                        else if (octet & 0xF0 == 0xE0) octet & 0x0F //
                        else if (octet & 0xF8 == 0xF0) octet & 0x07 //
                        else 0;

                        // Check and decode the trailing octets.

                        var k: usize = 1;
                        while (k < width) : (k += 1) {
                            octet = raw[rp + k];

                            // Check if the octet is valid.

                            if (octet & 0xC0 != 0x80) {
                                return p.setReaderError("invalid trailing UTF-8 octet", p.offset + k, octet);
                            }

                            // Decode the octet.

                            value = (value << 6) + (octet & 0x3F);
                        }

                        // Check the length of the sequence against the value.

                        if (!((width == 1) or
                            (width == 2 and value >= 0x80) or
                            (width == 3 and value >= 0x800) or
                            (width == 4 and value >= 0x10000)))
                        {
                            return p.setReaderError("invalid length of a UTF-8 sequence", p.offset, -1);
                        }

                        // Check the range of the value.

                        if ((value >= 0xD800 and value <= 0xDFFF) or value > 0x10FFFF) {
                            return p.setReaderError("invalid Unicode character", p.offset, @intCast(value));
                        }
                    },

                    .utf16le, .utf16be => {
                        const low: usize = if (p.encoding == .utf16le) 0 else 1;
                        const high: usize = if (p.encoding == .utf16le) 1 else 0;

                        // The UTF-16 encoding is not as simple as one might
                        // naively think. Check RFC 2781
                        // (http://www.ietf.org/rfc/rfc2781.txt).
                        //
                        // Normally, two subsequent bytes describe a Unicode
                        // character. However a special technique (called a
                        // surrogate pair) is used for specifying character
                        // values larger than 0xFFFF.
                        //
                        // A surrogate pair consists of two pseudo-characters:
                        //      high surrogate area (0xD800-0xDBFF)
                        //      low surrogate area (0xDC00-0xDFFF)
                        //
                        // The following formulas are used for decoding
                        // and encoding characters using surrogate pairs:
                        //
                        //  U  = U' + 0x10000   (0x01 00 00 <= U <= 0x10 FF FF)
                        //  U' = yyyyyyyyyyxxxxxxxxxx   (0 <= U' <= 0x0F FF FF)
                        //  W1 = 110110yyyyyyyyyy
                        //  W2 = 110111xxxxxxxxxx
                        //
                        // where U is the character value, W1 is the high surrogate
                        // area, W2 is the low surrogate area.

                        // Check for incomplete UTF-16 character.

                        if (raw_unread < 2) {
                            if (p.eof) {
                                return p.setReaderError("incomplete UTF-16 character", p.offset, -1);
                            }
                            incomplete = true;
                            break :decode;
                        }

                        // Get the character.

                        value = @as(u32, raw[rp + low]) + (@as(u32, raw[rp + high]) << 8);

                        // Check for unexpected low surrogate area.

                        if (value & 0xFC00 == 0xDC00) {
                            return p.setReaderError("unexpected low surrogate area", p.offset, @intCast(value));
                        }

                        // Check for a high surrogate area.

                        if (value & 0xFC00 == 0xD800) {
                            width = 4;

                            // Check for incomplete surrogate pair.

                            if (raw_unread < 4) {
                                if (p.eof) {
                                    return p.setReaderError("incomplete UTF-16 surrogate pair", p.offset, -1);
                                }
                                incomplete = true;
                                break :decode;
                            }

                            // Get the next character.

                            const value2 = @as(u32, raw[rp + low + 2]) + (@as(u32, raw[rp + high + 2]) << 8);

                            // Check for a low surrogate area.

                            if (value2 & 0xFC00 != 0xDC00) {
                                return p.setReaderError("expected low surrogate area", p.offset + 2, @intCast(value2));
                            }

                            // Generate the value of the surrogate pair.

                            value = 0x10000 + ((value & 0x3FF) << 10) + (value2 & 0x3FF);
                        } else {
                            width = 2;
                        }
                    },

                    // The C's `default: assert(1);` — a no-op assert, so in C
                    // this falls through with value 0 and is rejected as a
                    // control character. It cannot be reached either way:
                    // `determine_encoding` above always leaves a concrete
                    // encoding behind.
                    .any => unreachable,
                }
            }

            // Check if the raw buffer contains enough bytes to form a character.

            if (incomplete) break;

            // Check if the character is in the allowed range:
            //      #x9 | #xA | #xD | [#x20-#x7E]               (8 bit)
            //      | #x85 | [#xA0-#xD7FF] | [#xE000-#xFFFD]    (16 bit)
            //      | [#x10000-#x10FFFF]                        (32 bit)

            if (!(value == 0x09 or value == 0x0A or value == 0x0D or
                (value >= 0x20 and value <= 0x7E) or
                (value == 0x85) or (value >= 0xA0 and value <= 0xD7FF) or
                (value >= 0xE000 and value <= 0xFFFD) or
                (value >= 0x10000 and value <= 0x10FFFF)))
            {
                return p.setReaderError("control characters are not allowed", p.offset, @intCast(value));
            }

            // Move the raw pointers.

            p.raw_buffer.pos += width;
            p.offset += width;

            // Finally put the character into the buffer.

            if (value <= 0x7F) {
                // 0000 0000-0000 007F -> 0xxxxxxx
                put(p, @intCast(value));
            } else if (value <= 0x7FF) {
                // 0000 0080-0000 07FF -> 110xxxxx 10xxxxxx
                put(p, @intCast(0xC0 + (value >> 6)));
                put(p, @intCast(0x80 + (value & 0x3F)));
            } else if (value <= 0xFFFF) {
                // 0000 0800-0000 FFFF -> 1110xxxx 10xxxxxx 10xxxxxx
                put(p, @intCast(0xE0 + (value >> 12)));
                put(p, @intCast(0x80 + ((value >> 6) & 0x3F)));
                put(p, @intCast(0x80 + (value & 0x3F)));
            } else {
                // 0001 0000-0010 FFFF -> 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
                put(p, @intCast(0xF0 + (value >> 18)));
                put(p, @intCast(0x80 + ((value >> 12) & 0x3F)));
                put(p, @intCast(0x80 + ((value >> 6) & 0x3F)));
                put(p, @intCast(0x80 + (value & 0x3F)));
            }

            p.unread += 1;
        }

        // On EOF, put NUL into the buffer and return.

        if (p.eof) {
            put(p, 0);
            p.unread += 1;
            return;
        }
    }

    if (p.offset >= mem.MAX_FILE_SIZE) {
        return p.setReaderError("input is too long", p.offset, -1);
    }
}

// ---- Tests ----

const testing = std.testing;
const api = @import("api.zig");

/// Decode `input` in one go and return the parser, so a test can inspect the
/// decoded window. The caller deinits.
fn decodeAll(input: []const u8) Error!Parser {
    var p = try api.init(testing.allocator);
    errdefer api.deinit(&p);
    api.setInputString(&p, input);
    // 1 more than the expected character count, so the loop runs to EOF and
    // appends the NUL.
    try updateBuffer(&p, input.len + 2);
    return p;
}

test "UTF-8 input decodes verbatim and is NUL-terminated at EOF" {
    var p = try decodeAll("a: b\n");
    defer api.deinit(&p);

    try testing.expectEqual(types.Encoding.utf8, p.encoding);
    try testing.expectEqualStrings("a: b\n\x00", p.buffer.mem[0..p.buffer.last]);
    try testing.expectEqual(@as(usize, 6), p.unread); // five characters + NUL
}

test "a UTF-8 BOM is consumed, not decoded" {
    var p = try decodeAll("\xef\xbb\xbfx");
    defer api.deinit(&p);

    try testing.expectEqual(types.Encoding.utf8, p.encoding);
    try testing.expectEqualStrings("x\x00", p.buffer.mem[0..p.buffer.last]);
    try testing.expectEqual(@as(usize, 4), p.offset); // BOM + 'x'
}

test "UTF-16 BOMs switch the encoding and the input is re-encoded as UTF-8" {
    var le = try decodeAll("\xff\xfeh\x00i\x00");
    defer api.deinit(&le);
    try testing.expectEqual(types.Encoding.utf16le, le.encoding);
    try testing.expectEqualStrings("hi\x00", le.buffer.mem[0..le.buffer.last]);

    var be = try decodeAll("\xfe\xff\x00h\x00i");
    defer api.deinit(&be);
    try testing.expectEqual(types.Encoding.utf16be, be.encoding);
    try testing.expectEqualStrings("hi\x00", be.buffer.mem[0..be.buffer.last]);
}

test "a UTF-16 surrogate pair becomes a four-byte UTF-8 sequence" {
    // U+1F600, encoded UTF-16LE as D83D DE00.
    var p = try decodeAll("\xff\xfe\x3d\xd8\x00\xde");
    defer api.deinit(&p);
    try testing.expectEqualStrings("\u{1F600}\x00", p.buffer.mem[0..p.buffer.last]);
}

test "reader errors carry the C's problem strings" {
    const cases = [_]struct { input: []const u8, problem: []const u8 }{
        .{ .input = "\xff", .problem = "invalid leading UTF-8 octet" },
        .{ .input = "\xc3", .problem = "incomplete UTF-8 octet sequence" },
        .{ .input = "\xc3\x28", .problem = "invalid trailing UTF-8 octet" },
        .{ .input = "\xc0\x80", .problem = "invalid length of a UTF-8 sequence" },
        .{ .input = "\xed\xa0\x80", .problem = "invalid Unicode character" },
        .{ .input = "\x01", .problem = "control characters are not allowed" },
        .{ .input = "\xff\xfe\x00\xdc", .problem = "unexpected low surrogate area" },
        .{ .input = "\xff\xfe\x3d\xd8\x41\x00", .problem = "expected low surrogate area" },
        .{ .input = "\xff\xfe\x3d\xd8", .problem = "incomplete UTF-16 surrogate pair" },
        .{ .input = "\xff\xfeA", .problem = "incomplete UTF-16 character" },
    };

    for (cases) |c| {
        var p = try api.init(testing.allocator);
        defer api.deinit(&p);
        api.setInputString(&p, c.input);
        try testing.expectError(error.Yaml, updateBuffer(&p, c.input.len + 2));
        try testing.expectEqual(types.ErrorType.reader, p.err);
        try testing.expectEqualStrings(c.problem, p.problem.?);
    }
}

test "input longer than one raw buffer decodes across refills" {
    const size = mem.INPUT_RAW_BUFFER_SIZE + 1024;
    const input = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(input);
    @memset(input, 'x');

    var p = try api.init(testing.allocator);
    defer api.deinit(&p);
    api.setInputString(&p, input);

    // Consume the window a character at a time, the way the scanner does.
    var seen: usize = 0;
    while (true) {
        try p.cache(1);
        if (p.check(0)) break;
        try testing.expect(p.check('x'));
        p.skip();
        seen += 1;
    }
    try testing.expectEqual(size, seen);
}
