# Parser API (`src/abi.zig`)

> **There is no public C ABI.** MD4X is a Zig library; `src/abi.zig` is the single
> source of truth for the shared parser types, enums, flags, and the `Parser`
> callback table. These declarations started as a verbatim `zig translate-c`
> transcription of the former `md4x.h`; Phase 4c of `PLAN.md` idiomatized them:
>
> - **Detail types (`Attribute`, `Block*Detail`, `Span*Detail`) are ordinary Zig
>   structs** with compiler-chosen layout — slices instead of pointer +
>   `*_size`/`*_count` pairs, and `bool` instead of `c_int` for the two-state
>   members. An absent value is the **empty slice**; the parser never
>   distinguished null from empty.
> - **The type codes are real Zig enums** — `BlockType`, `SpanType`, `TextType`,
>   `Align` — and the details reach callbacks only through the tagged unions
>   `BlockDetail` / `SpanDetail`, so a renderer resolves them with an exhaustive
>   `switch` rather than an unchecked `@ptrCast` of a `?*anyopaque`. The enums
>   keep the numeric values and declaration order of the C enumerations they
>   replace.
> - **`MD_PARSER` is gone**, replaced by the plain Zig `Parser` struct: no
>   `extern`, no `callconv(.c)`, and no `abi_version` / `syntax` field or
>   `MD_RENDERER` alias (all three were dropped-C-ABI vestiges).

Core function:

```zig
pub fn md_parse(
    text: [*c]const MD_CHAR,
    size: MD_SIZE,
    parser: *const Parser,
    userdata: ?*anyopaque,
) c_int;
```

Returns `0` on success, `-1` on runtime error (e.g. memory failure), or the non-zero return value of any callback that aborted parsing.

`MD_CHAR` is `u8`; `MD_SIZE` and `MD_OFFSET` are `c_uint`. UTF-8 is the only supported encoding (the `MD4X_USE_ASCII` / `MD4X_USE_UTF16` build variants were dropped with the C sources).

The `Parser` struct holds callbacks and flags:

```zig
/// 0 continues the parse; non-zero aborts the enclosing emitter.
pub const CallbackResult = i32;

pub const Parser = struct {
    flags: c_uint = 0,         // Bitmask of MD_FLAG_xxxx values
    enter_block: ?*const fn (*const BlockDetail, ?*anyopaque) CallbackResult = null,
    leave_block: ?*const fn (*const BlockDetail, ?*anyopaque) CallbackResult = null,
    enter_span: ?*const fn (*const SpanDetail, ?*anyopaque) CallbackResult = null,
    leave_span: ?*const fn (*const SpanDetail, ?*anyopaque) CallbackResult = null,
    text: ?*const fn (TextType, []const MD_CHAR, ?*anyopaque) CallbackResult = null,
    debug_log: ?*const fn ([]const u8, ?*anyopaque) void = null,  // Optional
};
```

The detail arrives as a **const pointer to the tagged union** (the unions are
large and this is a hot path). There is no separate type parameter — the block
or span type _is_ the union's active tag, so a callback recovers it with
`switch (detail.*)` or `std.meta.activeTag(detail.*)`. `userdata` stays
`?*anyopaque`: it is a genuine type-erased user pointer.

```zig
pub const BlockDetail = union(BlockType) {
    doc: void,   quote: void,             ul: BlockUlDetail,        ol: BlockOlDetail,
    li: BlockLiDetail,                    hr: void,                 h: BlockHDetail,
    code: BlockCodeDetail,                html: void,               p: void,
    table: BlockTableDetail,              thead: void,              tbody: void,
    tr: void,    th: BlockTdDetail,       td: BlockTdDetail,        frontmatter: void,
    component: BlockComponentDetail,      template: BlockTemplateDetail,
    alert: BlockAlertDetail,
};

pub const SpanDetail = union(SpanType) {
    em: SpanAttrsDetail,     strong: SpanAttrsDetail, a: SpanADetail,   img: SpanImgDetail,
    code: SpanAttrsDetail,   del: SpanAttrsDetail,    latexmath: void,
    latexmath_display: void, wikilink: SpanWikilinkDetail,             u: SpanAttrsDetail,
    component: SpanComponentDetail,                    span: SpanSpanDetail,
};
```

`BlockDetail.default(ty)` returns the all-defaults value of the arm named by a
runtime `BlockType` — the emission path uses it to materialize a detail before
filling in the fields the type actually carries.

## Architecture

**SAX-like callback design** — No AST construction. Streaming for efficiency and low memory.

- Callbacks are invoked in nested order (block > span > text)
- Strings passed to callbacks are **not** null-terminated — always use the size parameter
- Any callback may abort parsing by returning non-zero

