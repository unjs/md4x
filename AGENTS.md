# MD4X

> **Always keep this file (`AGENTS.md`) and referenced `docs/*.md` files updated when making changes to the project.**
> **Always update `CHANGELOG.md` when adding removing user-facing features, APIs, build targets, CLI options, or library behavior.**

> Markdown parser library (Zig port of [mity/md4c](https://github.com/mity/md4c))

- **Version:** 0.5.2 (next: 0.5.3 WIP)
- **License:** MIT
- **Language:** Zig (port of the original C parser, with a stable C ABI; ABI headers + CLI driver remain C)
- **Spec:** CommonMark 0.31.2
- **Build:** Zig (`zig build`)
- **JS Runtime:** Bun (do **not** use npm, pnpm, yarn, or npx — use `bun`/`bunx` exclusively)
- **Formatting:** Always run `bun fmt` after finishing code changes

> **Implementation note:** The entire library (parser, all renderers, entity table, and wasm/napi glue) was migrated from C to Zig for memory safety. The C ABI is preserved unchanged and output is byte-for-byte identical to the original C implementation. The public ABI headers (`.h` files) and the CLI driver (`src/cli/*.c`) intentionally remain C.

## Project Structure

```
src/
  md4x.zig            # Parser root (exports md_parse; imports src/parser/ modules)
  md4x.h              # Parser public API (C ABI header, retained)
  parser/             # Parser implementation, split from the monolithic md4x.zig
    types.zig         # MD_CTX + internal structs, enums, shared @cImport
    util.zig          # char/UTF-8/unicode helpers, buffers, entity recognizers, attributes
    refdefs.zig       # ref-def dictionary + link/autolink/wiki recognizers
    inlines.zig       # inline mark engine (emphasis mod-3) + span/text emission
    blocks.zig        # line classification + container/block analysis
    process.zig       # block-content processing + md_process_doc
  unicode_tables.zig  # Generated Unicode tables (case folding, punct, whitespace)
  entity.zig           # HTML entity lookup table (generated)
  entity.h             # Entity header (C ABI, retained)
  md4x-wasm.zig        # WASM exports (alloc/free + renderer wrappers)
  md4x-napi.zig        # Node.js NAPI addon (module registration + renderer wrappers)
  renderers/
    md4x-props.zig     # Shared component property parser (Zig module)
    md4x-json.zig      # Shared JSON writer + YAML-to-JSON helpers (Zig module)
    md4x-html.zig      # HTML renderer library
    md4x-html.h        # HTML renderer public API (C ABI, retained)
    md4x-ast.zig      # AST renderer library
    md4x-ast.h        # AST renderer public API (C ABI, retained)
    md4x-ansi.zig      # ANSI terminal renderer library
    md4x-ansi.h        # ANSI renderer public API (C ABI, retained)
    md4x-meta.zig      # Meta renderer library
    md4x-meta.h        # Meta renderer public API (C ABI, retained)
    md4x-text.zig      # Plain text renderer library
    md4x-text.h        # Plain text renderer public API (C ABI, retained)
    md4x-markdown.zig  # Markdown renderer library
    md4x-markdown.h    # Markdown renderer public API (C ABI, retained)
    md4x-heal.zig      # Markdown heal/completion utility
    md4x-heal.h        # Heal utility public API (C ABI, retained)
  cli/
    md4x-cli.c           # CLI utility driver (C, multi-format: html, text, json, ansi, markdown, heal)
    cmdline.c            # Command-line parser (C, from c-reusables)
    cmdline.h            # Command-line parser API
    md4x.1               # Man page
packages/md4x/           # npm package
  package.json           # Package manifest (name: md4x)
  README.md              # Package README
  LICENSE.md             # MIT license
  build/
    md4x.wasm            # Prebuilt WASM binary
    md4x.*.node          # Prebuilt NAPI binaries (per-platform)
  lib/
    wasm.mjs             # JS entrypoint for WASM (async API, ESM)
    wasm.d.mts           # TypeScript declarations for WASM API
    napi.mjs             # JS entrypoint for NAPI (sync API, ESM)
    napi.d.mts           # TypeScript declarations for NAPI API
    types.d.ts           # Shared TypeScript types (ComarkTree, ComarkNode, ComarkElement, etc.)
  test/
    _suite.mjs           # Shared test suite (vitest, used by both NAPI and WASM tests)
    napi.test.mjs        # NAPI binding tests
    wasm.test.mjs        # WASM binding tests
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
  fuzzers/             # LibFuzzer harnesses (html, ast, ansi, text, meta, heal)
    build.sh           # Build script for all fuzzers (clang + sanitizers)
    seed-corpus/       # Seed inputs (commonmark, gfm, frontmatter, components, etc.)
scripts/
  run-tests.ts            # Main test runner (runs all suites)
  diff-corpus.sh          # Output-parity harness (sha256 of all 6 renderer formats over the corpus)
  build-entity-map.ts     # Generates entity.c from WHATWG spec
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

Outputs to `zig-out/` (`bin/md4x`, `lib/libmd4x*.a`, `include/md4x*.h`).

The project can also be consumed as a Zig package dependency via `build.zig.zon`.

`build.zig` compiles each Zig unit (parser, renderers, entity table) as a static library via the `addParserLib`/`addEntityLib`/`addZigRenderer` helpers, then links them into the CLI executable, the WASM target, and the NAPI targets. The CLI driver and command-line parser are still compiled from C (`src/cli/*.c`), and the WASM and NAPI roots are the Zig glue files (`src/md4x-wasm.zig`, `src/md4x-napi.zig`). The WASM JS loader (`packages/md4x/lib/wasm/common.mjs`) provides no-op `args_`/`environ_` WASI import stubs that Zig's `wasm32-wasi` startup references.

Produces a set of static libraries, one executable, and optional WASM/NAPI targets:

- **libmd4x** — Parser library (compiled with `-DMD4X_USE_UTF8`)
- **libmd4x-html** — HTML renderer (links against libmd4x)
- **libmd4x-ast** — AST renderer (links against libmd4x)
- **libmd4x-ansi** — ANSI terminal renderer (links against libmd4x)
- **libmd4x-meta** — Meta renderer (links against libmd4x)
- **libmd4x-text** — Plain text renderer (links against libmd4x)
- **libmd4x-markdown** — Markdown renderer (links against libmd4x)
- **libmd4x-heal** — Markdown heal/completion utility (standalone, no parser dependency)
- **md4x** — CLI utility (supports `--format=html|text|json|ansi|markdown|heal`)
- **md4x.wasm** — WASM library (`zig build wasm`, output: `packages/md4x/build/md4x.wasm`)
- **md4x.{platform}-{arch}[-musl].node** — Cross-compiled NAPI addons (`zig build napi-all`, 9 targets)

Compiler flags: `-Wall -Wextra -Wshadow -Wdeclaration-after-statement -O2`

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

The HTML-diff suites cannot express parser-internal behavior (e.g. SAX callback return-code handling); those invariants are covered by Zig unit tests in `src/md4x.zig`, run via `zig build test`.

Test suites: `spec.txt`, `spec-tables.txt`, `spec-strikethrough.txt`, `spec-tasklists.txt`, `spec-wiki-links.txt`, `spec-latex-math.txt`, `spec-permissive-autolinks.txt`, `spec-hard-soft-breaks.txt`, `spec-underline.txt`, `spec-frontmatter.txt`, `spec-components.txt`, `spec-attributes.txt`, `spec-alerts.txt`, `spec-markdown.txt`, `regressions.txt`, `coverage.txt`

## Fuzzing

LibFuzzer harnesses for all renderers and the heal utility. Requires clang with LibFuzzer and libyaml.

```sh
# Build & run a fuzzer (builds automatically, 60s default):
./test/fuzzers/run.sh html                        # html fuzzer, 60s, 1 core
./test/fuzzers/run.sh ast --timeout 300           # ast fuzzer, 300s
./test/fuzzers/run.sh heal --cores 4              # heal fuzzer, 4 cores
./test/fuzzers/run.sh html --cores 4 --timeout 0  # html fuzzer, forever, 4 cores

# Build all fuzzers (without running):
./test/fuzzers/build.sh

# Build a single fuzzer:
./test/fuzzers/build.sh html    # or: ast, ansi, text, meta, heal
```

Output goes to `fuzz-out/` (gitignored). Environment variables: `CC` (compiler, default: `clang`), `SANITIZERS` (default: `fuzzer,address,undefined`), `FUZZ_OUT_DIR` (output dir).

**Harnesses:**

| Harness             | Target          | Notes                                                 |
| ------------------- | --------------- | ----------------------------------------------------- |
| `fuzz-mdhtml.c`     | `md_html()`     | HTML renderer + libyaml                               |
| `fuzz-mdast.c`      | `md_ast()`      | AST renderer (in-memory tree, libyaml) — highest risk |
| `fuzz-mdansi.c`     | `md_ansi()`     | ANSI terminal renderer                                |
| `fuzz-mdtext.c`     | `md_text()`     | Plain text renderer                                   |
| `fuzz-mdmeta.c`     | `md_meta()`     | Metadata extractor + libyaml                          |
| `fuzz-mdmarkdown.c` | `md_markdown()` | Markdown renderer                                     |
| `fuzz-mdheal.c`     | `md_heal()`     | Heal utility (no flags, no parser dependency)         |

All harnesses reject invalid UTF-8 input (returning `-1` to steer the fuzzer toward valid inputs), matching the JS binding surface where input is always a valid UTF-8 string. Seed corpus in `test/fuzzers/seed-corpus/` covers: CommonMark, GFM, LaTeX math, wiki links, frontmatter, components, attributes, alerts, underline, code block metadata, and heal edge cases.

## `md4x` CLI

```sh
md4x [OPTION]... [FILE]
# Reads from stdin if no FILE given
```

**General options:**

| Option                  | Description                                                     |
| ----------------------- | --------------------------------------------------------------- |
| `-o`, `--output=FILE`   | Output file (default: stdout)                                   |
| `-t`, `--format=FORMAT` | Output format: `html` (default), `text`, `json`, `ansi`, `heal` |
| `-s`, `--stat`          | Measure parsing time                                            |
| `-h`, `--help`          | Display help                                                    |
| `-v`, `--version`       | Display version                                                 |

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

### AST Renderer: Union Safety with Dynamic Components

The AST renderer (`md4x-ast.c`) uses a `JSON_NODE` struct with a C union for type-specific detail data. **Dynamic components** (`tag_is_dynamic = 1`) always use `detail.component` and have a heap-allocated tag name. Since a user can create a component with any name (e.g. `::alert{...}`, `::pre{...}`, `::a{...}`), the tag name may collide with built-in static tags.

**Critical rule:** In `json_node_free`, `json_write_props`, and `json_serialize_node`, always check `node->tag_is_dynamic` **before** any `strcmp(node->tag, ...)` dispatch. If dynamic, use the component code path exclusively — never fall through to static tag handlers. Violating this causes:

1. **Double-free** — `json_node_free` frees the same union pointer via both the static tag cleanup and the dynamic cleanup (heap corruption, OOB in WASM)
2. **Wrong serialization** — `json_write_props` reads the union as the wrong type (e.g. interprets `raw_props` pointer as `alert.type_name`)

### Memory Safety Patterns (Common Bug Classes)

Based on past bugs found via fuzzing. **Check these patterns when modifying C code or reviewing for vulnerabilities:**

1. **Fixed-size stack buffers without overflow handling** — Every fixed-size array (e.g. `deferred_comp_closers[16]`, stack-allocated `MD_LINE` arrays) needs explicit bounds checking at every insertion point. Silent drops are as dangerous as overflows — they corrupt downstream state (e.g. `ctx->marks[-1]` OOB).

2. **Stale pointers after realloc** — Never cache pointers into growable buffers (`buf->data`, `ctx->comp_info`, etc.) across calls that may reallocate. Assign results immediately after each `realloc` before doing the next one. A double-realloc sequence where the first succeeds and the second fails can cause double-free if intermediate results aren't stored.

3. **Union type confusion with dynamic components** — See "AST Renderer: Union Safety" above. Always check `tag_is_dynamic` before `strcmp(node->tag, ...)`. This is the project's most recurring bug class.

4. **Unbalanced SAX callbacks** — Renderers must be defensive against unbalanced `enter`/`leave` callbacks from the parser. Always guard state transitions (stack pops, counter decrements) with the correct type check. Handle NULL `ctx->current` / stack underflow gracefully. Example: `json_leave_span` must only decrement `image_nesting` for `MD_SPAN_IMG`, not all span types.

5. **Unchecked `malloc`/`realloc`** — Every allocation must be checked for NULL. Use error flags on growable buffers and propagate failures up. Silent OOM produces corrupted output, dropped props, or incomplete nodes.

6. **Assertions as `__builtin_unreachable()`** — With UBSan, `MD_ASSERT` compiles to `__builtin_unreachable()`, so a wrong assertion is a crash, not a debug message. Don't assert invariants that edge-case inputs can violate — prefer defensive guards.

7. **Uncapped user-controlled ranges** — Cap ranges from user input (e.g. highlight ranges `{1-99999}`) at reasonable limits to prevent excessive allocation.

**Audit checklist when reviewing C changes:**

- Search for fixed-size arrays → verify bounds checks at every insertion
- Search for pointer caching across realloc → verify no stale pointer use after buffer growth
- Audit `strcmp(node->tag, ...)` dispatch → verify `tag_is_dynamic` checked first
- Audit `leave_block`/`leave_span` callbacks → verify correct type guard and underflow handling
- Search for unchecked `malloc`/`realloc` → every allocation needs NULL check
- Search for `MD_ASSERT` → verify condition cannot be violated by any input

### WASM Binary

The WASM binary (`packages/md4x/build/md4x.wasm`) is gitignored and must be rebuilt with `zig build wasm` after C source changes. The `zig build wasm` step installs directly to `packages/md4x/build/`. Run `bun vitest run packages/md4x/test/wasm.test.mjs` to verify.

### Adding New Block/Span Types

When adding a new block or span type with its own detail struct:

1. Add the detail struct to the `JSON_NODE` union in `md4x-ast.c`
2. Handle it in `json_enter_block`/`json_enter_span` (build the node)
3. Handle it in `json_write_props` (serialize props) — place **after** the `tag_is_dynamic` check
4. Handle it in `json_node_free` (free heap strings) — place **after** the `tag_is_dynamic` check
5. If needed, handle it in `json_serialize_node` (special child rendering)
6. Update all three renderers (HTML, AST, ANSI) and the CLI
7. Add a test suite in `test/spec-*.txt` and update `scripts/run-tests.ts`
8. Add JS binding tests in `packages/md4x/test/_suite.mjs`
9. Rebuild WASM with `zig build wasm` and run `bun vitest run packages/md4x/test/wasm.test.mjs`

## Detailed Reference

@docs/parser-api.md
@docs/renderers.md
@docs/js-bindings.md
@docs/markdown-syntax.md
