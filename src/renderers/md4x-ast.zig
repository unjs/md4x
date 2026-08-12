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
// Zig port of src/renderers/md4x-ast.c — byte-for-byte identical output.

const std = @import("std");

// MD_* types now come from the Zig-native
// abi module (replacing md4x.h / entity.h / md4x-heal.h); only genuinely
// external C headers stay in a @cImport, bound as `sys`.
const c = @import("abi");
// Sibling units are imported directly (one Zig module per artifact), not
// resolved through link-time C-ABI symbols. `abi` holds types only.
const md4x = @import("../md4x.zig");
const heal = @import("md4x-heal.zig");
const sys = @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("yaml.h");
});

const c_allocator = std.heap.c_allocator;

// Renderer flags (mirrors md4x-ast.h). Heal flag value is shared (0x0100).
const MD_AST_FLAG_DEBUG: c_uint = 0x0001;
const MD_AST_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_AST_FLAG_HEAL: c_uint = 0x0100;

const JSON_MAX_DEPTH: usize = 256;

const ProcessOutputFn = ?*const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void;

// ============================================================================
// Shared JSON writer + YAML-to-JSON helpers (md4x-json.zig) and component
// property parser (md4x-props.zig). These were previously reimplemented inline
// here; they now live in shared Zig modules and are imported. Local aliases
// preserve the original call-site names used throughout this file.
// ============================================================================

const json = @import("md4x-json.zig");
const props = @import("md4x-props.zig");

// ---- JSON writer (md4x-json.zig) ----
const JsonWriter = json.JsonWriter;
const jsonWrite = json.json_write;
const jsonWriteStr = json.json_write_str;
const jsonWriteStrZ = json.json_write_strz;
const jsonWriteEscaped = json.json_write_escaped;
const jsonWriteString = json.json_write_string;
const jsonWriteYamlProps = json.json_write_yaml_props;

// ---- Props parser (md4x-props.zig) ----
const ParsedProps = props.MD_PARSED_PROPS;
const mdParseProps = props.md_parse_props;

// *************************************
// ***  JSON AST node data structs   ***
// *************************************

const JsonNodeKind = enum(c_int) {
    document,
    element,
    text,
};

// Classifies the built-in tag for fast switch-based dispatch (replaces strcmp
// chains in jsonWriteProps / jsonSerializeNode / isLeafContainerTag). Set once
// at node creation. `dynamic` is for user components (tag_is_dynamic), `comment`
// for [null,{}] comment nodes, `other` for anything not needing special dispatch
// (em, strong, blockquote, headings, p, hr, ...).
const TagKind = enum {
    dynamic,
    comment,
    other,
    pre,
    a,
    img,
    wikilink,
    template,
    alert,
    ol,
    ul,
    li,
    th,
    td,
    code,
    math,
    math_display,
    html_block,
    frontmatter,
};

// Detail variants. The C version uses a union; since every dispatch checks the
// tag (and tag_is_dynamic first), a flat struct produces identical output while
// avoiding union type-confusion entirely. Dynamic components only ever touch the
// `component` fields, matching the C contract that they use detail.component
// exclusively.
const Detail = struct {
    // ol
    ol_is_tight: bool = false,
    ol_start: c_uint = 0,
    ol_delimiter: u8 = 0,
    // ul
    ul_is_tight: bool = false,
    // li
    li_is_task: bool = false,
    li_task_mark: u8 = 0,
    // code
    code_info: ?[*:0]u8 = null,
    code_lang: ?[*:0]u8 = null,
    code_fence_char: u8 = 0,
    code_filename: ?[*:0]u8 = null,
    code_meta: ?[*:0]u8 = null,
    code_highlights: ?[*]c_uint = null,
    code_highlight_count: c_uint = 0,
    // table
    table_col_count: c_uint = 0,
    // td
    td_align: c_int = 0,
    // a
    a_href: ?[*:0]u8 = null,
    a_title: ?[*:0]u8 = null,
    // img
    img_src: ?[*:0]u8 = null,
    img_title: ?[*:0]u8 = null,
    // wikilink
    wikilink_target: ?[*:0]u8 = null,
    // component
    component_raw_props: ?[*:0]u8 = null,
    component_raw_props_size: c.MD_SIZE = 0,
    component_title: ?[*:0]u8 = null,
    component_title_size: c.MD_SIZE = 0,
    // template
    tmpl_name: ?[*:0]u8 = null,
    // alert
    alert_type_name: ?[*:0]u8 = null,
};

const JsonNode = struct {
    kind: JsonNodeKind,
    tag: ?[*:0]const u8 = null,
    // Classification of the built-in tag for switch-based dispatch.
    tag_kind: TagKind = .other,

    first_child: ?*JsonNode = null,
    last_child: ?*JsonNode = null,
    next_sibling: ?*JsonNode = null,

    // Text value for text nodes, or literal content for leaf containers.
    text_value: ?[*:0]u8 = null,
    text_size: c.MD_SIZE = 0,

    detail: Detail = .{},

    // True if the tag is heap-allocated (dynamic component tag).
    tag_is_dynamic: bool = false,

    // Raw inline attributes string from trailing {attrs}, or NULL.
    raw_attrs: ?[*:0]u8 = null,
    raw_attrs_size: c.MD_SIZE = 0,
};

const JsonCtx = struct {
    // Arena owns the entire node tree and all node strings. The whole tree has a
    // single lifetime (built during parse, serialized once, freed all at once),
    // so an arena replaces the per-node malloc/free churn.
    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator = undefined,
    root: ?*JsonNode = null,
    current: ?*JsonNode = null,
    stack: [JSON_MAX_DEPTH]?*JsonNode = undefined,
    stack_depth: c_int = 0,
    image_nesting: c_int = 0,
    err: c_int = 0,
};

