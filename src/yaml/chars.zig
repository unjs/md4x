//! The character-class predicates from libyaml's `src/yaml_private.h`.
//!
//! Every `IS_*` / `AS_*` / `WIDTH` macro is ported here as an inline function
//! over the parser's decoded input window. In the C they are macros over
//! `(string).pointer[offset]`, and in `src/scanner.c` the argument is ALWAYS
//! `parser->buffer` — there is not one use on a `yaml_string_t` local — so the
//! port takes a `*const mem.Buffer` and an offset, and `Parser` re-exports each
//! one as a method so call sites read like the C:
//!
//!   IS_BLANKZ_AT(parser->buffer, i)   ->   parser.isBlankzAt(i)
//!   CHECK(parser->buffer, '-')        ->   parser.check('-')
//!   WIDTH(parser->buffer)             ->   parser.width()
//!
//! The multi-byte predicates read up to two bytes past the byte they test.
//! That is in-bounds by construction: `mem.Buffer` over-allocates by
//! `Buffer.guard` zero bytes, and each such predicate only looks ahead after
//! matching a lead byte that the reader guaranteed is followed by its
//! continuation bytes.

const mem = @import("mem.zig");
const Buffer = mem.Buffer;

/// `CHECK_AT(string, octet, offset)`
pub fn checkAt(b: *const Buffer, octet: u8, offset: usize) bool {
    return b.at(offset) == octet;
}

/// `CHECK(string, octet)`
pub fn check(b: *const Buffer, octet: u8) bool {
    return checkAt(b, octet, 0);
}

