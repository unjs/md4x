// MD4X: Markdown parser for C
// (http://github.com/unjs/md4x)
//
// Copyright (c) 2026 Pooya Parsa <pooya@pi0.io>
//
// Based on logic from https://github.com/vercel/streamdown/tree/main/packages/remend
// Written by Hayden Bleasel <https://github.com/haydenbleasel>
// Copyright (c) 2023 Vercel Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//
// Zig port of src/renderers/md4x-heal.c — byte-for-byte identical behavior.

const std = @import("std");

const c_allocator = std.heap.c_allocator;

// The original C uses `char` (signed on most platforms). We mirror its
// comparisons faithfully. Since all comparisons in the C code are either
// against ASCII literals (positive) or use is_word_char-style ranges, the
// signedness of `char` does not change any branch outcome here. We store
// bytes as u8 and compare against u8 literals.

// ***************************
// ***  Growable buffer    ***
// ***************************

const HEAL_BUF = struct {
    data: ?[*]u8,
    size: u32,
    cap: u32,
    err: c_int,
};

fn buf_init(buf: *HEAL_BUF, initial_cap: u32) void {
    // malloc(initial_cap). C malloc(0) may return NULL or a valid pointer;
    // initial_cap here is always input_size + 64 >= 64, so non-zero.
    const mem = c_allocator.alloc(u8, initial_cap) catch {
        buf.data = null;
        buf.size = 0;
        buf.cap = 0;
        buf.err = 0;
        return;
    };
    buf.data = mem.ptr;
    buf.size = 0;
    buf.cap = initial_cap;
    buf.err = 0;
}

fn buf_append(buf: *HEAL_BUF, s: [*]const u8, len: u32) void {
    if (len == 0 or buf.err != 0) return;
    if (buf.size +% len > buf.cap) {
        const new_cap: u32 = buf.cap +% buf.cap / 2 +% len +% 64;
        const old = buf.data.?[0..buf.cap];
        const p = c_allocator.realloc(old, new_cap) catch {
            buf.err = 1;
            return;
        };
        buf.data = p.ptr;
        buf.cap = new_cap;
    }
    const dst = buf.data.? + buf.size;
    @memcpy(dst[0..len], s[0..len]);
    buf.size +%= len;
}

fn buf_append_ch(buf: *HEAL_BUF, c: u8) void {
    var ch = c;
    buf_append(buf, @ptrCast(&ch), 1);
}

fn buf_free(buf: *HEAL_BUF) void {
    if (buf.data) |d| {
        c_allocator.free(d[0..buf.cap]);
    }
    buf.data = null;
    buf.size = 0;
    buf.cap = 0;
}

// ***************************
// ***  Utility helpers    ***
// ***************************

fn is_word_char(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn is_escaped(text: [*]const u8, pos_in: u32) bool {
    var n: u32 = 0;
    var pos = pos_in;
    while (pos > 0 and text[pos - 1] == '\\') {
        n +%= 1;
        pos -%= 1;
    }
    return (n % 2) != 0;
}

// Check if position i is part of a ``` sequence
fn is_triple_backtick(text: [*]const u8, size: u32, i: u32) bool {
    if (i + 2 < size and text[i] == '`' and text[i + 1] == '`' and text[i + 2] == '`')
        return true;
    if (i >= 1 and i + 1 < size and text[i - 1] == '`' and text[i] == '`' and text[i + 1] == '`')
        return true;
    if (i >= 2 and text[i - 2] == '`' and text[i - 1] == '`' and text[i] == '`')
        return true;
    return false;
}

// Find the start of the current line (returns index after preceding newline)
fn line_start(text: [*]const u8, pos_in: u32) u32 {
    var pos = pos_in;
    while (pos > 0 and text[pos - 1] != '\n')
        pos -%= 1;
    return pos;
}

// Find the end of the current line (returns index of newline or size)
fn line_end(text: [*]const u8, size: u32, pos_in: u32) u32 {
    var pos = pos_in;
    while (pos < size and text[pos] != '\n')
        pos +%= 1;
    return pos;
}

// Check if a line is a horizontal rule (3+ of same marker with only whitespace)
fn is_horizontal_rule(text: [*]const u8, size: u32, marker_pos: u32, marker: u8) bool {
    const ls = line_start(text, marker_pos);
    const le = line_end(text, size, marker_pos);
    var count: u32 = 0;
    var i: u32 = ls;
    while (i < le) : (i +%= 1) {
        if (text[i] == marker) {
            count +%= 1;
        } else if (text[i] != ' ' and text[i] != '\t') {
            return false;
        }
    }
    return count >= 3;
}

// ***************************
// ***  Context tracking   ***
// ***************************

fn in_fenced_code_block(text: [*]const u8, size: u32, pos: u32) bool {
    _ = size;
    var inside = false;
    var i: u32 = 0;
    while (i < pos) {
        if (text[i] == '`' and i + 2 < pos and text[i + 1] == '`' and text[i + 2] == '`') {
            if (!is_escaped(text, i))
                inside = !inside;
            i +%= 3;
            while (i < pos and text[i] != '\n') i +%= 1;
        } else {
            i +%= 1;
        }
    }
    return inside;
}

fn count_fences(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < size) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            if (!is_escaped(text, i))
                count +%= 1;
            i +%= 3;
            while (i < size and text[i] == '`') i +%= 1;
        } else {
            i +%= 1;
        }
    }
    return count;
}