// The active arena allocator. The callbacks receive only a `*JsonCtx` userdata,
// and the helper functions (allocBytes, dupNts, jsonAttrToStr, jsonAppendText,
// the text-merge paths) do not get the ctx threaded through; rather than rewrite
// every signature, the current ctx's allocator is stashed here for the duration
// of a single (non-reentrant) md_parse run. md_ast is the only entry point and
// md_parse is synchronous, so this is safe.
threadlocal var g_alloc: std.mem.Allocator = undefined;

// *****************************
// ***  Memory management    ***
// *****************************

// Allocate a buffer of `n` bytes from the arena (no NUL slot added here; callers
// add one when they want C-string semantics). Returns null on failure.
fn allocBytes(n: usize) ?[*]u8 {
    if (n == 0) {
        // Match malloc(0) behavior loosely: return a 1-byte allocation. The
        // call sites that pass 0 always also write a NUL terminator at [0].
        const m = g_alloc.alloc(u8, 1) catch return null;
        return m.ptr;
    }
    const m = g_alloc.alloc(u8, n) catch return null;
    return m.ptr;
}

fn jsonNodeNew(tag: ?[*:0]const u8, kind: JsonNodeKind) ?*JsonNode {
    const node = g_alloc.create(JsonNode) catch return null;
    node.* = .{ .kind = kind, .tag = tag };
    return node;
}

// All node and string memory lives in the arena and is freed wholesale when the
// arena is deinitialized. Per-node freeing is therefore a no-op; the function is
// retained so existing call sites read clearly (and so partial nodes on the OOM
// path are simply abandoned to the arena).
fn jsonNodeFree(node_opt: ?*JsonNode) void {
    _ = node_opt;
}

// Convert an MD_ATTRIBUTE to an arena-allocated, NUL-terminated string. Returns
// null for an unset (empty) attribute OR on allocation failure — matching the C
// version, whose `text == NULL` test was equivalent: md_build_attribute only
// ever leaves `text` empty when the attribute is unset or was built from zero
// bytes, and never produces a non-empty pointer with a zero size.
fn jsonAttrToStr(attr: *const c.Attribute) ?[*:0]u8 {
    if (attr.text.len == 0)
        return null;

    const size = attr.text.len;
    const buf = allocBytes(size + 1) orelse return null;
    @memcpy(buf[0..size], attr.text);
    buf[size] = 0;
    return @ptrCast(buf);
}

// Duplicate `len` bytes from `src` into a NUL-terminated arena string.
fn dupNts(src: [*]const u8, len: usize) ?[*:0]u8 {
    const buf = allocBytes(len + 1) orelse return null;
    if (len > 0)
        @memcpy(buf[0..len], src[0..len]);
    buf[len] = 0;
    return @ptrCast(buf);
}

// ***********************************
// ***  AST tree building helpers  ***
// ***********************************

fn jsonAppendChild(ctx: *JsonCtx, child: *JsonNode) void {
    if (ctx.current == null) {
        ctx.err = 1;
        jsonNodeFree(child);
        return;
    }
    const cur = ctx.current.?;
    if (cur.first_child == null) {
        cur.first_child = child;
        cur.last_child = child;
    } else {
        cur.last_child.?.next_sibling = child;
        cur.last_child = child;
    }
}

fn jsonPush(ctx: *JsonCtx, node: *JsonNode) void {
    if (ctx.stack_depth >= @as(c_int, @intCast(JSON_MAX_DEPTH))) {
        ctx.err = 1;
        return;
    }
    ctx.stack[@intCast(ctx.stack_depth)] = ctx.current;
    ctx.stack_depth += 1;
    ctx.current = node;
}

fn jsonPop(ctx: *JsonCtx) void {
    if (ctx.stack_depth > 0) {
        ctx.stack_depth -= 1;
        ctx.current = ctx.stack[@intCast(ctx.stack_depth)];
    }
}

// Append text to a node's text_value buffer. Returns 0 on success, -1 on OOM.
fn jsonAppendText(node: *JsonNode, src: [*]const u8, src_size: c.MD_SIZE) c_int {
    if (node.text_value == null) {
        const buf = allocBytes(@as(usize, src_size) + 1) orelse return -1;
        if (src_size > 0)
            @memcpy(buf[0..src_size], src[0..src_size]);
        buf[src_size] = 0;
        node.text_value = @ptrCast(buf);
        node.text_size = src_size;
    } else {
        const old_size = node.text_size;
        const old = node.text_value.?;
        const old_slice = @as([*]u8, @ptrCast(old))[0 .. @as(usize, old_size) + 1];
        const merged = g_alloc.realloc(old_slice, @as(usize, old_size) + @as(usize, src_size) + 1) catch return -1;
        if (src_size > 0)
            @memcpy(merged[old_size .. old_size + src_size], src[0..src_size]);
        node.text_size = old_size + src_size;
        merged[node.text_size] = 0;
        node.text_value = @ptrCast(merged.ptr);
    }
    return 0;
}

// *************************************
// ***  HTML comment helpers          ***
// *************************************

// Check if a string is an HTML comment (<!-- ... -->), possibly with
// surrounding whitespace. On match, set body.* / body_size.* to the comment
// body (between <!-- and -->). Returns 1 on match, 0 otherwise.
fn jsonIsHtmlComment(text: [*]const u8, size: c.MD_SIZE, body: *[*]const u8, body_size: *c.MD_SIZE) c_int {
    var p: usize = 0;
    const end: usize = size;

    // Skip leading whitespace.
    while (p < end and (text[p] == ' ' or text[p] == '\t' or text[p] == '\n' or text[p] == '\r'))
        p += 1;

    // Must start with <!--
    if (end - p < 7) // at minimum <!-- -->
        return 0;
    if (text[p] != '<' or text[p + 1] != '!' or text[p + 2] != '-' or text[p + 3] != '-')
        return 0;

    // Find --> from the end, skipping trailing whitespace.
    var q: usize = end;
    while (q > p and (text[q - 1] == ' ' or text[q - 1] == '\t' or text[q - 1] == '\n' or text[q - 1] == '\r'))
        q -= 1;

    if (q - p < 7)
        return 0;
    if (text[q - 1] != '>' or text[q - 2] != '-' or text[q - 3] != '-')
        return 0;

    body.* = text + p + 4; // after <!--
    body_size.* = @intCast((q - 3) - (p + 4)); // before -->
    return 1;
}

