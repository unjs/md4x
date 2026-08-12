# Parser API (`src/abi.zig`)

> **There is no public C ABI.** MD4X is a Zig library; `src/abi.zig` is the single
> source of truth for the shared `MD_*` types, enums, flags, and `MD_PARSER`.
> These declarations started as a verbatim `zig translate-c` transcription of the
> former `md4x.h`; Phase 4c of `PLAN.md` is idiomatizing them step by step:
>
> - **Detail types (`MD_ATTRIBUTE`, `MD_BLOCK_*_DETAIL`, `MD_SPAN_*_DETAIL`) are
>   now ordinary Zig structs** with compiler-chosen layout — slices instead of
>   pointer + `*_size`/`*_count` pairs, and `bool` instead of `c_int` for the
>   two-state members. An absent value is the **empty slice**; the parser never
>   distinguished null from empty.
> - **`MD_PARSER` and the type enums are still C-shaped** (`extern struct`,
>   `callconv(.c)` callbacks taking `?*anyopaque` details; `c_uint` enums) —
>   Phase 4c step 3 changes that.

Core function:

```zig
pub extern fn md_parse(
    text: [*c]const MD_CHAR,
    size: MD_SIZE,
    parser: [*c]const MD_PARSER,
    userdata: ?*anyopaque,
) c_int;
```

Returns `0` on success, `-1` on runtime error (e.g. memory failure), or the non-zero return value of any callback that aborted parsing.

`MD_CHAR` is `u8`; `MD_SIZE` and `MD_OFFSET` are `c_uint`. UTF-8 is the only supported encoding (the `MD4X_USE_ASCII` / `MD4X_USE_UTF16` build variants were dropped with the C sources).

The `MD_PARSER` struct holds callbacks and flags:

```zig
pub const MD_PARSER = extern struct {
    abi_version: c_uint = 0,   // Reserved, set to 0
    flags: c_uint = 0,         // Bitmask of MD_FLAG_xxxx values
    enter_block: ?*const fn (MD_BLOCKTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = null,
    leave_block: ?*const fn (MD_BLOCKTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = null,
    enter_span: ?*const fn (MD_SPANTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = null,
    leave_span: ?*const fn (MD_SPANTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = null,
    text: ?*const fn (MD_TEXTTYPE, [*c]const MD_CHAR, MD_SIZE, ?*anyopaque) callconv(.c) c_int = null,
    debug_log: ?*const fn ([*c]const u8, ?*anyopaque) callconv(.c) void = null,  // Optional
    syntax: ?*const fn () callconv(.c) void = null,   // Reserved, set to null
};
```

`MD_RENDERER` is a deprecated alias for `MD_PARSER`.

The `?*anyopaque` detail argument points at the matching `MD_*_DETAIL` struct for the block/span type (or is `null` where the table below says "—").

## Architecture

**SAX-like callback design** — No AST construction. Streaming for efficiency and low memory.

- Callbacks are invoked in nested order (block > span > text)
- Strings passed to callbacks are **not** null-terminated — always use the size parameter
- Any callback may abort parsing by returning non-zero

**Abort-code contract:** `md_parse` propagates a **negative** callback code verbatim, but returns `0` for a **positive** one (md4c parity). OOM and a callback returning `-1` are intentionally unified as `-1` in the emission path. This is pinned by the abort-matrix native test in `src/md4x.zig` (`zig build test`) — do not change it.

**Linear time guarantee** — Protections against pathological inputs:

- Code span mark limits (32 backticks max)
- Table column limits (128 max)
- Link reference definition abuse limits

**Callback sequence example** for `* foo **bar [link](http://example.com) baz**`:

```
enter_block(MD_BLOCK_DOC)
  enter_block(MD_BLOCK_UL)
    enter_block(MD_BLOCK_LI)
      text("foo ")
      enter_span(MD_SPAN_STRONG)
        text("bar ")
        enter_span(MD_SPAN_A)
          text("link")
        leave_span(MD_SPAN_A)
        text(" baz")
      leave_span(MD_SPAN_STRONG)
    leave_block(MD_BLOCK_LI)
  leave_block(MD_BLOCK_UL)
leave_block(MD_BLOCK_DOC)
```

## Encoding

MD4X assumes UTF-8. Unicode matters for: word boundary classification (emphasis), case-insensitive link reference matching (case-folding), entity translation (left to renderer). The tables live in the generated `src/unicode_tables.zig` (Unicode 15.1).

## Block Types (`MD_BLOCKTYPE`)

