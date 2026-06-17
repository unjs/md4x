# MD4X Change Log

## v0.0.18 (WIP)

### Features

- **Block component title (VitePress-style custom containers)**: Block components now support a title text after the component name: `:::danger STOP`, `:::details Click me`, `:::info My Title {props}`. The title is rendered as a `title` attribute in HTML, a `"title"` prop in JSON AST, and as the display label in ANSI output.
- **`md_heal()` — Markdown heal/completion utility**: Fixes incomplete/streaming Markdown text so it renders correctly mid-stream. Inspired by [remend](https://github.com/vercel/streamdown/tree/main/packages/remend). Heals unclosed bold/italic/strikethrough/code/math markers, completes incomplete links, removes incomplete images, closes open code blocks, strips incomplete HTML tags, prevents setext heading misinterpretation, and escapes comparison operators in list items.
- **CLI**: New `--format=heal` output format for the `md4x` CLI
- **JS bindings**: New `heal(input)` function exported from both `md4x/napi` and `md4x/wasm`
- **WASM**: New `md4x_heal` export
- **NAPI**: New `heal` binding

### Fixes

- **Parser callback abort codes**: A parser callback (`enter_block`/`leave_block`/`enter_span`/`leave_span`/`text`) that aborts with a non-zero **positive** return value now correctly stops emission immediately, matching the documented contract and the original md4c behavior. Previously several call sites checked `ret < 0`, so positive abort codes were logged as aborted but silently ignored (only negative codes aborted). Negative abort codes (used by all bundled renderers) were unaffected.

### Internal

- **C → Zig migration**: The entire library implementation (parser, all renderers, entity table, and wasm/napi glue) was ported from C to Zig for memory safety. The C ABI and all output are byte-for-byte unchanged; the public ABI headers and the CLI driver remain C.
- Extracted the shared component-property parser and JSON writer / YAML-to-JSON helpers into reusable Zig modules (`md4x-props.zig`, `md4x-json.zig`).
- Fixed a pre-existing parser bug that produced nondeterministic output on orphaned block-component (`::`) and setext edge cases.
- **Performance**: Built all Zig modules with `single_threaded = true` (the library is single-threaded by design), dropping thread-local/atomic scaffolding from native codegen. WASM size is unchanged (already single-threaded).
- **Performance**: Vectorized the HTML renderer's escape scan with a 16-wide SIMD compare (`render_html_escaped`), moving the Zig port ~1.22x ahead of the original C scalar scan on the medium benchmark. Output is byte-for-byte unchanged.
- Added `scripts/diff-corpus.sh`, an output-parity harness hashing all six renderer formats over the spec/extension/regression suites plus the fuzzer seed corpus.
- **Zig-native fuzz harness** (`src/fuzz.zig`, `zig build fuzz-zig --fuzz`): a coverage-instrumented complement to the C/libFuzzer harnesses. It `@import`s the parser + renderer Zig sources directly, so Zig's own fuzzer instruments the library and steers inputs by real coverage of the Zig internals — which the C/libFuzzer harnesses cannot (`zig build-obj` emits no SanitizerCoverage tables). Covers `md_parse`, all six renderers, and `md_heal`; built `ReleaseSafe` for runtime safety checks. The C/libFuzzer harnesses are retained for their ASan/UBSan coverage.
- **Idiomatic Zig pass (internals only; output, ABI, and behavior byte-for-byte unchanged)**: unified the duplicated realloc-grow blocks into `util.growArray`; converted the OOM-only allocators (attribute builders, mark/container/slot/alert/inline-attr/ref-def pushers) from `c_int` return codes to `error{OutOfMemory}`; switched the internal HTML-entity recognizers and the Unicode whitespace/punct classifiers (`md_is_unicode_whitespace`/`md_is_unicode_punct` plus their `ISUNICODE*` wrappers) to `bool`; and converted the entire internal line-array threading (`md_lookup_line`, `md_merge_lines`, the HTML/code-span/link recognizers, and the full inline/link pipeline) from `[*c]const MD_LINE` + count to Zig slices, adding Debug/ReleaseSafe bounds-checking on those paths. Verified by full corpus parity, the spec/extension suites, native unit tests, and the six libFuzzer harnesses.
- **Idiomatic Zig pass, cont. (internals only; output/ABI/behavior byte-for-byte unchanged)**: converted the offset-based char-class predicates (`ISWHITESPACE`, `ISNEWLINE`, `ISALNUM`, `ISANYOF`, the `ISUNICODE*` family, etc.) from ctx-first free functions in `util.zig` into `MD_CTX` methods (`ctx.isWhitespace(off)`, `ctx.isUnicodeWhitespace(off)`, …), matching the existing `ctx.ch`/`ctx.str`/`ctx.log` accessors. The pure `IS*_(ch)` byte helpers stay free functions (kept for md4c cross-reference). Verified by full corpus parity, the spec/extension suites, native tests, and the Zig-native fuzz smoke run.
- **Idiomatic Zig pass, cont.**: dropped the explicit `c_int` backing on the internal-only `MD_LINETYPE` enum (now a plain `enum`; the compiler picks the layout). Members keep their `MD_LINE_*` names for upstream md4c cross-reference. Internal-only; output/ABI/behavior byte-for-byte unchanged.
- **Idiomatic Zig pass, cont.**: began migrating the `MD_CTX` growable arrays from raw `[*c]T` + `n_*`/`alloc_*` triplets to `std.ArrayListUnmanaged(T)` backed by `c_allocator` (one array per commit). So far: `block_alert_info` and `slot_info` — their `n_*`/`alloc_*` bookkeeping fields are gone, growth is `.append(c_allocator, …)`, and cleanup is `.deinit(c_allocator)`. Internal-only; output/ABI/behavior byte-for-byte unchanged. Verified by corpus parity, the spec suites, native tests, the Zig-native fuzz smoke, and the html+ast libFuzzers under ASan/UBSan.

## v0.0.11

### Breaking Changes

- **AST root structure**: Changed from `{ type: "comark", value: [...] }` to `{ nodes: [...], frontmatter: {...}, meta: {} }`. Frontmatter is now a top-level field instead of a node in the array.
- **Boolean props**: Changed from `"key": true` (JSON boolean) to `":key": "true"` (colon-prefixed string) to match Comark AST spec.
- **TypeScript types**: `ComarkTree` now uses `nodes`/`frontmatter`/`meta` fields; `ComarkElement` tag type is `string | null`.

### Features

- Align Comark AST output with spec
- **HTML comment extraction**: HTML comments (`<!-- ... -->`) are now represented as `[null, {}, "comment body"]` instead of raw `html_block` passthrough. Both block-level and inline comments are supported.

### Other

- Fix AST benchmarks
- Add markdown-exit benchmark

## v0.0.10

### Features

- Add text renderer for stripping markdown to plain text
- Add GitHub-style alerts extension (`MD_FLAG_ALERTS`)
- Add `parseMeta` for extracting frontmatter metadata and headings
- Add full-HTML document mode with `md_html_ex()` and `MD_HTML_FLAG_FULL_HTML`
- Add `{ full: true }` option to JS `renderToHtml()`
- Render alerts and alert-like components with colored box style in ANSI renderer
- Use xterm.js for ANSI terminal rendering in playground

### Fixes

- Allow indented `::` components inside block components

### Breaking Changes

- Unified JS API usage (`refactor!: unified js api usage`)

### Other

- Update CLI usage documentation
- Various playground improvements

## v0.0.8

### Features

- Add linux-musl and linux-arm NAPI targets

### Fixes

- Fix release script tag handling

## v0.0.6

### Alerts (`MD_FLAG_ALERTS`)

Added GitHub-style alert/admonition syntax. A blockquote whose first line is `> [!TYPE]` (where TYPE is any alphanumeric/hyphenated name, case-insensitive) becomes an alert block (`MD_BLOCK_ALERT`). The `[!TYPE]` line is consumed and not emitted as text content.

HTML renderer: `<blockquote class="alert alert-{type}">` (type lowercased in class). JSON renderer: `["alert", {"type": "NOTE"}, ...children]`. ANSI renderer: bold yellow type label with quote-bar prefix.

New flag: `MD_FLAG_ALERTS` (`0x80000`), included in `MD_DIALECT_GITHUB` and `MD_DIALECT_ALL`. Supports all GitHub types (NOTE, TIP, IMPORTANT, WARNING, CAUTION) plus custom types.

### Full YAML frontmatter parsing with libyaml

The JSON renderer now uses [libyaml](https://github.com/yaml/libyaml) (0.2.5) for frontmatter parsing, replacing the previous hand-written flat parser. This adds support for nested objects, arrays (block and flow), and multi-line values (literal `|` and folded `>`). Plain scalar type coercion is preserved: numbers, booleans (`true`/`false`/`yes`/`no`/`on`/`off`), null (`null`/`~`/empty). Quoted scalars are always strings. The raw text is still preserved as a child string.

Example: `["frontmatter", {"title": "Hello", "tags": ["js", "ts"], "author": {"name": "John"}}, "..."]`

### Component slots (`MD_FLAG_COMPONENTS`)

Added named slot syntax inside block components: `#slot-name` at line start creates a `MD_BLOCK_TEMPLATE` container. Content after `#slot-name` until the next slot or component closer becomes the slot body. HTML renderer outputs `<template name="slot-name">...content...</template>`. JSON renderer outputs `["template", {"name": "slot-name"}, ...children]`.

### Inline attributes (`MD_FLAG_ATTRIBUTES`)

Added `{...}` attribute syntax on native inline elements: `**bold**{.class}`, `*italic*{#id}`, `` `code`{.lang} ``, `~~del~~{.class}`, `_underline_{.class}`, `[Link](url){target="_blank"}`, `![img](src){.responsive}`. The `[text]{.class}` syntax (brackets not followed by `(url)`) creates a generic `<span>`.

New parser types: `MD_SPAN_SPAN` (for `[text]{attrs}`), `MD_SPAN_ATTRS_DETAIL` (for em/strong/code/del/u with attrs), `MD_SPAN_SPAN_DETAIL`. Extended `MD_SPAN_A_DETAIL` and `MD_SPAN_IMG_DETAIL` with `raw_attrs`/`raw_attrs_size` fields. New flag: `MD_FLAG_ATTRIBUTES` (`0x40000`), included in `MD_DIALECT_ALL`.

### `renderToAST` returns raw string, new `parseAST` function

**Breaking:** `renderToAST` now returns the raw JSON string instead of a parsed `ComarkTree` object. A new `parseAST` function is added that calls `renderToAST` and parses the result into a `ComarkTree` object (equivalent to the previous `renderToAST` behavior).

### JSON renderer outputs Comark AST format

**Breaking:** The JSON renderer (`md_ast` / `renderToAST`) now outputs the Comark AST format instead of the previous mdast/unist-like format. The root is `{"type":"comark","value":[...]}` where each node is either a plain string (text) or a tuple array `["tag", {props}, ...children]`.

Key changes:

- Tags use HTML element names (`h1`–`h6`, `p`, `blockquote`, `em`, `strong`, `a`, `img`, `pre`/`code`, etc.)
- Text nodes are plain JSON strings (no `{type:"text",literal:"..."}` wrappers)
- Code blocks serialize as `["pre", {language}, ["code", {class}, literal]]`
- Images are void elements with `alt` in props: `["img", {src, alt}]`
- Heading level is baked into the tag name (`h1` not `heading` + `level`)
- TypeScript types changed from `MDNode`/`ContainerNode`/`LeafNode` to `ComarkTree`/`ComarkNode`/`ComarkElement`

### Zig build system

Replaced CMake with Zig build system. Build with `zig build` (defaults to `ReleaseFast`). The project can also be consumed as a Zig package dependency via `build.zig.zon`.

### CLI renamed from `md2html` to `md4x`

The CLI tool has been renamed from `md2html` to `md4x` and moved from `md2html/` to `src/cli/`. It now supports a `--format` (`-t`) flag to select the output format (`html`, `text`, `json`, `ansi`). HTML remains the default.

### AST renderer (`libmd4x-ast`)

Added a new renderer library (`src/md4x-ast.c`, `src/md4x-ast.h`) that converts Markdown into a nested JSON AST tree compatible with the [commonmark.js](https://github.com/commonmark/commonmark.js) AST format. Each node has `"type"`, type-specific properties, and either `"children"` (container nodes) or `"literal"` (leaf nodes).

The CLI supports it via `--format=json`.

Node types follow commonmark.js conventions: `document`, `block_quote`, `list`, `item`, `heading`, `code_block`, `html_block`, `paragraph`, `thematic_break`, `emph`, `strong`, `link`, `image`, `code`, `delete`, `text`, `linebreak`, `softbreak`, `html_inline`. Extension types: `table`, `table_head`, `table_body`, `table_row`, `table_header_cell`, `table_cell`, `latex_math`, `latex_math_display`, `wikilink`, `underline`, `frontmatter`.

### ANSI terminal renderer (`libmd4x-ansi`)

Added a new renderer library (`src/md4x-ansi.c`, `src/md4x-ansi.h`) that converts Markdown into ANSI terminal output with escape codes for colors, bold, italic, underline, strikethrough, and other styling. Links use OSC 8 clickable hyperlinks with a dim URL fallback for unsupported terminals.

The CLI supports it via `--format=ansi`. Pass `MD_ANSI_FLAG_NO_COLOR` to suppress all escape codes.

### WASM target (`zig build wasm`)

Added a WebAssembly build target (`wasm32-wasi`) that produces a ~163K `.wasm` binary. Exposes `md4x_to_html`, `md4x_to_ast`, and `md4x_to_ansi` functions callable from JavaScript, along with `md4x_alloc`/`md4x_free` for memory management and `md4x_result_ptr`/`md4x_result_size` for reading output.

### Node.js NAPI addon (`zig build napi`)

Added a Node-API native addon target that produces a `.node` shared library. Exposes `renderToHtml`, `renderToAST`, and `renderToAnsi` functions that take a string and optional parser/renderer flags, returning the rendered output as a string. Requires `node-api-headers` (`zig build napi -Dnapi-include=node_modules/node-api-headers/include`).

### Frontmatter support (`MD_FLAG_FRONTMATTER`)

Added YAML-style frontmatter parsing as an opt-in extension. When enabled, a `---` fence on the very first line of the document opens a frontmatter block. Content is exposed verbatim via `MD_BLOCK_FRONTMATTER` callbacks and rendered as `<x-frontmatter>` in HTML. CLI flag: `--ffrontmatter`.
