# MD4X — Drop the External C ABI: Remaining Work & Next Steps

> **Goal (owner decision, 2026-06-18):** MD4X becomes a **Zig library + JS
> bindings only**. The external C ABI (public `.h` headers + stable exported
> symbols, drop-in md4c compatibility) is **dropped**. The CLI is rewritten in
> Zig; the only C-callable surface left is the wasm/napi edge exports. This
> supersedes the earlier "autonomous Zig idiomatization" track (whose landed
> work — §8.1 array migration, §8.5 injectable allocator, the full OOM matrix —
> is recorded in `CHANGELOG.md` + git history and remains in place).
>
> **Compatibility surface to preserve (the new contract):** byte-for-byte
> output of every renderer (`md_html`/`md_ast`/`md_ansi`/`md_meta`/`md_text`/
> `md_markdown`/`md_heal`), the CLI's stdout for every format/flag, the
> wasm/napi exported function set + the Comark AST JSON shape consumed by the JS
> package. The _internal_ calling convention is no longer frozen — idiomatizing
> it is the point.
>
> All work happens on **`feat/zig-port`**, committed per phase.

---

## Done (committed, each gated against the verification gate below)

- **Phase 1 — `abi.zig` + flip parser/renderers off headers** (`14314d3`).
  Created `src/abi.zig`: a Zig-native single source of truth for the shared
  `MD_*` types/enums/flags, `MD_PARSER`, and (initially `extern`) cross-module
  declarations. The type/struct/flag decls are a verbatim transcription of
  `zig translate-c md4x.h`, so they are layout-identical to the old
  `@cImport`. The parser (`parser/types.zig`) and all renderers (+ shared
  `json`/`props`) now `@import("abi")`; genuinely-external headers (stdio/yaml/
  string) stay in a `sys` `@cImport`. `abi` is registered as a named build
  module on every Zig compile step. Later extended with the renderer ABI
  (entry-point externs + flag values + `MD_HTML_OPTS`) so the JS roots and CLI
  share it.
- **Phase 2 — Zig CLI** (`c6a02e1`). `src/cli/md4x-cli.c` + `cmdline.c` replaced
  by `src/cli/md4x-cli.zig`: imports `abi`, declares the renderer entry points
  `extern`, faithfully reproduces the option parser (`-o/-t/-f/-s/-h/-v/--heal/
--html-title/--html-css/--replay-fuzz`, `--stat` timing, full-html opts, fuzz
  replay). File I/O via a thin libc binding; argv via `std.process.Init`;
  version injected from `build.zig.zon` via a build-options module.
- **Phase 3 — drop the C scaffolding** (`83abae9`). Deleted **all** md4x-owned
  headers (`md4x.h`, `entity.h`, the 8 `renderers/md4x-*.h`), the orphaned C CLI
  sources, the C/libFuzzer harnesses + scripts (the Zig `fuzz-zig` harness
  covers the surface; `seed-corpus/`+`corpus/` kept), and the C-only CodeQL
  workflow (it referenced nonexistent `.c` and CodeQL has no Zig support).
  Flipped the last `@cImport`ers (`md4x-wasm.zig`, `md4x-napi.zig`, `fuzz.zig`)
  onto `@import("abi")` (`node_api.h` stays external for napi). `build.zig`: abi
  module on wasm/napi/fuzz steps, removed the C-fuzzer step + unused
  `cli_sources`/`c_flags`/`version` consts. **Only C left in any artifact: the
  vendored libyaml.** Remaining `@cImport`: `node_api.h`, `stdio.h`,
  `string.h`, `yaml.h` — all external.

**Net state after Phase 3:** the external C ABI _commitment_ is gone (no headers,
no stable-symbol promise, Zig CLI, Zig-only consumers) with **zero observable
output change**. What remains is purely _internal_: the parser, renderers, and
entity table are still compiled as **separate static libs that communicate via
C-ABI symbols** (`md_parse`, `md_html`, `entity_lookup`, … as `export` /
`callconv(.c)`), and `abi.zig` still declares those cross-lib functions
`extern`. The SAX interface still passes details as `?*anyopaque` into
`extern struct`s. Idiomatizing that is Phase 4.

---

## Remaining work — Phase 4: de-extern the internals (idiomatic Zig)

> **This is the large, engine-adjacent phase.** It "spends" the freedom Phases
> 1–3 bought. Do it **incrementally and test-first**, gating every step against
> the full verification gate (output must stay byte-identical). 4a/4b are
> moderate and low output-risk; **4c is the deep, highest-risk step** — it
> touches the block-analysis emission path that constraint #5 fences off and
> rewrites ~35 renderer callbacks.

### 4a — Collapse the static-lib graph into one Zig module per artifact

**Why:** de-externing `md_parse`/entry points/callbacks is impossible while the
parser and renderers are separate libs linked by C-ABI symbols — a direct Zig
call requires they live in one compilation. `src/fuzz.zig` already proves the
single-module pattern (it `@import`s the parser + every renderer + entity into
one module and works).

