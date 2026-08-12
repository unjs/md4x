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
const MD_CTX = types.MD_CTX;
const MD_LINE = types.MD_LINE;
const c_allocator = types.c_allocator;

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

// NOTE: the offset-based `CH(off)` predicate wrappers (ISWHITESPACE, ISNEWLINE,
// ISANYOF, …) are now methods on MD_CTX (`ctx.isWhitespace(off)`, etc.) in
// types.zig — see PLAN 8.7. The pure `IS*_(ch)` helpers above stay here.

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
pub inline fn md_ascii_case_eq(s1: [*c]const CHAR, s2: [*c]const CHAR, n: SZ) bool {
    var i: OFF = 0;
    while (i < n) : (i += 1) {
        var ch1: CHAR = s1[i];
        var ch2: CHAR = s2[i];
        // C: ch += ('A' - 'a') == ch - 32 on char; wrap in the byte domain.
        if (ISLOWER_(ch1)) ch1 -%= 32;
        if (ISLOWER_(ch2)) ch2 -%= 32;
        if (ch1 != ch2) return false;
    }
    return true;
}

pub inline fn md_ascii_eq(s1: [*c]const CHAR, s2: [*c]const CHAR, n: SZ) bool {
    const a = @as([*]const u8, @ptrCast(s1))[0..n];
    const b = @as([*]const u8, @ptrCast(s2))[0..n];
    return std.mem.eql(u8, a, b);
}

