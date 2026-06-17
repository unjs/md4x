// MD4X parser — reference definitions + link/autolink recognizers module.
//
// FNV-1a hashing, ref-def hashtable build/lookup/free, link-label/destination/
// title recognizers, inline-link spec, and `<...>` autolink recognizers.
// Extracted verbatim from the monolithic src/md4x.zig (pure refactor — no logic
// change). See AGENTS.md.

const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

const c = types.c;
const CHAR = types.CHAR;
const SZ = types.SZ;
const OFF = types.OFF;
const MD_SIZE = types.MD_SIZE;
const TRUE = types.TRUE;
const FALSE = types.FALSE;
const MD_CTX = types.MD_CTX;
const MD_LINE = types.MD_LINE;
const MD_REF_DEF = types.MD_REF_DEF;
const c_allocator = types.c_allocator;
const MD_REF_DEF_LIST = types.MD_REF_DEF_LIST;

const ISNEWLINE_ = util.ISNEWLINE_;
const ISUNICODEWHITESPACE_ = util.ISUNICODEWHITESPACE_;
const md_decode_unicode = util.md_decode_unicode;
const md_skip_unicode_whitespace = util.md_skip_unicode_whitespace;
const md_get_unicode_fold_info = util.md_get_unicode_fold_info;
const MD_UNICODE_FOLD_INFO = util.MD_UNICODE_FOLD_INFO;
const md_merge_lines_alloc = util.md_merge_lines_alloc;
const md_lookup_line = util.md_lookup_line;
const qsort = util.qsort;
const bsearch = util.bsearch;

// ============================================================================
//  Reference Definitions — FNV-1a, label hash/compare, hashtable build/lookup
// ============================================================================

pub const MD_FNV1A_BASE: c_uint = 2166136261;
pub const MD_FNV1A_PRIME: c_uint = 16777619;

// Faithful port of md_fnv1a (md4x.c ~1620). Wrapping multiply matches C's
// unsigned overflow semantics.
pub inline fn md_fnv1a(base: c_uint, data: [*]const u8, n: usize) c_uint {
    var hash: c_uint = base;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        hash ^= data[i];
        hash *%= MD_FNV1A_PRIME;
    }
    return hash;
}

// Hash one `unsigned` codepoint, matching C's `md_fnv1a(hash, &cp, sizeof(unsigned))`.
// The C code hashes the raw machine bytes of the `unsigned` (little-endian on our
// targets). We reproduce that by hashing the 4 bytes in native byte order.
pub inline fn md_fnv1a_uint(base: c_uint, cp: c_uint) c_uint {
    const bytes = std.mem.asBytes(&cp);
    return md_fnv1a(base, bytes.ptr, bytes.len);
}

// Faithful port of md_link_label_hash (md4x.c ~1652).
pub fn md_link_label_hash(label: [*c]const CHAR, size: SZ) c_uint {
    var hash: c_uint = MD_FNV1A_BASE;

    var off: OFF = md_skip_unicode_whitespace(label, 0, size);
    while (off < size) {
        var char_size: SZ = undefined;
        var codepoint = md_decode_unicode(label, off, size, &char_size);
        const is_whitespace = ISUNICODEWHITESPACE_(codepoint) or ISNEWLINE_(label[off]);

        if (is_whitespace) {
            codepoint = ' ';
            hash = md_fnv1a_uint(hash, codepoint);
            off = md_skip_unicode_whitespace(label, off, size);
        } else {
            var fold_info: MD_UNICODE_FOLD_INFO = .{};
            md_get_unicode_fold_info(codepoint, &fold_info);
            // C: md_fnv1a(hash, fold_info.codepoints, n_codepoints * sizeof(unsigned)).
            const n: usize = @intCast(fold_info.n_codepoints);
            const bytes = std.mem.sliceAsBytes(fold_info.codepoints[0..n]);
            hash = md_fnv1a(hash, bytes.ptr, bytes.len);
            off += char_size;
        }
    }

    return hash;
}

// Faithful port of md_link_label_cmp_load_fold_info (md4x.c ~1683).
pub fn md_link_label_cmp_load_fold_info(label: [*c]const CHAR, off_in: OFF, size: SZ, fold_info: *MD_UNICODE_FOLD_INFO) OFF {
    var off = off_in;

    whitespace: {
        if (off >= size) {
            // Treat end of a link label as whitespace.
            break :whitespace;
        }

        var char_size: SZ = undefined;
        const codepoint = md_decode_unicode(label, off, size, &char_size);
        off += char_size;
        if (ISUNICODEWHITESPACE_(codepoint)) {
            // Treat all whitespace as equivalent.
            break :whitespace;
        }

        // Get real folding info.
        md_get_unicode_fold_info(codepoint, fold_info);
        return off;
    }

    fold_info.codepoints[0] = ' ';
    fold_info.n_codepoints = 1;
    return md_skip_unicode_whitespace(label, off, size);
}

