# MD4X — Zig Idiomatization: Remaining Work & Next Steps

> **Goal (unchanged):** evolve the faithful C→Zig transliteration into idiomatic,
> safe Zig **without changing observable output** — every renderer must remain
> byte-for-byte identical to the `feat/zig-port` baseline.
>
> All work happens on **`feat/zig-port`**. This file now tracks only what's
> **left**; for what's already landed see `CHANGELOG.md` + git history.

---

## Done (for context)

Phases 0–2 and the selected Phase 3 work, plus these §8 leftovers:

- **§8.1** — all seven typed `MD_CTX` growable arrays (`marks`, `containers`,
  `ref_defs`, `block_component_info`, `slot_info`, `block_alert_info`,
  `inline_attrs`) migrated to `std.ArrayListUnmanaged(T)` + `c_allocator`; every
  `n_*`/`alloc_*` field and all 8 `util.growArray` call sites gone.
- **§8.3** (partial) — Unicode classifiers + `ISUNICODE*` wrappers → `bool`.
- **§8.5** — injectable `ctx.alloc` + `FailingAllocator` OOM native tests.
- **§C (fuller OOM matrix, partial)** — the three raw byte arenas (`block_bytes`,
  the ref-def hashtable array, and the `MD_REF_DEF_LIST` buckets) now allocate
  through `ctx.alloc` via the `util.arena_alloc`/`arena_realloc`/`arena_free`
  helpers; `md_parse` split into `md_parse_impl(alloc, …)` + a full-parse
  `FailingAllocator` sweep test (`zig build test` = 14/14, Debug + ReleaseFast).
  This surfaced and fixed a latent cleanup-ordering UB (hashtable freed after
  `ref_defs`; see CHANGELOG Fixes). **Remaining:** `md_build_attribute`'s typed
  buffers and the per-row scratch buffers in `process.zig` (`pipe_offs`,
  `align_arr`, code-meta) still use raw `std.c.malloc` — they need per-buffer
  length tracking before they can route through `ctx.alloc`.
- **§8.7** (partial) — ctx-first `ISxxx(ctx,off)` char-class predicates → `MD_CTX` methods (`ctx.isWhitespace(off)`, …).
- **§8.8** (partial) — dropped `MD_LINETYPE`'s explicit `c_int` backing.
- **§8.9** — corrected the stale AST-renderer "union safety" premise (the C-union footgun was already designed out: flat `Detail` struct + arena; **do not** convert to `union(enum)`).
- **§8.10** — "count ignored / trusted" audit: clean, no bug found.
- **§8.11** — Zig-native coverage-instrumented fuzz harness (`zig build fuzz-zig`).

---

## Hard constraints (apply to ALL remaining work)

