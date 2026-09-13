# Testing & Fuzzing

```sh
bun scripts/run-tests.ts                          # everything: JS artifact build + zig unit tests + .txt suites + pathological + vitest
zig build test                                    # Zig unit tests (ReleaseSafe)
zig build test -Doptimize=Debug                   # + undefined-fill and allocator length validation
python3 test/run-testsuite.py -s test/spec.txt -p zig-out/bin/md4x
python3 test/pathological-tests.py -p zig-out/bin/md4x
bunx vitest run                                   # JS bindings only (napi, wasm, standalone)
bun run build:js                                  # rebuild what the JS suites load
```

Suite format: Markdown examples with a `.` separator and expected HTML. The runner pipes input
through `md4x` and compares normalized output.

Suites: `spec.txt`, `spec-tables.txt`, `spec-strikethrough.txt`, `spec-tasklists.txt`,
`spec-latex-math.txt`, `spec-permissive-autolinks.txt`,
`spec-soft-breaks.txt`, `spec-underline.txt`, `spec-frontmatter.txt`, `spec-components.txt`,
`spec-attributes.txt`, `spec-alerts.txt`, `spec-highlight.txt`, `spec-footnotes.txt`,
`spec-markdown.txt`, `spec-binding.txt`, `spec-jsx.txt`,
`regressions.txt`, `coverage.txt`.

Both `bun scripts/run-tests.ts` and `.github/workflows/ci.yml` run the Zig unit tests on every PR.
CI additionally smoke-runs `zig build fuzz-zig` (see [Fuzzing](#fuzzing)); it does **not** run
`scripts/diff-corpus.sh`, which stays a local gate.

## The JS suites cannot run against a stale or foreign artifact

`packages/md4x/build/*` and `packages/md4x/lib/standalone.mjs` are **gitignored build outputs**, and
`md4x/napi` / `md4x/wasm` / `md4x/standalone` load whatever is sitting there. Two things used to go
wrong silently, both observed in this repo:

- **Stale** — a fix lands in `src/`, the suite (or a bench) runs against yesterday's `.node`, and the
  fix looks like it did not work. Nothing warns; the suite is green on old bytes.
- **Shadowed** — a `node_modules/md4x` (the _published_ package) on the resolution path. Test files
  inside `packages/md4x/` are saved by package self-reference, but any script at the repo root
  imports the published tarball instead of this checkout, successfully and silently.

`scripts/js-artifacts.ts` closes both, wired in as the vitest `globalSetup` (`vitest.config.mjs`):

- **Freshness** — each artifact's mtime against the newest file in `src/`, `build.zig` and
  `build.zig.zon` (and, for `standalone.mjs`, against `md4x-small.wasm`, `scripts/build-standalone.ts`,
  `lib/wasm/common.mjs`, `lib/_shared.mjs`). Only the **host** NAPI target is checked — the suites
  never dlopen the other eight.
- **Shadowing** — no `node_modules/md4x` on the resolution path that is not this workspace package.
- `packages/md4x/test/provenance.test.mjs` additionally asserts that each bare specifier yields the
  _same module instance_ as the local file behind it, so a bundler alias or a renamed package.json
  cannot quietly redirect the suite.

It **fails rather than rebuilding**: an auto-rebuild inside a test runner hides which artifact was
stale and can swap a binary out from under someone mid-bisect. The message names the artifact, the
source file that outran it, and the exact command. The fix-it path is:

```sh
bun run build:js     # wasm + wasm-small + host NAPI + standalone
bun run check:js     # just report, exit 1 if anything is off
```

`bun scripts/run-tests.ts` **does** build them first (it owns the whole pipeline) and then runs
vitest itself, so the one-command gate stays one command. `build:js` also stamps the artifacts'
mtimes after a successful build: Zig's install step skips the copy when its content-addressed cache
already matches, which would otherwise strand a source file that was touched without a content
change.

## The test artifact is pinned to a safe optimize mode

`build.zig` pins it: `.optimize = if (optimize == .Debug) .Debug else .ReleaseSafe`, independently of
the global `-Doptimize` default of `.ReleaseFast` the shipping artifacts use. Bounds checks,
`@intCast` range checks, overflow checks and `unreachable` panics are what make the OOM sweep's
"never a crash" assertion mean anything — under `ReleaseFast` it degrades to "no hard segfault".
**Do not hand the global `optimize` to the test artifact.** The pin is self-checking: the
`test artifact is built with runtime safety armed` case asserts `std.debug.runtime_safety`.

## Parser invariants the HTML-diff suites cannot express

Covered by Zig unit tests in `src/md4x.zig`:

- **Abort matrix** — for each of the five SAX callbacks, a negative code propagates verbatim and a
  positive one stops emission but returns 0. Plus the **doc-level exception**: `md_process_doc`'s own
  bookends test `!= 0`, not `< 0`, so a callback aborting on the `.doc` block propagates **both**
  signs verbatim (`md_parse` returns `5` for a `+5`, `-7` for a `-7`). That is md4c parity — do not
  "fix" those two `!= 0` tests into `< 0`, and keep the doc-level cases, the only guard either way.
- **OOM sweep** — a `FailingAllocator` walks every internal allocation index over a document
  exercising ref-defs, tables, code metadata, attributes, components and autolinks, asserting each
  run is crash- and leak-free. The document carries a link title with 15 substrings, the only thing
  driving `md_build_attr_append_substr` past its initial capacity of 8 — keep it.
- **Golden SAX event trace** — the full ordered `enter_block`/`leave_block`/`enter_span`/`leave_span`/
  `text` stream over a document covering every block, span and text type, with each detail union
  arm's field values and every `Attribute`'s substring table spelled out. The corpus harness only
  compares each renderer's final bytes, so it can miss a detail-packaging change renderers paper
  over; this compares the raw SAX stream instead. **Treat a trace diff as a stop-the-line
  regression.** The expected value is a _recorded_ baseline: to re-record after a deliberate change,
  temporarily `std.debug.print` `probe.out.items` from the test and say in the commit message what
  changed and why.

## Fuzzing

`src/fuzz.zig` / `zig build fuzz-zig` is the only harness. It `@import`s the parser + renderer
sources directly, so Zig's fuzzer instruments the library and steers by **real coverage of the Zig
internals**. No ASan/UBSan — it relies on Zig runtime safety checks (the artifact is `ReleaseSafe`).

```sh
zig build fuzz-zig                    # smoke-run each harness once (+ parser unit tests)
zig build fuzz-zig --fuzz             # coverage-guided (serves a local web UI)
zig build fuzz-zig --fuzz -- md_html  # a single named test
```

Covers `md_parse` (no-op SAX callbacks), the six renderers, and `md_heal`. Inputs are gated to valid,
NUL-free UTF-8, matching the JS binding surface. libyaml is linked for the html/ast/meta paths but is
not instrumented.

Seed corpus at `test/fuzzers/seed-corpus/` (CommonMark, GFM, LaTeX math, frontmatter,
components, attributes, alerts, code block metadata, heal edge cases) is shared with
`scripts/diff-corpus.sh`.

## Verification gate

Run after any internal change:

```sh
bash scripts/diff-corpus.sh    # must diff-clean against the baseline
zig build test
bun scripts/run-tests.ts       # rebuilds the JS artifacts, then runs every suite incl. vitest
zig build fuzz-zig
```