// ***********************************
// ***  md_parse() callbacks       ***
// ***********************************

const heading_tags = [_][*:0]const u8{ "h0", "h1", "h2", "h3", "h4", "h5", "h6" };

fn jsonEnterBlock(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *JsonCtx = @ptrCast(@alignCast(userdata.?));
    const block_type = std.meta.activeTag(detail.*);
    var node: ?*JsonNode = null;
    var tag: ?[*:0]const u8 = null;

    switch (detail.*) {
        .doc => tag = null,
        .quote => tag = "blockquote",
        .ul => tag = "ul",
        .ol => tag = "ol",
        .li => tag = "li",
        .hr => tag = "hr",
        .h => |*d| {
            tag = if (d.level >= 1 and d.level <= 6) heading_tags[d.level] else "h1";
        },
        .code => tag = "pre",
        .html => tag = "html_block",
        .p => tag = "p",
        .table => tag = "table",
        .thead => tag = "thead",
        .tbody => tag = "tbody",
        .tr => tag = "tr",
        .th => tag = "th",
        .td => tag = "td",
        .frontmatter => tag = "frontmatter",
        .component => tag = null, // handled below
        .template => tag = null, // handled below
        .alert => tag = "alert",
    }

    // Dispatch on the detail union, so a dynamic component whose name
    // collides with a built-in tag still takes the component path (see the
    // tag_is_dynamic-first rule in AGENTS.md).
    switch (detail.*) {
        .doc => node = jsonNodeNew(null, .document),
        .alert => |*d| {
            node = jsonNodeNew("alert", .element);
            if (node == null) {
                ctx.err = 1;
                return -1;
            }
            node.?.detail.alert_type_name = jsonAttrToStr(&d.type_name);
        },
        .component => |*d| {
            tag = jsonAttrToStr(&d.tag_name);
            if (tag == null) {
                ctx.err = 1;
                return -1;
            }
            node = jsonNodeNew(tag, .element);
            if (node == null) {
                ctx.err = 1;
                return -1;
            }
            node.?.tag_is_dynamic = true;
            if (d.raw_props.len > 0) {
                const dup = dupNts(d.raw_props.ptr, d.raw_props.len);
                if (dup == null) {
                    ctx.err = 1;
                    return -1;
                }
                node.?.detail.component_raw_props = dup;
                node.?.detail.component_raw_props_size = @intCast(d.raw_props.len);
            }
            if (d.title.len > 0) {
                const dup = dupNts(d.title.ptr, d.title.len);
                if (dup == null) {
                    jsonNodeFree(node);
                    ctx.err = 1;
                    return -1;
                }
                node.?.detail.component_title = dup;
                node.?.detail.component_title_size = @intCast(d.title.len);
            }
        },
        .template => |*d| {
            const name_str = jsonAttrToStr(&d.name);
            node = jsonNodeNew("template", .element);
            if (node == null) {
                ctx.err = 1;
                return -1;
            }
            node.?.detail.tmpl_name = name_str;
        },
        else => node = jsonNodeNew(tag, .element),
    }
    if (node == null) {
        ctx.err = 1;
        return -1;
    }
    const n = node.?;

    // Classify the tag once for fast dispatch later (dynamic components win).
    if (n.tag_is_dynamic) {
        n.tag_kind = .dynamic;
    } else switch (block_type) {
        .ul => n.tag_kind = .ul,
        .ol => n.tag_kind = .ol,
        .li => n.tag_kind = .li,
        .h => n.tag_kind = .other,
        .code => n.tag_kind = .pre,
        .html => n.tag_kind = .html_block,
        .th => n.tag_kind = .th,
        .td => n.tag_kind = .td,
        .frontmatter => n.tag_kind = .frontmatter,
        .template => n.tag_kind = .template,
        .alert => n.tag_kind = .alert,
        else => n.tag_kind = .other,
    }

    // Copy type-specific detail data.
    switch (detail.*) {
        .ul => |*d| {
            n.detail.ul_is_tight = d.is_tight;
        },
        .ol => |*d| {
            n.detail.ol_is_tight = d.is_tight;
            n.detail.ol_start = d.start;
            n.detail.ol_delimiter = @bitCast(d.mark_delimiter);
        },
        .li => |*d| {
            n.detail.li_is_task = d.is_task;
            n.detail.li_task_mark = @bitCast(d.task_mark);
        },
        .code => |*d| {
            n.detail.code_info = jsonAttrToStr(&d.info);
            n.detail.code_lang = jsonAttrToStr(&d.lang);
            n.detail.code_fence_char = @bitCast(d.fence_char);
            n.detail.code_filename = jsonAttrToStr(&d.filename);
            if (d.meta.len > 0) {
                // Note: C ignores OOM here (best-effort) — match that.
                if (dupNts(d.meta.ptr, d.meta.len)) |dup|
                    n.detail.code_meta = dup;
            }
            if (d.highlights.len > 0) {
                const m = g_alloc.alloc(c_uint, d.highlights.len) catch null;
                if (m) |arr| {
                    @memcpy(arr, d.highlights);
                    n.detail.code_highlights = arr.ptr;
                    n.detail.code_highlight_count = @intCast(d.highlights.len);
                }
            }
        },
        .table => |*d| {
            n.detail.table_col_count = d.col_count;
        },
        .th, .td => |*d| {
            n.detail.td_align = @intCast(@intFromEnum(d.@"align"));
        },
        else => {},
    }

    if (ctx.current != null) {
        jsonAppendChild(ctx, n);
    } else if (ctx.root == null) {
        ctx.root = n;
    } else {
        // Unbalanced callbacks caused stack underflow — attach to root
        // to avoid leaking the subtree.
        ctx.current = ctx.root;
        jsonAppendChild(ctx, n);
    }

    jsonPush(ctx, n);
    return if (ctx.err != 0) -1 else 0;
}

