# MD4X

> **Always keep this file (`AGENTS.md`) and referenced `docs/*.md` files updated when making changes to the project.**
> **Always update `CHANGELOG.md` when adding removing user-facing features, APIs, build targets, CLI options, or library behavior.**

> Markdown parser library (Zig port of [mity/md4c](https://github.com/mity/md4c))

- **License:** MIT
- **Language:** Zig (port of [mity/md4c](https://github.com/mity/md4c); the only C left in any artifact is the vendored libyaml)
- **Spec:** CommonMark 0.31.2
- **Build:** Zig (`zig build`)
- **JS Runtime:** Bun (do **not** use npm, pnpm, yarn, or npx — use `bun`/`bunx` exclusively)
- **Formatting:** Always run `bun fmt` after finishing code changes

> **Implementation note:** MD4X is a **Zig library + JS bindings**. The entire implementation (parser, all renderers, entity table, CLI driver, and wasm/napi glue) is Zig; output is byte-for-byte identical to the original C implementation.
>
> **There is no external C ABI.** The public `.h` headers, the stable-exported-symbol promise, and drop-in md4c compatibility were **dropped** (see `PLAN.md`). `src/abi.zig` is now the single source of truth for the shared parser types, enums, flags, and the `Parser` callback table. The only C-callable boundaries left are the **wasm exports** and the **napi module registration** — those stay `export` + `callconv(.c)` deliberately.
>
> **Compatibility surface that IS preserved:** byte-for-byte output of every renderer, the CLI's stdout for every format/flag, and the wasm/napi exported function set + Comark AST JSON shape consumed by the JS package. The _internal_ calling convention is not frozen.

## Project Structure

```
src/
  lib.zig             # Library root: parser + entity + all renderers in ONE module
  md4x.zig            # Parser root (md_parse; imports src/parser/ modules)
  abi.zig             # Shared types/enums/flags, detail unions, Parser (types only, leaf)
  parser/             # Parser implementation, split from the monolithic md4x.zig
    types.zig         # MD_CTX + internal structs, enums, shared @import("abi")
    util.zig          # char/UTF-8/unicode helpers, buffers, entity recognizers, attributes
    refdefs.zig       # ref-def dictionary + link/autolink/wiki recognizers
    inlines.zig       # inline mark engine (emphasis mod-3) + span/text emission
    blocks.zig        # line classification + container/block analysis
    process.zig       # block-content processing + md_process_doc
  unicode_tables.zig  # Generated Unicode tables (case folding, punct, whitespace)
  entity.zig           # HTML entity lookup table (generated)
  md4x-wasm.zig        # WASM exports (alloc/free + renderer wrappers)
  md4x-napi.zig        # Node.js NAPI addon (module registration + renderer wrappers)
  fuzz.zig             # Zig-native coverage-instrumented fuzz harness (zig build fuzz-zig --fuzz)
  renderers/
    md4x-props.zig     # Shared component property parser (Zig module)
    md4x-json.zig      # Shared JSON writer + YAML-to-JSON helpers (Zig module)
    md4x-html.zig      # HTML renderer library
    md4x-ast.zig       # AST renderer library
    md4x-ansi.zig      # ANSI terminal renderer library
    md4x-meta.zig      # Meta renderer library
    md4x-text.zig      # Plain text renderer library
    md4x-markdown.zig  # Markdown renderer library
    md4x-heal.zig      # Markdown heal/completion utility
  cli/
    md4x-cli.zig         # CLI utility driver (multi-format: html, text, json, ansi, markdown, heal)
    md4x.1               # Man page
packages/md4x/           # npm package
  package.json           # Package manifest (name: md4x)
  README.md              # Package README
  LICENSE.md             # MIT license
  build/
    md4x.wasm            # Prebuilt WASM binary (ReleaseFast)
    md4x-small.wasm      # Prebuilt WASM binary (ReleaseSmall, inlined into lib/standalone.mjs)
    md4x.*.node          # Prebuilt NAPI binaries (per-platform)
  lib/
    wasm/
      common.mjs         # Shared WASM render functions (instance singleton + imports)
      default.mjs        # `md4x/wasm` entrypoint (loads build/md4x.wasm)
      unwasm.mjs         # `md4x/wasm` entrypoint for the `unwasm` condition
      index.d.mts        # TypeScript declarations for WASM API
    standalone.mjs       # GENERATED (gitignored) — `md4x/standalone` rolldown bundle
    standalone.d.mts     # TypeScript declarations for the standalone API
    napi.mjs             # JS entrypoint for NAPI (sync API, ESM)
    napi.d.mts           # TypeScript declarations for NAPI API
    types.d.mts          # Shared TypeScript types (ComarkTree, ComarkNode, ComarkElement, etc.)
  test/
    _suite.mjs           # Shared test suite (vitest, used by NAPI/WASM/standalone tests)
    napi.test.mjs        # NAPI binding tests
    wasm.test.mjs        # WASM binding tests
    standalone.test.mjs  # Inlined-WASM (`md4x/standalone`) binding tests
  bench/
    _fixtures.mjs        # Benchmark fixture strings (small, medium, large)
    index.mjs            # Benchmark runner (mitata, compares napi/wasm/md4w/markdown-it)
test/
  spec.txt             # CommonMark 0.31.2 spec tests
  spec-*.txt           # Extension-specific tests (tables, strikethrough, frontmatter, etc.)
  regressions.txt      # Bug regression tests
  coverage.txt         # Code coverage tests
  run-testsuite.py     # Individual test suite runner
  pathological-tests.py # Stress tests for DoS resistance
  prog.py              # Program execution wrapper
  normalize.py         # HTML normalization for comparison
  fuzzers/             # Fuzz corpora (the C/libFuzzer harnesses were removed)
    seed-corpus/       # Seed inputs (commonmark, gfm, frontmatter, components, etc.)
    corpus/            # Accumulated fuzzer-discovered inputs
scripts/
  run-tests.ts            # Main test runner (runs all suites)
  diff-corpus.sh          # Output-parity harness (sha256 of all 6 renderer formats over the corpus)
  build-entity-map.ts     # Generates entity.c from WHATWG spec
  build-standalone.ts     # Bundles lib/standalone.mjs (rolldown, gzip+Z85 inlined wasm)
  build-folding-map.ts    # Unicode case folding map generator
  build-punct-map.ts      # Punctuation character map generator
  build-whitespace-map.ts # Whitespace classification generator
  _unicode-map.ts         # Shared helper for punct/whitespace map generators
  _gen-tables-zig.py      # Generates src/unicode_tables.zig (case folding/punct/whitespace tables)
  _gen-entity-zig.py      # Generates src/entity.zig from the WHATWG entity data
  coverity.sh             # Coverity Scan integration
  unicode/                # Unicode data files (CaseFolding.txt, DerivedGeneralCategory.txt)
website/                 # Docs + playground (Vite + Vue)
  package.json           # Website package manifest (md4x-demo)
  vite.config.mjs        # Vite config (base: /md4x/)
  index.html             # HTML entry
  index.ts               # App entry point
  index.css              # Styles
  App.vue                # Root component with navigation
  router.ts              # Vue Router config
  env.d.ts               # TypeScript env types
  components/
    TabSelect.vue        # Responsive select/button tab switcher
    AnsiTerminal.vue     # xterm.js-backed ANSI output view
    ComarkVueRenderer.vue # Comark AST -> Vue VNode renderer for playground
    ComarkReactRenderer.vue # Comark AST -> React renderer host for playground
  pages/
    readme.vue           # Renders README.md via md4x/wasm
    playground.vue       # Interactive markdown editor + renderer tabs (html, ast, vue, react, ansi, text, meta)
  samples/               # Example markdown files for playground
package.json             # Root workspace package (bun, workspaces: packages/*, website)
build.zig                # Zig build script
build.zig.zon            # Zig package manifest
.github/workflows/
  ci-build.yml         # Build + test (Linux/Windows, debug/release, coverage)
```

## Building

Uses Zig build system. External dependency: [libyaml](https://github.com/yaml/libyaml) 0.2.5 (YAML parser for AST/meta renderer frontmatter, fetched automatically via `build.zig.zon`).

```sh
zig build                          # build all (defaults to ReleaseFast)
zig build -Doptimize=Debug         # debug build
zig build && zig-out/bin/md4x --help  # run md4x CLI
```

Installs only `zig-out/bin/md4x`. **No static libraries or headers are installed** — they were part of the dropped C ABI. The wasm/napi artifacts install directly into `packages/md4x/build/`.

The project can also be consumed as a Zig package dependency via `build.zig.zon`.

**One Zig module graph per artifact.** `src/lib.zig` is the library root: it imports the parser, the entity table, and every renderer, and re-exports their entry points. Each artifact root pulls it in — `src/md4x-wasm.zig` (WASM), `src/md4x-napi.zig` (NAPI), and `src/fuzz.zig` via a relative `@import("lib.zig")`; `src/cli/md4x-cli.zig` via the named `md4x` module, because a module may not `@import` outside its own directory. The units therefore call each other by **direct Zig call**; there are no per-unit static libraries and no link-time C-ABI symbol resolution between them.

To add a renderer, add it to `src/lib.zig` — not to `build.zig`.

Two build-graph rules worth knowing: the `abi` module must be created **once** and shared by every module in an artifact (a second `createModule` on `src/abi.zig` fails with _"file exists in modules 'abi' and 'abi0'"_), and `src/abi.zig` must stay a **pure leaf** — types only, no imports, no function declarations. Anything that would make `abi` import the parser or a renderer creates a cycle. Entry-point declarations belong in `src/lib.zig`.

The WASM JS loader (`packages/md4x/lib/wasm/common.mjs`) provides no-op `args_`/`environ_` WASI import stubs that Zig's `wasm32-wasi` startup references.

Build targets:

- **md4x** — CLI utility (supports `--format=html|text|json|ansi|markdown|heal`)
- **md4x.wasm** — WASM library (`zig build wasm`, ReleaseFast, output: `packages/md4x/build/md4x.wasm`)
- **md4x-small.wasm** — Size-optimized WASM library (`zig build wasm-small`, ReleaseSmall, output: `packages/md4x/build/md4x-small.wasm`) — inlined into the `md4x/standalone` bundle, excluded from the npm tarball via `!build/md4x-small.wasm` in `files`
- **md4x.{platform}-{arch}[-musl].node** — Cross-compiled NAPI addons (`zig build napi-all`, 9 targets)

The only C compiled into any artifact is the vendored **libyaml**. Remaining `@cImport`s are all genuinely external headers: `node_api.h` (napi), `stdio.h`, `string.h`, `yaml.h`.

## Testing

```sh
# Run all test suites:
bun scripts/run-tests.ts

# Individual test suite:
python3 test/run-testsuite.py -s test/spec.txt -p zig-out/bin/md4x

# Pathological inputs only:
python3 test/pathological-tests.py -p zig-out/bin/md4x

# Zig unit tests (parser internals, e.g. callback-abort behavior):
zig build test
```

Test format: Markdown examples with `.` separator and expected HTML output. The test runner pipes input through `md4x` and compares normalized output.

The HTML-diff suites cannot express parser-internal behavior; those invariants are covered by Zig unit tests in `src/md4x.zig`, run via `zig build test`:

- **Abort matrix** — for each of the five SAX callbacks, that a negative code propagates verbatim and a positive one stops emission but returns 0.
- **OOM sweep** — a `FailingAllocator` walks every internal allocation index over a document exercising ref-defs, tables, code metadata, attributes, components, and autolinks, asserting each run is crash- and leak-free.
- **Golden SAX event trace** — the full ordered stream of `enter_block`/`leave_block`/`enter_span`/`leave_span`/`text` events over a document covering every block type, span type, and text type, with each detail union arm's field values and every `Attribute`'s substring type/offset table spelled out. The corpus harness only compares each renderer's final bytes, so it can miss a detail-packaging change that renderers paper over; this compares the raw SAX stream instead. **Phase 4c rewrote exactly this mechanism (and the expected string survived it unchanged), so treat a trace diff as a stop-the-line regression.** The expected value is a _recorded_ baseline: to re-record after a deliberate change, temporarily `std.debug.print` `probe.out.items` from the test, and say in the commit message what changed and why.

Test suites: `spec.txt`, `spec-tables.txt`, `spec-strikethrough.txt`, `spec-tasklists.txt`, `spec-wiki-links.txt`, `spec-latex-math.txt`, `spec-permissive-autolinks.txt`, `spec-hard-soft-breaks.txt`, `spec-underline.txt`, `spec-frontmatter.txt`, `spec-components.txt`, `spec-attributes.txt`, `spec-alerts.txt`, `spec-markdown.txt`, `regressions.txt`, `coverage.txt`

## Fuzzing

**`src/fuzz.zig` / `zig build fuzz-zig` is the only harness.** It `@import`s the parser + renderer sources directly, so Zig's own fuzzer instruments the library and steers inputs by **real coverage of the Zig internals**. No ASan/UBSan; it relies on Zig runtime safety checks (the artifact is built `ReleaseSafe`).

> The former C/libFuzzer harnesses (`test/fuzzers/fuzz-*.c` + `build.sh`/`run.sh`) were **removed** with the C ABI — they drove the public headers, which no longer exist, and gave no coverage feedback on the Zig library anyway (`zig build-obj` emits no SanitizerCoverage tables, so libFuzzer only "saw" the C harness + libyaml). Their seed corpus is retained at `test/fuzzers/seed-corpus/` and reused by `fuzz-zig` and `scripts/diff-corpus.sh`.

```sh
zig build fuzz-zig                 # smoke-run: exercise each harness once (+ parser unit tests)
zig build fuzz-zig --fuzz          # coverage-guided fuzzing (serves a local web UI)
zig build fuzz-zig --fuzz -- md_html   # fuzz a single named test
```

Covers `md_parse` (parser-only, no-op SAX callbacks), the six renderers (`md_html`, `md_ast`, `md_ansi`, `md_text`, `md_meta`, `md_markdown`), and `md_heal`. Inputs are gated to valid, NUL-free UTF-8, matching the JS binding surface where input is always a valid UTF-8 string. libyaml is linked for the html/ast/meta paths but is not instrumented.

Seed corpus in `test/fuzzers/seed-corpus/` covers: CommonMark, GFM, LaTeX math, wiki links, frontmatter, components, attributes, alerts, underline, code block metadata, and heal edge cases.

## `md4x` CLI

```sh
md4x [OPTION]... [FILE]
# Reads from stdin if no FILE given
```

**General options:**

| Option                  | Description                                                                 |
| ----------------------- | --------------------------------------------------------------------------- |
| `-o`, `--output=FILE`   | Output file (default: stdout)                                               |
| `-t`, `--format=FORMAT` | Output format: `html` (default), `text`, `json`, `ansi`, `markdown`, `heal` |
| `--heal`                | Heal incomplete markdown before rendering (applies to any format)           |
| `-s`, `--stat`          | Measure parsing time                                                        |
| `--replay-fuzz`         | Replay a fuzzer input file through every renderer (crash-repro aid)         |
| `-h`, `--help`          | Display help                                                                |
| `-v`, `--version`       | Display version                                                             |

All extensions are enabled by default (`MD_DIALECT_ALL`). No dialect preset flags.

**HTML output options:**

| Option               | Description                             |
| -------------------- | --------------------------------------- |
| `-f`, `--full-html`  | Generate full HTML document with header |
| `--html-title=TITLE` | Set document title (with `--full-html`) |
| `--html-css=URL`     | Add CSS link (with `--full-html`)       |

**ANSI output (`--format=ansi`):** Terminal-friendly output with ANSI escape codes for colors, bold, italic, underline, and other text styling.

**JSON output (`--format=json`):** Produces a Comark AST: `{"nodes":[...],"frontmatter":{...},"meta":{}}`. Each node is either a plain string (text) or a tuple array `[tag, props, ...children]`. Frontmatter YAML is parsed into the top-level `frontmatter` object. HTML comments are represented as `[null, {}, "comment body"]`.

## Code Generation Scripts

The `scripts/` directory contains generators for lookup tables compiled into the parser. The TypeScript generators below produce the legacy C tables; the Python generators (`_gen-tables-zig.py`, `_gen-entity-zig.py`) produce the Zig sources (`src/unicode_tables.zig`, `src/entity.zig`) used by the current build:

- `build-entity-map.ts` — Fetches [WHATWG entities.json](https://html.spec.whatwg.org/entities.json), generates `entity.c`
- `build-folding-map.ts` — Unicode case folding from `scripts/unicode/CaseFolding.txt`
- `build-punct-map.ts` — Unicode punctuation categories from `scripts/unicode/DerivedGeneralCategory.txt`
- `build-whitespace-map.ts` — Unicode whitespace classification
- `_unicode-map.ts` — Shared helper for punct/whitespace map generators

These are run manually when updating Unicode compliance (currently Unicode 15.1).

## Development Best Practices

### Idiomatic Zig conventions (parser internals)

The parser internals have been moved off several C-isms; follow these patterns
rather than reintroducing the old ones (all are internal-only — byte-for-byte
output stays frozen; the internal calling convention itself is being idiomatized
in Phase 4 of `PLAN.md`):

- **Growable arrays:** the seven typed `MD_CTX` growable arrays (`marks`, `containers`, `ref_defs`, `block_component_info`, `slot_info`, `block_alert_info`, `inline_attrs`) are `std.ArrayListUnmanaged(T)` backed by `c_allocator` — grow with `.append(c_allocator, …)` / `.ensureUnusedCapacity`, reset with `.clearRetainingCapacity()`, free with `.deinit(c_allocator)`, and index via `.items[i]` (bounds-checked) or `.items.ptr` only where raw pointer arithmetic is intrinsic (the emphasis engine's walking pointers). `containers`/`marks` depth is `ctx.nContainers()`/`ctx.nMarks()`. Do **not** reintroduce `n_*`/`alloc_*` count/capacity fields for these. Any _remaining_ `[*c]T` buffer still grows via `util.growArray(T, &ptr, &alloc, n, min)` — do not hand-write `if (n >= alloc) { … realloc … }` blocks (that idiom was deduplicated into one audited helper).
- **Raw byte arenas:** the heterogeneous byte arenas the parser reinterprets as typed records — the `block_bytes` block/line arena (kept `?*anyopaque` + `n_block_bytes`/`alloc_block_bytes`), the ref-def hashtable array, and the `MD_REF_DEF_LIST` flexible-array buckets — allocate through `ctx.alloc` via the `malloc`/`realloc`/`free`-shaped helpers `util.arena_alloc` / `arena_realloc` / `arena_free` (16-byte aligned, mirroring libc's `max_align_t` guarantee). The caller tracks the **exact** allocated byte length (the existing `alloc_*`/`*_size` fields) and passes it back to `arena_realloc`/`arena_free` — the std allocators validate that length, so a wrong length is a Debug crash. On OOM `arena_realloc` returns null and leaves the old block intact (libc-`realloc` semantics). Do **not** route these back through raw `std.c.malloc`. The hashtable indexes into `ctx.ref_defs`, so tear it down (`md_free_ref_def_hashtable`) **before** freeing `ref_defs` (`md_free_ref_defs`). The **typed** scratch buffers (`md_build_attribute`'s `text`/`substr_*`, `process.zig`'s `pipe_offs`/`align_arr`/code-`meta`) use the parallel `util.alloc_array_a` / `realloc_array_a` / `free_array_a` (`[*c]T` in/out, element-count tracked — same exact-length rule). Record any new buffer's length alongside it (e.g. `MD_ATTRIBUTE_BUILD.text_alloc`) so the matching free passes the exact count. `md_parse_highlights` (`det.code.highlights`) does this with a **shrink-to-fit** to `count` before returning, since `BlockCodeDetail` exposes `highlights` as a slice with no capacity — keep that shrink if you touch it. `ctx.buffer` (`md_temp_buffer`) is routed too (free length = `alloc_buffer`). The remaining libc allocations in the parser are the `md_merge_lines_alloc` buffers (ref-def label/title + merged autolink/link-label strings): they `c_allocator.alloc` `end-beg` but keep only the collapsed `*_size`, and some free via the `ptr_stack` (`md_mark_get_ptr` + `std.c.free`, no length). Routing them needs a shrink-to-fit plus a length-carrying `ptr_stack` free — a deliberate follow-on, not done yet.
- **Allocation failure:** OOM-only internal helpers return `error{OutOfMemory}` (e.g. `md_build_attribute`, the `md_push_*` / `md_add_mark` pushers). Use `try` / `catch`; do not invent new `-1`-on-OOM `c_int` returns for new OOM-only helpers.
- **Line arrays:** functions that scan a block's lines take a `[]const MD_LINE` slice (length via `.len`), not a `[*c]const MD_LINE` + separate `n_lines`. This bounds-checks the line access in Debug/ReleaseSafe builds.
- **Ctx accessors:** use the `MD_CTX` methods `ctx.ch(off)`, `ctx.str(off)`, `ctx.log(msg)`, and the offset-based char-class predicates `ctx.isWhitespace(off)` / `ctx.isNewline(off)` / `ctx.isAlnum(off)` / `ctx.isAnyOf(off, "...")` / `ctx.isUnicodeWhitespace(off)` … (not free `CH`/`STR`/`md_log`/`ISxxx(ctx, off)`). The pure `IS*_(ch)` helpers that take a raw `CHAR` (e.g. `util.ISWHITESPACE_`) stay free functions — they mirror md4c and are kept for upstream cross-reference.
- **Internal predicates** that are pure two-state return `bool` (e.g. the entity recognizers). Tri-state recognizers that also signal OOM still return `c_int` (`-1`/`0`/`N`).
- **Internal-only structs** (e.g. `MD_CONTAINER`) are plain `struct` (compiler-chosen layout). Keep `extern struct` ONLY where layout must mirror C: the `block_bytes` arena types (`MD_BLOCK`/`MD_LINE`/`MD_VERBATIMLINE`), `MD_MARK` (pointer-store trick), and `MD_REF_DEF`/`MD_REF_DEF_LIST`.
- **SAX detail types** (`Attribute`, `Block*Detail`, `Span*Detail` in `src/abi.zig`) are plain `struct`s with **slices** (`text`, `meta`, `highlights`, `raw_attrs`, `raw_props`, `title`, `substr_types`, `substr_offsets`) and `bool` for the two-state flags (`is_tight`, `is_task`, `is_autolink`). Slice lengths are **exact**: `substr_types.len == substr_count`, `substr_offsets.len == substr_count + 1`, and `Attribute.size()` is `text.len`. An absent value is the **empty slice** — do not reintroduce a nullable pointer or a parallel `*_size`/`*_count` field, and do not treat empty as meaningfully different from absent. Walk an `Attribute` with a bounded loop (`i < attr.substr_types.len and attr.substr_offsets[i] < attr.size()`), never a bare terminator walk.
- **Typed SAX callbacks:** the type codes are real Zig enums (`BlockType`, `SpanType`, `TextType`, `Align` — numeric values and declaration order frozen to the C enumerations they replaced), and the details reach callbacks only through the tagged unions `BlockDetail` / `SpanDetail`. A callback takes `(*const BlockDetail, ?*anyopaque)` — the type _is_ the active tag — and must resolve the payload with an exhaustive `switch (detail.*)` and a `|*d|` capture. Do **not** reintroduce a separate type parameter, a `?*anyopaque` detail, or an unchecked field access on the union. Detail-less types are `void` arms; `BlockDetail.default(ty)` materializes the arm for a runtime `BlockType` on the emission path. The em/strong/code/del/u spans always carry a `SpanAttrsDetail` whose **empty** `raw_attrs` means "no attributes" (the old "detail or null" split is gone — nothing distinguished the two).
- **`Parser`, not `MD_PARSER`:** the callback table is a plain Zig `struct` with no `abi_version`, no `syntax`, and no `MD_RENDERER` alias. `text` takes a `[]const u8`; `debug_log` takes a `[]const u8` (print it with `%.*s`, not `%s` — it is not NUL-terminated). Callbacks return `abi.CallbackResult` (`i32`), **not** an error union: the abort contract has to carry an arbitrary caller-chosen code through, and OOM must stay unified with `-1` (PLAN.md's deferred §8.2, resolved this way).
- **`MD_BLOCK.getType()` vs `typeIsRaw()`:** `getType()` decodes the stored byte with `@enumFromInt` and is only valid on a real block header. `md_analyze_line`'s two-blank-lines hack peeks at the tail of `block_bytes`, which may be an `MD_LINE` payload instead — use `typeIsRaw(.li)` there (a raw byte compare), never `getType()`, or an adversarial input turns into illegal behavior.
- **`export` / `callconv(.c)` only at real boundaries:** the internal entry points (`md_parse`, `md_html`/`md_html_ex`, `md_ast`, `md_ansi`, `md_text`, `md_markdown`, `md_meta`, `md_heal`, `entity_lookup`), the SAX callbacks, and the `process_output` sink are **plain Zig** — no `export`, no `callconv(.c)`. Do not add either back. They survive in exactly three places, all genuine boundaries: the **wasm exports** (`md4x_to_html`, `md4x_alloc`, …), the **napi** module registration and its registered callbacks, and the **`qsort`/`bsearch` comparators** in `refdefs.zig` that are handed to libc (constraint: glibc tie-break parity).
- **Abort-code contract (do not break):** `md_parse` propagates a NEGATIVE callback code verbatim but returns 0 for a POSITIVE one (md4c parity — see the abort-matrix native test in `md4x.zig`). OOM and a callback returning `-1` are intentionally unified as `-1` in the emission path; do not try to separate them.

Run the verification gate after any internal change: `bash scripts/diff-corpus.sh`
must diff-clean against the baseline, plus `zig build test`, the spec suites, and
the fuzzers (see Testing / Fuzzing).

### AST Renderer: Dynamic-Component Dispatch (formerly "Union Safety")

> **Zig-port note (current):** The Zig AST renderer (`src/renderers/md4x-ast.zig`) has **structurally retired** the two memory-safety failure modes below. `JsonNode.detail` is a **flat `Detail` struct** (one field per variant — see `md4x-ast.zig:107`), so union type-confusion is impossible. The node tree is **arena-allocated** (`JsonCtx.arena`; built during parse, serialized once, freed wholesale), so `jsonNodeFree` is a deliberate **no-op** (`md4x-ast.zig:226`) — there is no per-node free, hence no double-free. **The dispatch-order rule still applies for correctness:** `jsonWriteProps` / `jsonSerializeNode` check `tag_is_dynamic` (and switch on `tag_kind`) **before** any built-in-tag handling, so a dynamic component whose name collides with a built-in tag is still serialized via the component path (otherwise it reads the wrong flat-struct field). Do **not** "modernize" this into a `union(enum)`: that would reintroduce a discriminant to keep in sync, regressing the safety the flat struct already guarantees.

**Why the rule exists (historical, from the deleted `md4x-ast.c`):** the C renderer used a real `union` for type-specific detail data. **Dynamic components** (`tag_is_dynamic = 1`) always use the component variant and have a heap-allocated tag name; since a user can create a component with any name (e.g. `::alert{...}`, `::pre{...}`, `::a{...}`), the tag name may collide with a built-in static tag. Dispatching on the tag name before checking `tag_is_dynamic` therefore caused:

1. **Double-free** — the free path released the same union pointer via both the static-tag and the dynamic cleanup (heap corruption, OOB in WASM). _(N/A in the Zig port: arena alloc, no per-node free.)_
2. **Wrong serialization** — props were read as the wrong union type (e.g. interpreting `raw_props` as `alert.type_name`). _(In the Zig port this surfaces as reading the wrong flat-struct field — still prevented by the `tag_is_dynamic`-first rule.)_

### Memory Safety Patterns (Common Bug Classes)

Based on past bugs found via fuzzing in the original C implementation. Zig's bounds checks, optionals, and allocator length validation kill several of these outright in Debug/ReleaseSafe — but the **shipping artifacts are `ReleaseFast`**, where those checks are off, so the patterns still deserve review. **Check them when touching the parser/renderer internals:**

1. **Fixed-size stack buffers without overflow handling** — Every fixed-size array (e.g. `deferred_comp_closers[16]`, stack-allocated `MD_LINE` arrays) needs explicit bounds checking at every insertion point. Silent drops are as dangerous as overflows — they corrupt downstream state (e.g. `ctx->marks[-1]` OOB).

2. **Stale pointers after realloc** — Never cache pointers into growable buffers (`buf->data`, `ctx->comp_info`, etc.) across calls that may reallocate. Assign results immediately after each `realloc` before doing the next one. A double-realloc sequence where the first succeeds and the second fails can cause double-free if intermediate results aren't stored.

3. **Union type confusion with dynamic components** — See "AST Renderer: Dynamic-Component Dispatch" above. Historically the project's most recurring bug class in the C renderer. In the Zig port it is **structurally prevented** (flat `Detail` struct + arena alloc), but the `tag_is_dynamic`-first dispatch rule is still required for correct serialization — always resolve `tag_is_dynamic` / `tag_kind` before any built-in-tag handling.

4. **Unbalanced SAX callbacks** — Renderers must be defensive against unbalanced `enter`/`leave` callbacks from the parser. Always guard state transitions (stack pops, counter decrements) with the correct type check. Handle NULL `ctx->current` / stack underflow gracefully. Example: `jsonLeaveSpan` must only decrement `image_nesting` for `.img`, not all span types.

5. **Unchecked allocation** — Every allocation must handle failure. Use `error{OutOfMemory}` (or the documented null-return arena helpers) and propagate failures up; never ignore them. Silent OOM produces corrupted output, dropped props, or incomplete nodes.

6. **`unreachable` on adversarial paths** — In `ReleaseFast` (what ships) `unreachable` is UB, not a panic, so a wrong assertion is a silent miscompile rather than a debug message. Don't assert invariants that edge-case inputs can violate — prefer defensive guards.

7. **Uncapped user-controlled ranges** — Cap ranges from user input (e.g. highlight ranges `{1-99999}`) at reasonable limits to prevent excessive allocation.

**Audit checklist when reviewing changes:**

- Search for fixed-size arrays → verify bounds checks at every insertion
- Search for pointer caching across a realloc/`append` → verify no stale pointer use after buffer growth
- Audit tag-name dispatch in the AST renderer → verify `tag_is_dynamic` checked first
- Audit `leave_block`/`leave_span` callbacks → verify correct type guard and underflow handling
- Search for allocation sites → verify the failure path is handled, and that the freed length matches the allocated length exactly
- Search for `unreachable` → verify the condition cannot be violated by any input

### WASM Binary

The WASM binary (`packages/md4x/build/md4x.wasm`) is gitignored and must be rebuilt with `zig build wasm` after source changes. The `zig build wasm` step installs directly to `packages/md4x/build/`. Run `bun vitest run packages/md4x/test/wasm.test.mjs` to verify.

The `md4x/standalone` entry is a rolldown bundle (`packages/md4x/lib/standalone.mjs`, also generated + gitignored) with the **ReleaseSmall** binary (`zig build wasm-small`) embedded as gzip + Z85. The payload, the Z85 decoder, and the entry module are rolldown **virtual modules** defined in `scripts/build-standalone.ts` — they never exist on disk as source. It is also what `md4x` and `md4x/wasm` resolve to under the `browser` export condition, so bundlers get a self-contained module with no `.wasm` asset. `init()` inflates via `node:zlib` when `process.getBuiltinModule` exists (~4x faster cold start on Node than `DecompressionStream`) and falls back to `DecompressionStream` in browsers — both paths are covered by `test/standalone.test.mjs`. Rebuild it whenever the WASM is rebuilt:

```sh
bun run build:standalone        # zig build wasm-small && bun scripts/build-standalone.ts
bun vitest run packages/md4x/test/standalone.test.mjs
```

### Adding New Block/Span Types

When adding a new block or span type with its own detail struct:

1. Add the enum member to `BlockType`/`SpanType` **at the end** (the ordinals are frozen), the detail struct to `src/abi.zig`, the matching arm to `BlockDetail`/`SpanDetail` (same name, same position), and a field for it to the flat `Detail` struct in `src/renderers/md4x-ast.zig`
2. Handle it in `jsonEnterBlock`/`jsonEnterSpan` (build the node). Every renderer's `switch (detail.*)` is exhaustive, so the compiler will list the sites that need an arm
3. Handle it in `jsonWriteProps` (serialize props) — place **after** the `tag_is_dynamic` check
4. If needed, handle it in `jsonSerializeNode` (special child rendering)
5. Update all three renderers (HTML, AST, ANSI) and the CLI
6. Add a test suite in `test/spec-*.txt` and update `scripts/run-tests.ts`
7. Add JS binding tests in `packages/md4x/test/_suite.mjs`
8. Rebuild WASM with `zig build wasm` and run `bun vitest run packages/md4x/test/wasm.test.mjs`

## Detailed Reference

@docs/parser-api.md
@docs/renderers.md
@docs/js-bindings.md
@docs/markdown-syntax.md
