# MD4X Change Log

## v0.0.18 (WIP)

### Breaking Changes

- **Dropped the external C ABI.** MD4X is now a **Zig library + JS bindings** only. Removed: all public headers (`md4x.h`, `entity.h`, and the eight `renderers/md4x-*.h`), the installed static libraries (`zig-out/lib/libmd4x*.a`) and installed headers (`zig-out/include/`), the stable-exported-symbol promise, and drop-in [md4c](https://github.com/mity/md4c) compatibility. `zig build` now installs only `zig-out/bin/md4x`; the wasm/napi artifacts still install into `packages/md4x/build/`. Consumers who linked MD4X as a C library are no longer supported — use the Zig package (via `build.zig.zon`) or the JS bindings.
- **CLI rewritten in Zig.** `src/cli/md4x-cli.c` and the vendored `cmdline.c`/`cmdline.h` are replaced by `src/cli/md4x-cli.zig`. All options, formats, and stdout are byte-for-byte unchanged.
- **Removed the C/libFuzzer harnesses** (`test/fuzzers/fuzz-*.c`, `build.sh`, `run.sh`) and the C-only CodeQL workflow. They drove the deleted public headers, and gave no coverage feedback on the Zig library anyway (`zig build-obj` emits no SanitizerCoverage tables). `zig build fuzz-zig` — which does instrument the Zig internals — is now the only harness; the seed corpus is retained and reused.

**Unchanged:** every renderer's byte-for-byte output, the CLI's stdout for every format and flag, and the wasm/napi exported function set + Comark AST JSON shape consumed by the JS package. The wasm exports and napi module registration remain real C-callable boundaries.

### Features

- **Block component title (VitePress-style custom containers)**: Block components now support a title text after the component name: `:::danger STOP`, `:::details Click me`, `:::info My Title {props}`. The title is rendered as a `title` attribute in HTML, a `"title"` prop in JSON AST, and as the display label in ANSI output.
- **`md_heal()` — Markdown heal/completion utility**: Fixes incomplete/streaming Markdown text so it renders correctly mid-stream. Inspired by [remend](https://github.com/vercel/streamdown/tree/main/packages/remend). Heals unclosed bold/italic/strikethrough/code/math markers, completes incomplete links, removes incomplete images, closes open code blocks, strips incomplete HTML tags, prevents setext heading misinterpretation, and escapes comparison operators in list items.
- **CLI**: New `--format=heal` output format for the `md4x` CLI
- **JS bindings**: New `heal(input)` function exported from both `md4x/napi` and `md4x/wasm`
- **WASM**: New `md4x_heal` export
- **NAPI**: New `heal` binding

### Fixes

- **Parser callback abort codes**: A parser callback (`enter_block`/`leave_block`/`enter_span`/`leave_span`/`text`) that aborts with a non-zero **positive** return value now correctly stops emission immediately, matching the documented contract and the original md4c behavior. Previously several call sites checked `ret < 0`, so positive abort codes were logged as aborted but silently ignored (only negative codes aborted). Negative abort codes (used by all bundled renderers) were unaffected.
- **Parser cleanup ordering (latent UB)**: `md_parse`/`md_process_doc` freed `ctx.ref_defs` **before** `md_free_ref_def_hashtable`, which reads the `ref_defs` address range (and now the bucket headers) to distinguish simple from complex hashtable buckets. The hashtable was therefore torn down against a deinitialized `ref_defs`, working only because ReleaseFast leaves the stale-but-numerically-valid pointer in place. The teardown is now correctly ordered (hashtable before `ref_defs`) at all three cleanup sites. No observable output change; surfaced by a new Debug-mode FailingAllocator full-parse sweep.

### Internal

- **Idiomatic SAX detail types** (Phase 4c step 2 — internal only, output byte-for-byte unchanged): `MD_ATTRIBUTE` and every `MD_BLOCK_*_DETAIL` / `MD_SPAN_*_DETAIL` in `src/abi.zig` dropped `extern struct` and are now ordinary Zig structs. Their `[*c]` pointer + separate `*_size`/`*_count` pairs became **slices with exact lengths** (`MD_ATTRIBUTE.text` / `.substr_types` / `.substr_offsets`, `MD_BLOCK_CODE_DETAIL.meta` / `.highlights`, and every `raw_attrs` / `raw_props` / block-component `title`), with `MD_ATTRIBUTE.size()` replacing the old `size` field; the genuinely two-state `c_int` members (`is_tight`, `is_task`, `is_autolink`) became `bool`. An absent value is now the **empty** slice — the parser never produced a non-empty pointer with a zero length, and no consumer distinguished null from empty. Consequences: the seven renderers' `MD_ATTRIBUTE` walks are bounded loops instead of terminator-driven pointer walks; the two `extern union` detail scratch slots in `process.zig` became structs with an explicit per-block-type selector (auto-layout structs no longer share offset 0); and `MD_SPAN_A_DETAIL` / `MD_SPAN_IMG_DETAIL` are no longer layout-compatible (nothing relied on it). `MD_PARSER` is untouched — its five callbacks stay `callconv(.c)` and still receive details as `?*anyopaque` until step 3. Verified by the golden SAX event trace (unchanged byte-for-byte), full corpus parity across all six renderer formats, all 16 spec/extension suites, 30 pathological tests, `zig build test` in Debug and ReleaseFast, the Zig fuzz smoke, and the JS binding tests against freshly built wasm + napi.
- **Golden SAX event-trace test** (`zig build test`): freezes the full ordered stream of parser callbacks — every `enter_block`/`leave_block`/`enter_span`/`leave_span`/`text` event over a document covering every block type, span type, and text type — including each detail struct's field values and every `MD_ATTRIBUTE`'s substring type/offset table. The corpus harness compares only each renderer's final bytes, so it can miss a detail-packaging change that renderers paper over; this compares the raw SAX stream. Test-only.
- **De-externed the internal entry points**: `md_parse`, `md_html`/`md_html_ex`, `md_ast`, `md_ansi`, `md_text`, `md_markdown`, `md_meta`, `md_heal`, and `entity_lookup` dropped `export` + `callconv(.c)` and are now plain `pub fn`. The `process_output` sink type and every implementation of it (the CLI, wasm, and napi sinks, the renderers' heal and capture sinks) dropped `callconv(.c)` too — those pointers only ever cross Zig-to-Zig boundaries now. `export` + `callconv(.c)` remains exactly where there is a real boundary: the wasm exports, the napi module registration, the `MD_PARSER` SAX callbacks, and the `qsort`/`bsearch` comparators handed to libc. `src/entity.zig` is generated, so its `entity_lookup` change was made in lockstep with its generator, `scripts/_gen-entity-zig.py` (whose input, the deleted `src/entity.c`, means it can no longer be re-run). Internal-only; output byte-for-byte unchanged.
- **One Zig module per artifact (no more internal static-lib seam)**: the parser, entity table, and seven renderers were each compiled as a separate static library and found each other through link-time C-ABI symbols (`export fn` definitions + `pub extern fn` re-declarations in `abi.zig`). They are now pulled into each artifact's module graph through a new library root, `src/lib.zig`, and call each other by **direct Zig call**. `build.zig` lost the `addParserLib`/`addEntityLib`/`addZigRenderer` helpers and the `zig_renderers` list; adding a renderer is now an edit to `src/lib.zig`. `src/abi.zig` became a pure leaf module (types, enums, and flags only — its function declarations moved to `lib.zig`, and `ENTITY` / `MD_HTML_OPTS` moved to their real definition sites in `entity.zig` / `md4x-html.zig`). Internal-only: the wasm and napi edge exports are untouched, and output is byte-for-byte unchanged. Verified by full corpus parity, all spec/extension suites, 30 pathological tests, native tests in Debug and ReleaseFast, the Zig-native fuzz smoke, and the 616 JS binding tests against freshly built wasm + napi artifacts.
- **C → Zig migration**: The entire library implementation (parser, all renderers, entity table, CLI driver, and wasm/napi glue) was ported from C to Zig for memory safety, with all output byte-for-byte unchanged. The only C compiled into any artifact is now the vendored libyaml.
- **`src/abi.zig`**: a Zig-native single source of truth for the shared `MD_*` types, enums, flags, `MD_PARSER`, and the cross-module declarations — replacing the deleted `md4x.h` / `entity.h` / `md4x-*.h`. The type and flag declarations began as a verbatim `zig translate-c` transcription; the SAX detail types have since been idiomatized (see the Phase 4c step 2 entry above), while `MD_PARSER` and the type enums keep their C shapes. The parser, every renderer, the CLI, and the wasm/napi/fuzz roots all `@import("abi")`; the only remaining `@cImport`s are genuinely external headers (`node_api.h`, `stdio.h`, `string.h`, `yaml.h`).
- Extracted the shared component-property parser and JSON writer / YAML-to-JSON helpers into reusable Zig modules (`md4x-props.zig`, `md4x-json.zig`).
- Fixed a pre-existing parser bug that produced nondeterministic output on orphaned block-component (`::`) and setext edge cases.
- **Performance**: Built all Zig modules with `single_threaded = true` (the library is single-threaded by design), dropping thread-local/atomic scaffolding from native codegen. WASM size is unchanged (already single-threaded).
- **Performance**: Vectorized the HTML renderer's escape scan with a 16-wide SIMD compare (`render_html_escaped`), moving the Zig port ~1.22x ahead of the original C scalar scan on the medium benchmark. Output is byte-for-byte unchanged.
- Added `scripts/diff-corpus.sh`, an output-parity harness hashing all six renderer formats over the spec/extension/regression suites plus the fuzzer seed corpus.
- **Zig-native fuzz harness** (`src/fuzz.zig`, `zig build fuzz-zig --fuzz`): a coverage-instrumented complement to the C/libFuzzer harnesses. It `@import`s the parser + renderer Zig sources directly, so Zig's own fuzzer instruments the library and steers inputs by real coverage of the Zig internals — which the C/libFuzzer harnesses cannot (`zig build-obj` emits no SanitizerCoverage tables). Covers `md_parse`, all six renderers, and `md_heal`; built `ReleaseSafe` for runtime safety checks. (It has since become the _only_ harness — see Breaking Changes.)
- **Idiomatic Zig pass (internals only; output, ABI, and behavior byte-for-byte unchanged)**: unified the duplicated realloc-grow blocks into `util.growArray`; converted the OOM-only allocators (attribute builders, mark/container/slot/alert/inline-attr/ref-def pushers) from `c_int` return codes to `error{OutOfMemory}`; switched the internal HTML-entity recognizers and the Unicode whitespace/punct classifiers (`md_is_unicode_whitespace`/`md_is_unicode_punct` plus their `ISUNICODE*` wrappers) to `bool`; and converted the entire internal line-array threading (`md_lookup_line`, `md_merge_lines`, the HTML/code-span/link recognizers, and the full inline/link pipeline) from `[*c]const MD_LINE` + count to Zig slices, adding Debug/ReleaseSafe bounds-checking on those paths. Verified by full corpus parity, the spec/extension suites, native unit tests, and the six libFuzzer harnesses.
- **Idiomatic Zig pass, cont. (internals only; output/ABI/behavior byte-for-byte unchanged)**: converted the offset-based char-class predicates (`ISWHITESPACE`, `ISNEWLINE`, `ISALNUM`, `ISANYOF`, the `ISUNICODE*` family, etc.) from ctx-first free functions in `util.zig` into `MD_CTX` methods (`ctx.isWhitespace(off)`, `ctx.isUnicodeWhitespace(off)`, …), matching the existing `ctx.ch`/`ctx.str`/`ctx.log` accessors. The pure `IS*_(ch)` byte helpers stay free functions (kept for md4c cross-reference). Verified by full corpus parity, the spec/extension suites, native tests, and the Zig-native fuzz smoke run.
- **Idiomatic Zig pass, cont.**: dropped the explicit `c_int` backing on the internal-only `MD_LINETYPE` enum (now a plain `enum`; the compiler picks the layout). Members keep their `MD_LINE_*` names for upstream md4c cross-reference. Internal-only; output/ABI/behavior byte-for-byte unchanged.
- **Idiomatic Zig pass, cont.**: began migrating the `MD_CTX` growable arrays from raw `[*c]T` + `n_*`/`alloc_*` triplets to `std.ArrayListUnmanaged(T)` backed by `c_allocator` (one array per commit). **Complete:** all seven typed `MD_CTX` growable arrays — `block_alert_info`, `slot_info`, `block_component_info`, `inline_attrs`, `containers`, `ref_defs`, and `marks` — are now `std.ArrayListUnmanaged(T)` backed by `c_allocator`. Every `n_*`/`alloc_*` bookkeeping field and all eight `util.growArray` call sites are gone; growth is `.append`/`ensureUnusedCapacity`, cleanup is `.deinit(c_allocator)`, and per-pass resets use `clearRetainingCapacity()`. The `containers` and `marks` stacks expose their depth via new `ctx.nContainers()`/`ctx.nMarks()` helpers (pops are `.items.len -= 1`). `ref_defs` preserves the hashtable's pointer-identity bucket trick (range check recomputed from `.items.ptr`/`.items.len`) and reserves-then-commits new entries so its abort paths can't leave a half-filled slot. The `block_bytes` byte arena, the `MD_REF_DEF_LIST` flexible-array buckets, and the ref-def hashtable stay on raw `malloc` by design. Each array was migrated and committed one at a time, every step gated on full corpus parity + the spec suites + native tests + the Zig-native (ReleaseSafe) and libFuzzer (ASan/UBSan) fuzzers. Internal-only; output/ABI/behavior byte-for-byte unchanged. Verified by corpus parity, the spec suites, native tests, the Zig-native fuzz smoke, and the html+ast libFuzzers under ASan/UBSan.
- **Idiomatic Zig pass, cont.**: `MD_CTX` now carries an injectable `alloc: std.mem.Allocator` field (defaulting to `c_allocator`), and the seven ArrayList arrays grow/free through `ctx.alloc`. Production is unchanged (default `c_allocator`, byte-identical output); the indirection enables `std.testing.FailingAllocator` native tests that exercise the array OOM-cleanup paths fuzzing can't reach — asserting the push helpers return `error.OutOfMemory` cleanly and that `.deinit` is leak-free. Internal-only.
- **Idiomatic Zig pass, cont. (fuller OOM matrix)**: routed the three remaining raw byte arenas — the `block_bytes` block/line arena, the ref-def hashtable array, and the `MD_REF_DEF_LIST` flexible-array buckets — off raw `std.c.malloc`/`realloc`/`free` and through `ctx.alloc` via new `malloc`/`realloc`/`free`-shaped `util.arena_*` helpers (16-byte aligned, exact-length tracked). `md_parse` was split into a thin export over `md_parse_impl(alloc, …)` so a `std.testing.FailingAllocator` can drive a full parse; a new native test sweeps every internal allocation index over a ref-def/heading/list/code/emphasis document and asserts each run is crash- and leak-free. Production still uses `c_allocator` (byte-identical output). Internal-only. Verified by full corpus parity, the spec/extension suites, native tests in **both** Debug (safety checks) and ReleaseFast, the Zig-native (ReleaseSafe) fuzz smoke, and the html+ast libFuzzers under ASan/UBSan.
- **Idiomatic Zig pass, cont. (fuller OOM matrix, typed buffers)**: routed the remaining typed scratch buffers through `ctx.alloc` via new `util.alloc_array_a`/`realloc_array_a`/`free_array_a` helpers (typed-`[*c]T` variants of the `arena_*` helpers, exact element-count tracked): `md_build_attribute`'s `text`/`substr_types`/`substr_offsets` (with the `text` length now recorded in `MD_ATTRIBUTE_BUILD`), and `process.zig`'s per-table-row `pipe_offs`/`align_arr` plus the fenced-code `meta_buf`/`meta_copy` (`MD_BLOCK_CODE_DETAIL.meta`). The `md_parse` `FailingAllocator` sweep input was widened to drive these (table, fenced code with filename + highlight metadata, an inline link title containing an entity, and inline/block components). Only `md_parse_highlights`'s `det.code.highlights` array remains on raw `malloc` (its capacity ≠ the stored `highlight_count`, so it needs a shrink-to-fit first). Production still uses `c_allocator` (byte-identical output). Internal-only. Verified by full corpus parity, the spec/extension suites, native tests in both Debug and ReleaseFast, the Zig-native fuzz smoke, and the html+ast libFuzzers under ASan/UBSan (57M+ executions, no crashes).
- **Idiomatic Zig pass, cont. (fuller OOM matrix complete)**: routed the last raw-`malloc` matrix buffer — `md_parse_highlights`'s `det.code.highlights` line-number array — through `ctx.alloc` (`realloc_array_a` to grow, then a **shrink-to-fit** to `count` so the freed length matches the ABI `highlight_count`, which has no capacity field; a shrink OOM drops the highlights cleanly). With this, every parser allocation the OOM matrix targeted now flows through the injectable allocator, so the `md_parse` `FailingAllocator` sweep reaches them all. Production still uses `c_allocator` (byte-identical output). Internal-only. Verified by full corpus parity, the spec/extension suites, native tests in both Debug and ReleaseFast, the Zig-native fuzz smoke, and the html+ast libFuzzers under ASan/UBSan (57M+ executions, no crashes).
- **Idiomatic Zig pass, cont. (`ctx.buffer` routed)**: routed the `ctx.buffer` / `md_temp_buffer` scratch (used to splice `mailto:`/`http://` prefixes onto permissive autolinks) off raw `std.c.malloc`/`realloc`/`free` and through `ctx.alloc` via the typed `realloc_array_a`/`free_array_a` helpers (length = `alloc_buffer`); the `md_parse` `FailingAllocator` sweep gained email + www autolinks to drive its OOM path. The remaining libc allocations in the parser are the `md_merge_lines_alloc` buffers (ref-def label/title + merged autolink/link-label strings), which need a shrink-to-fit and a length-carrying `ptr_stack` free before they can move — a separate follow-on. Production still uses `c_allocator` (byte-identical output). Internal-only. Verified by full corpus parity, the spec/extension suites, native tests in both Debug and ReleaseFast, the Zig-native fuzz smoke, and the html+ast libFuzzers under ASan/UBSan (58M+ executions, no crashes).

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