fn jsonLeaveBlock(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *JsonCtx = @ptrCast(@alignCast(userdata.?));

    // Convert html_block comments to [null, {}, "body"] nodes.
    if (detail.* == .html and ctx.current != null and ctx.current.?.text_value != null) {
        const cur = ctx.current.?;
        var body: [*]const u8 = undefined;
        var body_size: c.MD_SIZE = undefined;
        if (jsonIsHtmlComment(@ptrCast(cur.text_value.?), cur.text_size, &body, &body_size) != 0) {
            // Replace tag with NULL (comment node).
            cur.tag = null;
            // Replace text_value with just the comment body. The old buffer is
            // abandoned to the arena (freed wholesale at deinit).
            if (dupNts(body, body_size)) |new_text| {
                cur.tag_kind = .comment;
                cur.text_value = new_text;
                cur.text_size = body_size;
            }
        }
    }

    jsonPop(ctx);
    return 0;
}

fn jsonEnterSpan(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *JsonCtx = @ptrCast(@alignCast(userdata.?));
    const span_type = std.meta.activeTag(detail.*);
    var node: ?*JsonNode = null;
    var tag: ?[*:0]const u8 = null;

    // Inside an image: suppress nested spans, just accumulate alt text.
    if (ctx.image_nesting > 0) {
        if (detail.* == .img)
            ctx.image_nesting += 1;
        return 0;
    }

    // The dynamic-component arm is resolved from the union tag *before* any
    // built-in tag handling (AGENTS.md's tag_is_dynamic-first rule), so a
    // component named e.g. "code" still takes the component path.
    if (detail.* == .component) {
        const d = &detail.component;
        tag = jsonAttrToStr(&d.tag_name);
        if (tag == null) {
            ctx.err = 1;
            return -1;
        }
        node = jsonNodeNew(tag, .element);
        if (node == null) {
            ctx.err = 1;
            return -1;
        }
        node.?.tag_is_dynamic = true;
        node.?.tag_kind = .dynamic;
        if (d.raw_props.len > 0) {
            const dup = dupNts(d.raw_props.ptr, d.raw_props.len);
            if (dup == null) {
                ctx.err = 1;
                return -1;
            }
            node.?.detail.component_raw_props = dup;
            node.?.detail.component_raw_props_size = @intCast(d.raw_props.len);
        }
    } else {
        switch (detail.*) {
            .em => tag = "em",
            .strong => tag = "strong",
            .a => tag = "a",
            .img => tag = "img",
            .code => tag = "code",
            .del => tag = "del",
            .latexmath => tag = "math",
            .latexmath_display => tag = "math-display",
            .wikilink => tag = "wikilink",
            .u => tag = "u",
            .span => tag = "span",
            // `.component` is resolved above; the arm only exists to keep the
            // switch exhaustive without an `unreachable` (AGENTS.md: prefer a
            // defensive guard, since `unreachable` is UB in ReleaseFast).
            .component => tag = "unknown",
        }

        node = jsonNodeNew(tag, .element);
        if (node == null) {
            ctx.err = 1;
            return -1;
        }
        const n = node.?;

        n.tag_kind = switch (span_type) {
            .a => .a,
            .img => .img,
            .code => .code,
            .latexmath => .math,
            .latexmath_display => .math_display,
            .wikilink => .wikilink,
            else => .other,
        };

        switch (detail.*) {
            .a => |*d| {
                n.detail.a_href = jsonAttrToStr(&d.href);
                n.detail.a_title = jsonAttrToStr(&d.title);
                if (d.raw_attrs.len > 0) {
                    if (dupNts(d.raw_attrs.ptr, d.raw_attrs.len)) |dup| {
                        n.raw_attrs = dup;
                        n.raw_attrs_size = @intCast(d.raw_attrs.len);
                    }
                }
            },
            .img => |*d| {
                n.detail.img_src = jsonAttrToStr(&d.src);
                n.detail.img_title = jsonAttrToStr(&d.title);
                if (d.raw_attrs.len > 0) {
                    if (dupNts(d.raw_attrs.ptr, d.raw_attrs.len)) |dup| {
                        n.raw_attrs = dup;
                        n.raw_attrs_size = @intCast(d.raw_attrs.len);
                    }
                }
                ctx.image_nesting = 1;
            },
            .wikilink => |*d| {
                n.detail.wikilink_target = jsonAttrToStr(&d.target);
            },
            .span => |*d| {
                if (d.raw_attrs.len > 0) {
                    if (dupNts(d.raw_attrs.ptr, d.raw_attrs.len)) |dup| {
                        n.raw_attrs = dup;
                        n.raw_attrs_size = @intCast(d.raw_attrs.len);
                    }
                }
            },
            .em, .strong, .code, .del, .u => |*d| {
                // These spans may carry trailing {attrs}; an empty raw_attrs
                // means there were none.
                if (d.raw_attrs.len > 0) {
                    if (dupNts(d.raw_attrs.ptr, d.raw_attrs.len)) |dup| {
                        n.raw_attrs = dup;
                        n.raw_attrs_size = @intCast(d.raw_attrs.len);
                    }
                }
            },
            .latexmath, .latexmath_display => {},
            .component => {}, // resolved above
        }
    }

    jsonAppendChild(ctx, node.?);
    jsonPush(ctx, node.?);
    return if (ctx.err != 0) -1 else 0;
}

fn jsonLeaveSpan(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *JsonCtx = @ptrCast(@alignCast(userdata.?));

    if (ctx.image_nesting > 0) {
        if (detail.* == .img)
            ctx.image_nesting -= 1;
        if (ctx.image_nesting > 0)
            return 0;
        // Leaving the outermost image span: text_value has the accumulated alt text.
    }

    jsonPop(ctx);
    return 0;
}

