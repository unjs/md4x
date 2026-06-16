# C → Zig Progressive Migration

Goal: progressively migrate MD4X source from C to Zig for safety (and where possible speed),
without ever breaking the full original test suite. One unit at a time; each unit is verified
for byte-parity, then independently validated for memory-safety/bugs by a background agent.

## Invariants (must hold after every step)

- `zig build` exits 0
- `zig build wasm` exits 0 (rewrites `packages/md4x/build/md4x.wasm`)
- `bun scripts/run-tests.ts` exits 0 — **baseline:** all 16 suites pass (spec.txt 652) + 30 pathological
- `bunx vitest run packages/md4x/test/` — **baseline:** 616 passed, 6 skipped (napi 310, wasm 312)
- Public C ABI headers unchanged (`md4x.h`, `md4x-*.h`)
- `bun fmt` clean
- No new memory leaks / UB (validated via fuzzers + ASan/UBSan + differential fuzzing vs the original C, retrieved from git)

## Order (leaf → core; renderers before parser)

| #   | Unit                                                           | File                                 | Status                    |
| --- | -------------------------------------------------------------- | ------------------------------------ | ------------------------- |
| 1   | heal (standalone, no deps)                                     | `src/renderers/md4x-heal.c` → `.zig` | ✅ DONE (validated clean) |
| 2   | text renderer                                                  | `src/renderers/md4x-text.c`          | ✅ DONE (validated clean) |
| 3   | meta renderer (+libyaml interop)                               | `src/renderers/md4x-meta.c`          | ✅ DONE (validated clean) |
| 4   | ast renderer (tagged-union safety win)                         | `src/renderers/md4x-ast.c`           | ✅ DONE (validated clean) |
| 5   | ansi renderer                                                  | `src/renderers/md4x-ansi.c`          | ✅ DONE (validated clean) |
| 6   | markdown renderer                                              | `src/renderers/md4x-markdown.c`      | ✅ DONE (validated clean) |
| 7   | html renderer                                                  | `src/renderers/md4x-html.c`          | ✅ DONE (validated clean) |
| 8   | shared utils (props.h / json.h)                                | `src/renderers/*.h`                  | ⬜                        |
| 9   | entity table (comptime-generated)                              | `src/entity.c`                       | ✅ DONE (value-identical, 19.5k diff + spec) |
| 10  | **core parser** (8047 LoC → `md4x.zig` 7453 LoC)               | `src/md4x.c`                         | ✅ MIGRATED & INTEGRATED · 🔬 validating (A–E all 0-diff; gate green; 972k-cmp differential 0 div) |

## Per-step protocol

1. Subagent ports the unit to Zig, keeps the C-ABI export, wires `build.zig`, deletes the `.c`.
2. Run the **full original** test suite + JS bindings; must match baseline exactly.
3. Background validator agent: differential-fuzz Zig vs original C (`git show HEAD:<file>`),
   run the unit's libFuzzer harness under ASan/UBSan, and code-review for leaks/UB/bugs.
4. Only advance to the next unit once validation comes back clean.

## Interop notes

- Build already compiles mixed C/Zig in one artifact (`zig build`, Zig 0.16, `link_libc`).
- Zig exports use `export fn ... callconv(.c)`; Zig→C calls via `@cImport`.
- Use `std.heap.c_allocator` so C and Zig share malloc/free safely (esp. the WASM result buffer).
- The "not null-terminated, use the size" C convention maps to Zig slices `[]const u8`.

## Log