// Faithful port of md_link_label_cmp (md4x.c ~1712). Returns a tri-state int
// (sign-significant) like C — `b - a` per codepoint, so callers using the sign
// behave identically.
pub fn md_link_label_cmp(a_label: [*c]const CHAR, a_size: SZ, b_label: [*c]const CHAR, b_size: SZ) c_int {
    var a_fi: MD_UNICODE_FOLD_INFO = .{};
    var b_fi: MD_UNICODE_FOLD_INFO = .{};
    var a_fi_off: OFF = 0;
    var b_fi_off: OFF = 0;

    var a_off: OFF = md_skip_unicode_whitespace(a_label, 0, a_size);
    var b_off: OFF = md_skip_unicode_whitespace(b_label, 0, b_size);
    while (a_off < a_size or a_fi_off < a_fi.n_codepoints or
        b_off < b_size or b_fi_off < b_fi.n_codepoints)
    {
        // If needed, load fold info for next char.
        if (a_fi_off >= a_fi.n_codepoints) {
            a_fi_off = 0;
            a_off = md_link_label_cmp_load_fold_info(a_label, a_off, a_size, &a_fi);
        }
        if (b_fi_off >= b_fi.n_codepoints) {
            b_fi_off = 0;
            b_off = md_link_label_cmp_load_fold_info(b_label, b_off, b_size, &b_fi);
        }

        // C: cmp = b_fi.codepoints[b_fi_off] - a_fi.codepoints[a_fi_off];
        // Both operands are `unsigned`; the difference is computed in `unsigned`
        // then assigned to `int` (implementation-defined but on our targets a
        // plain bit-reinterpretation). Reproduce via wrapping subtract + bitcast.
        const diff: c_uint = b_fi.codepoints[b_fi_off] -% a_fi.codepoints[a_fi_off];
        const cmp: c_int = @bitCast(diff);
        if (cmp != 0)
            return cmp;

        a_fi_off += 1;
        b_fi_off += 1;
    }

    return 0;
}

// Pointer arithmetic helper: the flexible-array `ref_defs[]` of MD_REF_DEF_LIST
// begins immediately after the header. Returns a many-item pointer to the array.
pub inline fn md_ref_def_list_items(list: *MD_REF_DEF_LIST) [*c]?*MD_REF_DEF {
    const base: [*]u8 = @ptrCast(list);
    return @ptrCast(@alignCast(base + @sizeOf(MD_REF_DEF_LIST)));
}

// qsort/bsearch comparators. CRITICAL ORDERING NOTE (see PARSER-PORT.md log):
// these mirror md_ref_def_cmp / md_ref_def_cmp_for_sort byte-for-byte and are
// passed to libc qsort()/bsearch() (via std.c) so that, on the *same* glibc
// runtime, the ordering and tie-breaking are bit-identical to the C parser. The
// comparators read only the MD_REF_DEF fields + the pointer values (for sort
// stability) — they need no ctx, so they are pure `callconv(.c)` functions.
//
// `a`/`b` are `const void*` pointing at `MD_REF_DEF*` slots (i.e. *(MD_REF_DEF**)).
pub fn md_ref_def_cmp(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    const a_pp: *const (*const MD_REF_DEF) = @ptrCast(@alignCast(a.?));
    const b_pp: *const (*const MD_REF_DEF) = @ptrCast(@alignCast(b.?));
    const a_ref = a_pp.*;
    const b_ref = b_pp.*;

    if (a_ref.hash < b_ref.hash)
        return -1
    else if (a_ref.hash > b_ref.hash)
        return 1
    else
        return md_link_label_cmp(a_ref.label, a_ref.label_size, b_ref.label, b_ref.label_size);
}

pub fn md_ref_def_cmp_for_sort(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    var cmp = md_ref_def_cmp(a, b);

    // Ensure stability of the sorting (tie-break on pointer identity, exactly as
    // C does — these pointers index into ctx->ref_defs[], so this reproduces the
    // array order for equal labels).
    if (cmp == 0) {
        const a_pp: *const (*const MD_REF_DEF) = @ptrCast(@alignCast(a.?));
        const b_pp: *const (*const MD_REF_DEF) = @ptrCast(@alignCast(b.?));
        const a_ref = @intFromPtr(a_pp.*);
        const b_ref = @intFromPtr(b_pp.*);

        if (a_ref < b_ref)
            cmp = -1
        else if (a_ref > b_ref)
            cmp = 1
        else
            cmp = 0;
    }

    return cmp;
}