fn count_single_backticks(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and !is_escaped(text, i) and !is_triple_backtick(text, size, i))
            count +%= 1;
    }
    return count;
}

fn in_complete_inline_code(text: [*]const u8, size: u32, pos: u32) bool {
    var i: u32 = 0;
    var in_code: bool = false;
    var code_start: u32 = 0;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and !is_escaped(text, i) and !is_triple_backtick(text, size, i)) {
            if (!in_code) {
                in_code = true;
                code_start = i;
            } else {
                if (pos > code_start and pos < i)
                    return true;
                in_code = false;
            }
        }
    }
    return false;
}

fn in_math_block(text: [*]const u8, size: u32, pos: u32) bool {
    var in_block: bool = false;
    var in_inline: bool = false;
    var i: u32 = 0;
    while (i < size and i < pos) : (i +%= 1) {
        if (text[i] == '\\') {
            i +%= 1;
            continue;
        }
        if (text[i] == '$') {
            if (i + 1 < size and text[i + 1] == '$') {
                in_block = !in_block;
                i +%= 1;
            } else if (!in_block) {
                in_inline = !in_inline;
            }
        }
    }
    return in_block or in_inline;
}

fn in_link_url(text: [*]const u8, pos: u32) bool {
    if (pos == 0) return false;
    var i: u32 = pos;
    while (i > 0) : (i -%= 1) {
        if (text[i - 1] == '\n') return false;
        if (text[i - 1] == ')') return false;
        if (text[i - 1] == '(') {
            if (i >= 2 and text[i - 2] == ']')
                return true;
            return false;
        }
    }
    return false;
}

fn in_html_tag(text: [*]const u8, pos: u32) bool {
    if (pos == 0) return false;
    var i: u32 = pos;
    while (i > 0) : (i -%= 1) {
        if (text[i - 1] == '\n') return false;
        if (text[i - 1] == '>') return false;
        if (text[i - 1] == '<') {
            if (i < pos) {
                const next = text[i];
                return (next >= 'a' and next <= 'z') or
                    (next >= 'A' and next <= 'Z') or next == '/';
            }
            return false;
        }
    }
    return false;
}

// ***************************
// ***  Setext headings    ***
// ***************************

fn heal_setext_heading(buf: *HEAL_BUF) void {
    if (buf.size == 0) return;
    const data = buf.data.?;

    const le: u32 = buf.size;
    var ls: u32 = le;
    while (ls > 0 and data[ls - 1] != '\n') ls -%= 1;

    if (le - ls < 1 or le - ls > 2) return;
    const marker = data[ls];
    if (marker != '-' and marker != '=') return;
    var count: c_int = 1;
    var i: u32 = ls + 1;
    while (i < le) : (i +%= 1) {
        if (data[i] != marker) return;
        count += 1;
    }
    if (count > 2) return;

    if (ls == 0) return;
    const prev_le: u32 = ls - 1;
    if (prev_le == 0) return;
    i = prev_le;
    while (i > 0 and data[i - 1] != '\n') i -%= 1;
    if (i == prev_le) return;

    buf_append(buf, "\xE2\x80\x8B", 3);
}

