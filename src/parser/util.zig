// MD4X parser — low-level utilities module.
//
// Char access/classification, UTF-8 codec, unicode wiring (via unicode_tables),
// growable buffer + libc malloc/realloc wrappers, line merging, entity
// recognizers, MD_ATTRIBUTE building, line lookup. Extracted verbatim from the
// monolithic src/md4x.zig (pure refactor — no logic change). See AGENTS.md.

const std = @import("std");
const utbl = @import("../unicode_tables.zig");
const types = @import("types.zig");

const c = types.c;
const CHAR = types.CHAR;
const SZ = types.SZ;
const OFF = types.OFF;
const MD_SIZE = types.MD_SIZE;
const TRUE = types.TRUE;
const FALSE = types.FALSE;
const MD_CTX = types.MD_CTX;
const MD_LINE = types.MD_LINE;
const md_log = types.md_log;
const c_allocator = types.c_allocator;

// Character accessors. `CH(off)` / `STR(off)` from md4x.c operate on the
// enclosing `ctx`; here they are explicit helpers taking `ctx`.
// NOTE: ctx.text is `char*`; in classification we always reinterpret as the
// unsigned byte value to match the C `(unsigned)(ch)` casts.
pub inline fn CH(ctx: *const MD_CTX, off: OFF) CHAR {
    return ctx.text[off];
}
pub inline fn STR(ctx: *const MD_CTX, off: OFF) [*c]const CHAR {
    return ctx.text + off;
}

// Treat a CHAR (which may be signed `char`) as an unsigned byte, then widen.
// This reproduces C's `(unsigned)(ch)` on `char` operands which first promotes
// `char` to `int` (sign-extending), *but* the ISxxx macros only ever compare
// against ASCII ranges and use `(unsigned)`. md4c relies on the byte value for
// ASCII tests; for bytes >= 0x80 the comparisons fail anyway. To be exact with
// the C semantics where `(unsigned)(char)0x80 == 0xffffff80`, we sign-extend
// like C does. The ISxxx predicates are written to match that.
pub inline fn uval(ch: CHAR) c_uint {
    // C: (unsigned)(ch) where `ch` is plain `char`. The C parser is compiled
    // with Zig's clang where `char` is SIGNED on x86-64/aarch64 Linux + Windows
    // (the targets we ship), so `(unsigned)(char)0x80 == 0xFFFFFF80`. Zig's
    // @cImport maps C `char` to `u8` (unsigned), so we must reinterpret the
    // byte's bit pattern as a signed `i8` first, then sign-extend through c_int
    // and bitcast to unsigned — reproducing the signed-char promotion exactly.
    // (This only affects the md_decode_utf8 fallback return for invalid bytes;
    // the ASCII-range ISxxx predicates are unaffected.)
    const signed: i8 = @bitCast(@as(u8, @bitCast(ch)));
    return @bitCast(@as(c_int, signed));
}

pub inline fn ISIN_(ch: CHAR, ch_min: c_uint, ch_max: c_uint) bool {
    const u = uval(ch);
    return ch_min <= u and u <= ch_max;
}
pub inline fn ISANYOF2_(ch: CHAR, ch1: CHAR, ch2: CHAR) bool {
    return ch == ch1 or ch == ch2;
}
pub inline fn ISANYOF3_(ch: CHAR, ch1: CHAR, ch2: CHAR, ch3: CHAR) bool {
    return ch == ch1 or ch == ch2 or ch == ch3;
}
pub inline fn ISASCII_(ch: CHAR) bool {
    return uval(ch) <= 127;
}
pub inline fn ISBLANK_(ch: CHAR) bool {
    return ISANYOF2_(ch, ' ', '\t');
}
pub inline fn ISNEWLINE_(ch: CHAR) bool {
    return ISANYOF2_(ch, '\r', '\n');
}
pub inline fn ISWHITESPACE_(ch: CHAR) bool {
    return ISBLANK_(ch) or ISANYOF2_(ch, 11, 12); // '\v', '\f'
}
pub inline fn ISCNTRL_(ch: CHAR) bool {
    const u = uval(ch);
    return u <= 31 or u == 127;
}
pub inline fn ISPUNCT_(ch: CHAR) bool {
    return ISIN_(ch, 33, 47) or ISIN_(ch, 58, 64) or ISIN_(ch, 91, 96) or ISIN_(ch, 123, 126);
}
pub inline fn ISUPPER_(ch: CHAR) bool {
    return ISIN_(ch, 'A', 'Z');
}
pub inline fn ISLOWER_(ch: CHAR) bool {
    return ISIN_(ch, 'a', 'z');
}
pub inline fn ISALPHA_(ch: CHAR) bool {
    return ISUPPER_(ch) or ISLOWER_(ch);
}
pub inline fn ISDIGIT_(ch: CHAR) bool {
    return ISIN_(ch, '0', '9');
}
pub inline fn ISXDIGIT_(ch: CHAR) bool {
    return ISDIGIT_(ch) or ISIN_(ch, 'A', 'F') or ISIN_(ch, 'a', 'f');
}
pub inline fn ISALNUM_(ch: CHAR) bool {
    return ISALPHA_(ch) or ISDIGIT_(ch);
}