**Steps:**

1. Decide the aggregation shape. Option A (recommended): an `md4x.zig`-level
   library root that `@import`s the parser + renderers + entity and re-exports
   their entry points, so each artifact imports _one_ module. Option B: each
   artifact imports the pieces it needs directly (what fuzz.zig does).
2. In `build.zig`, stop building/​linking `addParserLib` / `addEntityLib` /
   `addZigRenderer` as separate static libs for the CLI/wasm/napi; instead add
   their sources to each artifact's module graph via imports (libyaml stays the
   only C compiled in). Keep per-artifact `target`/`optimize`/`strip`.
3. Replace `abi.zig`'s `pub extern fn md_parse/md_heal/entity_lookup/md_html/…`
   with re-exports of the real Zig definitions (e.g.
   `pub const md_parse = @import("…").md_parse;`), now that they're in-module.
   Watch for: a file imported twice in one artifact is deduped by Zig (same
   module) — fine; `export` kept on the defs is harmless within one artifact.
4. Confirm no duplicate-symbol errors per artifact and that wasm `--export`
   list + napi registration still resolve.

**Risk:** moderate (build graph), low output-risk (calling convention still
`callconv(.c)` internally at this step). **Gate:** corpus + all tests + wasm +
napi + fuzz-zig.

### 4b — De-extern `md_parse` + renderer entry points

**Steps:**

1. Drop `export` + `callconv(.c)` from `md_parse`, `md_html`/`md_html_ex`,
   `md_ast`, `md_ansi`, `md_text`, `md_markdown`, `md_meta`, `md_heal`,
   `entity_lookup` → plain `pub fn`. Update `abi.zig` re-exports accordingly.
2. Keep `export` + `callconv(.c)` **only** at the true edges: the wasm exports
   (`md4x_to_html`, `md4x_alloc`, …) and the napi exports
   (`napi_register_module_v1`, the registered callbacks). These are real C/JS
   ABI boundaries and must stay.
3. The internal `process_output` sink: today
   `?*const fn([*c]const u8, MD_SIZE, ?*anyopaque) callconv(.c) void`. It may
   become a Zig fn pointer internally; the wasm/napi/CLI sinks are Zig fns that
   can keep `callconv(.c)` only if still handed to an edge.

**Risk:** low; output unchanged. **Gate:** full.

### 4c — Idiomatize the SAX interface (deep, highest-risk)

**Scope:** replace the `?*anyopaque` + `extern struct` detail mechanism and the
`callconv(.c) c_int` callbacks with idiomatic Zig, across the parser emission
path **and all 7 renderers (5 callbacks each ≈ 35 implementations)**, with
byte-identical output.

**Steps (test-first):**

1. **Strengthen the abort/OOM matrix first.** The abort-code contract is md4c
   parity: a NEGATIVE callback code is propagated verbatim, a POSITIVE one
   returns 0 (pinned by the abort-matrix native test in `md4x.zig`). OOM and a
   callback returning `-1` are intentionally unified as `-1`. Add tests that
   freeze this for every callback kind **before** changing signatures.
2. **Detail representation:** convert the `extern struct` detail types
   (`MD_BLOCK_*_DETAIL`, `MD_SPAN_*_DETAIL`, `MD_ATTRIBUTE`) to idiomatic Zig —
   a `union(enum)` of typed details (exhaustive `switch`, no type confusion) or
   typed pointers. `MD_ATTRIBUTE`'s `substr_types`/`substr_offsets` `[*c]`
   arrays become slices.
3. **Callbacks:** `MD_PARSER`'s 5 callbacks lose `callconv(.c)` and take the
   Zig detail type instead of `?*anyopaque`. Return type: fold in the deferred
   **§8.2** decision — either keep an abort `c_int`/enum, or move to
   `error{OutOfMemory}!enum{ok,abort:i32}`-style. Must preserve the abort
   semantics from step 1.
4. **Parser emission call sites (`process.zig`, `inlines.zig`):** rework where
   details are constructed and callbacks invoked to build the union/typed value.
   **Constraint #5 still applies — change packaging only, never the
   ordering/logic of the mark-resolution/emphasis engine or block state
   machine.**
5. **Renderers:** convert each renderer's callbacks to take the Zig types and
   `switch` on the union instead of `@ptrCast(?*anyopaque)`. **Convert and gate
   one renderer at a time** against the corpus.
6. Re-confirm the AST renderer's flat-`Detail` + arena design and the
   `tag_is_dynamic`-first dispatch rule still hold (see `AGENTS.md` §8.9 note).

**Risk:** **highest in the project** — engine-adjacent, ~35 call sites, output
parity across 6 renderers + the abort matrix. Realistically a multi-session
effort. **Gate after every renderer + the emission change:** full gate, both
Debug and ReleaseFast.

### Folded-in cleanups (do alongside 4c where natural)

These earlier deferred items become free once the internals are Zig-native:

- **§8.2 OOM/abort result type** — see 4c step 3.
- **`TRUE`/`FALSE` → `bool`** where genuinely two-state (tri-state recognizers
  excepted).
- **Naming (§3.1/§8.6), `MD_LINETYPE` member rename (§8.8), `MD_MARK_*`
  namespacing (§8.7)** — now that upstream-md4c grep-ability is no longer a
  hard requirement (the C source it cross-referenced is gone), these become
  ordinary idiomatization. The `MD_MARK_*` work still lives in the sensitive
  mark engine — bundle with 4c, never standalone.

---

## Hard constraints (apply to all Phase 4 work)

1. **Byte-for-byte output parity** for all 6 renderers + `md_heal`, the CLI's
   stdout per format/flag, and the wasm/napi/Comark-AST JS surface.
2. **Edge ABI stays C:** the wasm exported function set and the napi module
   registration are real boundaries — keep `export`/`callconv(.c)` there.
   (The _internal_ convention is now free — that is the goal.)
3. **Generated files off-limits** — `unicode_tables.zig`, `entity.zig` (change
   the generator if output must change; it shouldn't).
4. **No Debug-vs-Release behavior**; no `unreachable` on adversarial-reachable
   paths (prefer defensive guards).
5. **Do not touch engine logic** — the mark-resolution/emphasis mod-3 engine
   (`inlines.zig`) and the block-analysis state machine (`blocks.zig`/
   `process.zig`): in 4c, change detail _packaging_ at the emission boundary
   only, never the logic or ordering. Leave the `qsort`/`bsearch`/`memcmp`
   libc externs (glibc tie-break parity).
6. **Keep docs in sync** — `AGENTS.md` / `docs/*.md` / `CHANGELOG.md`. The
   post-Phase-3 doc sync is **done** (see "Doc sync" below); keep them current
   as Phase 4 lands.

## Verification gate (run after every change)

```sh
bun fmt
zig build
zig build test                                      # ReleaseFast (default)
zig build test -Doptimize=Debug                     # undefined-fill + allocator length checks
bun scripts/run-tests.ts                            # spec suites (CLI-driven)
python3 test/pathological-tests.py -p zig-out/bin/md4x
bash scripts/diff-corpus.sh > /tmp/md4x-now.sha     # diff vs /tmp/md4x-baseline.sha — MUST be empty
# Memory-touching changes also:
zig build fuzz-zig                                  # ReleaseSafe smoke (the C/libFuzzer harnesses are gone)
zig build wasm && bun vitest run packages/md4x/test/wasm.test.mjs
zig build napi-linux-x64 -Dnapi-include=node_modules/node-api-headers/include \
  && bun vitest run packages/md4x/test/napi.test.mjs
```

Capture the baseline from the Phase-3 commit (`83abae9`) before starting:
`bash scripts/diff-corpus.sh > /tmp/md4x-baseline.sha`. Any non-empty diff is a
**stop-the-line** regression — bisect, fix or revert.

---

## Doc sync (independent of Phase 4) — ✅ DONE

`AGENTS.md` / `docs/*.md` / `CHANGELOG.md` were stale after Phases 1–3 (they
still described a frozen C ABI, `.h` headers, a C CLI, and the C/libFuzzer
harnesses). Now updated to the Zig-library-only reality:

- `AGENTS.md`: no `.h` headers in the structure tree; `src/abi.zig` documented
  as the ABI types module; CLI is `src/cli/md4x-cli.zig`; build section states
  only `bin/md4x` is installed and that the static libs are an _internal_ seam
  Phase 4a collapses; the C/libFuzzer harness section removed; the memory-safety
  and "adding new block/span types" checklists retargeted at the Zig sources;
  the CLI option table corrected (`markdown` format, `--heal`, `--replay-fuzz`).
- `docs/parser-api.md`: retitled to `src/abi.zig`, signatures/structs converted
  to Zig; the stale `MD_BLOCK_CODE_DETAIL` gained its missing `filename`/`meta`/
  `highlights` fields; the abort-code contract documented.
- `docs/renderers.md`: section titles point at the `.zig` sources, signatures
  converted to Zig, AST-renderer architecture note rewritten for the flat
  `Detail` struct + arena.
- `docs/js-bindings.md`: "the C renderer" → "the AST renderer".
- `docs/zig-migration.md` / `docs/parser-port.md`: archived-log banners (they
  are historical records of a completed port; not rewritten).
- `CHANGELOG.md`: a **Breaking Changes** entry for dropping the C ABI / public
  headers / static-lib + header install outputs / the C CLI / the C fuzzers,
  plus a corrected internal entry for `src/abi.zig`.

**Known doc gaps, not caused by the C-ABI drop (left alone):**
`docs/renderers.md` has no section for the **markdown** renderer (`md_markdown`)
even though it ships and has a CLI format. `CHANGELOG.md`'s WIP heading says
`v0.0.18` while the last tag is `v0.0.25` — a release-process question, not a
doc-sync one.