**Abort-code contract:** `md_parse` propagates a **negative** callback code verbatim, but returns `0` for a **positive** one (md4c parity). OOM and a callback returning `-1` are intentionally unified as `-1` in the emission path. This is pinned by the abort-matrix native test in `src/md4x.zig` (`zig build test`) — do not change it.

That contract is why `CallbackResult` is a plain `i32` rather than a Zig error
union (PLAN.md's deferred §8.2): the code has to carry an arbitrary
caller-chosen integer through unchanged, and OOM must stay indistinguishable
from a callback's `-1`.

**Linear time guarantee** — Protections against pathological inputs:

- Code span mark limits (32 backticks max)
- Table column limits (128 max)
- Link reference definition abuse limits
- Inline `{...}` attributes: the document's `{`…`}` pairing is computed once per
  parse (one linear pass, lazily on the first candidate) and then queried by
  binary search, so a candidate never re-scans the document — unbalanced or
  deeply nested braces stay linear

**Callback sequence example** for `* foo **bar [link](http://example.com) baz**`:

```
enter_block(.doc)
  enter_block(.ul)
    enter_block(.li)
      text("foo ")
      enter_span(.strong)
        text("bar ")
        enter_span(.a)
          text("link")
        leave_span(.a)
        text(" baz")
      leave_span(.strong)
    leave_block(.li)
  leave_block(.ul)
leave_block(.doc)
```

## Encoding

MD4X assumes UTF-8. Unicode matters for: word boundary classification (emphasis), case-insensitive link reference matching (case-folding), entity translation (left to renderer). The tables live in the generated `src/unicode_tables.zig` (Unicode 15.1).

## Block Types (`BlockType` / `BlockDetail`)

| Type           | HTML            | Union payload          |
| -------------- | --------------- | ---------------------- |
| `.doc`         | `<body>`        | `void`                 |
| `.quote`       | `<blockquote>`  | `void`                 |
| `.ul`          | `<ul>`          | `BlockUlDetail`        |
| `.ol`          | `<ol>`          | `BlockOlDetail`        |
| `.li`          | `<li>`          | `BlockLiDetail`        |
| `.hr`          | `<hr>`          | `void`                 |
| `.h`           | `<h1>`–`<h6>`   | `BlockHDetail`         |
| `.code`        | `<pre><code>`   | `BlockCodeDetail`      |
| `.html`        | _(raw HTML)_    | `void`                 |
| `.p`           | `<p>`           | `void`                 |
| `.table`       | `<table>`       | `BlockTableDetail`     |
| `.thead`       | `<thead>`       | `void`                 |
| `.tbody`       | `<tbody>`       | `void`                 |
| `.tr`          | `<tr>`          | `void`                 |
| `.th`          | `<th>`          | `BlockTdDetail`        |
| `.td`          | `<td>`          | `BlockTdDetail`        |
| `.frontmatter` | _(suppressed)_  | `void`                 |
| `.component`   | _(dynamic tag)_ | `BlockComponentDetail` |
| `.template`    | `<template>`    | `BlockTemplateDetail`  |
| `.alert`       | `<blockquote>`  | `BlockAlertDetail`     |

## Span Types (`SpanType` / `SpanDetail`)

| Type                 | HTML             | Union payload         |
| -------------------- | ---------------- | --------------------- |
| `.em`                | `<em>`           | `SpanAttrsDetail`     |
| `.strong`            | `<strong>`       | `SpanAttrsDetail`     |
| `.a`                 | `<a>`            | `SpanADetail`         |
| `.img`               | `<img>`          | `SpanImgDetail`       |
| `.code`              | `<code>`         | `SpanAttrsDetail`     |
| `.del`               | `<del>`          | `SpanAttrsDetail`     |
| `.latexmath`         | _(inline math)_  | `void`                |
| `.latexmath_display` | _(display math)_ | `void`                |
| `.wikilink`          | _(wiki link)_    | `SpanWikilinkDetail`  |
| `.u`                 | `<u>`            | `SpanAttrsDetail`     |
| `.component`         | _(dynamic tag)_  | `SpanComponentDetail` |
| `.span`              | `<span>`         | `SpanSpanDetail`      |

The five `SpanAttrsDetail` spans used to receive _either_ a detail or a `null`
pointer, depending on whether a trailing `{...}` was present. That distinction
is gone: they always carry a `SpanAttrsDetail`, and an **empty** `raw_attrs`
means "no attributes". No consumer ever told the two apart (every guard was
`detail != null and raw_attrs.len > 0`).

## Text Types (`TextType`)

| Type         | Description                                                   |
| ------------ | ------------------------------------------------------------- |
| `.normal`    | Normal text                                                   |
| `.nullchar`  | NULL character (replace with U+FFFD)                          |
| `.br`        | Hard line break (`<br>`)                                      |
| `.softbr`    | Soft line break                                               |
| `.entity`    | HTML entity (`&nbsp;`, `&#1234;`, `&#x12AB;`)                 |
| `.code`      | Text inside code block/span (`\n` for newlines, no BR events) |
| `.html`      | Raw HTML text (`\n` for newlines in block-level HTML)         |
| `.latexmath` | Text inside LaTeX equation (processed like code spans)        |

## Alignment (`Align`)

`.default`, `.left`, `.center`, `.right` — the `BlockTdDetail.@"align"` value.

## Detail Structs

All are plain Zig `struct`s in `src/abi.zig` — compiler-chosen layout, every
field defaulted, so an unset detail is just `.{}`. Absent strings/arrays are the
**empty slice**, never a null pointer (field defaults omitted below for brevity).

```zig
pub const BlockUlDetail = struct {
    is_tight: bool,         // True for a tight list, false for a loose one
    mark: MD_CHAR,          // Bullet character: '-', '+', '*'
};

pub const BlockOlDetail = struct {
    start: c_uint,          // Start index of ordered list
    is_tight: bool,         // True for a tight list, false for a loose one
    mark_delimiter: MD_CHAR, // '.' or ')'
};

pub const BlockLiDetail = struct {
    is_task: bool,              // Can be true only with MD_FLAG_TASKLISTS
    task_mark: MD_CHAR,         // 'x', 'X', or ' ' (if is_task)
    task_mark_offset: MD_OFFSET, // Offset of char between '[' and ']'
};

pub const BlockHDetail = struct {
    level: c_uint,          // Header level (1-6)
};

pub const BlockCodeDetail = struct {
    info: Attribute,        // Full info string
    lang: Attribute,        // First word of info string (language)
    fence_char: MD_CHAR,    // Fence character, or zero for indented code
    filename: Attribute, // `[filename]` from the info string
    meta: []const MD_CHAR,  // Raw metadata remainder; empty when absent.
                            // The backing buffer carries a NUL at meta.len
    highlights: []const c_uint, // Line numbers from `{1-3,5}`; empty when absent
};

pub const BlockTableDetail = struct {
    col_count: c_uint,      // Number of columns
    head_row_count: c_uint, // Header rows (currently always 1)
    body_row_count: c_uint, // Body rows
};

pub const BlockTdDetail = struct {
    @"align": Align,        // .default, .left, .center, or .right
};

pub const SpanAttrsDetail = struct {
    raw_attrs: []const MD_CHAR, // Raw attrs from trailing {...}. Not NUL-terminated
};

pub const SpanADetail = struct {
    href: Attribute,
    title: Attribute,
    raw_attrs: []const MD_CHAR,
    is_autolink: bool,
};

pub const SpanImgDetail = struct {
    src: Attribute,
    title: Attribute,
    raw_attrs: []const MD_CHAR,
};

pub const SpanSpanDetail = struct {
    raw_attrs: []const MD_CHAR, // Raw attrs from {...}. Not NUL-terminated
};

pub const SpanWikilinkDetail = struct {
    target: Attribute,
};

pub const SpanComponentDetail = struct {
    tag_name: Attribute,        // Component name (e.g. "badge", "icon-star")
    raw_props: []const MD_CHAR, // Raw props from {...}. Not NUL-terminated
};

pub const BlockComponentDetail = struct {
    tag_name: Attribute,        // Component name (e.g. "alert", "card")
    raw_props: []const MD_CHAR, // Raw props from {...}
    title: []const MD_CHAR,     // Title after name (e.g. "STOP" in :::danger STOP)
};

pub const BlockTemplateDetail = struct {
    name: Attribute,        // Slot name (e.g. "header", "footer")
};

pub const BlockAlertDetail = struct {
    type_name: Attribute, // Alert type (e.g. "NOTE", "WARNING")
};
```

`SpanADetail` and `SpanImgDetail` are **no longer layout-compatible** (they are
auto-layout structs now). Nothing relies on that any more either: the parser's
shared link/image builder projects an `SpanADetail` onto the `.img` arm
explicitly instead of handing over a pointer for the renderer to blind-cast.

## `Attribute`

String attribute for non-text-flow content (titles, URLs, etc.) that may contain mixed substrings (normal text + entities):

```zig
pub const Attribute = struct {
    text: []const MD_CHAR = &.{},
    substr_types: []const TextType = &.{},      // One entry per substring
    substr_offsets: []const MD_OFFSET = &.{},   // substr_types.len + 1 entries

    /// text.len as the MD_SIZE the offset tables are expressed in.
    pub fn size(self: Attribute) MD_SIZE { ... }
};
```

Invariants: `substr_offsets.len == substr_types.len + 1`, `substr_offsets[0] == 0`,
`substr_offsets[substr_types.len] == size()`. Only `.normal`, `.entity`, and
`.nullchar` substrings appear.

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