// `ISANYOF_(ch, palette)`: ch != '\0' && md_strchr(palette, ch) != NULL.
pub inline fn ISANYOF_(ch: CHAR, palette: [*:0]const u8) bool {
    return ch != 0 and md_strchr(palette, ch) != null;
}

// Offset-based wrappers (CH(off) variants).
pub inline fn ISANYOF(ctx: *const MD_CTX, off: OFF, palette: [*:0]const u8) bool {
    return ISANYOF_(CH(ctx, off), palette);
}
pub inline fn ISANYOF2(ctx: *const MD_CTX, off: OFF, ch1: CHAR, ch2: CHAR) bool {
    return ISANYOF2_(CH(ctx, off), ch1, ch2);
}
pub inline fn ISANYOF3(ctx: *const MD_CTX, off: OFF, ch1: CHAR, ch2: CHAR, ch3: CHAR) bool {
    return ISANYOF3_(CH(ctx, off), ch1, ch2, ch3);
}
pub inline fn ISASCII(ctx: *const MD_CTX, off: OFF) bool {
    return ISASCII_(CH(ctx, off));
}
pub inline fn ISBLANK(ctx: *const MD_CTX, off: OFF) bool {
    return ISBLANK_(CH(ctx, off));
}
pub inline fn ISNEWLINE(ctx: *const MD_CTX, off: OFF) bool {
    return ISNEWLINE_(CH(ctx, off));
}
pub inline fn ISWHITESPACE(ctx: *const MD_CTX, off: OFF) bool {
    return ISWHITESPACE_(CH(ctx, off));
}
pub inline fn ISCNTRL(ctx: *const MD_CTX, off: OFF) bool {
    return ISCNTRL_(CH(ctx, off));
}
pub inline fn ISPUNCT(ctx: *const MD_CTX, off: OFF) bool {
    return ISPUNCT_(CH(ctx, off));
}
pub inline fn ISUPPER(ctx: *const MD_CTX, off: OFF) bool {
    return ISUPPER_(CH(ctx, off));
}
pub inline fn ISLOWER(ctx: *const MD_CTX, off: OFF) bool {
    return ISLOWER_(CH(ctx, off));
}
pub inline fn ISALPHA(ctx: *const MD_CTX, off: OFF) bool {
    return ISALPHA_(CH(ctx, off));
}
pub inline fn ISDIGIT(ctx: *const MD_CTX, off: OFF) bool {
    return ISDIGIT_(CH(ctx, off));
}
pub inline fn ISXDIGIT(ctx: *const MD_CTX, off: OFF) bool {
    return ISXDIGIT_(CH(ctx, off));
}
pub inline fn ISALNUM(ctx: *const MD_CTX, off: OFF) bool {
    return ISALNUM_(CH(ctx, off));
}

// `md_strchr` — C's strchr(palette, ch): returns pointer to first occurrence of
// (char)ch in NUL-terminated palette, including matching the terminating NUL.
// Returns null if not found. We replicate the exact C contract (NUL match).
pub fn md_strchr(palette: [*:0]const u8, ch: CHAR) ?[*:0]const u8 {
    // C strchr compares (char)ch; the NUL terminator is part of the searched
    // string, so strchr(s, '\0') returns the pointer to the terminator.
    const needle: u8 = @bitCast(ch);
    var p: [*:0]const u8 = palette;
    while (true) : (p += 1) {
        if (p[0] == needle) return p;
        if (p[0] == 0) return null;
    }
}

// Case insensitive check of string equality (ASCII). Mirrors md_ascii_case_eq.
pub inline fn md_ascii_case_eq(s1: [*c]const CHAR, s2: [*c]const CHAR, n: SZ) c_int {
    var i: OFF = 0;
    while (i < n) : (i += 1) {
        var ch1: CHAR = s1[i];
        var ch2: CHAR = s2[i];
        // C: ch += ('A' - 'a') == ch - 32 on char; wrap in the byte domain.
        if (ISLOWER_(ch1)) ch1 -%= 32;
        if (ISLOWER_(ch2)) ch2 -%= 32;
        if (ch1 != ch2) return FALSE;
    }
    return TRUE;
}