// ***************************
// ***  Code block heal    ***
// ***************************

fn heal_code_block(buf: *HEAL_BUF) void {
    const fences = count_fences(buf.data.?, buf.size);
    if (fences % 2 != 0) {
        if (buf.size > 0 and buf.data.?[buf.size - 1] != '\n')
            buf_append_ch(buf, '\n');
        buf_append(buf, "```", 3);
    }
}

// ***************************
// ***  Inline code heal   ***
// ***************************

fn heal_inline_code(buf: *HEAL_BUF) void {
    const fences = count_fences(buf.data.?, buf.size);
    if (fences % 2 != 0) return;

    const singles = count_single_backticks(buf.data.?, buf.size);
    if (singles % 2 != 0) {
        buf_append_ch(buf, '`');
    }
}

// ***************************
// ***  Emphasis healing   ***
// ***************************

fn count_double_asterisks(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] == '*' and i + 1 < size and text[i + 1] == '*') {
            count +%= 1;
            i +%= 1;
        }
    }
    return count;
}

fn count_double_underscores(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] == '_' and i + 1 < size and text[i + 1] == '_') {
            count +%= 1;
            i +%= 1;
        }
    }
    return count;
}

fn count_triple_asterisks(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var consecutive: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            if (consecutive >= 3) count +%= consecutive / 3;
            consecutive = 0;
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] == '*') {
            consecutive +%= 1;
        } else {
            if (consecutive >= 3) count +%= consecutive / 3;
            consecutive = 0;
        }
    }
    if (consecutive >= 3) count +%= consecutive / 3;
    return count;
}

fn count_single_asterisks(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] != '*') continue;

        const prev: u8 = if (i > 0) text[i - 1] else 0;
        const next: u8 = if (i + 1 < size) text[i + 1] else 0;

        if (prev == '\\') continue;
        if (in_math_block(text, size, i)) continue;

        if (prev != '*' and next == '*') {
            const next2: u8 = if (i + 2 < size) text[i + 2] else 0;
            if (next2 == '*') {
                count +%= 1;
                continue;
            }
            continue;
        }
        if (prev == '*') continue;

        if (is_word_char(prev) and is_word_char(next)) continue;

        {
            const prev_ws = (prev == 0 or prev == ' ' or prev == '\t' or prev == '\n');
            const next_ws = (next == 0 or next == ' ' or next == '\t' or next == '\n');
            if (prev_ws and next_ws) continue;
        }

        count +%= 1;
    }
    return count;
}

fn count_single_underscores(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] != '_') continue;

        const prev: u8 = if (i > 0) text[i - 1] else 0;
        const next: u8 = if (i + 1 < size) text[i + 1] else 0;

        if (prev == '\\') continue;
        if (in_math_block(text, size, i)) continue;
        if (in_link_url(text, i)) continue;
        if (in_html_tag(text, i)) continue;
        if (prev == '_' or next == '_') continue;
        if (is_word_char(prev) and is_word_char(next)) continue;

        count +%= 1;
    }
    return count;
}

fn count_double_tildes(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] == '~' and i + 1 < size and text[i + 1] == '~') {
            count +%= 1;
            i +%= 1;
        }
    }
    return count;
}

fn count_double_dollars(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] == '$' and i + 1 < size and text[i + 1] == '$') {
            count +%= 1;
            i +%= 1;
        }
    }
    return count;
}

fn has_meaningful_content(text: [*]const u8, start: u32, end: u32) bool {
    var i: u32 = start;
    while (i < end) : (i +%= 1) {
        const c = text[i];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and
            c != '*' and c != '_' and c != '~' and c != '`')
            return true;
    }
    return false;
}