// Faithful port of md_build_ref_def_hashtable (md4x.c ~1793). Returns 0 / -1.
pub fn md_build_ref_def_hashtable(ctx: *MD_CTX) c_int {
    if (ctx.ref_defs.items.len == 0)
        return 0;

    ctx.ref_def_hashtable_size = @divTrunc(@as(c_int, @intCast(ctx.ref_defs.items.len)) * 5, 4);
    ctx.ref_def_hashtable = @ptrCast(@alignCast(std.c.malloc(@as(usize, @intCast(ctx.ref_def_hashtable_size)) * @sizeOf(?*anyopaque))));
    if (ctx.ref_def_hashtable == null) {
        ctx.log("malloc() failed.");
        return -1;
    }
    @memset(ctx.ref_def_hashtable[0..@intCast(ctx.ref_def_hashtable_size)], null);

    const ref_defs_base = @intFromPtr(ctx.ref_defs.items.ptr);
    const ref_defs_end = @intFromPtr(ctx.ref_defs.items.ptr + ctx.ref_defs.items.len);

    // Build the buckets.
    var i: c_int = 0;
    while (i < @as(c_int, @intCast(ctx.ref_defs.items.len))) : (i += 1) {
        const def: *MD_REF_DEF = @ptrCast(&ctx.ref_defs.items[@intCast(i)]);

        def.hash = md_link_label_hash(def.label, def.label_size);
        const slot: usize = @intCast(@mod(def.hash, @as(c_uint, @intCast(ctx.ref_def_hashtable_size))));
        const bucket = ctx.ref_def_hashtable[slot];

        if (bucket == null) {
            // Empty bucket: point it at the def.
            ctx.ref_def_hashtable[slot] = @ptrCast(def);
            continue;
        }

        const bucket_addr = @intFromPtr(bucket);
        if (ref_defs_base <= bucket_addr and bucket_addr < ref_defs_end) {
            // Bucket holds one ref-def. Same label (dup) or hash conflict?
            const old_def: *MD_REF_DEF = @ptrCast(@alignCast(bucket));

            if (md_link_label_cmp(def.label, def.label_size, old_def.label, old_def.label_size) == 0) {
                // Duplicate label: ignore this ref-def.
                continue;
            }

            // Promote to a complex bucket.
            const list: ?*MD_REF_DEF_LIST = @ptrCast(@alignCast(std.c.malloc(@sizeOf(MD_REF_DEF_LIST) + 2 * @sizeOf(?*MD_REF_DEF))));
            if (list == null) {
                ctx.log("malloc() failed.");
                return -1;
            }
            const l = list.?;
            const items = md_ref_def_list_items(l);
            items[0] = old_def;
            items[1] = def;
            l.n_ref_defs = 2;
            l.alloc_ref_defs = 2;
            ctx.ref_def_hashtable[slot] = @ptrCast(l);
            continue;
        }

        // Append to the existing complex bucket. (Duplicates within complex
        // buckets are resolved after sorting, below — matching C.)
        var list: *MD_REF_DEF_LIST = @ptrCast(@alignCast(bucket));
        if (list.n_ref_defs >= list.alloc_ref_defs) {
            const new_alloc = list.alloc_ref_defs + @divTrunc(list.alloc_ref_defs, 2);
            const list_tmp: ?*MD_REF_DEF_LIST = @ptrCast(@alignCast(std.c.realloc(list, @sizeOf(MD_REF_DEF_LIST) + @as(usize, @intCast(new_alloc)) * @sizeOf(?*MD_REF_DEF))));
            if (list_tmp == null) {
                ctx.log("realloc() failed.");
                return -1;
            }
            list = list_tmp.?;
            list.alloc_ref_defs = new_alloc;
            ctx.ref_def_hashtable[slot] = @ptrCast(list);
        }

        const items = md_ref_def_list_items(list);
        items[@intCast(list.n_ref_defs)] = def;
        list.n_ref_defs += 1;
    }

    // Sort the complex buckets so we can bsearch() them.
    i = 0;
    while (i < ctx.ref_def_hashtable_size) : (i += 1) {
        const bucket = ctx.ref_def_hashtable[@intCast(i)];
        if (bucket == null)
            continue;
        const bucket_addr = @intFromPtr(bucket);
        if (ref_defs_base <= bucket_addr and bucket_addr < ref_defs_end)
            continue;

        const list: *MD_REF_DEF_LIST = @ptrCast(@alignCast(bucket));
        const items = md_ref_def_list_items(list);
        qsort(@ptrCast(items), @intCast(list.n_ref_defs), @sizeOf(?*MD_REF_DEF), md_ref_def_cmp_for_sort);

        // Disable duplicates in the complex bucket by forcing duplicate records
        // to point to the 1st such ref-def (so lookup always resolves the same).
        var j: c_int = 1;
        while (j < list.n_ref_defs) : (j += 1) {
            if (md_ref_def_cmp(@ptrCast(&items[@intCast(j - 1)]), @ptrCast(&items[@intCast(j)])) == 0)
                items[@intCast(j)] = items[@intCast(j - 1)];
        }
    }

    return 0;
}