pub inline fn md_ascii_eq(s1: [*c]const CHAR, s2: [*c]const CHAR, n: SZ) c_int {
    const a = @as([*]const u8, @ptrCast(s1))[0..n];
    const b = @as([*]const u8, @ptrCast(s2))[0..n];
    return if (std.mem.eql(u8, a, b)) TRUE else FALSE;
}

// `md_text_with_null_replacement` — split a run at NUL bytes, emitting
// MD_TEXT_NULLCHAR for each. Returns the callback's non-zero code or 0.
pub fn md_text_with_null_replacement(ctx: *MD_CTX, ttype: c.MD_TEXTTYPE, str_in: [*c]const CHAR, size_in: SZ) c_int {
    var str = str_in;
    var size = size_in;
    var off: OFF = 0;
    var ret: c_int = 0;

    while (true) {
        while (off < size and str[off] != 0) off += 1;

        if (off > 0) {
            ret = ctx.parser.text.?(ttype, str, off, ctx.userdata);
            if (ret != 0) return ret;
            str += off;
            size -= off;
            off = 0;
        }

        if (off >= size) return 0;

        ret = ctx.parser.text.?(c.MD_TEXT_NULLCHAR, "", 1, ctx.userdata);
        if (ret != 0) return ret;
        str += 1;
        size -= 1;
        off = 0;
    }
}

// ----------------------------------------------------------------------------
// MD_TEMP_BUFFER(sz) — grow ctx->buffer to at least `sz` CHARs. Returns 0 on
// success, -1 on OOM (the C macro `goto abort`s; callers translate via try).
// ----------------------------------------------------------------------------
pub fn md_temp_buffer(ctx: *MD_CTX, sz: SZ) c_int {
    if (sz > ctx.alloc_buffer) {
        // C: new_size = ((sz) + (sz)/2 + 128) & ~127. Arithmetic in SZ (c_uint).
        const new_size: SZ = (sz +% sz / 2 +% 128) & ~@as(SZ, 127);
        // Use raw libc realloc to mirror C exactly (realloc(ctx->buffer, new_size)).
        // ctx.buffer may be null on first call, which realloc treats as malloc.
        const new_buffer = c_realloc_array(CHAR, ctx.buffer, @intCast(new_size));
        if (new_buffer == null) {
            md_log(ctx, "realloc() failed.");
            return -1;
        }
        ctx.buffer = new_buffer;
        ctx.alloc_buffer = new_size;
    }
    return 0;
}

// ============================================================================
//  Unicode Support
// ============================================================================

pub const MD_UNICODE_FOLD_INFO = struct {
    codepoints: [3]c_uint = .{ 0, 0, 0 },
    n_codepoints: c_uint = 0,
};

// Binary search over a sorted "map" of codepoints. Range-encoding:
//   (MIN | 0x40000000) and (MAX | 0x80000000). Returns the index of the found
// record (range minimum) or -1. Faithful port of md_unicode_bsearch__.
pub fn md_unicode_bsearch(codepoint: c_uint, map: []const c_uint) c_int {
    var beg: c_int = 0;
    var end: c_int = @as(c_int, @intCast(map.len)) - 1;
    while (beg <= end) {
        var pivot_beg: c_int = @divTrunc(beg + end, 2);
        var pivot_end: c_int = pivot_beg;
        if (map[@intCast(pivot_end)] & 0x40000000 != 0) pivot_end += 1;
        if (map[@intCast(pivot_beg)] & 0x80000000 != 0) pivot_beg -= 1;

        if (codepoint < (map[@intCast(pivot_beg)] & 0x00ffffff)) {
            end = pivot_beg - 1;
        } else if (codepoint > (map[@intCast(pivot_end)] & 0x00ffffff)) {
            beg = pivot_end + 1;
        } else {
            return pivot_beg;
        }
    }
    return -1;
}

pub fn md_is_unicode_whitespace(codepoint: c_uint) c_int {
    // ASCII fast path (also CommonMark few more in this range).
    if (codepoint <= 0x7f) {
        return if (ISWHITESPACE_(@as(CHAR, @intCast(codepoint)))) TRUE else FALSE;
    }
    return if (md_unicode_bsearch(codepoint, &utbl.WHITESPACE_MAP) >= 0) TRUE else FALSE;
}

pub fn md_is_unicode_punct(codepoint: c_uint) c_int {
    if (codepoint <= 0x7f) {
        return if (ISPUNCT_(@as(CHAR, @intCast(codepoint)))) TRUE else FALSE;
    }
    return if (md_unicode_bsearch(codepoint, &utbl.PUNCT_MAP) >= 0) TRUE else FALSE;
}