fn jsonText(text_type: c.TextType, text_slice: []const c.MD_CHAR, userdata: ?*anyopaque) c.CallbackResult {
    const ctx: *JsonCtx = @ptrCast(@alignCast(userdata.?));
    const text: [*]const u8 = text_slice.ptr;
    const size: c.MD_SIZE = @intCast(text_slice.len);
    var value: ?[*:0]u8 = null;
    var value_size: c.MD_SIZE = 0;

    // Guard against unbalanced callbacks causing NULL current.
    if (ctx.current == null) {
        if (ctx.root != null)
            ctx.current = ctx.root
        else
            return 0;
    }
    const cur = ctx.current.?;

    // Inside an image: accumulate text as alt attribute.
    if (ctx.image_nesting > 0) {
        if (text_type == c.TextType.softbr) {
            if (jsonAppendText(cur, " ", 1) != 0) {
                ctx.err = 1;
                return -1;
            }
        } else if (text_type == c.TextType.nullchar) {
            const buf = [_]u8{ 0xEF, 0xBF, 0xBD };
            if (jsonAppendText(cur, &buf, 3) != 0) {
                ctx.err = 1;
                return -1;
            }
        } else {
            if (jsonAppendText(cur, text, size) != 0) {
                ctx.err = 1;
                return -1;
            }
        }
        return 0;
    }

    // Leaf container nodes: accumulate text as literal on the parent node.
    // Dynamic components (tag_is_dynamic) must never match here, even if their
    // name collides with a built-in tag (e.g. ::pre, ::code).
    if (!cur.tag_is_dynamic and cur.tag != null and isLeafContainer(cur.tag_kind)) {
        var src: [*]const u8 = text;
        var src_size: c.MD_SIZE = size;
        const nullchar_buf = [_]u8{ 0xEF, 0xBF, 0xBD };

        if (text_type == c.TextType.nullchar) {
            src = &nullchar_buf;
            src_size = 3;
        }

        if (jsonAppendText(cur, src, src_size) != 0) {
            ctx.err = 1;
            return -1;
        }
        return 0;
    }

    switch (text_type) {
        .br => {
            // Linebreak → ["br", {}] element node.
            const node = jsonNodeNew("br", .element);
            if (node == null) {
                ctx.err = 1;
                return -1;
            }
            jsonAppendChild(ctx, node.?);
            return 0;
        },

        .softbr => {
            // Softbreak → "\n" text.
            const buf = allocBytes(2) orelse {
                ctx.err = 1;
                return -1;
            };
            buf[0] = '\n';
            buf[1] = 0;
            value = @ptrCast(buf);
            value_size = 1;
        },

        .nullchar => {
            const buf = allocBytes(4) orelse {
                ctx.err = 1;
                return -1;
            };
            // U+FFFD in UTF-8
            buf[0] = 0xEF;
            buf[1] = 0xBF;
            buf[2] = 0xBD;
            buf[3] = 0;
            value = @ptrCast(buf);
            value_size = 3;
        },

        .html => {
            // Inline HTML: check for comment <!-- ... -->
            var cbody: [*]const u8 = undefined;
            var cbody_size: c.MD_SIZE = undefined;
            if (jsonIsHtmlComment(text, size, &cbody, &cbody_size) != 0) {
                // Emit [null, {}, "comment body"] element.
                const cnode = jsonNodeNew(null, .element);
                if (cnode == null) {
                    ctx.err = 1;
                    return -1;
                }
                cnode.?.tag_kind = .comment;
                if (cbody_size > 0) {
                    const dup = dupNts(cbody, cbody_size);
                    if (dup == null) {
                        jsonNodeFree(cnode);
                        ctx.err = 1;
                        return -1;
                    }
                    cnode.?.text_value = dup;
                    cnode.?.text_size = cbody_size;
                }
                jsonAppendChild(ctx, cnode.?);
                return 0;
            }
            // Non-comment inline HTML: fall through to default text handling.
            const dup = dupNts(text, size) orelse {
                ctx.err = 1;
                return -1;
            };
            value = dup;
            value_size = size;
        },

        else => {
            // Normal text, entity, code, latexmath.
            const dup = dupNts(text, size) orelse {
                ctx.err = 1;
                return -1;
            };
            value = dup;
            value_size = size;
        },
    }

    // Merge consecutive text nodes.
    const prev_opt = cur.last_child;
    if (prev_opt != null and prev_opt.?.kind == .text and prev_opt.?.text_value != null and value != null) {
        const prev = prev_opt.?;
        const old_size = prev.text_size;
        const old_slice = @as([*]u8, @ptrCast(prev.text_value.?))[0 .. @as(usize, old_size) + 1];
        const merged = g_alloc.realloc(old_slice, @as(usize, old_size) + @as(usize, value_size) + 1) catch {
            ctx.err = 1;
            return -1;
        };
        if (value_size > 0)
            @memcpy(merged[old_size .. old_size + value_size], @as([*]const u8, @ptrCast(value.?))[0..value_size]);
        prev.text_size = old_size + value_size;
        merged[prev.text_size] = 0;
        prev.text_value = @ptrCast(merged.ptr);
        // `value` is abandoned to the arena.
        return 0;
    }

    const node = jsonNodeNew(null, .text);
    if (node == null) {
        // `value` is abandoned to the arena.
        ctx.err = 1;
        return -1;
    }
    node.?.text_value = value;
    node.?.text_size = value_size;

    jsonAppendChild(ctx, node.?);
    return 0;
}

fn isLeafContainer(kind: TagKind) bool {
    return switch (kind) {
        .pre, .html_block, .code, .frontmatter, .math, .math_display => true,
        else => false,
    };
}