// `md_text_with_null_replacement` — split a run at NUL bytes, emitting
// MD_TEXT_NULLCHAR for each. Returns the callback's non-zero code or 0.
pub fn md_text_with_null_replacement(ctx: *MD_CTX, ttype: c.TextType, str_in: [*c]const CHAR, size_in: SZ) c_int {
    var str = str_in;
    var size = size_in;
    var off: OFF = 0;
    var ret: c_int = 0;

    while (true) {
        while (off < size and str[off] != 0) off += 1;

        if (off > 0) {
            ret = ctx.parser.text(ttype, str[0..off], ctx.userdata);
            if (ret != 0) return ret;
            str += off;
            size -= off;
            off = 0;
        }

        if (off >= size) return 0;

        ret = ctx.parser.text(c.TextType.nullchar, "\x00", ctx.userdata);
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
        // Routed through ctx.alloc (exact old length = alloc_buffer). ctx.buffer
        // is null on the first call, which realloc_array_a treats as a fresh
        // alloc; on OOM it returns null leaving the old buffer intact.
        const new_buffer = realloc_array_a(CHAR, ctx.alloc, ctx.buffer, @intCast(ctx.alloc_buffer), @intCast(new_size));
        if (new_buffer == null) {
            ctx.log("realloc() failed.");
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

pub fn md_is_unicode_whitespace(codepoint: c_uint) bool {
    // ASCII fast path (also CommonMark few more in this range).
    if (codepoint <= 0x7f) {
        return ISWHITESPACE_(@as(CHAR, @intCast(codepoint)));
    }
    return md_unicode_bsearch(codepoint, &utbl.WHITESPACE_MAP) >= 0;
}

pub fn md_is_unicode_punct(codepoint: c_uint) bool {
    if (codepoint <= 0x7f) {
        return ISPUNCT_(@as(CHAR, @intCast(codepoint)));
    }
    return md_unicode_bsearch(codepoint, &utbl.PUNCT_MAP) >= 0;
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
    if (!IS_UTF8_LEAD1(ctx.ch(off - 1))) {
        if (off > 1 and IS_UTF8_LEAD2(ctx.ch(off - 2)) and IS_UTF8_TAIL(ctx.ch(off - 1)))
            return ((uval(ctx.ch(off - 2)) & 0x1f) << 6) |
                ((uval(ctx.ch(off - 1)) & 0x3f) << 0);

        if (off > 2 and IS_UTF8_LEAD3(ctx.ch(off - 3)) and IS_UTF8_TAIL(ctx.ch(off - 2)) and IS_UTF8_TAIL(ctx.ch(off - 1)))
            return ((uval(ctx.ch(off - 3)) & 0x0f) << 12) |
                ((uval(ctx.ch(off - 2)) & 0x3f) << 6) |
                ((uval(ctx.ch(off - 1)) & 0x3f) << 0);

        if (off > 3 and IS_UTF8_LEAD4(ctx.ch(off - 4)) and IS_UTF8_TAIL(ctx.ch(off - 3)) and IS_UTF8_TAIL(ctx.ch(off - 2)) and IS_UTF8_TAIL(ctx.ch(off - 1)))
            return ((uval(ctx.ch(off - 4)) & 0x07) << 18) |
                ((uval(ctx.ch(off - 3)) & 0x3f) << 12) |
                ((uval(ctx.ch(off - 2)) & 0x3f) << 6) |
                ((uval(ctx.ch(off - 1)) & 0x3f) << 0);
    }
    return uval(ctx.ch(off - 1));
}

pub inline fn md_decode_unicode(str: [*c]const CHAR, off: OFF, str_size: SZ, p_char_size: ?*SZ) c_uint {
    return md_decode_utf8(str + off, str_size - off, p_char_size);
}

// ISUNICODE* codepoint helper (UTF-8 build). The offset-based wrappers
// (ISUNICODEWHITESPACE/PUNCT[BEFORE]) are now MD_CTX methods in types.zig
// (`ctx.isUnicodeWhitespace(off)`, …) — see PLAN 8.7.
pub inline fn ISUNICODEWHITESPACE_(codepoint: c_uint) bool {
    return md_is_unicode_whitespace(codepoint);
}

// ============================================================================
//  Helper string manipulations
// ============================================================================

// Fill `buffer` with copy of [beg, end) replacing line breaks with the given
// char. Caller guarantees buffer is large enough (>= end-beg). Mirrors
// md_merge_lines exactly.
pub fn md_merge_lines(ctx: *const MD_CTX, beg: OFF, end: OFF, lines: []const MD_LINE, line_break_replacement_char: CHAR, buffer: [*c]CHAR, p_size: *SZ) void {
    var ptr = buffer;
    var line_index: c_int = 0;
    var off: OFF = beg;

    while (true) {
        const line = &lines[@intCast(line_index)];
        var line_end = line.end;
        if (end < line_end) line_end = end;

        while (off < line_end) {
            ptr[0] = ctx.ch(off);
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
//
// Routed through `ctx.alloc` (PLAN item 5), so the caller must free the result
// at its EXACT allocated length. md_merge_lines writes at most `end - beg`
// bytes but usually fewer (the inter-line prefixes are dropped), so the buffer
// is SHRUNK TO FIT before it is handed back: on return the allocated length is
// exactly `p_size.*`, which is the field every call site already keeps. Do not
// remove the shrink — it is what lets `md_free_ref_defs`, `md_is_link_reference`
// and the `ptr_stack` walk free by `*_size` alone.
pub fn md_merge_lines_alloc(ctx: *MD_CTX, beg: OFF, end: OFF, lines: []const MD_LINE, line_break_replacement_char: CHAR, p_str: *[*c]CHAR, p_size: *SZ) c_int {
    const n: usize = @intCast(end - beg);

    // Zero-length guard. Currently unreachable (every call site is gated by a
    // `contents_beg < contents_end` invariant), but `Allocator.alloc` of 0 bytes
    // short-circuits the vtable and returns a non-null `maxInt(usize)` sentinel,
    // which would reach the free sites — unlike C's `malloc(0)`. The sibling
    // helpers (`arena_alloc`, `alloc_array_a`) special-case zero the same way.
    // Callers tolerate a null string with a zero size (it is the ordinary
    // "no title" shape).
    if (n == 0) {
        p_str.* = null;
        p_size.* = 0;
        return 0;
    }

    const buffer = alloc_array_a(CHAR, ctx.alloc, n);
    if (buffer == null) {
        ctx.log("malloc() failed.");
        return -1;
    }
    md_merge_lines(ctx, beg, end, lines, line_break_replacement_char, buffer, p_size);

    const size: usize = @intCast(p_size.*);
    if (size == 0) {
        // Also unreachable for n > 0 (the first loop iteration always writes at
        // least one byte), but keep the buffer's length and `p_size` in sync.
        free_array_a(CHAR, ctx.alloc, buffer, n);
        p_str.* = null;
        return 0;
    }
    if (size < n) {
        // Shrink-to-fit. A shrinking realloc resizes in place on c_allocator and
        // on the testing allocator, so this effectively never fails; if it ever
        // did, fail the whole merge rather than hand back a length≠size buffer.
        const shr = realloc_array_a(CHAR, ctx.alloc, buffer, n, size);
        if (shr == null) {
            free_array_a(CHAR, ctx.alloc, buffer, n);
            p_str.* = null;
            p_size.* = 0;
            ctx.log("realloc() failed.");
            return -1;
        }
        p_str.* = shr;
        return 0;
    }
    p_str.* = buffer;
    return 0;
}

pub fn md_skip_unicode_whitespace(label: [*c]const CHAR, off_in: OFF, size: SZ) OFF {
    var off = off_in;
    while (off < size) {
        var char_size: SZ = undefined;
        const codepoint = md_decode_unicode(label, off, size, &char_size);
        if (!ISUNICODEWHITESPACE_(codepoint) and !ISNEWLINE_(label[off])) break;
        off += char_size;
    }
    return off;
}

// ============================================================================
//  Recognizing HTML entities
// ============================================================================

pub fn md_is_hex_entity_contents(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) bool {
    _ = ctx;
    var off = beg;
    while (off < max_end and ISXDIGIT_(text[off]) and off - beg <= 8) off += 1;
    if (1 <= off - beg and off - beg <= 6) {
        p_end.* = off;
        return true;
    }
    return false;
}

pub fn md_is_dec_entity_contents(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) bool {
    _ = ctx;
    var off = beg;
    while (off < max_end and ISDIGIT_(text[off]) and off - beg <= 8) off += 1;
    if (1 <= off - beg and off - beg <= 7) {
        p_end.* = off;
        return true;
    }
    return false;
}

pub fn md_is_named_entity_contents(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) bool {
    _ = ctx;
    var off = beg;
    if (off < max_end and ISALPHA_(text[off])) {
        off += 1;
    } else {
        return false;
    }
    while (off < max_end and ISALNUM_(text[off]) and off - beg <= 48) off += 1;
    if (2 <= off - beg and off - beg <= 48) {
        p_end.* = off;
        return true;
    }
    return false;
}

pub fn md_is_entity_str(ctx: *MD_CTX, text: [*c]const CHAR, beg: OFF, max_end: OFF, p_end: *OFF) bool {
    var off = beg;
    // MD_ASSERT(text[off] == '&'); — defensive guard instead of UB-assert.
    off += 1;

    var is_contents: bool = undefined;
    if (off + 2 < max_end and text[off] == '#' and (text[off + 1] == 'x' or text[off + 1] == 'X')) {
        is_contents = md_is_hex_entity_contents(ctx, text, off + 2, max_end, &off);
    } else if (off + 1 < max_end and text[off] == '#') {
        is_contents = md_is_dec_entity_contents(ctx, text, off + 1, max_end, &off);
    } else {
        is_contents = md_is_named_entity_contents(ctx, text, off, max_end, &off);
    }

    if (is_contents and off < max_end and text[off] == ';') {
        p_end.* = off + 1;
        return true;
    }
    return false;
}

pub inline fn md_is_entity(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF) bool {
    return md_is_entity_str(ctx, ctx.text, beg, max_end, p_end);
}

// ============================================================================
//  Attribute Management
// ============================================================================

pub const MD_ATTRIBUTE_BUILD = struct {
    text: [*c]CHAR = null,
    substr_types: [*c]c.TextType = null,
    substr_offsets: [*c]OFF = null,
    substr_count: c_int = 0,
    // Exact element count owned by `substr_offsets` MINUS one (the tables are
    // sized `substr_alloc` / `substr_alloc + 1`), and the capacity the append
    // loop grows against.
    substr_alloc: c_int = 0,
    // Exact element count owned by `substr_types`. Normally equal to
    // `substr_alloc`, but the two legitimately diverge when growth fails between
    // the two reallocs, so one field cannot express the state (PLAN item 1c).
    // Each array must be freed at its OWN length.
    types_alloc: c_int = 0,
    // Exact element count owned by `text` (the decoded-text buffer), so it can be
    // freed through ctx.alloc (PLAN C). 0 when `text` is borrowed (trivial path)
    // or unset; md_free_attribute only frees `text` when this is > 0.
    text_alloc: usize = 0,
    trivial_types: [1]c.TextType = .{.normal},
    trivial_offsets: [2]OFF = .{ 0, 0 },
};

pub const MD_BUILD_ATTR_NO_ESCAPES: c_uint = 0x0001;

pub fn md_build_attr_append_substr(ctx: *MD_CTX, build: *MD_ATTRIBUTE_BUILD, ttype: c.TextType, off: OFF) error{OutOfMemory}!void {
    if (build.substr_count >= build.substr_alloc) {
        const old_alloc: usize = @intCast(build.substr_alloc);
        const new_alloc: c_int = if (build.substr_alloc > 0)
            build.substr_alloc + @divTrunc(build.substr_alloc, 2)
        else
            8;
        const alloc_u: usize = @intCast(new_alloc);

        // A capacity field is published only AFTER the block it describes exists,
        // so md_free_attribute always frees at the length actually allocated
        // (same discipline as md_push_block_bytes in blocks.zig).
        //
        // realloc substr_types (routed through ctx.alloc; exact old length passed).
        const new_types = realloc_array_a(c.TextType, ctx.alloc, build.substr_types, @intCast(build.types_alloc), alloc_u);
        if (new_types == null) {
            ctx.log("realloc() failed.");
            return error.OutOfMemory;
        }
        build.substr_types = new_types;
        build.types_alloc = new_alloc;

        // realloc substr_offsets (+1 for final offset == raw_size).
        const old_off_alloc: usize = if (old_alloc > 0) old_alloc + 1 else 0;
        const new_offsets = realloc_array_a(OFF, ctx.alloc, build.substr_offsets, old_off_alloc, alloc_u + 1);
        if (new_offsets == null) {
            ctx.log("realloc() failed.");
            return error.OutOfMemory;
        }
        build.substr_offsets = new_offsets;
        build.substr_alloc = new_alloc;
    }

    build.substr_types[@intCast(build.substr_count)] = ttype;
    build.substr_offsets[@intCast(build.substr_count)] = off;
    build.substr_count += 1;
}

pub fn md_free_attribute(ctx: *MD_CTX, build: *MD_ATTRIBUTE_BUILD) void {
    // Each buffer is freed at its OWN tracked length: an OOM between the two
    // reallocs in md_build_attr_append_substr leaves types_alloc > substr_alloc,
    // and the very first growth can fail with `text` already owned while neither
    // capacity is published. free_array_a no-ops on a zero count, which is what
    // the trivial path (borrowed `text`, embedded trivial_* tables, all lengths
    // 0) relies on.
    free_array_a(CHAR, ctx.alloc, build.text, build.text_alloc);
    free_array_a(c.TextType, ctx.alloc, build.substr_types, @intCast(build.types_alloc));
    free_array_a(OFF, ctx.alloc, build.substr_offsets, if (build.substr_alloc > 0) @as(usize, @intCast(build.substr_alloc)) + 1 else 0);
    // Reset so a second call is a safe no-op. md_build_attribute() frees the
    // build itself on an OOM mid-build and returns -1; callers then also free
    // it in their error cleanup, which would otherwise double-free. (Idempotent
    // free; only reachable under heap-allocation failure. Original C lacked this.)
    build.text = null;
    build.text_alloc = 0;
    build.substr_types = null;
    build.substr_offsets = null;
    build.substr_alloc = 0;
    build.types_alloc = 0;
}

pub fn md_build_attribute(ctx: *MD_CTX, raw_text: [*c]const CHAR, raw_size: SZ, flags: c_uint, attr: *c.Attribute, build: *MD_ATTRIBUTE_BUILD) error{OutOfMemory}!void {
    var raw_off: OFF = 0;
    var off: OFF = 0;

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
        build.trivial_types[0] = c.TextType.normal;
        build.trivial_offsets[0] = 0;
        build.trivial_offsets[1] = raw_size;
        off = raw_size;
    } else {
        const buf = alloc_array_a(CHAR, ctx.alloc, raw_size);
        if (buf == null) {
            ctx.log("malloc() failed.");
            md_free_attribute(ctx, build);
            return error.OutOfMemory;
        }
        build.text = buf;
        build.text_alloc = raw_size;

        raw_off = 0;
        off = 0;

        while (raw_off < raw_size) {
            if (raw_text[raw_off] == 0) {
                md_build_attr_append_substr(ctx, build, c.TextType.nullchar, off) catch {
                    md_free_attribute(ctx, build);
                    return error.OutOfMemory;
                };
                @memcpy(@as([*]u8, @ptrCast(build.text + off))[0..1], @as([*]const u8, @ptrCast(raw_text + raw_off))[0..1]);
                off += 1;
                raw_off += 1;
                continue;
            }

            if (raw_text[raw_off] == '&') {
                var ent_end: OFF = undefined;
                if (md_is_entity_str(ctx, raw_text, raw_off, raw_size, &ent_end)) {
                    md_build_attr_append_substr(ctx, build, c.TextType.entity, off) catch {
                        md_free_attribute(ctx, build);
                        return error.OutOfMemory;
                    };
                    const n: usize = @intCast(ent_end - raw_off);
                    @memcpy(@as([*]u8, @ptrCast(build.text + off))[0..n], @as([*]const u8, @ptrCast(raw_text + raw_off))[0..n]);
                    off += ent_end - raw_off;
                    raw_off = ent_end;
                    continue;
                }
            }

            if (build.substr_count == 0 or build.substr_types[@intCast(build.substr_count - 1)] != c.TextType.normal) {
                md_build_attr_append_substr(ctx, build, c.TextType.normal, off) catch {
                    md_free_attribute(ctx, build);
                    return error.OutOfMemory;
                };
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

    // Hand the build buffers over as exact-length slices. The buffers stay owned
    // by `build` (freed by md_free_attribute with the tracked element counts);
    // only the *view* handed to the callback is a slice. `substr_count` is >= 1
    // on every path through this function, so the two tables are non-empty and
    // keep the `offsets.len == types.len + 1` invariant.
    const n: usize = @intCast(build.substr_count);
    attr.text = if (build.text != null) build.text[0..off] else &.{};
    attr.substr_types = build.substr_types[0..n];
    attr.substr_offsets = build.substr_offsets[0 .. n + 1];
}

// ============================================================================
//  Line lookup (binary search over the analyzed lines)
// ============================================================================

// Faithful port of md_lookup_line (md4x.c ~558). If the offset falls into a gap
// between lines, returns the following line. n_lines/lines are MD_LINE arrays.
pub fn md_lookup_line(off: OFF, lines: []const MD_LINE, p_line_index: ?*MD_SIZE) *const MD_LINE {
    var lo: MD_SIZE = 0;
    var hi: MD_SIZE = @intCast(lines.len - 1);
    while (lo <= hi) {
        const pivot: MD_SIZE = (lo + hi) / 2;
        const line: *const MD_LINE = &lines[pivot];

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
    return &lines[lines.len - 1];
}

// libc qsort/bsearch (not exposed by std.c in this Zig version). Same
// signatures as C. Used so ordering/tie-breaking matches glibc byte-for-byte.
pub const c_cmp_fn = *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;
pub extern "c" fn qsort(base: ?*anyopaque, nmemb: usize, size: usize, compar: c_cmp_fn) void;
pub extern "c" fn bsearch(key: ?*const anyopaque, base: ?*const anyopaque, nmemb: usize, size: usize, compar: c_cmp_fn) ?*anyopaque;
pub extern "c" fn memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) c_int;
pub extern "c" fn strcspn(s: [*c]const u8, reject: [*c]const u8) usize;
pub extern "c" fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;

// --- raw byte-arena helpers routed through a std.mem.Allocator ----------------
//
// PLAN C ("fuller OOM matrix"): `malloc`/`realloc`/`free`-shaped wrappers over
// `ctx.alloc` for the heterogeneous byte arenas the parser reinterprets as typed
// records (the block_bytes arena, the ref-def hashtable array, the
// MD_REF_DEF_LIST flexible-array buckets). Routing them through the injectable
// allocator lets a std.testing.FailingAllocator drive their OOM paths, which the
// production libc-malloc build never reaches.
//
// Returned pointers are 16-byte aligned — matching libc malloc's max_align_t
// guarantee — so the arenas stay safe to `@ptrCast`/`@alignCast` into MD_BLOCK /
// MD_LINE / MD_REF_DEF_LIST / pointer-array views. Callers must track the exact
// allocated byte length (as the existing alloc_*/`*_size` fields already do) and
// pass it back to `arena_realloc`/`arena_free`; the std allocators validate that
// length on free, and the realloc move-fallback uses it to size the copy.
//
// Semantics mirror libc: `arena_realloc` returns null on OOM and leaves the old
// block intact (no free), exactly like the `if (tmp == NULL) keep old` idiom the
// call sites use. Each returns `?*anyopaque` to match the raw arena field types.

pub const ARENA_ALIGN: std.mem.Alignment = .@"16";

pub fn arena_alloc(alloc: std.mem.Allocator, len: usize) ?*anyopaque {
    if (len == 0) return null;
    const slice = alloc.alignedAlloc(u8, ARENA_ALIGN, len) catch return null;
    return @ptrCast(slice.ptr);
}

pub fn arena_realloc(alloc: std.mem.Allocator, old: ?*anyopaque, old_len: usize, new_len: usize) ?*anyopaque {
    const op = old orelse return arena_alloc(alloc, new_len);
    const old_slice: []align(16) u8 = @as([*]align(16) u8, @ptrCast(@alignCast(op)))[0..old_len];
    const new_slice = alloc.realloc(old_slice, new_len) catch return null;
    return @ptrCast(new_slice.ptr);
}

pub fn arena_free(alloc: std.mem.Allocator, old: ?*anyopaque, old_len: usize) void {
    const op = old orelse return;
    if (old_len == 0) return;
    alloc.free(@as([*]align(16) u8, @ptrCast(@alignCast(op)))[0..old_len]);
}

// Typed-array variants of the same idea (PLAN C): `malloc`/`realloc`/`free`-shaped
// over a std.mem.Allocator but keeping the `[*c]T` element-pointer shape that the
// C ABI buffers need (e.g. MD_ATTRIBUTE's `substr_types`/`substr_offsets`/`text`).
// They keep libc's `malloc`/`realloc` semantics (return `[*c]T`, null on OOM, old
// block kept on realloc OOM) but track the exact element count so the std
// allocators can free/validate them — letting a FailingAllocator reach these.
//
// NOTE: they return a plain `[*c]T`, which is itself nullable — callers check
// `== null` (mirroring C's `malloc`/`realloc` returning a possibly-NULL pointer).
// Do NOT wrap in `?[*c]T`: an optional C-pointer is a malformed type in Zig and
// produces garbage payloads (observed via valgrind as uninitialised reads).
pub fn alloc_array_a(comptime T: type, alloc: std.mem.Allocator, count: usize) [*c]T {
    if (count == 0) return null;
    const slice = alloc.alloc(T, count) catch return null;
    return slice.ptr;
}

pub fn realloc_array_a(comptime T: type, alloc: std.mem.Allocator, old: [*c]T, old_count: usize, new_count: usize) [*c]T {
    if (old == null) return alloc_array_a(T, alloc, new_count);
    const old_slice = old[0..old_count];
    const new_slice = alloc.realloc(old_slice, new_count) catch return null;
    return new_slice.ptr;
}

pub fn free_array_a(comptime T: type, alloc: std.mem.Allocator, old: [*c]T, count: usize) void {
    if (old != null and count > 0) alloc.free(old[0..count]);
}