const FoldMapEntry = struct {
    map: []const c_uint,
    data: []const c_uint,
    n_codepoints: c_uint,
};
const FOLD_MAP_LIST = [_]FoldMapEntry{
    .{ .map = &utbl.FOLD_MAP_1, .data = &utbl.FOLD_MAP_1_DATA, .n_codepoints = 1 },
    .{ .map = &utbl.FOLD_MAP_2, .data = &utbl.FOLD_MAP_2_DATA, .n_codepoints = 2 },
    .{ .map = &utbl.FOLD_MAP_3, .data = &utbl.FOLD_MAP_3_DATA, .n_codepoints = 3 },
};

pub fn md_get_unicode_fold_info(codepoint: c_uint, info: *MD_UNICODE_FOLD_INFO) void {
    // Fast path for ASCII characters.
    if (codepoint <= 0x7f) {
        info.codepoints[0] = codepoint;
        if (ISUPPER_(@as(CHAR, @intCast(codepoint)))) info.codepoints[0] += 'a' - 'A';
        info.n_codepoints = 1;
        return;
    }

    // Try to locate the codepoint in any of the maps.
    for (FOLD_MAP_LIST) |entry| {
        const index = md_unicode_bsearch(codepoint, entry.map);
        if (index >= 0) {
            const ui: usize = @intCast(index);
            const n_codepoints = entry.n_codepoints;
            const map = entry.map;
            const codepoints = entry.data[ui * n_codepoints ..];

            var k: usize = 0;
            while (k < n_codepoints) : (k += 1) info.codepoints[k] = codepoints[k];
            info.n_codepoints = n_codepoints;

            if (map[ui] != codepoint) {
                // The found mapping maps a whole range of codepoints; offset
                // info->codepoints[0] accordingly.
                if ((map[ui] & 0x00ffffff) + 1 == codepoints[0]) {
                    // Alternating type of the range.
                    info.codepoints[0] = codepoint + (if ((codepoint & 0x1) == (map[ui] & 0x1)) @as(c_uint, 1) else 0);
                } else {
                    // Range to range kind of mapping.
                    info.codepoints[0] += (codepoint - (map[ui] & 0x00ffffff));
                }
            }
            return;
        }
    }

    // No mapping found. Map the codepoint to itself.
    info.codepoints[0] = codepoint;
    info.n_codepoints = 1;
}

// ----------------------------------------------------------------------------
// UTF-8 codec (MD4X_USE_UTF8). Faithful port of md_decode_utf8__,
// md_decode_utf8_before__, md_decode_unicode.
// ----------------------------------------------------------------------------
pub inline fn IS_UTF8_LEAD1(byte: CHAR) bool {
    return @as(u8, @bitCast(byte)) <= 0x7f;
}
pub inline fn IS_UTF8_LEAD2(byte: CHAR) bool {
    return (@as(u8, @bitCast(byte)) & 0xe0) == 0xc0;
}
pub inline fn IS_UTF8_LEAD3(byte: CHAR) bool {
    return (@as(u8, @bitCast(byte)) & 0xf0) == 0xe0;
}
pub inline fn IS_UTF8_LEAD4(byte: CHAR) bool {
    return (@as(u8, @bitCast(byte)) & 0xf8) == 0xf0;
}
pub inline fn IS_UTF8_TAIL(byte: CHAR) bool {
    return (@as(u8, @bitCast(byte)) & 0xc0) == 0x80;
}

// C bit-ops use `(unsigned int)str[i]` which sign-extends the signed char. We
// replicate that exact value via uval() to keep the (rare) high-bit masking
// identical to C even though the masks (& 0x1f, & 0x3f, ...) make sign moot.
pub fn md_decode_utf8(str: [*c]const CHAR, str_size: SZ, p_size: ?*SZ) c_uint {
    if (!IS_UTF8_LEAD1(str[0])) {
        if (IS_UTF8_LEAD2(str[0])) {
            if (1 < str_size and IS_UTF8_TAIL(str[1])) {
                if (p_size) |ps| ps.* = 2;
                return ((uval(str[0]) & 0x1f) << 6) |
                    ((uval(str[1]) & 0x3f) << 0);
            }
        } else if (IS_UTF8_LEAD3(str[0])) {
            if (2 < str_size and IS_UTF8_TAIL(str[1]) and IS_UTF8_TAIL(str[2])) {
                if (p_size) |ps| ps.* = 3;
                return ((uval(str[0]) & 0x0f) << 12) |
                    ((uval(str[1]) & 0x3f) << 6) |
                    ((uval(str[2]) & 0x3f) << 0);
            }
        } else if (IS_UTF8_LEAD4(str[0])) {
            if (3 < str_size and IS_UTF8_TAIL(str[1]) and IS_UTF8_TAIL(str[2]) and IS_UTF8_TAIL(str[3])) {
                if (p_size) |ps| ps.* = 4;
                return ((uval(str[0]) & 0x07) << 18) |
                    ((uval(str[1]) & 0x3f) << 12) |
                    ((uval(str[2]) & 0x3f) << 6) |
                    ((uval(str[3]) & 0x3f) << 0);
            }
        }
    }
    if (p_size) |ps| ps.* = 1;
    return uval(str[0]);
}