fn match_bold_at_end(text: [*]const u8, size: u32) u32 {
    if (size < 3) return size;

    // for(i = size - 1; i >= 2; i--) { ...; if(i == 2) break; }
    var i: u32 = size - 1;
    while (i >= 2) {
        if (text[i - 1] == '*' and text[i - 2] == '*') {
            blk: {
                if (i >= 3 and text[i - 3] == '*') break :blk;
                if (text[i] == '*') break :blk;
                {
                    var j: u32 = i;
                    var has_double_star = false;
                    while (j + 1 < size) : (j +%= 1) {
                        if (text[j] == '*' and text[j + 1] == '*') {
                            has_double_star = true;
                            break;
                        }
                    }
                    if (!has_double_star) return i - 2;
                }
            }
        }
        if (i == 2) break;
        i -%= 1;
    }
    return size;
}

fn heal_bold(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    const marker_pos = match_bold_at_end(text, size);
    if (marker_pos >= size) return;

    if (in_complete_inline_code(text, size, marker_pos)) return;

    if (!has_meaningful_content(text, marker_pos + 2, size)) return;

    if (is_horizontal_rule(text, size, marker_pos, '*')) return;

    const pairs = count_double_asterisks(text, size);
    if (pairs % 2 != 0) {
        if (text[size - 1] == '*' and size > marker_pos + 3) {
            buf_append_ch(buf, '*');
        } else {
            buf_append(buf, "**", 2);
        }
    }
}

fn heal_italic_asterisk(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    const singles = count_single_asterisks(text, size);
    if (singles % 2 != 0) {
        buf_append_ch(buf, '*');
    }
}

fn heal_italic_double_underscore(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;
    var pairs: u32 = undefined;

    if (in_fenced_code_block(text, size, size)) return;

    if (size >= 4 and text[size - 1] == '_' and
        text[size - 2] != '_' and text[size - 2] != '\\')
    {
        pairs = count_double_underscores(text, size);
        if (pairs % 2 != 0) {
            buf_append_ch(buf, '_');
            return;
        }
    }

    pairs = count_double_underscores(text, size);
    if (pairs % 2 != 0) {
        buf_append(buf, "__", 2);
    }
}

fn heal_italic_underscore(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    const singles = count_single_underscores(text, size);
    if (singles % 2 != 0) {
        var end: u32 = size;
        while (end > 0 and buf.data.?[end - 1] == '\n') end -%= 1;

        if (end < size) {
            const tail_len: u32 = size - end;
            const tail = c_allocator.alloc(u8, tail_len) catch {
                buf.err = 1;
                return;
            };
            @memcpy(tail[0..tail_len], (buf.data.? + end)[0..tail_len]);
            buf.size = end;
            buf_append_ch(buf, '_');
            buf_append(buf, tail.ptr, tail_len);
            c_allocator.free(tail);
        } else {
            buf_append_ch(buf, '_');
        }
    }
}

fn heal_bold_italic(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    {
        var i: u32 = 0;
        var all_stars = true;
        while (i < size) : (i +%= 1) {
            if (text[i] != '*') {
                all_stars = false;
                break;
            }
        }
        if (all_stars) return;
    }

    const triples = count_triple_asterisks(text, size);
    if (triples % 2 != 0) {
        const doubles = count_double_asterisks(text, size);
        const singles = count_single_asterisks(text, size);
        if (doubles % 2 == 0 and singles % 2 == 0) return;
        buf_append(buf, "***", 3);
    }
}

// ***************************
// ***  Strikethrough heal ***
// ***************************

fn heal_strikethrough(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    if (size >= 4 and text[size - 1] == '~' and
        text[size - 2] != '~' and text[size - 2] != '\\')
    {
        var i: u32 = size - 2;
        while (i > 0) {
            if (text[i] == '~' and i > 0 and text[i - 1] == '~') {
                if (has_meaningful_content(text, i + 1, size - 1)) {
                    buf_append_ch(buf, '~');
                    return;
                }
            }
            i -%= 1;
        }
    }

    const pairs = count_double_tildes(text, size);
    if (pairs % 2 != 0) {
        // for(i = size; i >= 2; i--)
        var i: u32 = size;
        while (i >= 2) : (i -%= 1) {
            if (text[i - 2] == '~' and text[i - 1] == '~') {
                if (i < size and has_meaningful_content(text, i, size)) {
                    buf_append(buf, "~~", 2);
                    return;
                }
            }
        }
    }
}

// ***************************
// ***  KaTeX heal         ***
// ***************************

