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
// Zig port of src/md4x-napi.c — byte-for-byte identical behavior.

const std = @import("std");

const c = @cImport({
    @cInclude("node_api.h");
    @cInclude("md4x.h");
    @cInclude("md4x-html.h");
    @cInclude("md4x-ast.h");
    @cInclude("md4x-ansi.h");
    @cInclude("md4x-meta.h");
    @cInclude("md4x-text.h");
    @cInclude("md4x-markdown.h");
    @cInclude("md4x-heal.h");
});

// Growable output buffer
const napi_buf = struct {
    data: ?[*]u8,
    size: c_uint,
    cap: c_uint,
    err: c_int,
};

fn napi_buf_append(text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) void {
    const buf: *napi_buf = @ptrCast(@alignCast(userdata.?));
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

// Generic renderer wrapper
const md4x_render_fn = *const fn (
    [*c]const c.MD_CHAR,
    c.MD_SIZE,
    ?*const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) callconv(.c) void,
    ?*anyopaque,
    c_uint,
    c_uint,
) callconv(.c) c_int;

fn render_impl(env: c.napi_env, info: c.napi_callback_info, fn_ptr: md4x_render_fn) c.napi_value {
    var argc: usize = 2;
    var argv: [2]c.napi_value = undefined;
    var renderer_flags: c_uint = 0;
    _ = c.napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        _ = c.napi_throw_error(env, null, "Expected 1 argument");
        return null;
    }

    // Get input string length, then read
    var input_size: usize = undefined;
    _ = c.napi_get_value_string_utf8(env, argv[0], null, 0, &input_size);
    const input: ?[*]u8 = @ptrCast(std.c.malloc(input_size + 1));
    if (input == null) {
        _ = c.napi_throw_error(env, null, "Allocation failed");
        return null;
    }
    _ = c.napi_get_value_string_utf8(env, argv[0], @ptrCast(input), input_size + 1, &input_size);

    // Get optional renderer flags (second arg)
    if (argc >= 2) {
        var flags: u32 = undefined;
        if (c.napi_get_value_uint32(env, argv[1], &flags) == c.napi_ok) {
            renderer_flags = flags;
        }
    }

    // Render with all extensions enabled
    var buf = napi_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = fn_ptr(@ptrCast(input), @intCast(input_size), napi_buf_append, &buf, c.MD_DIALECT_ALL, renderer_flags);
    std.c.free(input);

    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        _ = c.napi_throw_error(env, null, "Markdown parsing failed");
        return null;
    }

    var result: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, if (buf.data) |d| @ptrCast(d) else "", buf.size, &result);
    std.c.free(buf.data);
    return result;
}

// --- Exported functions ---

fn md4x_napi_to_html(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 2;
    var argv: [2]c.napi_value = undefined;
    _ = c.napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        _ = c.napi_throw_error(env, null, "Expected 1 argument");
        return null;
    }

    // Get input string
    var input_size: usize = undefined;
    _ = c.napi_get_value_string_utf8(env, argv[0], null, 0, &input_size);
    const input: ?[*]u8 = @ptrCast(std.c.malloc(input_size + 1));
    if (input == null) {
        _ = c.napi_throw_error(env, null, "Allocation failed");
        return null;
    }
    _ = c.napi_get_value_string_utf8(env, argv[0], @ptrCast(input), input_size + 1, &input_size);

    // Get optional renderer flags (second arg)
    var renderer_flags: c_uint = 0;
    if (argc >= 2) {
        var flags: u32 = undefined;
        if (c.napi_get_value_uint32(env, argv[1], &flags) == c.napi_ok) {
            renderer_flags = flags;
        }
    }

    // Render
    var buf = napi_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = c.md_html(@ptrCast(input), @intCast(input_size), napi_buf_append, &buf, c.MD_DIALECT_ALL, renderer_flags);
    std.c.free(input);

    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        _ = c.napi_throw_error(env, null, "Markdown parsing failed");
        return null;
    }

    var result: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, if (buf.data) |d| @ptrCast(d) else "", buf.size, &result);
    std.c.free(buf.data);
    return result;
}

fn md4x_napi_to_html_meta(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    _ = c.napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        _ = c.napi_throw_error(env, null, "Expected 1 argument");
        return null;
    }

    var input_size: usize = undefined;
    _ = c.napi_get_value_string_utf8(env, argv[0], null, 0, &input_size);
    const input: ?[*]u8 = @ptrCast(std.c.malloc(input_size + 1));
    if (input == null) {
        _ = c.napi_throw_error(env, null, "Allocation failed");
        return null;
    }
    _ = c.napi_get_value_string_utf8(env, argv[0], @ptrCast(input), input_size + 1, &input_size);

    var buf = napi_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = c.md_html(@ptrCast(input), @intCast(input_size), napi_buf_append, &buf, c.MD_DIALECT_ALL, c.MD_HTML_FLAG_CODE_META);
    std.c.free(input);

    if (ret != 0) {
        std.c.free(buf.data);
        _ = c.napi_throw_error(env, null, "Markdown parsing failed");
        return null;
    }

    var result: c.napi_value = undefined;
    var result_data: ?*anyopaque = undefined;
    _ = c.napi_create_buffer_copy(env, buf.size, if (buf.data) |d| @ptrCast(d) else @ptrCast(@constCast("")), &result_data, &result);
    std.c.free(buf.data);
    return result;
}