pub fn md_decode_utf8_before(ctx: *const MD_CTX, off: OFF) c_uint {
    if (!IS_UTF8_LEAD1(CH(ctx, off - 1))) {
        if (off > 1 and IS_UTF8_LEAD2(CH(ctx, off - 2)) and IS_UTF8_TAIL(CH(ctx, off - 1)))
            return ((uval(CH(ctx, off - 2)) & 0x1f) << 6) |
                ((uval(CH(ctx, off - 1)) & 0x3f) << 0);

        if (off > 2 and IS_UTF8_LEAD3(CH(ctx, off - 3)) and IS_UTF8_TAIL(CH(ctx, off - 2)) and IS_UTF8_TAIL(CH(ctx, off - 1)))
            return ((uval(CH(ctx, off - 3)) & 0x0f) << 12) |
                ((uval(CH(ctx, off - 2)) & 0x3f) << 6) |
                ((uval(CH(ctx, off - 1)) & 0x3f) << 0);

        if (off > 3 and IS_UTF8_LEAD4(CH(ctx, off - 4)) and IS_UTF8_TAIL(CH(ctx, off - 3)) and IS_UTF8_TAIL(CH(ctx, off - 2)) and IS_UTF8_TAIL(CH(ctx, off - 1)))
            return ((uval(CH(ctx, off - 4)) & 0x07) << 18) |
                ((uval(CH(ctx, off - 3)) & 0x3f) << 12) |
                ((uval(CH(ctx, off - 2)) & 0x3f) << 6) |
                ((uval(CH(ctx, off - 1)) & 0x3f) << 0);
    }
    return uval(CH(ctx, off - 1));
}

pub inline fn md_decode_unicode(str: [*c]const CHAR, off: OFF, str_size: SZ, p_char_size: ?*SZ) c_uint {
    return md_decode_utf8(str + off, str_size - off, p_char_size);
}

// ISUNICODE* offset wrappers (UTF-8 build).
pub inline fn ISUNICODEWHITESPACE_(codepoint: c_uint) c_int {
    return md_is_unicode_whitespace(codepoint);
}
pub inline fn ISUNICODEWHITESPACE(ctx: *const MD_CTX, off: OFF) bool {
    return md_is_unicode_whitespace(md_decode_utf8(STR(ctx, off), ctx.size - off, null)) != 0;
}
pub inline fn ISUNICODEWHITESPACEBEFORE(ctx: *const MD_CTX, off: OFF) bool {
    return md_is_unicode_whitespace(md_decode_utf8_before(ctx, off)) != 0;
}
pub inline fn ISUNICODEPUNCT(ctx: *const MD_CTX, off: OFF) bool {
    return md_is_unicode_punct(md_decode_utf8(STR(ctx, off), ctx.size - off, null)) != 0;
}
pub inline fn ISUNICODEPUNCTBEFORE(ctx: *const MD_CTX, off: OFF) bool {
    return md_is_unicode_punct(md_decode_utf8_before(ctx, off)) != 0;
}

// ============================================================================
//  Helper string manipulations
// ============================================================================

// Fill `buffer` with copy of [beg, end) replacing line breaks with the given
// char. Caller guarantees buffer is large enough (>= end-beg). Mirrors
// md_merge_lines exactly.
pub fn md_merge_lines(ctx: *const MD_CTX, beg: OFF, end: OFF, lines: [*c]const MD_LINE, n_lines: MD_SIZE, line_break_replacement_char: CHAR, buffer: [*c]CHAR, p_size: *SZ) void {
    _ = n_lines;
    var ptr = buffer;
    var line_index: c_int = 0;
    var off: OFF = beg;

    while (true) {
        const line = &lines[@intCast(line_index)];
        var line_end = line.end;
        if (end < line_end) line_end = end;

        while (off < line_end) {
            ptr[0] = CH(ctx, off);
            ptr += 1;
            off += 1;
        }

        if (off >= end) {
            p_size.* = @intCast(@intFromPtr(ptr) - @intFromPtr(buffer));
            return;
        }

        ptr[0] = line_break_replacement_char;
        ptr += 1;

        line_index += 1;
        off = lines[@intCast(line_index)].beg;
    }
}