// Faithful port of md_free_ref_def_hashtable (md4x.c ~1907).
pub fn md_free_ref_def_hashtable(ctx: *MD_CTX) void {
    if (ctx.ref_def_hashtable != null) {
        const ref_defs_base = @intFromPtr(ctx.ref_defs.items.ptr);
        const ref_defs_end = @intFromPtr(ctx.ref_defs.items.ptr + ctx.ref_defs.items.len);

        var i: c_int = 0;
        while (i < ctx.ref_def_hashtable_size) : (i += 1) {
            const bucket = ctx.ref_def_hashtable[@intCast(i)];
            if (bucket == null)
                continue;
            const bucket_addr = @intFromPtr(bucket);
            if (ref_defs_base <= bucket_addr and bucket_addr < ref_defs_end)
                continue;
            std.c.free(bucket);
        }

        std.c.free(@ptrCast(ctx.ref_def_hashtable));
    }
}

// Faithful port of md_lookup_ref_def (md4x.c ~1925). Returns the matching
// const MD_REF_DEF* or null.
pub fn md_lookup_ref_def(ctx: *MD_CTX, label: [*c]const CHAR, label_size: SZ) ?*const MD_REF_DEF {
    if (ctx.ref_def_hashtable_size == 0)
        return null;

    const hash = md_link_label_hash(label, label_size);
    const slot: usize = @intCast(@mod(hash, @as(c_uint, @intCast(ctx.ref_def_hashtable_size))));
    const bucket = ctx.ref_def_hashtable[slot];

    if (bucket == null) {
        return null;
    }

    const ref_defs_base = @intFromPtr(ctx.ref_defs.items.ptr);
    const ref_defs_end = @intFromPtr(ctx.ref_defs.items.ptr + ctx.ref_defs.items.len);
    const bucket_addr = @intFromPtr(bucket);

    if (ref_defs_base <= bucket_addr and bucket_addr < ref_defs_end) {
        const def: *const MD_REF_DEF = @ptrCast(@alignCast(bucket));
        if (md_link_label_cmp(def.label, def.label_size, label, label_size) == 0)
            return def
        else
            return null;
    } else {
        const list: *MD_REF_DEF_LIST = @ptrCast(@alignCast(bucket));
        var key_buf: MD_REF_DEF = .{};
        key_buf.label = @constCast(label);
        key_buf.label_size = label_size;
        key_buf.hash = md_link_label_hash(key_buf.label, key_buf.label_size);
        const key: *const MD_REF_DEF = &key_buf;

        const items = md_ref_def_list_items(list);
        const ret = bsearch(@ptrCast(&key), @ptrCast(items), @intCast(list.n_ref_defs), @sizeOf(?*MD_REF_DEF), md_ref_def_cmp);
        if (ret) |r| {
            const rp: *const (?*MD_REF_DEF) = @ptrCast(@alignCast(r));
            return rp.*;
        } else {
            return null;
        }
    }
}

// Faithful port of md_free_ref_defs (md4x.c ~2491).
pub fn md_free_ref_defs(ctx: *MD_CTX) void {
    var i: c_int = 0;
    while (i < @as(c_int, @intCast(ctx.ref_defs.items.len))) : (i += 1) {
        const def: *MD_REF_DEF = @ptrCast(&ctx.ref_defs.items[@intCast(i)]);
        if (def.label_needs_free)
            std.c.free(def.label);
        if (def.title_needs_free)
            std.c.free(def.title);
    }
    ctx.ref_defs.deinit(c_allocator);
}

// ============================================================================
//  Recognizing Links
// ============================================================================

// Mirrors `struct MD_LINK_ATTR_tag` (md4x.c ~1975). Internal — no C ABI.
pub const MD_LINK_ATTR = struct {
    dest_beg: OFF = 0,
    dest_end: OFF = 0,
    title: [*c]CHAR = null,
    title_size: SZ = 0,
    title_needs_free: c_int = 0,
};