1. **Byte-for-byte output parity** for `md_html`/`md_ast`/`md_ansi`/`md_meta`/`md_text`/`md_markdown`/`md_heal`.
2. **C ABI frozen** — public `.h`, exported symbols, and `extern struct` layouts keep their exact C shape. Idiomatize internals only.
3. **Generated files off-limits** — `unicode_tables.zig`, `entity.zig` (change the generator if output must change; it shouldn't).
4. **No Debug-vs-Release behavior**; no `unreachable` on adversarial-reachable paths (prefer defensive guards).
5. **Do not touch engine logic** — the mark-resolution / emphasis mod-3 engine (`inlines.zig`) and the block-analysis state machine (`blocks.zig`/`process.zig`): refactor _plumbing_ (allocation, types) only, never logic or ordering. Also leave the `qsort`/`bsearch`/`memcmp` libc externs (glibc tie-break parity).
6. **Keep docs in sync** — `AGENTS.md` / `docs/*.md` / `CHANGELOG.md`.

## Verification gate (run after every change)

```sh
bun fmt
zig build
zig build test                                      # ReleaseFast (default)
zig build test -Doptimize=Debug                     # undefined-fill + allocator length checks (catches OOM/cleanup UB)
bun scripts/run-tests.ts
python3 test/pathological-tests.py -p zig-out/bin/md4x
bash scripts/diff-corpus.sh > /tmp/md4x-now.sha   # diff vs baseline — MUST be empty
# Memory-touching changes also:
zig build fuzz-zig                                  # ReleaseSafe, live bounds-checks
./test/fuzzers/build.sh html ast && for h in html ast; do ./test/fuzzers/run.sh $h --timeout 90; done   # ASan/UBSan
# JS bindings:
zig build wasm && bun vitest run packages/md4x/test/wasm.test.mjs
```

Any non-empty corpus diff is a **stop-the-line** regression — bisect, fix or revert.

---

## Remaining work

### A. Deferred — owner decision needed (do NOT do autonomously)

These trade upstream-md4c grep-ability (the source is full of `md4x.c ~NNNN`
cross-refs) for cosmetic Zig idiom. Revisit only if the project decides to stop
tracking upstream md4c.

- **Naming (§3.1 / §8.6):** rename screaming-case helpers (`ISALNUM_`,
  `ISANYOF2_`, `MD_TEMP_BUFFER`, `MD_CHECK`-style). `md_*` function names should
  stay regardless.
- **Internal-enum member rename (§8.8):** `MD_LINETYPE` members `MD_LINE_BLANK` →
  `.blank`, … (backing already dropped; only the member names remain).
- **`MD_MARK_*` constant namespacing (§8.7):** group into a struct
  (`mark_flags.resolved`, …). Lives in the sensitive mark engine — bundle with
  future engine work, never standalone.

### B. Declined re-architecture — needs deliberate, test-first, reviewed work

- **OOM/abort result type (§8.2):** replace the `c_int` `-1`/abort-code
  convention on the emission path with an explicit
  `union(enum){ ok, oom, abort: c_int }` (or `error{OutOfMemory}!enum`). Today
  OOM and a callback aborting with `-1` are **intentionally unified** (pinned by
  the `md_parse` abort-matrix native test in `md4x.zig`). Large and
  semantics-adjacent: attempt **only** behind a strengthened abort/OOM test
  matrix, and reconcile `docs/parser-api.md`'s aspirational "returns the
  aborting callback's code" contract with actual md4c-parity behavior.

### C. Lower-value / out of original scope (safe, but modest payoff)

- **Fuller OOM matrix (extends §8.5/§8.1) — partially landed.** The three byte
  arenas (`block_bytes`, `ref_def_hashtable`, `MD_REF_DEF_LIST` buckets) are done
  (see Done above). **Still raw `std.c.malloc`:** `md_build_attribute`'s typed
  buffers (`text`/`substr_types`/`substr_offsets` — need their lengths recorded
  in `MD_ATTRIBUTE_BUILD` so the Allocator can free them) and the per-row scratch
  buffers in `process.zig` (`pipe_offs`, `align_arr`, code-block `meta`). Same
  arena-helper / exact-length pattern; each is short-lived and self-contained.
  When done, extend the `md_parse` `FailingAllocator` sweep input to a table +
  fenced code with metadata + a component with attrs so those paths are covered.
- **Renderers (§8.9):** `html`/`ansi`/`text`/`meta`/`markdown` + shared
  `md4x-props.zig`/`md4x-json.zig` still use `c_int` returns, `[*c]` buffers, and
  manual `malloc`/`realloc`; the growArray/error-union/slice/ArrayList treatment
  could extend to them. (The AST renderer already uses an arena + Zig allocator —
  no action; see §8.9 "do not convert to union(enum)".)
- **`TRUE`/`FALSE` retirement (rest of §8.3):** still pervasive; convert to `bool`
  where genuinely two-state. Nuanced — many feed `c_int` ABI-ish fields. The
  tri-state recognizers (`md_is_link_reference_definition`, `md_is_autolink`)
  must stay `c_int` (or wait for §8.2's result type).
- **Test-visibility cleanup (§8.10):** `md4x.zig` keeps a `_testing` re-export
  struct + `_ = &fn;` suppression refs; a tidier scheme (`pub` behind a build
  option) could remove them.
- **`@intCast`/`@ptrCast` density (§8.10):** mostly intrinsic to mirroring C's
  integer model at the scalar boundary — **not worth a dedicated pass**.

---

## Suggested next step

If continuing autonomously, **finish the "fuller OOM matrix"** — the three byte
arenas are landed; what's left is routing `md_build_attribute`'s typed buffers and
`process.zig`'s per-row scratch buffers through `ctx.alloc` (record their lengths
first), then widening the `md_parse` `FailingAllocator` sweep input to cover the
table / code-meta / component-attr paths. Same fuzz-gated per-buffer pattern; no
engine-logic or upstream-grep changes. Run the verification gate in **both Debug
and ReleaseFast** (`zig build test -Doptimize=Debug`) — Debug's `undefined`-fill +
allocator length validation is what catches the cleanup-ordering / length-tracking
bugs this class is prone to (it found one already). Everything else remaining is
either an **owner judgment call (A)** or needs **deliberate, human-reviewed
design (B)**.