// Wrapper of md_merge_lines() which allocates the output. Returns 0 / -1.
pub fn md_merge_lines_alloc(ctx: *MD_CTX, beg: OFF, end: OFF, lines: [*c]const MD_LINE, n_lines: MD_SIZE, line_break_replacement_char: CHAR, p_str: *[*c]CHAR, p_size: *SZ) c_int {
    const n: usize = @intCast(end - beg);
    const buffer = c_allocator.alloc(CHAR, n) catch {
        md_log(ctx, "malloc() failed.");
        return -1;
    };
    md_merge_lines(ctx, beg, end, lines, n_lines, line_break_replacement_char, buffer.ptr, p_size);
    p_str.* = buffer.ptr;
    return 0;
}

pub fn md_skip_unicode_whitespace(label: [*c]const CHAR, off_in: OFF, size: SZ) OFF {
    var off = off_in;
    while (off < size) {
        var char_size: SZ = undefined;
        const codepoint = md_decode_unicode(label, off, size, &char_size);
        if (ISUNICODEWHITESPACE_(codepoint) == 0 and !ISNEWLINE_(label[off])) break;
        off += char_size;
    }
    return off;
}

// ============================================================================
//  Recognizing HTML entities
// ============================================================================

pub fn md_is_hex_entity_contents(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    _ = ctx;
    var off = beg;
    while (off < max_end and ISXDIGIT_(text[off]) and off - beg <= 8) off += 1;
    if (1 <= off - beg and off - beg <= 6) {
        p_end.* = off;
        return TRUE;
    }
    return FALSE;
}

pub fn md_is_dec_entity_contents(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    _ = ctx;
    var off = beg;
    while (off < max_end and ISDIGIT_(text[off]) and off - beg <= 8) off += 1;
    if (1 <= off - beg and off - beg <= 7) {
        p_end.* = off;
        return TRUE;
    }
    return FALSE;
}

pub fn md_is_named_entity_contents(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    _ = ctx;
    var off = beg;
    if (off < max_end and ISALPHA_(text[off])) {
        off += 1;
    } else {
        return FALSE;
    }
    while (off < max_end and ISALNUM_(text[off]) and off - beg <= 48) off += 1;
    if (2 <= off - beg and off - beg <= 48) {
        p_end.* = off;
        return TRUE;
    }
    return FALSE;
}

pub fn md_is_entity_str(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off = beg;
    // MD_ASSERT(text[off] == '&'); — defensive guard instead of UB-assert.
    off += 1;

    var is_contents: c_int = undefined;
    if (off + 2 < max_end and text[off] == '#' and (text[off + 1] == 'x' or text[off + 1] == 'X')) {
        is_contents = md_is_hex_entity_contents(ctx, text, off + 2, max_end, &off);
    } else if (off + 1 < max_end and text[off] == '#') {
        is_contents = md_is_dec_entity_contents(ctx, text, off + 1, max_end, &off);
    } else {
        is_contents = md_is_named_entity_contents(ctx, text, off, max_end, &off);
    }

    if (is_contents != 0 and off < max_end and text[off] == ';') {
        p_end.* = off + 1;
        return TRUE;
    }
    return FALSE;
}

pub inline fn md_is_entity(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    return md_is_entity_str(ctx, ctx.text, beg, max_end, p_end);
}

// ============================================================================
//  Attribute Management
// ============================================================================

pub const MD_ATTRIBUTE_BUILD = struct {
    text: [*c]CHAR = null,
    substr_types: [*c]c.MD_TEXTTYPE = null,
    substr_offsets: [*c]OFF = null,
    substr_count: c_int = 0,
    substr_alloc: c_int = 0,
    trivial_types: [1]c.MD_TEXTTYPE = .{0},
    trivial_offsets: [2]OFF = .{ 0, 0 },
};

pub const MD_BUILD_ATTR_NO_ESCAPES: c_uint = 0x0001;

pub fn md_build_attr_append_substr(ctx: *MD_CTX, build: *MD_ATTRIBUTE_BUILD, ttype: c.MD_TEXTTYPE, off: OFF) c_int {
    if (build.substr_count >= build.substr_alloc) {
        build.substr_alloc = if (build.substr_alloc > 0)
            build.substr_alloc + @divTrunc(build.substr_alloc, 2)
        else
            8;
        const alloc_u: usize = @intCast(build.substr_alloc);

        // realloc substr_types.
        // realloc substr_types (libc realloc tracks the old block's size).
        const new_types = c_realloc_array(c.MD_TEXTTYPE, build.substr_types, alloc_u);
        if (new_types == null) {
            md_log(ctx, "realloc() failed.");
            return -1;
        }
        build.substr_types = new_types;

        // realloc substr_offsets (+1 for final offset == raw_size).
        const new_offsets = c_realloc_array(OFF, build.substr_offsets, alloc_u + 1);
        if (new_offsets == null) {
            md_log(ctx, "realloc() failed.");
            return -1;
        }
        build.substr_offsets = new_offsets;
    }

    build.substr_types[@intCast(build.substr_count)] = ttype;
    build.substr_offsets[@intCast(build.substr_count)] = off;
    build.substr_count += 1;
    return 0;
}