// Faithful port of md_is_link_label (md4x.c ~1986).
pub fn md_is_link_label(
    ctx: *MD_CTX,
    lines: []const MD_LINE,
    beg: OFF,
    p_end: *OFF,
    p_beg_line_index: *MD_SIZE,
    p_end_line_index: *MD_SIZE,
    p_contents_beg: *OFF,
    p_contents_end: *OFF,
) c_int {
    var off = beg;
    var contents_beg: OFF = 0;
    var contents_end: OFF = 0;
    var line_index: MD_SIZE = 0;
    var len: c_int = 0;

    p_beg_line_index.* = 0;

    if (ctx.ch(off) != '[')
        return FALSE;
    off += 1;

    while (true) {
        const line_end = lines[line_index].end;

        while (off < line_end) {
            if (ctx.ch(off) == '\\' and off + 1 < ctx.size and (ctx.isPunct(off + 1) or ctx.isNewline(off + 1))) {
                if (contents_end == 0) {
                    contents_beg = off;
                    p_beg_line_index.* = line_index;
                }
                contents_end = off + 2;
                off += 2;
            } else if (ctx.ch(off) == '[') {
                return FALSE;
            } else if (ctx.ch(off) == ']') {
                if (contents_beg < contents_end) {
                    // Success.
                    p_contents_beg.* = contents_beg;
                    p_contents_end.* = contents_end;
                    p_end.* = off + 1;
                    p_end_line_index.* = line_index;
                    return TRUE;
                } else {
                    // Link label must have some non-whitespace contents.
                    return FALSE;
                }
            } else {
                var char_size: SZ = undefined;
                const codepoint = md_decode_unicode(ctx.text, off, ctx.size, &char_size);
                if (!ISUNICODEWHITESPACE_(codepoint)) {
                    if (contents_end == 0) {
                        contents_beg = off;
                        p_beg_line_index.* = line_index;
                    }
                    contents_end = off + char_size;
                }

                off += char_size;
            }

            len += 1;
            if (len > 999)
                return FALSE;
        }

        line_index += 1;
        len += 1;
        if (line_index < lines.len)
            off = lines[line_index].beg
        else
            break;
    }

    return FALSE;
}

// Faithful port of md_is_link_destination_A (md4x.c ~2060).
pub fn md_is_link_destination_A(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF, p_contents_beg: *OFF, p_contents_end: *OFF) c_int {
    var off = beg;

    if (off >= max_end or ctx.ch(off) != '<')
        return FALSE;
    off += 1;

    while (off < max_end) {
        if (ctx.ch(off) == '\\' and off + 1 < max_end and ctx.isPunct(off + 1)) {
            off += 2;
            continue;
        }

        if (ctx.isNewline(off) or ctx.ch(off) == '<')
            return FALSE;

        if (ctx.ch(off) == '>') {
            // Success.
            p_contents_beg.* = beg + 1;
            p_contents_end.* = off;
            p_end.* = off + 1;
            return TRUE;
        }

        off += 1;
    }

    return FALSE;
}

// Faithful port of md_is_link_destination_B (md4x.c ~2093).
pub fn md_is_link_destination_B(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF, p_contents_beg: *OFF, p_contents_end: *OFF) c_int {
    var off = beg;
    var parenthesis_level: c_int = 0;

    while (off < max_end) {
        if (ctx.ch(off) == '\\' and off + 1 < max_end and ctx.isPunct(off + 1)) {
            off += 2;
            continue;
        }

        if (ctx.isWhitespace(off) or ctx.isCntrl(off))
            break;

        // Balanced pairs of unescaped '(' ')', nesting capped at 32 (cmark #214).
        if (ctx.ch(off) == '(') {
            parenthesis_level += 1;
            if (parenthesis_level > 32)
                return FALSE;
        } else if (ctx.ch(off) == ')') {
            if (parenthesis_level == 0)
                break;
            parenthesis_level -= 1;
        }

        off += 1;
    }

    if (parenthesis_level != 0 or off == beg)
        return FALSE;

    // Success.
    p_contents_beg.* = beg;
    p_contents_end.* = off;
    p_end.* = off;
    return TRUE;
}

// Faithful port of md_is_link_destination (md4x.c ~2134).
pub inline fn md_is_link_destination(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF, p_contents_beg: *OFF, p_contents_end: *OFF) c_int {
    if (ctx.ch(beg) == '<')
        return md_is_link_destination_A(ctx, beg, max_end, p_end, p_contents_beg, p_contents_end)
    else
        return md_is_link_destination_B(ctx, beg, max_end, p_end, p_contents_beg, p_contents_end);
}