| Type                   | HTML            | Detail struct               |
| ---------------------- | --------------- | --------------------------- |
| `MD_BLOCK_DOC`         | `<body>`        | —                           |
| `MD_BLOCK_QUOTE`       | `<blockquote>`  | —                           |
| `MD_BLOCK_UL`          | `<ul>`          | `MD_BLOCK_UL_DETAIL`        |
| `MD_BLOCK_OL`          | `<ol>`          | `MD_BLOCK_OL_DETAIL`        |
| `MD_BLOCK_LI`          | `<li>`          | `MD_BLOCK_LI_DETAIL`        |
| `MD_BLOCK_HR`          | `<hr>`          | —                           |
| `MD_BLOCK_H`           | `<h1>`–`<h6>`   | `MD_BLOCK_H_DETAIL`         |
| `MD_BLOCK_CODE`        | `<pre><code>`   | `MD_BLOCK_CODE_DETAIL`      |
| `MD_BLOCK_HTML`        | _(raw HTML)_    | —                           |
| `MD_BLOCK_P`           | `<p>`           | —                           |
| `MD_BLOCK_TABLE`       | `<table>`       | `MD_BLOCK_TABLE_DETAIL`     |
| `MD_BLOCK_THEAD`       | `<thead>`       | —                           |
| `MD_BLOCK_TBODY`       | `<tbody>`       | —                           |
| `MD_BLOCK_TR`          | `<tr>`          | —                           |
| `MD_BLOCK_TH`          | `<th>`          | `MD_BLOCK_TD_DETAIL`        |
| `MD_BLOCK_TD`          | `<td>`          | `MD_BLOCK_TD_DETAIL`        |
| `MD_BLOCK_FRONTMATTER` | _(suppressed)_  | —                           |
| `MD_BLOCK_COMPONENT`   | _(dynamic tag)_ | `MD_BLOCK_COMPONENT_DETAIL` |
| `MD_BLOCK_TEMPLATE`    | `<template>`    | `MD_BLOCK_TEMPLATE_DETAIL`  |
| `MD_BLOCK_ALERT`       | `<blockquote>`  | `MD_BLOCK_ALERT_DETAIL`     |

## Span Types (`MD_SPANTYPE`)

| Type                        | HTML             | Detail struct                    |
| --------------------------- | ---------------- | -------------------------------- |
| `MD_SPAN_EM`                | `<em>`           | `MD_SPAN_ATTRS_DETAIL` or `null` |
| `MD_SPAN_STRONG`            | `<strong>`       | `MD_SPAN_ATTRS_DETAIL` or `null` |
| `MD_SPAN_A`                 | `<a>`            | `MD_SPAN_A_DETAIL`               |
| `MD_SPAN_IMG`               | `<img>`          | `MD_SPAN_IMG_DETAIL`             |
| `MD_SPAN_CODE`              | `<code>`         | `MD_SPAN_ATTRS_DETAIL` or `null` |
| `MD_SPAN_DEL`               | `<del>`          | `MD_SPAN_ATTRS_DETAIL` or `null` |
| `MD_SPAN_LATEXMATH`         | _(inline math)_  | —                                |
| `MD_SPAN_LATEXMATH_DISPLAY` | _(display math)_ | —                                |
| `MD_SPAN_WIKILINK`          | _(wiki link)_    | `MD_SPAN_WIKILINK_DETAIL`        |
| `MD_SPAN_U`                 | `<u>`            | `MD_SPAN_ATTRS_DETAIL` or `null` |
| `MD_SPAN_COMPONENT`         | _(dynamic tag)_  | `MD_SPAN_COMPONENT_DETAIL`       |
| `MD_SPAN_SPAN`              | `<span>`         | `MD_SPAN_SPAN_DETAIL`            |

## Text Types (`MD_TEXTTYPE`)

| Type                | Description                                                   |
| ------------------- | ------------------------------------------------------------- |
| `MD_TEXT_NORMAL`    | Normal text                                                   |
| `MD_TEXT_NULLCHAR`  | NULL character (replace with U+FFFD)                          |
| `MD_TEXT_BR`        | Hard line break (`<br>`)                                      |
| `MD_TEXT_SOFTBR`    | Soft line break                                               |
| `MD_TEXT_ENTITY`    | HTML entity (`&nbsp;`, `&#1234;`, `&#x12AB;`)                 |
| `MD_TEXT_CODE`      | Text inside code block/span (`\n` for newlines, no BR events) |
| `MD_TEXT_HTML`      | Raw HTML text (`\n` for newlines in block-level HTML)         |
| `MD_TEXT_LATEXMATH` | Text inside LaTeX equation (processed like code spans)        |