pub fn md_free_attribute(ctx: *MD_CTX, build: *MD_ATTRIBUTE_BUILD) void {
    _ = ctx;
    if (build.substr_alloc > 0) {
        if (build.text != null) std.c.free(build.text);
        if (build.substr_types != null) std.c.free(build.substr_types);
        if (build.substr_offsets != null) std.c.free(build.substr_offsets);
        // Reset so a second call is a safe no-op. md_build_attribute() frees the
        // build itself on an OOM mid-build and returns -1; callers then also free
        // it in their error cleanup, which would otherwise double-free. (Idempotent
        // free; only reachable under heap-allocation failure. Original C lacked this.)
        build.text = null;
        build.substr_types = null;
        build.substr_offsets = null;
        build.substr_alloc = 0;
    }
}

pub fn md_build_attribute(ctx: *MD_CTX, raw_text: [*c]const CHAR, raw_size: SZ, flags: c_uint, attr: *c.MD_ATTRIBUTE, build: *MD_ATTRIBUTE_BUILD) c_int {
    var raw_off: OFF = 0;
    var off: OFF = 0;
    var ret: c_int = 0;
    _ = &ret;

    // C: memset(build, 0, sizeof(MD_ATTRIBUTE_BUILD)). Use zeroes to match the
    // byte-level zero-init exactly (defaults could leave padding uninitialized).
    build.* = std.mem.zeroes(MD_ATTRIBUTE_BUILD);

    // Trivial path if no backslash, ampersand, or NUL.
    var is_trivial = true;
    raw_off = 0;
    while (raw_off < raw_size) : (raw_off += 1) {
        if (ISANYOF3_(raw_text[raw_off], '\\', '&', 0)) {
            is_trivial = false;
            break;
        }
    }

    if (is_trivial) {
        build.text = if (raw_size != 0) @constCast(raw_text) else null;
        build.substr_types = &build.trivial_types;
        build.substr_offsets = &build.trivial_offsets;
        build.substr_count = 1;
        build.substr_alloc = 0;
        build.trivial_types[0] = c.MD_TEXT_NORMAL;
        build.trivial_offsets[0] = 0;
        build.trivial_offsets[1] = raw_size;
        off = raw_size;
    } else {
        const buf = c_malloc_array(CHAR, raw_size);
        if (buf == null) {
            md_log(ctx, "malloc() failed.");
            md_free_attribute(ctx, build);
            return -1;
        }
        build.text = buf;

        raw_off = 0;
        off = 0;

        while (raw_off < raw_size) {
            if (raw_text[raw_off] == 0) {
                if (md_build_attr_append_substr(ctx, build, c.MD_TEXT_NULLCHAR, off) < 0) {
                    md_free_attribute(ctx, build);
                    return -1;
                }
                @memcpy(@as([*]u8, @ptrCast(build.text + off))[0..1], @as([*]const u8, @ptrCast(raw_text + raw_off))[0..1]);
                off += 1;
                raw_off += 1;
                continue;
            }

            if (raw_text[raw_off] == '&') {
                var ent_end: OFF = undefined;
                if (md_is_entity_str(ctx, raw_text, raw_off, raw_size, &ent_end) != 0) {
                    if (md_build_attr_append_substr(ctx, build, c.MD_TEXT_ENTITY, off) < 0) {
                        md_free_attribute(ctx, build);
                        return -1;
                    }
                    const n: usize = @intCast(ent_end - raw_off);
                    @memcpy(@as([*]u8, @ptrCast(build.text + off))[0..n], @as([*]const u8, @ptrCast(raw_text + raw_off))[0..n]);
                    off += ent_end - raw_off;
                    raw_off = ent_end;
                    continue;
                }
            }

            if (build.substr_count == 0 or build.substr_types[@intCast(build.substr_count - 1)] != c.MD_TEXT_NORMAL) {
                if (md_build_attr_append_substr(ctx, build, c.MD_TEXT_NORMAL, off) < 0) {
                    md_free_attribute(ctx, build);
                    return -1;
                }
            }

            if ((flags & MD_BUILD_ATTR_NO_ESCAPES) == 0 and
                raw_text[raw_off] == '\\' and raw_off + 1 < raw_size and
                (ISPUNCT_(raw_text[raw_off + 1]) or ISNEWLINE_(raw_text[raw_off + 1])))
            {
                raw_off += 1;
            }

            build.text[off] = raw_text[raw_off];
            off += 1;
            raw_off += 1;
        }
        build.substr_offsets[@intCast(build.substr_count)] = off;
    }

    attr.text = build.text;
    attr.size = off;
    attr.substr_offsets = build.substr_offsets;
    attr.substr_types = build.substr_types;
    return 0;
}