/// `IS_ALPHA_AT`: an ASCII alphanumeric, `_` or `-`.
pub fn isAlphaAt(b: *const Buffer, offset: usize) bool {
    const c = b.at(offset);
    return (c >= '0' and c <= '9') or
        (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        c == '_' or c == '-';
}

pub fn isAlpha(b: *const Buffer) bool {
    return isAlphaAt(b, 0);
}

/// `IS_DIGIT_AT`
pub fn isDigitAt(b: *const Buffer, offset: usize) bool {
    const c = b.at(offset);
    return c >= '0' and c <= '9';
}

pub fn isDigit(b: *const Buffer) bool {
    return isDigitAt(b, 0);
}

/// `AS_DIGIT_AT`
pub fn asDigitAt(b: *const Buffer, offset: usize) u8 {
    return b.at(offset) - '0';
}

pub fn asDigit(b: *const Buffer) u8 {
    return asDigitAt(b, 0);
}

/// `IS_HEX_AT`
pub fn isHexAt(b: *const Buffer, offset: usize) bool {
    const c = b.at(offset);
    return (c >= '0' and c <= '9') or
        (c >= 'A' and c <= 'F') or
        (c >= 'a' and c <= 'f');
}

pub fn isHex(b: *const Buffer) bool {
    return isHexAt(b, 0);
}

/// `AS_HEX_AT`
pub fn asHexAt(b: *const Buffer, offset: usize) u8 {
    const c = b.at(offset);
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return c - '0';
}

pub fn asHex(b: *const Buffer) u8 {
    return asHexAt(b, 0);
}

/// `IS_ASCII_AT`
pub fn isAsciiAt(b: *const Buffer, offset: usize) bool {
    return b.at(offset) <= 0x7F;
}

pub fn isAscii(b: *const Buffer) bool {
    return isAsciiAt(b, 0);
}

/// `IS_PRINTABLE_AT`: a character that can be written unescaped.
pub fn isPrintableAt(b: *const Buffer, offset: usize) bool {
    const c = b.at(offset);
    return c == 0x0A // . == #x0A
    or (c >= 0x20 and c <= 0x7E) // #x20 <= . <= #x7E
    or (c == 0xC2 and b.at(offset + 1) >= 0xA0) // #xA0 <= . <= #xD7FF
    or (c > 0xC2 and c < 0xED) or (c == 0xED and b.at(offset + 1) < 0xA0) or (c == 0xEE) or (c == 0xEF // #xE000 <= . <= #xFFFD
    and !(b.at(offset + 1) == 0xBB and b.at(offset + 2) == 0xBF) // && . != #xFEFF
    and !(b.at(offset + 1) == 0xBF and (b.at(offset + 2) == 0xBE or b.at(offset + 2) == 0xBF)));
}

pub fn isPrintable(b: *const Buffer) bool {
    return isPrintableAt(b, 0);
}

/// `IS_Z_AT`: NUL, which is also how libyaml spells end-of-input.
pub fn isZAt(b: *const Buffer, offset: usize) bool {
    return checkAt(b, 0, offset);
}

pub fn isZ(b: *const Buffer) bool {
    return isZAt(b, 0);
}

/// `IS_BOM_AT`
pub fn isBomAt(b: *const Buffer, offset: usize) bool {
    return checkAt(b, 0xEF, offset) and checkAt(b, 0xBB, offset + 1) and checkAt(b, 0xBF, offset + 2);
}

pub fn isBom(b: *const Buffer) bool {
    return isBomAt(b, 0);
}

/// `IS_SPACE_AT`
pub fn isSpaceAt(b: *const Buffer, offset: usize) bool {
    return checkAt(b, ' ', offset);
}

pub fn isSpace(b: *const Buffer) bool {
    return isSpaceAt(b, 0);
}

/// `IS_TAB_AT`
pub fn isTabAt(b: *const Buffer, offset: usize) bool {
    return checkAt(b, '\t', offset);
}

pub fn isTab(b: *const Buffer) bool {
    return isTabAt(b, 0);
}

/// `IS_BLANK_AT`: space or tab.
pub fn isBlankAt(b: *const Buffer, offset: usize) bool {
    return isSpaceAt(b, offset) or isTabAt(b, offset);
}

pub fn isBlank(b: *const Buffer) bool {
    return isBlankAt(b, 0);
}

/// `IS_BREAK_AT`: CR, LF, NEL (#x85), LS (#x2028) or PS (#x2029).
pub fn isBreakAt(b: *const Buffer, offset: usize) bool {
    return checkAt(b, '\r', offset) // CR (#xD)
    or checkAt(b, '\n', offset) // LF (#xA)
    or (checkAt(b, 0xC2, offset) and checkAt(b, 0x85, offset + 1)) // NEL (#x85)
    or (checkAt(b, 0xE2, offset) and checkAt(b, 0x80, offset + 1) and checkAt(b, 0xA8, offset + 2)) // LS (#x2028)
    or (checkAt(b, 0xE2, offset) and checkAt(b, 0x80, offset + 1) and checkAt(b, 0xA9, offset + 2)); // PS (#x2029)
}

pub fn isBreak(b: *const Buffer) bool {
    return isBreakAt(b, 0);
}

/// `IS_CRLF_AT`
pub fn isCrlfAt(b: *const Buffer, offset: usize) bool {
    return checkAt(b, '\r', offset) and checkAt(b, '\n', offset + 1);
}

pub fn isCrlf(b: *const Buffer) bool {
    return isCrlfAt(b, 0);
}

/// `IS_BREAKZ_AT`: a line break or NUL.
pub fn isBreakzAt(b: *const Buffer, offset: usize) bool {
    return isBreakAt(b, offset) or isZAt(b, offset);
}

pub fn isBreakz(b: *const Buffer) bool {
    return isBreakzAt(b, 0);
}

/// `IS_SPACEZ_AT`: a space, line break or NUL.
pub fn isSpacezAt(b: *const Buffer, offset: usize) bool {
    return isSpaceAt(b, offset) or isBreakzAt(b, offset);
}

pub fn isSpacez(b: *const Buffer) bool {
    return isSpacezAt(b, 0);
}

/// `IS_BLANKZ_AT`: a space, tab, line break or NUL.
pub fn isBlankzAt(b: *const Buffer, offset: usize) bool {
    return isBlankAt(b, offset) or isBreakzAt(b, offset);
}

pub fn isBlankz(b: *const Buffer) bool {
    return isBlankzAt(b, 0);
}

/// `WIDTH_AT`: the byte width of the UTF-8 character at `offset`, or 0 for a
/// byte that cannot start one.
pub fn widthAt(b: *const Buffer, offset: usize) usize {
    const c = b.at(offset);
    if (c & 0x80 == 0x00) return 1;
    if (c & 0xE0 == 0xC0) return 2;
    if (c & 0xF0 == 0xE0) return 3;
    if (c & 0xF8 == 0xF0) return 4;
    return 0;
}

pub fn width(b: *const Buffer) usize {
    return widthAt(b, 0);
}