// Faithful port of md_is_link_title (md4x.c ~2144).
pub fn md_is_link_title(
    ctx: *MD_CTX,
    lines: []const MD_LINE,
    beg: OFF,
    p_end: *OFF,
    p_beg_line_index: *MD_SIZE,
    p_end_line_index: *MD_SIZE,
    p_contents_beg: *OFF,
    p_contents_end: *OFF,
) c_int {
    var off = beg;
    var closer_char: CHAR = undefined;
    var line_index: MD_SIZE = 0;

    // White space with up to one line break.
    while (off < lines[line_index].end and ctx.isWhitespace(off))
        off += 1;
    if (off >= lines[line_index].end) {
        line_index += 1;
        if (line_index >= lines.len)
            return FALSE;
        off = lines[line_index].beg;
    }
    if (off == beg)
        return FALSE;

    p_beg_line_index.* = line_index;

    // First char determines how to detect end of it.
    switch (ctx.ch(off)) {
        '"' => closer_char = '"',
        '\'' => closer_char = '\'',
        '(' => closer_char = ')',
        else => return FALSE,
    }
    off += 1;

    p_contents_beg.* = off;

    while (line_index < lines.len) {
        const line_end = lines[line_index].end;

        while (off < line_end) {
            if (ctx.ch(off) == '\\' and off + 1 < ctx.size and (ctx.isPunct(off + 1) or ctx.isNewline(off + 1))) {
                off += 1;
            } else if (ctx.ch(off) == closer_char) {
                // Success.
                p_contents_end.* = off;
                p_end.* = off + 1;
                p_end_line_index.* = line_index;
                return TRUE;
            } else if (closer_char == ')' and ctx.ch(off) == '(') {
                // ()-style title cannot contain an unescaped '('.
                return FALSE;
            }

            off += 1;
        }

        line_index += 1;
    }

    return FALSE;
}

// Faithful port of md_is_link_reference_definition (md4x.c ~2212). Returns 0 if
// not a ref-def, N>0 (number of lines) if it is, -1 on OOM.
pub fn md_is_link_reference_definition(ctx: *MD_CTX, lines: []const MD_LINE) c_int {
    var label_contents_beg: OFF = undefined;
    var label_contents_end: OFF = undefined;
    var label_contents_line_index: MD_SIZE = undefined;
    var label_is_multiline: bool = false;
    var dest_contents_beg: OFF = undefined;
    var dest_contents_end: OFF = undefined;
    var title_contents_beg: OFF = undefined;
    var title_contents_end: OFF = undefined;
    var title_contents_line_index: MD_SIZE = undefined;
    var title_is_multiline: bool = false;
    var off: OFF = undefined;
    var line_index: MD_SIZE = 0;
    var tmp_line_index: MD_SIZE = undefined;
    var def: ?*MD_REF_DEF = null;
    var ret: c_int = 0;

    // Link label.
    if (md_is_link_label(ctx, lines, lines[0].beg, &off, &label_contents_line_index, &line_index, &label_contents_beg, &label_contents_end) == 0)
        return FALSE;
    label_is_multiline = (label_contents_line_index != line_index);

    // Colon.
    if (off >= lines[line_index].end or ctx.ch(off) != ':')
        return FALSE;
    off += 1;

    // Optional white space with up to one line break.
    while (off < lines[line_index].end and ctx.isWhitespace(off))
        off += 1;
    if (off >= lines[line_index].end) {
        line_index += 1;
        if (line_index >= lines.len)
            return FALSE;
        off = lines[line_index].beg;
    }

    // Link destination.
    if (md_is_link_destination(ctx, off, lines[line_index].end, &off, &dest_contents_beg, &dest_contents_end) == 0)
        return FALSE;

    // (Optional) title. Only a title if nothing more follows on its last line.
    if (md_is_link_title(ctx, lines[line_index..], off, &off, &title_contents_line_index, &tmp_line_index, &title_contents_beg, &title_contents_end) != 0 and
        off >= lines[line_index + tmp_line_index].end)
    {
        title_is_multiline = (tmp_line_index != title_contents_line_index);
        title_contents_line_index += line_index;
        line_index += tmp_line_index;
    } else {
        // Not a title.
        title_is_multiline = false;
        title_contents_beg = off;
        title_contents_end = off;
        title_contents_line_index = 0;
    }

    // Nothing more can follow on the last line.
    if (off < lines[line_index].end)
        return FALSE;

    // So, it _is_ a reference definition. Remember it.
    // Reserve (but do not yet commit) one slot: the abort paths below must not
    // leave a half-filled committed entry, so we only bump items.len on success.
    ctx.ref_defs.ensureUnusedCapacity(c_allocator, 1) catch {
        ctx.log("realloc() failed.");
        // ret stays 0 → abort.
        return md_is_link_reference_definition_abort(def, ret);
    };
    def = &ctx.ref_defs.items.ptr[ctx.ref_defs.items.len];
    @memset(std.mem.asBytes(def.?), 0);

    if (label_is_multiline) {
        ret = md_merge_lines_alloc(ctx, label_contents_beg, label_contents_end, lines[label_contents_line_index..], ' ', &def.?.label, &def.?.label_size);
        if (ret < 0) return md_is_link_reference_definition_abort(def, ret);
        def.?.label_needs_free = true;
    } else {
        def.?.label = @constCast(ctx.str(label_contents_beg));
        def.?.label_size = label_contents_end - label_contents_beg;
    }

    if (title_is_multiline) {
        ret = md_merge_lines_alloc(ctx, title_contents_beg, title_contents_end, lines[title_contents_line_index..], '\n', &def.?.title, &def.?.title_size);
        if (ret < 0) return md_is_link_reference_definition_abort(def, ret);
        def.?.title_needs_free = true;
    } else {
        def.?.title = @constCast(ctx.str(title_contents_beg));
        def.?.title_size = title_contents_end - title_contents_beg;
    }

    def.?.dest_beg = dest_contents_beg;
    def.?.dest_end = dest_contents_end;

    // Success: commit the reserved slot.
    ctx.ref_defs.items.len += 1;
    return @as(c_int, @intCast(line_index)) + 1;
}