// ============================================================================
//  Line lookup (binary search over the analyzed lines)
// ============================================================================

// Faithful port of md_lookup_line (md4x.c ~558). If the offset falls into a gap
// between lines, returns the following line. n_lines/lines are MD_LINE arrays.
pub fn md_lookup_line(off: OFF, lines: [*c]const MD_LINE, n_lines: MD_SIZE, p_line_index: ?*MD_SIZE) *const MD_LINE {
    var lo: MD_SIZE = 0;
    var hi: MD_SIZE = n_lines - 1;
    while (lo <= hi) {
        const pivot: MD_SIZE = (lo + hi) / 2;
        const line: *const MD_LINE = @ptrCast(&lines[pivot]);

        if (off < line.beg) {
            if (hi == 0 or lines[hi - 1].end < off) {
                if (p_line_index) |p| p.* = pivot;
                return line;
            }
            hi = pivot - 1;
        } else if (off > line.end) {
            lo = pivot + 1;
        } else {
            if (p_line_index) |p| p.* = pivot;
            return line;
        }
    }

    // C: unreachable in practice (the document always has a "following" line);
    // mirror the C fall-through which returns &lines[n_lines-1] would be UB, but
    // the C code has no return here — it relies on the loop always returning.
    // We return the last line defensively (cannot be hit for well-formed input).
    return @ptrCast(&lines[n_lines - 1]);
}

// libc qsort/bsearch (not exposed by std.c in this Zig version). Same
// signatures as C. Used so ordering/tie-breaking matches glibc byte-for-byte.
pub const c_cmp_fn = *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;
pub extern "c" fn qsort(base: ?*anyopaque, nmemb: usize, size: usize, compar: c_cmp_fn) void;
pub extern "c" fn bsearch(key: ?*const anyopaque, base: ?*const anyopaque, nmemb: usize, size: usize, compar: c_cmp_fn) ?*anyopaque;
pub extern "c" fn memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) c_int;
pub extern "c" fn strcspn(s: [*c]const u8, reject: [*c]const u8) usize;
pub extern "c" fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;

// ----------------------------------------------------------------------------
// libc malloc/realloc wrappers used where md4c relies on realloc(NULL,…) and
// freeing pointers across allocations whose previous size is not tracked in a
// Zig slice. These mirror the C runtime exactly (the C parser uses raw
// malloc/realloc/free for these attribute build buffers).
// ----------------------------------------------------------------------------
// NOTE: these return a plain `[*c]T`, which is itself nullable — callers check
// `== null` (mirroring C's `malloc`/`realloc` returning a possibly-NULL pointer).
// Do NOT wrap in `?[*c]T`: an optional C-pointer is a malformed type in Zig and
// produces garbage payloads (observed via valgrind as uninitialised reads).
pub fn c_malloc_array(comptime T: type, count: usize) [*c]T {
    if (count == 0) {
        // C: malloc(0) is impl-defined; md4c only mallocs raw_size>0 here.
        return @ptrCast(@alignCast(std.c.malloc(0)));
    }
    return @ptrCast(@alignCast(std.c.malloc(count * @sizeOf(T))));
}

pub fn c_realloc_array(comptime T: type, old: [*c]T, count: usize) [*c]T {
    return @ptrCast(@alignCast(std.c.realloc(old, count * @sizeOf(T))));
}

// Grow a `[*c]T` array using the duplicated `n >= alloc` realloc-grow idiom that
// appears on several MD_CTX growable arrays (marks, containers, block/slot/alert
// info, inline attrs, ref defs). `n` is the live element count and `alloc.*` the
// current capacity; when full, capacity grows by 1.5x (or to `min_alloc` from
// empty) via libc realloc. On success `ptr.*`/`alloc.*` are updated together; on
// realloc failure both are left unchanged and error.OutOfMemory is returned (the
// caller logs + maps to its own abort contract). The growth schedule, the
// `n >= alloc` trigger, and the realloc ABI are byte-identical to the hand-written
// blocks this replaces — only the duplication is removed.
pub fn growArray(comptime T: type, ptr: *[*c]T, alloc: *c_int, n: c_int, min_alloc: c_int) error{OutOfMemory}!void {
    if (n < alloc.*) return;
    const new_alloc: c_int = if (alloc.* > 0)
        alloc.* + @divTrunc(alloc.*, 2)
    else
        min_alloc;
    const new_arr = c_realloc_array(T, ptr.*, @intCast(new_alloc));
    if (new_arr == null) return error.OutOfMemory;
    ptr.* = new_arr;
    alloc.* = new_alloc;
}