## Detail Structs

All are plain Zig `struct`s in `src/abi.zig` — compiler-chosen layout, every
field defaulted, so an unset detail is just `.{}`. Absent strings/arrays are the
**empty slice**, never a null pointer (field defaults omitted below for brevity).

```zig
pub const MD_BLOCK_UL_DETAIL = struct {
    is_tight: bool,         // True for a tight list, false for a loose one
    mark: MD_CHAR,          // Bullet character: '-', '+', '*'
};

pub const MD_BLOCK_OL_DETAIL = struct {
    start: c_uint,          // Start index of ordered list
    is_tight: bool,         // True for a tight list, false for a loose one
    mark_delimiter: MD_CHAR, // '.' or ')'
};

pub const MD_BLOCK_LI_DETAIL = struct {
    is_task: bool,              // Can be true only with MD_FLAG_TASKLISTS
    task_mark: MD_CHAR,         // 'x', 'X', or ' ' (if is_task)
    task_mark_offset: MD_OFFSET, // Offset of char between '[' and ']'
};

pub const MD_BLOCK_H_DETAIL = struct {
    level: c_uint,          // Header level (1-6)
};

pub const MD_BLOCK_CODE_DETAIL = struct {
    info: MD_ATTRIBUTE,     // Full info string
    lang: MD_ATTRIBUTE,     // First word of info string (language)
    fence_char: MD_CHAR,    // Fence character, or zero for indented code
    filename: MD_ATTRIBUTE, // `[filename]` from the info string
    meta: []const MD_CHAR,  // Raw metadata remainder; empty when absent.
                            // The backing buffer carries a NUL at meta.len
    highlights: []const c_uint, // Line numbers from `{1-3,5}`; empty when absent
};

pub const MD_BLOCK_TABLE_DETAIL = struct {
    col_count: c_uint,      // Number of columns
    head_row_count: c_uint, // Header rows (currently always 1)
    body_row_count: c_uint, // Body rows
};

pub const MD_BLOCK_TD_DETAIL = struct {
    @"align": MD_ALIGN,     // MD_ALIGN_DEFAULT, _LEFT, _CENTER, or _RIGHT
};

pub const MD_SPAN_ATTRS_DETAIL = struct {
    raw_attrs: []const MD_CHAR, // Raw attrs from trailing {...}. Not NUL-terminated
};

pub const MD_SPAN_A_DETAIL = struct {
    href: MD_ATTRIBUTE,
    title: MD_ATTRIBUTE,
    raw_attrs: []const MD_CHAR,
    is_autolink: bool,
};

pub const MD_SPAN_IMG_DETAIL = struct {
    src: MD_ATTRIBUTE,
    title: MD_ATTRIBUTE,
    raw_attrs: []const MD_CHAR,
};

pub const MD_SPAN_SPAN_DETAIL = struct {
    raw_attrs: []const MD_CHAR, // Raw attrs from {...}. Not NUL-terminated
};

pub const MD_SPAN_WIKILINK_DETAIL = struct {
    target: MD_ATTRIBUTE,
};

pub const MD_SPAN_COMPONENT_DETAIL = struct {
    tag_name: MD_ATTRIBUTE,     // Component name (e.g. "badge", "icon-star")
    raw_props: []const MD_CHAR, // Raw props from {...}. Not NUL-terminated
};

pub const MD_BLOCK_COMPONENT_DETAIL = struct {
    tag_name: MD_ATTRIBUTE,     // Component name (e.g. "alert", "card")
    raw_props: []const MD_CHAR, // Raw props from {...}
    title: []const MD_CHAR,     // Title after name (e.g. "STOP" in :::danger STOP)
};

pub const MD_BLOCK_TEMPLATE_DETAIL = struct {
    name: MD_ATTRIBUTE,     // Slot name (e.g. "header", "footer")
};

pub const MD_BLOCK_ALERT_DETAIL = struct {
    type_name: MD_ATTRIBUTE, // Alert type (e.g. "NOTE", "WARNING")
};
```

`MD_SPAN_A_DETAIL` and `MD_SPAN_IMG_DETAIL` are **no longer layout-compatible**
(they are auto-layout structs now); nothing relied on that, and each `@ptrCast`
site already dispatches on the span type.

## `MD_ATTRIBUTE`

String attribute for non-text-flow content (titles, URLs, etc.) that may contain mixed substrings (normal text + entities):