// The C `abort:` cleanup for md_is_link_reference_definition. Factored out since
// Zig has no goto; only the realloc/merge-lines paths can reach it (with ret<=0).
pub fn md_is_link_reference_definition_abort(def: ?*MD_REF_DEF, ret: c_int) c_int {
    if (def) |d| {
        if (d.label_needs_free) std.c.free(d.label);
        if (d.title_needs_free) std.c.free(d.title);
    }
    return ret;
}

// Faithful port of md_is_link_reference (md4x.c ~2334).
pub fn md_is_link_reference(ctx: *MD_CTX, lines: []const MD_LINE, beg_in: OFF, end_in: OFF, attr: *MD_LINK_ATTR) c_int {
    var beg = beg_in;
    var end = end_in;
    var label: [*c]CHAR = undefined;
    var label_size: SZ = undefined;
    var ret: c_int = FALSE;

    // MD_ASSERT(CH(beg) == '[' || CH(beg) == '!');  MD_ASSERT(CH(end-1) == ']');
    if (ctx.max_ref_def_output == 0)
        return FALSE;

    beg += if (ctx.ch(beg) == '!') @as(OFF, 2) else 1;
    end -= 1;

    // Find lines corresponding to beg/end positions.
    const beg_line = md_lookup_line(beg, lines, null);
    const is_multiline = (end > beg_line.end);

    if (is_multiline) {
        const beg_line_idx: usize = (@intFromPtr(beg_line) - @intFromPtr(lines.ptr)) / @sizeOf(MD_LINE);
        ret = md_merge_lines_alloc(ctx, beg, end, lines[beg_line_idx..], ' ', &label, &label_size);
        if (ret < 0) return ret;
        ret = FALSE;
    } else {
        label = @constCast(ctx.str(beg));
        label_size = end - beg;
    }

    const def = md_lookup_ref_def(ctx, label, label_size);
    if (def) |d| {
        attr.dest_beg = d.dest_beg;
        attr.dest_end = d.dest_end;
        attr.title = d.title;
        attr.title_size = d.title_size;
        attr.title_needs_free = FALSE;
    }

    if (is_multiline)
        std.c.free(label);

    if (def) |d| {
        // See https://github.com/mity/md4c/issues/238
        const output_size_estimation: MD_SIZE = d.label_size + d.title_size + d.dest_end - d.dest_beg;
        if (output_size_estimation < ctx.max_ref_def_output) {
            ctx.max_ref_def_output -= output_size_estimation;
            ret = TRUE;
        } else {
            ctx.log("Too many link reference definition instantiations.");
            ctx.max_ref_def_output = 0;
        }
    }

    return ret;
}

// Faithful port of md_is_inline_link_spec (md4x.c ~2394).
pub fn md_is_inline_link_spec(ctx: *MD_CTX, lines: []const MD_LINE, beg: OFF, p_end: *OFF, attr: *MD_LINK_ATTR) c_int {
    var line_index: MD_SIZE = 0;
    var tmp_line_index: MD_SIZE = undefined;
    var title_contents_beg: OFF = undefined;
    var title_contents_end: OFF = undefined;
    var title_contents_line_index: MD_SIZE = undefined;
    var title_is_multiline: bool = undefined;
    var off = beg;
    var ret: c_int = FALSE;

    _ = md_lookup_line(off, lines, &line_index);

    // MD_ASSERT(CH(off) == '(');
    off += 1;

    // Optional white space with up to one line break.
    while (off < lines[line_index].end and ctx.isWhitespace(off))
        off += 1;
    if (off >= lines[line_index].end and (off >= ctx.size or ctx.isNewline(off))) {
        line_index += 1;
        if (line_index >= lines.len)
            return FALSE;
        off = lines[line_index].beg;
    }

    // Link destination may be omitted, but only when not also having a title.
    if (off < ctx.size and ctx.ch(off) == ')') {
        attr.dest_beg = off;
        attr.dest_end = off;
        attr.title = null;
        attr.title_size = 0;
        attr.title_needs_free = FALSE;
        off += 1;
        p_end.* = off;
        return TRUE;
    }

    // Link destination.
    if (md_is_link_destination(ctx, off, lines[line_index].end, &off, &attr.dest_beg, &attr.dest_end) == 0)
        return FALSE;

    // (Optional) title.
    if (md_is_link_title(ctx, lines[line_index..], off, &off, &title_contents_line_index, &tmp_line_index, &title_contents_beg, &title_contents_end) != 0) {
        title_is_multiline = (tmp_line_index != title_contents_line_index);
        title_contents_line_index += line_index;
        line_index += tmp_line_index;
    } else {
        // Not a title.
        title_is_multiline = false;
        title_contents_beg = off;
        title_contents_end = off;
        title_contents_line_index = 0;
    }

    // Optional whitespace followed with final ')'.
    while (off < lines[line_index].end and ctx.isWhitespace(off))
        off += 1;
    if (off >= lines[line_index].end) {
        line_index += 1;
        if (line_index >= lines.len)
            return FALSE;
        off = lines[line_index].beg;
    }
    if (ctx.ch(off) != ')')
        return ret; // goto abort (ret == FALSE here)
    off += 1;

    if (title_contents_beg >= title_contents_end) {
        attr.title = null;
        attr.title_size = 0;
        attr.title_needs_free = FALSE;
    } else if (!title_is_multiline) {
        attr.title = @constCast(ctx.str(title_contents_beg));
        attr.title_size = title_contents_end - title_contents_beg;
        attr.title_needs_free = FALSE;
    } else {
        ret = md_merge_lines_alloc(ctx, title_contents_beg, title_contents_end, lines[title_contents_line_index..], '\n', &attr.title, &attr.title_size);
        if (ret < 0) return ret;
        attr.title_needs_free = TRUE;
    }

    p_end.* = off;
    ret = TRUE;
    return ret;
}