fn heal_katex(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    const pairs = count_double_dollars(text, size);
    if (pairs % 2 != 0) {
        var has_newline = false;
        // for(i = size; i >= 2; i--)
        var i: u32 = size;
        while (i >= 2) : (i -%= 1) {
            if (text[i - 2] == '$' and text[i - 1] == '$') {
                var j: u32 = i;
                while (j < size) : (j +%= 1) {
                    if (text[j] == '\n') {
                        has_newline = true;
                        break;
                    }
                }
                break;
            }
        }
        if (has_newline) {
            if (size > 0 and text[size - 1] != '\n')
                buf_append_ch(buf, '\n');
        }
        buf_append(buf, "$$", 2);
    }
}

// ***************************
// ***  Link/image heal    ***
// ***************************

fn find_matching_open_bracket(text: [*]const u8, close_idx: u32) c_int {
    var depth: c_int = 0;
    var i: c_int = @intCast(close_idx);
    while (i >= 0) : (i -= 1) {
        const u: u32 = @intCast(i);
        if (text[u] == ']') {
            depth += 1;
        } else if (text[u] == '[') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return -1;
}

fn heal_links_and_images(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    // Case 1: Incomplete URL — [text](url  (no closing paren)
    {
        var i: c_int = @as(c_int, @intCast(size)) - 1;
        while (i >= 1) : (i -= 1) {
            const u: u32 = @intCast(i);
            if (text[u] == '(' and text[u - 1] == ']') {
                var j: u32 = @intCast(i + 1);
                var has_close = false;
                while (j < size) : (j +%= 1) {
                    if (text[j] == ')') {
                        has_close = true;
                        break;
                    }
                    if (text[j] == '\n') break;
                }
                if (!has_close) {
                    const open = find_matching_open_bracket(text, @intCast(i - 1));
                    if (open >= 0) {
                        const open_u: u32 = @intCast(open);
                        const is_image = (open > 0 and text[open_u - 1] == '!');
                        if (is_image) {
                            const img_start: u32 = @intCast(open - 1);
                            buf.size = img_start;
                            while (buf.size > 0 and (buf.data.?[buf.size - 1] == ' ' or buf.data.?[buf.size - 1] == '\t'))
                                buf.size -%= 1;
                        } else {
                            buf.size = @intCast(i + 1);
                            buf_append(buf, ")", 1);
                        }
                        return;
                    }
                }
                break;
            }
        }
    }

    // Case 2: Incomplete text — [text  (no closing ])
    {
        var i: c_int = @as(c_int, @intCast(size)) - 1;
        while (i >= 0) : (i -= 1) {
            const u: u32 = @intCast(i);
            if (text[u] == '[' and !is_escaped(text, u)) {
                var j: u32 = @intCast(i + 1);
                var has_close = false;
                while (j < size) : (j +%= 1) {
                    if (text[j] == ']' and !is_escaped(text, j)) {
                        has_close = true;
                        break;
                    }
                }
                if (!has_close) {
                    const is_image = (i > 0 and text[u - 1] == '!');
                    if (is_image) {
                        buf.size = @intCast(i - 1);
                        while (buf.size > 0 and (buf.data.?[buf.size - 1] == ' ' or buf.data.?[buf.size - 1] == '\t'))
                            buf.size -%= 1;
                    } else {
                        const after: u32 = @intCast(i + 1);
                        // memmove(buf->data + i, buf->data + after, buf->size - after)
                        const n: u32 = buf.size - after;
                        std.mem.copyForwards(u8, buf.data.?[u .. u + n], buf.data.?[after .. after + n]);
                        buf.size -%= 1;
                    }
                    return;
                }
            }
        }
    }
}

// ***************************
// ***  HTML tag heal      ***
// ***************************

fn heal_html_tag(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    var i: c_int = @as(c_int, @intCast(size)) - 1;
    while (i >= 0) : (i -= 1) {
        const u: u32 = @intCast(i);
        if (text[u] == '>') return;
        if (text[u] == '\n') return;
        if (text[u] == '<') {
            if (@as(u32, @intCast(i + 1)) < size) {
                const next = text[u + 1];
                if ((next >= 'a' and next <= 'z') or
                    (next >= 'A' and next <= 'Z') or next == '/')
                {
                    if (!in_fenced_code_block(text, size, u)) {
                        buf.size = u;
                        while (buf.size > 0 and
                            (buf.data.?[buf.size - 1] == ' ' or buf.data.?[buf.size - 1] == '\t'))
                            buf.size -%= 1;
                    }
                }
            }
            return;
        }
    }
}

// ***************************
// ***  Comparison ops     ***
// ***************************

fn heal_comparison_operators(buf: *HEAL_BUF) void {
    var size = buf.size;
    var i: u32 = 0;

    while (i < size) {
        const ls = i;

        while (i < size and (buf.data.?[i] == ' ' or buf.data.?[i] == '\t')) i +%= 1;

        var is_list = false;
        if (i < size) {
            if (buf.data.?[i] == '-' or buf.data.?[i] == '*' or buf.data.?[i] == '+') {
                const after = i + 1;
                if (after < size and buf.data.?[after] == ' ') {
                    is_list = true;
                    i = after + 1;
                }
            } else if (buf.data.?[i] >= '0' and buf.data.?[i] <= '9') {
                var j = i;
                while (j < size and buf.data.?[j] >= '0' and buf.data.?[j] <= '9') j +%= 1;
                if (j < size and (buf.data.?[j] == '.' or buf.data.?[j] == ')')) {
                    j +%= 1;
                    if (j < size and buf.data.?[j] == ' ') {
                        is_list = true;
                        i = j + 1;
                    }
                }
            }
        }

        if (is_list and i < size and buf.data.?[i] == '>') {
            const gt_pos = i;
            i +%= 1;
            if (i < size and buf.data.?[i] == '=') {
                i +%= 1;
            }
            while (i < size and buf.data.?[i] == ' ') i +%= 1;
            if (i < size and buf.data.?[i] == '$') i +%= 1;
            if (i < size and buf.data.?[i] >= '0' and buf.data.?[i] <= '9') {
                if (!in_fenced_code_block(buf.data.?, size, gt_pos)) {
                    const old_size = buf.size;
                    buf_append_ch(buf, 0);
                    if (buf.size <= old_size)
                        return;
                    // memmove(buf->data + gt_pos + 1, buf->data + gt_pos, old_size - gt_pos)
                    const n: u32 = old_size - gt_pos;
                    std.mem.copyBackwards(u8, buf.data.?[gt_pos + 1 .. gt_pos + 1 + n], buf.data.?[gt_pos .. gt_pos + n]);
                    buf.data.?[gt_pos] = '\\';
                    size = buf.size;
                    i +%= 1;
                }
            }
        }

        while (i < size and buf.data.?[i] != '\n') i +%= 1;
        if (i < size) i +%= 1;

        _ = ls;
    }
}

// ***************************
// ***  Main heal function ***
// ***************************

pub fn md_heal(
    input: [*]const u8,
    input_size: c_uint,
    process_output: *const fn ([*]const u8, c_uint, ?*anyopaque) void,
    userdata: ?*anyopaque,
) c_int {
    var buf: HEAL_BUF = undefined;

    if (input_size == 0) {
        return 0;
    }

    buf_init(&buf, input_size +% 64);
    if (buf.data == null) return -1;

    buf_append(&buf, input, input_size);

    // Strip trailing single space (preserve double space for line break)
    if (buf.size > 0 and buf.data.?[buf.size - 1] == ' ') {
        if (buf.size < 2 or buf.data.?[buf.size - 2] != ' ')
            buf.size -%= 1;
    }

    heal_comparison_operators(&buf);
    heal_html_tag(&buf);
    heal_setext_heading(&buf);
    heal_links_and_images(&buf);
    heal_bold_italic(&buf);
    heal_bold(&buf);
    heal_italic_double_underscore(&buf);
    heal_italic_asterisk(&buf);
    heal_italic_underscore(&buf);
    heal_inline_code(&buf);
    heal_strikethrough(&buf);
    heal_katex(&buf);
    heal_code_block(&buf);

    if (buf.err != 0) {
        buf_free(&buf);
        return -1;
    }

    if (buf.size > 0)
        process_output(buf.data.?, buf.size, userdata);

    buf_free(&buf);
    return 0;
}
