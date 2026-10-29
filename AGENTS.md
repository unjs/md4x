# MD4X

> Markdown parser library (Zig port of [mity/md4c](https://github.com/mity/md4c))

## Guides

| Area                                                 | Read when                                                                                      |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| [.agents/build.md](.agents/build.md)                 | Building, targets, module graph rules                                                          |
| [.agents/testing.md](.agents/testing.md)             | Running tests, fuzzing, the parser invariants only unit tests pin                              |
| [.agents/conventions.md](.agents/conventions.md)     | Touching parser or renderer internals                                                          |
| [.agents/safety.md](.agents/safety.md)               | Reviewing changes — bug classes and the audit checklist                                        |
| [.agents/performance.md](.agents/performance.md)     | Byte scans, SIMD, libc, benchmarking                                                           |
| [.agents/extending.md](.agents/extending.md)         | Adding a block/span type, a renderer, or regenerating tables                                   |
| [.agents/upstream-sync.md](.agents/upstream-sync.md) | Syncing with mity/md4c — ledger of reviewed commits, do-not-port decisions                     |
| [.agents/github-parity.md](.agents/github-parity.md) | Changing output — md4x has one dialect, measured against GitHub; parity baseline and not-goals |
| [docs/parser-api.md](docs/parser-api.md)             | SAX callback table, detail types, parser flags                                                 |
| [docs/renderers.md](docs/renderers.md)               | Renderer entry points and their flags                                                          |
| [docs/js-bindings.md](docs/js-bindings.md)           | WASM / standalone / NAPI targets and the JS package API                                        |
| [docs/markdown-syntax.md](docs/markdown-syntax.md)   | Supported syntax and extensions                                                                |
| [docs/compatibility.md](docs/compatibility.md)       | How the default preset scores against CommonMark, GitHub and Comark — matrix and known bugs    |

## Quick start

```sh
zig build                       # all artifacts (ReleaseFast); CLI at zig-out/bin/md4x
bun run build:js                # wasm + host NAPI + standalone (what the JS suites load)
bun scripts/run-tests.ts        # full test suite (does build:js itself, then runs vitest)
bash scripts/diff-corpus.sh     # output-parity gate — must diff-clean after any internal change
bun scripts/gh-parity.ts        # GitHub parity vs the committed baseline (needs a token)
bun fmt
```

## Project Structure

```
src/
  lib.zig             # Library root: parser + entity + all renderers in ONE module
  md4x.zig            # Parser root (md_parse) + parser unit tests
  abi.zig             # Shared types/enums/flags, detail unions, Parser (types only, leaf)
  parser/
    types.zig         # MD_CTX + internal structs, enums
    util.zig          # char/UTF-8/unicode helpers, buffers, entity recognizers, attributes
    refdefs.zig       # ref-def dictionary + link/autolink recognizers
    inlines.zig       # inline mark engine (emphasis mod-3) + span/text emission
    blocks.zig        # line classification + container/block analysis
    process.zig       # block-content processing + md_process_doc
  scan.zig            # Vectorized byte scan shared by parser + renderers
  unicode_tables.zig  # Generated: case folding, punct, whitespace
  entity.zig          # Generated: HTML entity lookup table
  md4x-wasm.zig       # WASM exports (alloc/free + renderer wrappers)
  md4x-napi.zig       # Node.js NAPI addon
  fuzz.zig            # Zig-native coverage-instrumented fuzz harness
  renderers/
    md4x-props.zig    # Shared component property parser
    md4x-json.zig     # Shared JSON writer + YAML-to-JSON + md_yaml entry point
    md4x-diag.zig     # Shared debug-sink stderr write (the only portable `stderr`)
    md4x-slug.zig     # Shared heading text + GitHub-compatible heading slugs
    md4x-highlight.zig # Shared per-code-block syntax-highlight hook (HTML + ANSI)
    md4x-{html,ast,ansi,meta,text,markdown}.zig
    md4x-heal.zig     # Markdown heal/completion utility (no parser dependency)
  cli/
    md4x-cli.zig      # CLI driver (html, text, json, ansi, markdown, heal)
    md4x.1            # Man page
packages/md4x/        # npm package — build/ (wasm + .node), lib/, test/, bench/
test/
  spec.txt            # CommonMark 0.31.2
  spec-*.txt          # Per-extension suites
  regressions.txt     # Bug regression tests
  gh-parity.baseline.json # GitHub parity baseline, per-divergence causes
  coverage.txt        # Code coverage tests
  run-testsuite.py    # Individual suite runner
  pathological-tests.py, prog.py, prog-tests.py, normalize.py
  fuzzers/            # seed-corpus/ + corpus/
scripts/
  run-tests.ts        # Main test runner (builds JS artifacts, then every suite incl. vitest)
  js-artifacts.ts     # Build/freshness/provenance guard for the gitignored JS artifacts
                      #   (vitest globalSetup — see vitest.config.mjs)
  diff-corpus.sh      # Output-parity harness (sha256 of all 6 formats over the corpus)
  build-standalone.ts # Bundles lib/standalone.mjs (rolldown, gzip+Z85 inlined wasm)
  wasm-size.ts        # WASM size analyzer — sections, per-function/module code, data tables
  upstream-sync.ts    # Lists md4c commits newer than .agents/upstream-sync.json
  gh-parity.ts        # GitHub Markdown parity harness (see .agents/github-parity.md)
  _gen-*.py           # Zig table generators (unicode, entities)
  build-*.ts          # Legacy C table generators
  unicode/            # Unicode data files
website/              # Docs + playground (Vite + Vue) — pages/, components/, samples/
build.zig, build.zig.zon
vitest.config.mjs     # globalSetup: the JS artifact freshness/provenance guard
.github/workflows/    # ci.yml: build + test (ubuntu-latest, ReleaseSafe + Debug) + Pages deploy
                      # release.yml: build + test + npm publish on tags
```
