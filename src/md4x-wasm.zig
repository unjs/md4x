// MD4X: Markdown parser for C
// (http://github.com/unjs/md4x)
//
// Copyright (c) 2026 Pooya Parsa <pooya@pi0.io>
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
// Zig port of src/md4x-wasm.c — byte-for-byte identical behavior.

const std = @import("std");

// The md4x ABI surface (MD_* types/flags, parser + renderer entry points,
// entity) now lives in the Zig-native abi module; libc comes from std.c.
const c = @import("abi");
// Parser + renderers live in this artifact's module graph (Phase 4a).
const lib = @import("lib.zig");

// We manage the result/output buffer memory with libc malloc/realloc/free so
// that the JS-side md4x_free(md4x_result_ptr()) (which frees the result buffer)
// is compatible. This mirrors the original C code exactly, including the
// realloc(NULL, n) / realloc(p, n) growth semantics.

// Stub main for wasi libc (we are a library, not a program)
export fn main() callconv(.c) c_int {
    return 0;
}

// Result storage (global — WASM is single-threaded)
var g_result_data: ?[*]u8 = null;
var g_result_size: c_uint = 0;

// Growable output buffer
const md4x_buf = struct {
    data: ?[*]u8,
    size: c_uint,
    cap: c_uint,
    err: c_int,
};

fn buf_append(text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) void {
    const buf: *md4x_buf = @ptrCast(@alignCast(userdata.?));
    if (buf.err != 0) return;
    if (buf.size + size > buf.cap) {
        const new_cap: c_uint = buf.cap + buf.cap / 2 + size + 256;
        const p: ?*anyopaque = std.c.realloc(buf.data, new_cap);
        if (p == null) {
            buf.err = 1;
            return;
        }
        buf.data = @ptrCast(p);
        buf.cap = new_cap;
    }
    if (size > 0) {
        @memcpy(buf.data.?[buf.size .. buf.size + size], @as([*]const u8, @ptrCast(text))[0..size]);
    }
    buf.size += size;
}

// --- Memory management exports ---

export fn md4x_alloc(size: c_uint) callconv(.c) ?*anyopaque {
    return std.c.malloc(size);
}

export fn md4x_free(ptr: ?*anyopaque) callconv(.c) void {
    std.c.free(ptr);
}

// --- Result accessors ---

export fn md4x_result_ptr() callconv(.c) c_uint {
    return @intCast(@intFromPtr(g_result_data));
}

export fn md4x_result_size() callconv(.c) c_uint {
    return g_result_size;
}

// --- Renderer wrappers ---

const md4x_render_fn = *const fn (
    [*c]const c.MD_CHAR,
    c.MD_SIZE,
    ?*const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) callconv(.c) void,
    ?*anyopaque,
    c_uint,
    c_uint,
) callconv(.c) c_int;

fn render(fn_ptr: md4x_render_fn, input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) c_int {
    var buf = md4x_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = fn_ptr(input, input_size, buf_append, &buf, c.MD_DIALECT_ALL, renderer_flags);
    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        g_result_data = null;
        g_result_size = 0;
        return -1;
    }
    // Caller (JS) frees previous g_result_data via md4x_free(md4x_result_ptr()).
    g_result_data = buf.data;
    g_result_size = buf.size;
    return 0;
}

export fn md4x_to_html(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_html, input, input_size, renderer_flags);
}

export fn md4x_to_html_meta(input: [*c]const u8, input_size: c_uint) callconv(.c) c_int {
    var buf = md4x_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = lib.md_html(input, input_size, buf_append, &buf, c.MD_DIALECT_ALL, c.MD_HTML_FLAG_CODE_META);
    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        g_result_data = null;
        g_result_size = 0;
        return -1;
    }
    g_result_data = buf.data;
    g_result_size = buf.size;
    return 0;
}

export fn md4x_to_ast(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_ast, input, input_size, renderer_flags);
}

export fn md4x_to_ansi(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_ansi, input, input_size, renderer_flags);
}

export fn md4x_to_ansi_meta(input: [*c]const u8, input_size: c_uint) callconv(.c) c_int {
    var buf = md4x_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = lib.md_ansi(input, input_size, buf_append, &buf, c.MD_DIALECT_ALL, c.MD_ANSI_FLAG_CODE_META);
    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        g_result_data = null;
        g_result_size = 0;
        return -1;
    }
    g_result_data = buf.data;
    g_result_size = buf.size;
    return 0;
}

export fn md4x_to_meta(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_meta, input, input_size, renderer_flags);
}

export fn md4x_to_text(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_text, input, input_size, renderer_flags);
}

export fn md4x_to_markdown(input: [*c]const u8, input_size: c_uint, renderer_flags: c_uint) callconv(.c) c_int {
    return render(lib.md_markdown, input, input_size, renderer_flags);
}

export fn md4x_heal(input: [*c]const u8, input_size: c_uint) callconv(.c) c_int {
    var buf = md4x_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = lib.md_heal(input, input_size, buf_append, &buf);
    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        g_result_data = null;
        g_result_size = 0;
        return -1;
    }
    // Caller (JS) frees previous g_result_data via md4x_free(md4x_result_ptr()).
    g_result_data = buf.data;
    g_result_size = buf.size;
    return 0;
}