// ============================================================================
//  Recognizing `<...>` Autolinks (pure recognizers; permissive autolinks live
//  in the inline mark engine — Pass C — because they need ctx->marks).
// ============================================================================

// Faithful port of md_is_autolink_uri (md4x.c ~2951).
pub fn md_is_autolink_uri(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off = beg + 1;

    // MD_ASSERT(CH(beg) == '<');

    // Scheme.
    if (off >= max_end or !ctx.isAscii(off))
        return FALSE;
    off += 1;
    while (true) {
        if (off >= max_end)
            return FALSE;
        if (off - beg > 32)
            return FALSE;
        if (ctx.ch(off) == ':' and off - beg >= 3)
            break;
        if (!ctx.isAlnum(off) and ctx.ch(off) != '+' and ctx.ch(off) != '-' and ctx.ch(off) != '.')
            return FALSE;
        off += 1;
    }

    // Path after the scheme.
    while (off < max_end and ctx.ch(off) != '>') {
        if (ctx.isWhitespace(off) or ctx.isCntrl(off) or ctx.ch(off) == '<')
            return FALSE;
        off += 1;
    }

    if (off >= max_end)
        return FALSE;

    // MD_ASSERT(CH(off) == '>');
    p_end.* = off + 1;
    return TRUE;
}

// Faithful port of md_is_autolink_email (md4x.c ~2989).
pub fn md_is_autolink_email(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF) c_int {
    var off = beg + 1;
    var label_len: c_int = undefined;

    // MD_ASSERT(CH(beg) == '<');

    // Username (before '@').
    while (off < max_end and (ctx.isAlnum(off) or ctx.isAnyOf(off, ".!#$%&'*+/=?^_`{|}~-")))
        off += 1;
    if (off <= beg + 1)
        return FALSE;

    // '@'
    if (off >= max_end or ctx.ch(off) != '@')
        return FALSE;
    off += 1;

    // '.'-delimited labels: each 1-63 alnum or '-', '-' not first/last.
    label_len = 0;
    while (off < max_end) {
        if (ctx.isAlnum(off))
            label_len += 1
        else if (ctx.ch(off) == '-' and label_len > 0)
            label_len += 1
        else if (ctx.ch(off) == '.' and label_len > 0 and ctx.ch(off - 1) != '-')
            label_len = 0
        else
            break;

        if (label_len > 63)
            return FALSE;

        off += 1;
    }

    if (label_len <= 0 or off >= max_end or ctx.ch(off) != '>' or ctx.ch(off - 1) == '-')
        return FALSE;

    p_end.* = off + 1;
    return TRUE;
}

// Faithful port of md_is_autolink (md4x.c ~3040).
pub fn md_is_autolink(ctx: *MD_CTX, beg: OFF, max_end: OFF, p_end: *OFF, p_missing_mailto: *c_int) c_int {
    if (md_is_autolink_uri(ctx, beg, max_end, p_end) != 0) {
        p_missing_mailto.* = FALSE;
        return TRUE;
    }

    if (md_is_autolink_email(ctx, beg, max_end, p_end) != 0) {
        p_missing_mailto.* = TRUE;
        return TRUE;
    }

    return FALSE;
}