fn jsonDebugLog(msg: []const u8, userdata: ?*anyopaque) void {
    _ = userdata;
    _ = sys.fprintf(sys.stderr, "MD4X: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
}

fn jsonAlignStr(align_v: c_int) ?[*:0]const u8 {
    return switch (align_v) {
        @intFromEnum(c.Align.left) => "left",
        @intFromEnum(c.Align.center) => "center",
        @intFromEnum(c.Align.right) => "right",
        else => null,
    };
}

// Write parsed component props from a raw props string.
// Uses the shared md_parse_props() parser from md4x-props.zig.
// Returns number of props written.
fn jsonWriteComponentProps(w: *JsonWriter, raw: [*]const u8, size: c.MD_SIZE) c_int {
    var parsed: ParsedProps = undefined;
    var n_written: c_int = 0;

    mdParseProps(raw, size, &parsed);

    // Write #id.
    if (parsed.id != null and parsed.id_size > 0) {
        if (n_written > 0) jsonWrite(w, ",", 1);
        jsonWriteStr(w, "\"id\":");
        jsonWriteString(w, parsed.id.?, parsed.id_size);
        n_written += 1;
    }

    // Write regular props.
    var i: c_int = 0;
    while (i < parsed.n_props) : (i += 1) {
        const p = &parsed.props[@intCast(i)];

        if (n_written > 0) jsonWrite(w, ",", 1);

        switch (p.type) {
            .string => {
                jsonWrite(w, "\"", 1);
                jsonWriteEscaped(w, p.key, p.key_size);
                jsonWriteStr(w, "\":");
                jsonWriteString(w, p.value.?, p.value_size);
                n_written += 1;
            },
            .boolean => {
                jsonWriteStr(w, "\":");
                jsonWriteEscaped(w, p.key, p.key_size);
                jsonWriteStr(w, "\":\"true\"");
                n_written += 1;
            },
            .bind => {
                jsonWrite(w, "\":", 2);
                jsonWriteEscaped(w, p.key, p.key_size);
                jsonWriteStr(w, "\":");
                jsonWrite(w, p.value.?, p.value_size);
                n_written += 1;
            },
        }
    }

    // Write merged class.
    if (parsed.class_len > 0) {
        if (n_written > 0) jsonWrite(w, ",", 1);
        jsonWriteStr(w, "\"class\":");
        jsonWriteString(w, &parsed.class_buf, parsed.class_len);
        n_written += 1;
    }

    return n_written;
}

fn strlenZ(s: [*:0]const u8) c.MD_SIZE {
    return @intCast(sys.strlen(@ptrCast(s)));
}

// Write the props object for an element node.
fn jsonWriteProps(w: *JsonWriter, node: *const JsonNode) void {
    var has_prop: c_int = 0;

    jsonWrite(w, "{", 1);

    // Dynamic components (tag_is_dynamic) use detail.component fields, so must
    // be checked first to avoid misinterpreting detail when a component name
    // collides with a static tag (e.g. ::alert{...}).
    if (node.tag_is_dynamic) {
        // Component frontmatter: if first child is a frontmatter node, merge its YAML as props.
        if (node.first_child != null and node.first_child.?.kind == .element and
            node.first_child.?.tag != null and !node.first_child.?.tag_is_dynamic and
            node.first_child.?.tag_kind == .frontmatter and
            node.first_child.?.text_value != null and node.first_child.?.text_size > 0)
        {
            has_prop = @intFromBool(jsonWriteYamlProps(w, @ptrCast(node.first_child.?.text_value.?), node.first_child.?.text_size) > 0);
        }
        // Component title (e.g. :::danger STOP → "title":"STOP").
        if (node.detail.component_title != null and node.detail.component_title_size > 0) {
            if (has_prop != 0) jsonWrite(w, ",", 1);
            jsonWriteStr(w, "\"title\":");
            jsonWriteString(w, @ptrCast(node.detail.component_title.?), node.detail.component_title_size);
            has_prop = 1;
        }
        // Component: parse raw props string.
        if (node.detail.component_raw_props != null and node.detail.component_raw_props_size > 0) {
            if (has_prop != 0) jsonWrite(w, ",", 1);
            const wrote = jsonWriteComponentProps(w, @ptrCast(node.detail.component_raw_props.?), node.detail.component_raw_props_size);
            has_prop = @intFromBool(wrote != 0 or has_prop != 0);
        }
    } else switch (node.tag_kind) {
        .ol => {
            if (node.detail.ol_start != 1) {
                var buf: [32]u8 = undefined;
                _ = sys.snprintf(&buf, buf.len, "\"start\":%u", node.detail.ol_start);
                jsonWriteStrZ(w, @ptrCast(&buf));
                has_prop = 1;
            }
        },
        .li => {
            if (node.detail.li_is_task) {
                jsonWriteStr(w, "\"task\":true,\"checked\":");
                jsonWriteStr(w, if (node.detail.li_task_mark == 'x' or node.detail.li_task_mark == 'X') "true" else "false");
                has_prop = 1;
            }
        },
        .pre => {
            if (node.detail.code_lang != null and node.detail.code_lang.?[0] != 0) {
                jsonWriteStr(w, "\"language\":");
                jsonWriteString(w, @ptrCast(node.detail.code_lang.?), strlenZ(node.detail.code_lang.?));
                has_prop = 1;
            }
            if (node.detail.code_filename != null and node.detail.code_filename.?[0] != 0) {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"filename\":");
                jsonWriteString(w, @ptrCast(node.detail.code_filename.?), strlenZ(node.detail.code_filename.?));
                has_prop = 1;
            }
            if (node.detail.code_highlights != null and node.detail.code_highlight_count > 0) {
                var buf: [16]u8 = undefined;
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"highlights\":[");
                var hi: c_uint = 0;
                while (hi < node.detail.code_highlight_count) : (hi += 1) {
                    if (hi > 0) jsonWrite(w, ",", 1);
                    _ = sys.snprintf(&buf, buf.len, "%u", node.detail.code_highlights.?[hi]);
                    jsonWriteStrZ(w, @ptrCast(&buf));
                }
                jsonWrite(w, "]", 1);
                has_prop = 1;
            }
            if (node.detail.code_meta != null and node.detail.code_meta.?[0] != 0) {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"meta\":");
                jsonWriteString(w, @ptrCast(node.detail.code_meta.?), strlenZ(node.detail.code_meta.?));
                has_prop = 1;
            }
        },
        .th, .td => {
            const align_str = jsonAlignStr(node.detail.td_align);
            if (align_str) |a| {
                jsonWriteStr(w, "\"align\":\"");
                jsonWriteStrZ(w, a);
                jsonWrite(w, "\"", 1);
                has_prop = 1;
            }
        },
        .a => {
            if (node.detail.a_href != null) {
                jsonWriteStr(w, "\"href\":");
                jsonWriteString(w, @ptrCast(node.detail.a_href.?), strlenZ(node.detail.a_href.?));
                has_prop = 1;
            }
            if (node.detail.a_title != null and node.detail.a_title.?[0] != 0) {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"title\":");
                jsonWriteString(w, @ptrCast(node.detail.a_title.?), strlenZ(node.detail.a_title.?));
                has_prop = 1;
            }
        },
        .img => {
            if (node.detail.img_src != null) {
                jsonWriteStr(w, "\"src\":");
                jsonWriteString(w, @ptrCast(node.detail.img_src.?), strlenZ(node.detail.img_src.?));
                has_prop = 1;
            }
            if (node.text_value != null) {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"alt\":");
                jsonWriteString(w, @ptrCast(node.text_value.?), node.text_size);
                has_prop = 1;
            }
            if (node.detail.img_title != null and node.detail.img_title.?[0] != 0) {
                if (has_prop != 0) jsonWrite(w, ",", 1);
                jsonWriteStr(w, "\"title\":");
                jsonWriteString(w, @ptrCast(node.detail.img_title.?), strlenZ(node.detail.img_title.?));
                has_prop = 1;
            }
        },
        .wikilink => {
            if (node.detail.wikilink_target != null) {
                jsonWriteStr(w, "\"target\":");
                jsonWriteString(w, @ptrCast(node.detail.wikilink_target.?), strlenZ(node.detail.wikilink_target.?));
                has_prop = 1;
            }
        },
        .template => {
            if (node.detail.tmpl_name != null) {
                jsonWriteStr(w, "\"name\":");
                jsonWriteString(w, @ptrCast(node.detail.tmpl_name.?), strlenZ(node.detail.tmpl_name.?));
                has_prop = 1;
            }
        },
        .alert => {
            if (node.detail.alert_type_name != null) {
                jsonWriteStr(w, "\"type\":");
                jsonWriteString(w, @ptrCast(node.detail.alert_type_name.?), strlenZ(node.detail.alert_type_name.?));
                has_prop = 1;
            }
        },
        .frontmatter => {
            if (node.text_value != null and node.text_size > 0) {
                has_prop = @intFromBool(jsonWriteYamlProps(w, @ptrCast(node.text_value.?), node.text_size) > 0);
            }
        },
        else => {},
    }

    // Merge inline attributes from trailing {attrs} syntax.
    if (node.raw_attrs != null and node.raw_attrs_size > 0) {
        // Pre-parse to check if there are any props to write.
        var check: ParsedProps = undefined;
        mdParseProps(@ptrCast(node.raw_attrs.?), node.raw_attrs_size, &check);
        if (check.n_props > 0 or check.id != null or check.class_len > 0) {
            if (has_prop != 0) jsonWrite(w, ",", 1);
            _ = jsonWriteComponentProps(w, @ptrCast(node.raw_attrs.?), node.raw_attrs_size);
            has_prop = 1;
        }
    }

    // (C had a `(void) has_prop;` here; has_prop is read above, so nothing to do.)
    jsonWrite(w, "}", 1);
}

