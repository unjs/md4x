# Parser API (`src/abi.zig`)

> **There is no public C ABI.** MD4X is a Zig library; `src/abi.zig` is the single
> source of truth for the shared `MD_*` types, enums, flags, and `MD_PARSER`.
> The declarations below are a verbatim transcription of the former `md4x.h`
> (via `zig translate-c`), so field names, order, and layout are unchanged from
> the original C implementation — Phase 4c of `PLAN.md` idiomatizes them.

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

All are `extern struct` in `src/abi.zig` (field defaults omitted here for brevity).

```zig
pub const MD_BLOCK_UL_DETAIL = extern struct {
    is_tight: c_int,        // Non-zero if tight list, zero if loose
    mark: MD_CHAR,          // Bullet character: '-', '+', '*'
};

pub const MD_BLOCK_OL_DETAIL = extern struct {
    start: c_uint,          // Start index of ordered list
    is_tight: c_int,        // Non-zero if tight list, zero if loose
    mark_delimiter: MD_CHAR, // '.' or ')'
};

pub const MD_BLOCK_LI_DETAIL = extern struct {
    is_task: c_int,             // Non-zero only with MD_FLAG_TASKLISTS
    task_mark: MD_CHAR,         // 'x', 'X', or ' ' (if is_task)
    task_mark_offset: MD_OFFSET, // Offset of char between '[' and ']'
};

pub const MD_BLOCK_H_DETAIL = extern struct {
    level: c_uint,          // Header level (1-6)
};

pub const MD_BLOCK_CODE_DETAIL = extern struct {
    info: MD_ATTRIBUTE,     // Full info string
    lang: MD_ATTRIBUTE,     // First word of info string (language)
    fence_char: MD_CHAR,    // Fence character, or zero for indented code
    filename: MD_ATTRIBUTE, // `[filename]` from the info string
    meta: [*c]const MD_CHAR,   // Raw metadata remainder, or null
    meta_size: MD_SIZE,
    highlights: [*c]const c_uint, // Line numbers from `{1-3,5}`, or null
    highlight_count: c_uint,      // Length of `highlights` (no capacity field)
};

pub const MD_BLOCK_TABLE_DETAIL = extern struct {
    col_count: c_uint,      // Number of columns
    head_row_count: c_uint, // Header rows (currently always 1)
    body_row_count: c_uint, // Body rows
};

pub const MD_BLOCK_TD_DETAIL = extern struct {
    @"align": MD_ALIGN,     // MD_ALIGN_DEFAULT, _LEFT, _CENTER, or _RIGHT
};

pub const MD_SPAN_ATTRS_DETAIL = extern struct {
    raw_attrs: [*c]const MD_CHAR, // Raw attrs from trailing {...}, or null. Not NUL-terminated
    raw_attrs_size: MD_SIZE,
};

// Fields up to raw_attrs_size are layout-compatible with MD_SPAN_IMG_DETAIL.
pub const MD_SPAN_A_DETAIL = extern struct {
    href: MD_ATTRIBUTE,
    title: MD_ATTRIBUTE,
    raw_attrs: [*c]const MD_CHAR,
    raw_attrs_size: MD_SIZE,
    is_autolink: c_int,     // Non-zero if autolink
};

pub const MD_SPAN_IMG_DETAIL = extern struct {
    src: MD_ATTRIBUTE,
    title: MD_ATTRIBUTE,
    raw_attrs: [*c]const MD_CHAR,
    raw_attrs_size: MD_SIZE,
};

pub const MD_SPAN_SPAN_DETAIL = extern struct {
    raw_attrs: [*c]const MD_CHAR, // Raw attrs from {...}. Not NUL-terminated
    raw_attrs_size: MD_SIZE,
};

pub const MD_SPAN_WIKILINK_DETAIL = extern struct {
    target: MD_ATTRIBUTE,
};

pub const MD_SPAN_COMPONENT_DETAIL = extern struct {
    tag_name: MD_ATTRIBUTE,      // Component name (e.g. "badge", "icon-star")
    raw_props: [*c]const MD_CHAR, // Raw props from {...}, or null. Not NUL-terminated
    raw_props_size: MD_SIZE,
};

pub const MD_BLOCK_COMPONENT_DETAIL = extern struct {
    tag_name: MD_ATTRIBUTE,      // Component name (e.g. "alert", "card")
    raw_props: [*c]const MD_CHAR, // Raw props from {...}, or null
    raw_props_size: MD_SIZE,
    title: [*c]const MD_CHAR,    // Title after name (e.g. "STOP" in :::danger STOP), or null
    title_size: MD_SIZE,
};

pub const MD_BLOCK_TEMPLATE_DETAIL = extern struct {
    name: MD_ATTRIBUTE,     // Slot name (e.g. "header", "footer")
};

pub const MD_BLOCK_ALERT_DETAIL = extern struct {
    type_name: MD_ATTRIBUTE, // Alert type (e.g. "NOTE", "WARNING")
};
```

## `MD_ATTRIBUTE`

String attribute for non-text-flow content (titles, URLs, etc.) that may contain mixed substrings (normal text + entities):

```zig
pub const MD_ATTRIBUTE = extern struct {
    text: [*c]const MD_CHAR,
    size: MD_SIZE,
    substr_types: [*c]const MD_TEXTTYPE,   // Array of substring types
    substr_offsets: [*c]const MD_OFFSET,   // Array of substring offsets
};
```

Invariants: `substr_offsets[0] == 0`, `substr_offsets[LAST+1] == size`. Only `MD_TEXT_NORMAL`, `MD_TEXT_ENTITY`, and `MD_TEXT_NULLCHAR` substrings appear.

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