```zig
pub const MD_ATTRIBUTE = struct {
    text: []const MD_CHAR = &.{},
    substr_types: []const MD_TEXTTYPE = &.{},   // One entry per substring
    substr_offsets: []const MD_OFFSET = &.{},   // substr_types.len + 1 entries

    /// text.len as the MD_SIZE the offset tables are expressed in.
    pub fn size(self: MD_ATTRIBUTE) MD_SIZE { ... }
};
```

Invariants: `substr_offsets.len == substr_types.len + 1`, `substr_offsets[0] == 0`,
`substr_offsets[substr_types.len] == size()`. Only `MD_TEXT_NORMAL`,
`MD_TEXT_ENTITY`, and `MD_TEXT_NULLCHAR` substrings appear.

An **unset** attribute is the default value — empty `text` with both tables empty
(the only case where the `len + 1` invariant does not hold, since there is no
substring table at all). It replaces the old `text == NULL` test: the builder
never produces a non-empty `text` with a zero size, so "empty" and "absent" were
already the same thing. Walk the substrings with a bounded loop:

```zig
const total = attr.size();
var i: usize = 0;
while (i < attr.substr_types.len and attr.substr_offsets[i] < total) : (i += 1) {
    const ttype = attr.substr_types[i];
    const part  = attr.text[attr.substr_offsets[i]..attr.substr_offsets[i + 1]];
    // ...
}
```

## Parser Flags

| Flag                               | Value     | Description                                                                       |
| ---------------------------------- | --------- | --------------------------------------------------------------------------------- |
| `MD_FLAG_COLLAPSEWHITESPACE`       | `0x0001`  | Collapse non-trivial whitespace to single space                                   |
| `MD_FLAG_PERMISSIVEATXHEADERS`     | `0x0002`  | Allow ATX headers without space (`###header`)                                     |
| `MD_FLAG_PERMISSIVEURLAUTOLINKS`   | `0x0004`  | Recognize URLs as autolinks without `<>`                                          |
| `MD_FLAG_PERMISSIVEEMAILAUTOLINKS` | `0x0008`  | Recognize emails as autolinks without `<>` and `mailto:`                          |
| `MD_FLAG_NOINDENTEDCODEBLOCKS`     | `0x0010`  | Disable indented code blocks (fenced only)                                        |
| `MD_FLAG_NOHTMLBLOCKS`             | `0x0020`  | Disable raw HTML blocks                                                           |
| `MD_FLAG_NOHTMLSPANS`              | `0x0040`  | Disable inline raw HTML                                                           |
| `MD_FLAG_TABLES`                   | `0x0100`  | Enable tables extension                                                           |
| `MD_FLAG_STRIKETHROUGH`            | `0x0200`  | Enable strikethrough extension                                                    |
| `MD_FLAG_PERMISSIVEWWWAUTOLINKS`   | `0x0400`  | Enable `www.` autolinks                                                           |
| `MD_FLAG_TASKLISTS`                | `0x0800`  | Enable task list extension                                                        |
| `MD_FLAG_LATEXMATHSPANS`           | `0x1000`  | Enable `$` / `$$` LaTeX math                                                      |
| `MD_FLAG_WIKILINKS`                | `0x2000`  | Enable `[[wiki links]]`                                                           |
| `MD_FLAG_UNDERLINE`                | `0x4000`  | Enable underline (disables `_` emphasis)                                          |
| `MD_FLAG_HARD_SOFT_BREAKS`         | `0x8000`  | Force all soft breaks to act as hard breaks                                       |
| `MD_FLAG_FRONTMATTER`              | `0x10000` | Enable frontmatter extension                                                      |
| `MD_FLAG_COMPONENTS`               | `0x20000` | Enable components (inline `:name[content]{props}` and block `::name{props}...::`) |
| `MD_FLAG_ATTRIBUTES`               | `0x40000` | Enable `{...}` attributes on inline elements and `[text]{.class}` spans           |
| `MD_FLAG_ALERTS`                   | `0x80000` | Enable `> [!TYPE]` alert/admonition syntax                                        |

**Compound flags:**

- `MD_FLAG_PERMISSIVEAUTOLINKS` = email + URL + WWW autolinks
- `MD_FLAG_NOHTML` = no HTML blocks + no HTML spans
- `MD_DIALECT_COMMONMARK` = `0` (strict CommonMark)
- `MD_DIALECT_GITHUB` = permissive autolinks + tables + strikethrough + task lists + alerts
- `MD_DIALECT_ALL` = all additive extensions (autolinks + tables + strikethrough + tasklists + latex math + wikilinks + underline + frontmatter + components + attributes + alerts)