fn jsonSerializeNode(w: *JsonWriter, node: *const JsonNode) void {
    switch (node.kind) {
        .document => {
            var fm_node: ?*const JsonNode = null;

            // Find frontmatter node (if any).
            var child = node.first_child;
            while (child) |ch| : (child = ch.next_sibling) {
                if (ch.kind == .element and ch.tag != null and
                    !ch.tag_is_dynamic and ch.tag_kind == .frontmatter)
                {
                    fm_node = ch;
                    break;
                }
            }

            // Emit nodes (excluding frontmatter).
            jsonWriteStr(w, "{\"nodes\":[");
            var first: c_int = 1;
            child = node.first_child;
            while (child) |ch| : (child = ch.next_sibling) {
                if (ch == fm_node) continue;
                if (first == 0) jsonWrite(w, ",", 1);
                jsonSerializeNode(w, ch);
                first = 0;
            }

            // Emit frontmatter field.
            jsonWriteStr(w, "],\"frontmatter\":{");
            if (fm_node != null and fm_node.?.text_value != null and fm_node.?.text_size > 0) {
                _ = jsonWriteYamlProps(w, @ptrCast(fm_node.?.text_value.?), fm_node.?.text_size);
            }

            jsonWriteStr(w, "},\"meta\":{}}");
        },

        .text => {
            jsonWriteString(w, @ptrCast(node.text_value.?), node.text_size);
        },

        .element => {
            // Comment nodes: [null, {}, "body"]
            if (node.tag == null) {
                jsonWriteStr(w, "[null,{}");
                if (node.text_value != null) {
                    jsonWrite(w, ",", 1);
                    jsonWriteString(w, @ptrCast(node.text_value.?), node.text_size);
                }
                jsonWrite(w, "]", 1);
                return;
            }

            jsonWriteStr(w, "[\"");
            jsonWriteStrZ(w, node.tag.?);
            jsonWriteStr(w, "\",");

            // Write props.
            jsonWriteProps(w, node);

            // Special handling for built-in tags.
            // Dynamic components always use the regular container path.
            if (!node.tag_is_dynamic and node.tag_kind == .pre) {
                jsonWriteStr(w, ",[\"code\",{");
                if (node.detail.code_lang != null and node.detail.code_lang.?[0] != 0) {
                    jsonWriteStr(w, "\"class\":\"language-");
                    jsonWriteEscaped(w, @ptrCast(node.detail.code_lang.?), strlenZ(node.detail.code_lang.?));
                    jsonWrite(w, "\"", 1);
                }
                jsonWriteStr(w, "},");
                if (node.text_value != null)
                    jsonWriteString(w, @ptrCast(node.text_value.?), node.text_size)
                else
                    jsonWriteStr(w, "\"\"");
                jsonWrite(w, "]", 1);
            }
            // html_block and frontmatter: emit literal as text child.
            else if (!node.tag_is_dynamic and node.text_value != null and
                (node.tag_kind == .html_block or node.tag_kind == .frontmatter))
            {
                jsonWrite(w, ",", 1);
                jsonWriteString(w, @ptrCast(node.text_value.?), node.text_size);
            }
            // Inline code, math, math-display: emit literal as text child.
            else if (!node.tag_is_dynamic and node.text_value != null and
                (node.tag_kind == .code or node.tag_kind == .math or node.tag_kind == .math_display))
            {
                jsonWrite(w, ",", 1);
                jsonWriteString(w, @ptrCast(node.text_value.?), node.text_size);
            }
            // img: void element, no children (alt is in props).
            else if (!node.tag_is_dynamic and node.tag_kind == .img) {
                // No children emitted.
            }
            // Regular container: emit children.
            else {
                // For dynamic components, skip frontmatter first child (merged into props).
                var skip_fm: ?*const JsonNode = null;
                if (node.tag_is_dynamic and node.first_child != null and
                    node.first_child.?.kind == .element and node.first_child.?.tag != null and
                    !node.first_child.?.tag_is_dynamic and node.first_child.?.tag_kind == .frontmatter)
                {
                    skip_fm = node.first_child;
                }
                var child = node.first_child;
                while (child) |ch| : (child = ch.next_sibling) {
                    if (ch == skip_fm) continue;
                    jsonWrite(w, ",", 1);
                    jsonSerializeNode(w, ch);
                }
            }

            jsonWrite(w, "]", 1);
        },
    }
}