fn md4x_napi_to_ast(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_impl(env, info, c.md_ast);
}

fn md4x_napi_to_ansi(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_impl(env, info, c.md_ansi);
}

fn md4x_napi_to_ansi_meta(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    _ = c.napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        _ = c.napi_throw_error(env, null, "Expected 1 argument");
        return null;
    }

    var input_size: usize = undefined;
    _ = c.napi_get_value_string_utf8(env, argv[0], null, 0, &input_size);
    const input: ?[*]u8 = @ptrCast(std.c.malloc(input_size + 1));
    if (input == null) {
        _ = c.napi_throw_error(env, null, "Allocation failed");
        return null;
    }
    _ = c.napi_get_value_string_utf8(env, argv[0], @ptrCast(input), input_size + 1, &input_size);

    var buf = napi_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = c.md_ansi(@ptrCast(input), @intCast(input_size), napi_buf_append, &buf, c.MD_DIALECT_ALL, c.MD_ANSI_FLAG_CODE_META);
    std.c.free(input);

    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        _ = c.napi_throw_error(env, null, "Markdown parsing failed");
        return null;
    }

    var result: c.napi_value = undefined;
    var result_data: ?*anyopaque = undefined;
    _ = c.napi_create_buffer_copy(env, buf.size, if (buf.data) |d| @ptrCast(d) else @ptrCast(@constCast("")), &result_data, &result);
    std.c.free(buf.data);
    return result;
}

fn md4x_napi_to_meta(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_impl(env, info, c.md_meta);
}

fn md4x_napi_to_text(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_impl(env, info, c.md_text);
}

fn md4x_napi_to_markdown(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    return render_impl(env, info, c.md_markdown);
}

fn md4x_napi_heal(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    _ = c.napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        _ = c.napi_throw_error(env, null, "Expected 1 argument");
        return null;
    }

    var input_size: usize = undefined;
    _ = c.napi_get_value_string_utf8(env, argv[0], null, 0, &input_size);
    const input: ?[*]u8 = @ptrCast(std.c.malloc(input_size + 1));
    if (input == null) {
        _ = c.napi_throw_error(env, null, "Allocation failed");
        return null;
    }
    _ = c.napi_get_value_string_utf8(env, argv[0], @ptrCast(input), input_size + 1, &input_size);

    var buf = napi_buf{ .data = null, .size = 0, .cap = 0, .err = 0 };
    const ret = c.md_heal(@ptrCast(input), @intCast(input_size), napi_buf_append, &buf);
    std.c.free(input);

    if (ret != 0 or buf.err != 0) {
        std.c.free(buf.data);
        _ = c.napi_throw_error(env, null, "Markdown heal failed");
        return null;
    }

    var result: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, if (buf.data) |d| @ptrCast(d) else "", buf.size, &result);
    std.c.free(buf.data);
    return result;
}

// --- Module initialization ---

fn descriptor(name: [*c]const u8, method: c.napi_callback) c.napi_property_descriptor {
    return .{
        .utf8name = name,
        .name = null,
        .method = method,
        .getter = null,
        .setter = null,
        .value = null,
        .attributes = c.napi_default,
        .data = null,
    };
}

fn init(env: c.napi_env, exports: c.napi_value) callconv(.c) c.napi_value {
    const props = [_]c.napi_property_descriptor{
        descriptor("renderToHtml", md4x_napi_to_html),
        descriptor("renderToHtmlMeta", md4x_napi_to_html_meta),
        descriptor("renderToAST", md4x_napi_to_ast),
        descriptor("renderToAnsi", md4x_napi_to_ansi),
        descriptor("renderToAnsiMeta", md4x_napi_to_ansi_meta),
        descriptor("renderToMeta", md4x_napi_to_meta),
        descriptor("renderToText", md4x_napi_to_text),
        descriptor("renderToMarkdown", md4x_napi_to_markdown),
        descriptor("heal", md4x_napi_heal),
    };
    _ = c.napi_define_properties(env, exports, props.len, &props);
    return exports;
}

// Symbol-based module registration (expansion of the NAPI_MODULE / NAPI_MODULE_INIT
// macros for a non-wasm target with NAPI_VERSION 8):
//   - node_api_module_get_api_version_v1 returns NAPI_VERSION
//   - napi_register_module_v1 invokes the init function

export fn node_api_module_get_api_version_v1() callconv(.c) i32 {
    return c.NAPI_VERSION;
}

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) callconv(.c) c.napi_value {
    return init(env, exports);
}