- 🏁🏁 **CORE PARSER MIGRATED & INTEGRATED ON MAIN.** `src/md4x.c` (8047 LoC) → `src/md4x.zig` (7453 LoC) via a 5-pass port (A foundation → B ref-defs/links → C inline engine → D block analysis → E glue+cutover), each pass 0-diff unit-verified. `build.zig` swaps the C parser for `addParserLib`; `md4x.c` removed. Full gate green on main: build/wasm/napi 0, run-tests all 16 suites (spec.txt 652) + 30 pathological (linear/DoS-safe), JS 616/6. Pass E differential: 194,430 inputs × 5 formats = ~972k comparisons, **0 divergences** vs the fixed C parser. **The whole library (parser + 7 renderers + entity) is now Zig** — only `src/md4x-wasm.c` + `src/md4x-napi.c` (thin ABI glue) remain C. Parser memory-safety validator running. Remaining optional: step 8 (dedup per-renderer props/json into a shared Zig module + delete orphaned `md4x-props.h`/`md4x-json.h`), migrate glue, fix `test/fuzzers/build.sh` (still references deleted `.c`).
- ✅✅ **MILESTONE: all 7 renderers + entity table migrated to Zig, integrated on main, and INDEPENDENTLY VALIDATED CLEAN** (heal, text, markdown, ansi, meta, ast, html — each: zero leaks via valgrind, zero UB via Zig Debug safety + ASan/UBSan, byte-for-byte parity vs original C over collectively millions of differential/fuzz inputs). main green at every gate (spec.txt 652, JS 616/6). Remaining C: `src/md4x.c` (parser, multi-pass port in progress), wasm/napi glue (optional). Validators independently corroborated + my fix landed for the one real pre-existing parser bug.
- Baseline established & green (build, wasm, run-tests EXIT 0, JS 616/6 skipped).
- **heal** ported to `md4x-heal.zig` (c_allocator, wrapping arithmetic to match C unsigned). build.zig: `addHealZig` static lib linked into exe/wasm/napi. Gate re-verified independently: build 0, run-tests 0, JS 616/6. Migration agent's differential fuzz (5001 random + corpus + prefixes) = 0 divergences. Background validation in progress.
- ⚠️ Known follow-up: `test/fuzzers/build.sh` + heal fuzzer still reference the deleted `md4x-heal.c` (7 refs) — must relink the Zig static lib.
- **heal VALIDATED CLEAN**: code review (no leaks/OOB/UB), valgrind 0 errors, ~96k differential inputs vs original C = 0 divergence, 42.8M libFuzzer execs 0 crashes.
- Parallelization model: migrations run sequentially on the **main tree** (build.zig chains); each step's **validator runs in an isolated worktree** (own `.zig-cache`/`zig-out`, original C via `git show HEAD:<file>`, new `.zig` seeded by copy) so the next migration never corrupts validation. Built-in worktree isolation can't be used (no local `origin/main`); worktrees created manually off local `main`.
- **text** renderer ported to `md4x-text.zig` (600 LoC; `@cImport` of md4x.h/md4x-heal.h/entity.h to call the C parser, supports HEAL). `build.zig`: `addTextZig` static lib (with src include paths) linked into exe/wasm/napi. Gate re-verified on main: build 0, wasm 0, napi 0, run-tests 0, JS 616/6. Validator running in `wt-text` worktree (differential fuzz + valgrind + review).
- **Integrated batch 1** (markdown, ansi, meta) onto main: `build.zig` refactored to a generic `addZigRenderer(name)` helper + `zig_renderers` list `[heal,text,markdown,ansi,meta]`. Full gate green: build/wasm/napi 0, run-tests 0, JS 616/6. Migration agents reported byte-parity clean (markdown 75k inputs, ansi 30k+flags + my independent 29-file check, meta 201k comparisons). Validators (memory-safety focus) spawned in their worktrees. ast + html still migrating.
- **html integrated** (1505 LoC; both `md_html` + `md_html_ex`). zig_renderers now all 7 `[heal,text,markdown,ansi,meta,ast,html]`; `renderer_sources` is just `entity.c`. **🎉 ALL RENDERERS ARE ZIG.** Full gate green (build/wasm/napi 0, run-tests 0 spec.txt 652, JS 616/6). Byte-parity 80k+ inputs across full flag matrix. Note: subtle `strchr(set,0)` NUL-match semantics replicated.
- **Renderer phase done. Remaining C:** `src/entity.c` (generated table — step 9), `src/md4x.c` (parser — step 10), `src/md4x-wasm.c` + `src/md4x-napi.c` (glue — optional later). Each Zig renderer reimplemented its own `md_parse_props`/json/yaml helpers (translate-c can't import the `static` headers `md4x-props.h`/`md4x-json.h`, now orphaned) → step 8 becomes: dedup that duplicated logic into ONE shared Zig module + delete the dead headers.
- **Parser (step 10): wholesale 1-pass port NOT feasible** — agent honestly declined (option b), left build green on C parser. Durable progress: `src/unicode_tables.zig` + `scripts/_gen-tables-zig.py` — whitespace/punct/case-fold tables ported & **verified identical over all 1,114,113 codepoints** (preserved unwired on main). Hard remainder (~7000 LoC): inline/emphasis engine (opener_stacks mod-3, 31 gotos), block/line analysis, and **ref-defs using qsort/bsearch (impl-defined ordering must be replicated for byte-parity)**. Recommended: split `md4x.c` into C TUs (internal header) → migrate TU-by-TU keeping full gate green each step.
- **🐛 Parser bug FIXED** (user-approved), two parts in `src/md4x.c`: (1) `md_process_doc` `memset`s `line_buf` to 0 (defensive); (2) **real fix** — `md_analyze_line`'s block-component-closer path now uses a local `matched` flag instead of re-reading `line->type` at the old line 7288, which on the no-match path read a stale/uninitialized value (root cause: a logic bug exposed nondeterministically by the uninitialized buffer; symptom: orphaned `::` closer lines dropped). Found via MSan (markdown/text validators) + corroborated by ansi/html/ast. Full suite green (spec.txt 652, spec-components 58); repro now deterministic and the orphaned closer is correctly kept as text. ⚠️ TODO: propagate BOTH fixes into `wt-parser/src/md4x.c` + rebuild `/tmp/cparser-ref` before the parser port's final differential (the oracle currently has only the memset).
- **Parser strategy = multi-pass full port** (user choice): build `src/md4x.zig` across several subagent passes in dependency order (A foundation → B ref-defs/links → C inline engine → D block analysis → E block processing + wire+full-gate). Build stays on C parser until the final pass. Handoff/plan tracked in `wt-parser/PARSER-PORT.md`. Pass A (foundation: MD_CTX, char-class/UTF-8 helpers, buffers, entity hook, attributes; wires verified `unicode_tables.zig`) launched.
- **markdown VALIDATED CLEAN** (line-by-line review, Debug+valgrind over ~83k inputs, 0 leaks/UB; divergences all traced to the parser UB above, not the renderer).
- **ast integrated** (1774 LoC, the hardest). zig_renderers now `[heal,text,markdown,ansi,meta,ast]`; only html.c + entity.c remain as C renderers. Full gate green. Byte-parity ~100k cases. The dangerous C `detail` union is now a **flat Zig struct** → structurally kills the union-type-confusion bug class (AGENTS #3) while preserving `tag_is_dynamic`-first dispatch + byte-identical output. Self-ported props/json/yaml writers (no static-header cImport).
- ⚠️ **Parser UB flagged for step 10:** original `md4x.c` has codegen-dependent UB on malformed nested components (`::::name … :::`, closer with fewer colons than opener) — gcc vs `zig cc` produce different trailing-text output. Renderers are byte-identical against a `zig cc`-built reference; this is a *parser* latent bug to fix/lock down when migrating the core. (Validators must compile their C reference with `zig cc`, not gcc, to avoid a false-positive divergence here.)
- **WASM linkage trap (important for future shared-util migrations):** `@cImport`-ing header-only `static` helpers (`md4x-json.h`, `md4x-props.h`) links natively but becomes an unresolvable `env` import in WASM. Fix used by meta/ansi: don't cImport those — call real external symbols (libyaml) or reimplement the helper in Zig. Implies step 8 (props.h/json.h) should become external-linkage compiled units or full Zig ports.
- **Parallel renderer batch**: meta, ast, ansi, markdown, html each migrating in its own seeded worktree (`wt-<name>`, off main, with heal+text already applied). Each produces only its `md4x-<name>.zig` (self-verifies build + run-tests + differential fuzz vs original C). **Integration is serialized by me on main:** collect all `.zig` files, then rewrite `build.zig` once to a generic `addZigRenderer(name)` helper + renderer list, then run the full gate, then spawn per-renderer validators. (CLI has no `meta` format → meta agent uses a direct harness.)