// **************************************
// ***  Heal-before-render wrapper    ***
// **************************************

const MD4X_HEAL_BUF = struct {
    data: ?[*]u8,
    size: c_uint,
    cap: c_uint,
    err: c_int,
};

fn md4xHealBufAppend(text: [*c]const u8, size: c_uint, userdata: ?*anyopaque) void {
    const buf: *MD4X_HEAL_BUF = @ptrCast(@alignCast(userdata.?));
    if (buf.err != 0) return;
    if (buf.size + size > buf.cap) {
        const new_cap: c_uint = buf.cap + buf.cap / 2 + size + 256;
        if (buf.data) |old| {
            const p = c_allocator.realloc(old[0..buf.cap], new_cap) catch {
                buf.err = 1;
                return;
            };
            buf.data = p.ptr;
        } else {
            const p = c_allocator.alloc(u8, new_cap) catch {
                buf.err = 1;
                return;
            };
            buf.data = p.ptr;
        }
        buf.cap = new_cap;
    }
    @memcpy(buf.data.?[buf.size .. buf.size + size], @as([*]const u8, @ptrCast(text))[0..size]);
    buf.size += size;
}

fn md4xHealInput(input: [*c]const c.MD_CHAR, input_size: c.MD_SIZE, buf: *MD4X_HEAL_BUF) c_int {
    buf.data = null;
    buf.size = 0;
    buf.cap = 0;
    buf.err = 0;
    const ret = heal.md_heal(@ptrCast(input), input_size, md4xHealBufAppend, buf);
    if (buf.err != 0) return -1;
    return ret;
}

fn healBufFree(buf: *MD4X_HEAL_BUF) void {
    if (buf.data) |d| {
        c_allocator.free(d[0..buf.cap]);
    }
}

// **************************************
// ***  Public API                    ***
// **************************************

pub fn md_ast(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int {
    var input_ptr = input;
    var size = input_size;

    // Heal-before-render: run md_heal first, then render the healed output.
    if (renderer_flags & MD_AST_FLAG_HEAL != 0) {
        var hbuf: MD4X_HEAL_BUF = undefined;
        if (md4xHealInput(input, input_size, &hbuf) != 0) {
            healBufFree(&hbuf);
            return -1;
        }
        const ret = md_ast(@ptrCast(hbuf.data), hbuf.size, process_output, userdata, parser_flags, renderer_flags & ~MD_AST_FLAG_HEAL);
        healBufFree(&hbuf);
        return ret;
    }

    const parser: c.Parser = .{
        .flags = parser_flags,
        .enter_block = jsonEnterBlock,
        .leave_block = jsonLeaveBlock,
        .enter_span = jsonEnterSpan,
        .leave_span = jsonLeaveSpan,
        .text = jsonText,
        .debug_log = if (renderer_flags & MD_AST_FLAG_DEBUG != 0) jsonDebugLog else null,
    };

    var ctx: JsonCtx = .{ .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator) };
    defer ctx.arena.deinit();
    ctx.alloc = ctx.arena.allocator();
    g_alloc = ctx.alloc;

    // Skip UTF-8 BOM.
    if (@sizeOf(c.MD_CHAR) == 1) {
        if (renderer_flags & MD_AST_FLAG_SKIP_UTF8_BOM != 0) {
            if (size >= 3 and @as(u8, @bitCast(input_ptr[0])) == 0xEF and
                @as(u8, @bitCast(input_ptr[1])) == 0xBB and @as(u8, @bitCast(input_ptr[2])) == 0xBF)
            {
                input_ptr += 3;
                size -= 3;
            }
        }
    }

    const ret = md4x.md_parse(@ptrCast(input_ptr), size, &parser, @ptrCast(&ctx));

    if (ret != 0 or ctx.err != 0) {
        // Arena (via defer) frees the whole partial tree at once.
        return -1;
    }

    // Serialize the AST to JSON via the output callback.
    var writer: JsonWriter = undefined;
    writer.process_output = process_output;
    writer.userdata = userdata;
    if (ctx.root) |root| {
        jsonSerializeNode(&writer, root);
    }
    jsonWrite(&writer, "\n", 1);

    // Arena (via defer) frees the whole tree at once.
    return 0;
}
