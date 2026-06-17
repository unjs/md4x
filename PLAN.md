# MD4X — Zig Idiomatization & Performance Plan

> **Audience:** a delegated implementation agent (and the humans reviewing it).
> **Goal:** evolve the faithful C→Zig transliteration into idiomatic, safe, fast
> Zig **without changing observable output** — every renderer must remain
> byte-for-byte identical to the current `feat/zig-port` baseline.

---

## ✅ Status (as of this branch)

Phases 0–2 and the selected parts of Phase 3 are **implemented, verified, and
pushed** (each milestone gated on `scripts/diff-corpus.sh` parity + spec/extension
suites + native tests + libFuzzer; the slice work additionally gated on a Debug
build with live bounds-checks). Summary:

| Item                                      | Status                | Notes                                                                                                                                                                        |
| ----------------------------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **0** baseline parity harness             | ✅ done               | `scripts/diff-corpus.sh` (git-tracked corpus only)                                                                                                                           |
| **1.1** `single_threaded=true`            | ✅ done               | native codegen wins; WASM already single-threaded (size unchanged)                                                                                                           |
| **1.2** SIMD HTML escape scan             | ✅ done               | `@Vector(16,u8)`; ~1.22× over C on the medium bench. URL-escape scan left scalar (its "escape set" is the _complement_ of a small set, so positive-match SIMD doesn't apply) |
| **1.3** batch callback granularity        | ⏭️ skipped            | `out_buf` already amortizes; bench showed no call-overhead win                                                                                                               |
| **2.1** one grow helper                   | ✅ done (Approach A)  | `util.growArray`; the 8 dup'd realloc blocks unified. **Approach B (ArrayListUnmanaged) NOT done** — see leftovers §8.1                                                      |
| **2.2** error unions                      | ◑ partial             | **All OOM-only fns done** (attribute builders, every `md_push_*`/`md_add_mark`). **Emission-path split declined** — see leftovers §8.2                                       |
| **2.3** `bool` predicates                 | ◑ partial             | entity recognizers → `bool`. Tri-state + hot/test-coupled predicates left — see §8.3                                                                                         |
| **2.4** `[*c]`→slices                     | ✅ done (line arrays) | every line-array param (`md_lookup_line`, `md_merge_lines`, recognizers, full inline/link pipeline) is now `[]const MD_LINE`. Other `[*c]` remain — see §8.4                 |
| **2.5** native tests                      | ✅ done               | `growArray`, `md_decode_utf8`, **abort-code matrix** (see §8.2). Failing-allocator test NOT added (libc-malloc path can't inject) — see §8.5                                 |
| **3.1** naming                            | ⏭️ skipped (owner)    | reduces grep-ability vs upstream `md4x.c ~NNNN` cross-refs — see §8.6                                                                                                        |
| **3.2** methods/namespacing               | ◑ partial             | `CH/STR/md_log` → `ctx.ch/str/log`; `ISxxx(ctx,off)` → `ctx.isXxx(off)` methods (§8.7). Constant-namespacing left — see §8.7                                                 |
| **3.3** drop `extern` on internal structs | ✅ done               | `MD_CONTAINER` → plain struct (others already plain or must stay extern); `MD_LINETYPE` dropped its `c_int` backing (§8.8). Internal-enum member rename deferred — see §8.8  |
| **3.4** docs sweep                        | ✅ done               | CHANGELOG + AGENTS.md "Idiomatic Zig conventions" note                                                                                                                       |

The idiomatic conventions now in force are recorded in **AGENTS.md →
"Idiomatic Zig conventions (parser internals)"**; follow them rather than
reverting to the C-isms they replaced.

See **§8 "Remaining for a fully Zig-native codebase"** (added below) for the
leftovers and for additional opportunities spotted during the work.

---

## 0. Orientation & hard constraints

**Target branch:** all work happens on **`feat/zig-port`** (the Zig port), _not_
`main` (which is still the original C). Start by:

```sh
git checkout feat/zig-port
git checkout -b feat/zig-idiomatic      # or per-phase branches, see §6
```

The Zig source lives under `src/` on that branch:

```
src/md4x.zig                # parser root (re-exports parser/ modules; exports md_parse)
src/parser/{types,util,refdefs,inlines,blocks,process}.zig
src/unicode_tables.zig      # generated — DO NOT hand-edit
src/entity.zig              # generated — DO NOT hand-edit
src/md4x-wasm.zig           # WASM exports + output membuffer (buf_append)
src/md4x-napi.zig           # NAPI exports
src/renderers/md4x-{html,ast,ansi,meta,text,markdown,heal}.zig
src/renderers/md4x-{props,json}.zig   # shared Zig modules
src/*.h, src/renderers/*.h, src/cli/*.c   # C ABI headers + CLI driver — STAY C
```

### Non-negotiable constraints

1. **Byte-for-byte output parity.** The project's core value is differential
   parity with `mity/md4c` + a large fuzz corpus. Output of `md_html`, `md_ast`,
   `md_ansi`, `md_meta`, `md_text`, `md_markdown`, `md_heal` must not change for
   any input. Verify after **every** phase (see §5).
2. **C ABI is frozen.** Public headers (`src/**/*.h`) and the exported symbols
   (`md_parse`, `md_html`, `md4x_to_*`, NAPI registration, etc.) keep their exact
   C signatures (`c_int` returns, `[*c]` params, struct layouts). Idiomatization
   is for **internals only**. Anything `extern fn` / `export fn` / `callconv(.c)`
   or any `extern struct` that crosses the ABI keeps its layout.
3. **Generated files are off-limits.** `unicode_tables.zig`, `entity.zig` are
   produced by `scripts/_gen-tables-zig.py` / `_gen-entity-zig.py`. Change the
   generator if output must change (it shouldn't here).
4. **No behavior in `Debug` vs `Release`.** Don't introduce `unreachable` on
   paths reachable by adversarial input (UBSan turns these into crashes — see the
   AGENTS.md memory-safety notes). Prefer defensive guards.
5. **Keep docs in sync.** Update `AGENTS.md` / `docs/*.md` / `CHANGELOG.md` when a
   change is user-visible (build flags, layout). Internal refactors that don't
   change behavior still warrant a `Project Structure`/notes touch-up if files
   move.

### Baseline characteristics (what we're improving)

Measured across `src/` on `feat/zig-port`:

- `[*c]` C-pointers: **191** • `c_int`/`c_uint`: **485** • raw
  `std.c.malloc/realloc/free` + `c_*_array`: **117** • `@intCast/@ptrCast/@alignCast`:
  thousands (mostly index juggling, **compile-time** — readability cost, not speed).
- The grow-array idiom (`if (n >= alloc) { alloc = alloc?alloc*2:N; realloc }`) is
  duplicated **8+** times: `inlines.zig:289`, `inlines.zig:1697`,
  `blocks.zig:262`, `blocks.zig:290`, `blocks.zig:312`, `blocks.zig:847`,
  `refdefs.zig:280`, `refdefs.zig:699`, `util.zig:576`.
- Two allocation styles mixed: `std.heap.c_allocator` (imported as
  `c_allocator`, used cleanly in `util.zig:470` `md_merge_lines_alloc`) **and**
  raw `std.c.malloc`/`c_malloc_array`/`c_realloc_array` (most other sites).
- Internal functions return `c_int` `-1`/`0` with a `goto abort`→`return -1`→
  caller-checks-`<0` chain; `TRUE`/`FALSE` constants used as bools.
- Only **4** native `test {}` blocks (all in `md4x.zig`); correctness rides on
  `bun scripts/run-tests.ts` (Python spec harness) + the JS vitest suite.
- The WASM output membuffer (`md4x-wasm.zig` `buf_append`) **already** uses
  amortized `cap + cap/2 + size + 256` growth — **not** an O(n²) risk. The
  remaining renderer-side cost is _callback granularity_ (one `process_output`
  call per escape literal), addressed in Phase 1.

---

## 1. Phase 1 — Safe perf wins (zero parser-core semantic change)

Lowest risk, measurable. Do these first; they establish the verification rhythm.

### 1.1 `single_threaded = true`

- **Where:** `build.zig` — add `.single_threaded = true` to the module/compile
  options in `addParserLib`, `addEntityLib`, `addZigRenderer`, the WASM target,
  and (carefully) NAPI. The whole library is single-threaded by design.
- **Why:** removes thread-local/atomic scaffolding → smaller WASM (advertised
  ~163K) and a small speed win everywhere.
- **Risk:** very low. NAPI is called from one JS thread per binding; confirm no
  worker-thread reentrancy assumption. If unsure, apply to parser + renderers +
  WASM first, leave NAPI for a follow-up.
- **Verify:** full suite + WASM JS tests + record WASM byte size before/after.

### 1.2 SIMD / `indexOfAny` escape scanning (HTML renderer)

- **Where:** `src/renderers/md4x-html.zig` — `render_html_escaped` (~:150) and
  `render_url_escaped` (~:186). Both walk byte-by-byte to find the next special
  char, flushing a verbatim run when they hit one.
- **Change:** replace the inner scan that finds the next special byte with
  `std.mem.indexOfAnyPos` (or an explicit `@Vector(16, u8)` compare loop) over
  the escape set (`& < > "` for HTML; the URL set for URLs). Emit the plain run,
  then the escape, then continue. **Output bytes must be identical** — only the
  scan is vectorized.
- **Why:** the common case is long plain runs; vectorized scan is the renderer
  throughput lever. Differential-safe (no output change).
- **Risk:** low, but easy to get an off-by-one in run boundaries → caught by spec
  suite + HTML fuzzer.
- **Verify:** spec suite, `./test/fuzzers/run.sh html --timeout 120`, and the
  bench (`bun packages/md4x/bench/index.mjs`) for throughput delta.

### 1.3 (Optional, measure first) batch renderer callback granularity

- **Observation:** each escape currently emits a separate `process_output` call
  (`render_verbatim_lit(r, "&amp;")` etc.). With `buf_append` already amortized,
  the cost is per-call indirect-call overhead, not realloc.
- **Only pursue if** the bench shows escape-heavy inputs dominated by call
  overhead. If so, add a small fixed stack buffer in the renderer that coalesces
  adjacent small writes and flushes in chunks. Skip if bench says it's noise.
- **Risk:** medium (buffering bugs change output if flush is missed). Gate on a
  measured win only.

**Phase 1 exit:** all suites green, WASM tests green, fuzzers clean for the
timeout, bench numbers recorded in the PR description, WASM size noted.

---

## 2. Phase 2 — Internal de-C (output identical, internals modernized)

Touches parser internals but must not change a single output byte. This is the
bulk of the value. Order matters: do 2.1 (allocator + grow helper) first because
later steps build on it.

### 2.1 One allocator + one grow helper

- **Goal:** kill the 8+ duplicated realloc-grow blocks and the two-allocator
  split. Standardize on `std.heap.c_allocator` (keeps libc `realloc(NULL)`
  semantics and ABI, but yields slices with known lengths).
- **Approach A (minimal):** add `fn growArray(comptime T, ptr: *[*c]T, n: c_int,
alloc: *c_int, min: c_int) error{OutOfMemory}!void` in `util.zig`; replace each
  of the 8 sites with a call. Keeps `[*c]T + n_x + alloc_x` triplets.
- **Approach B (preferred, bigger):** migrate the growable arrays on `MD_CTX`
  (`marks`, `containers`, `block_*`, `slot_info`, `inline_attrs`, `ref_defs`) and
  the attribute-build buffers to `std.ArrayListUnmanaged(T)` backed by
  `c_allocator`. Removes ~24 `n_*`/`alloc_*` fields from `MD_CTX`
  (`types.zig:228`), gives `.items` with Debug bounds-checks, and `defer
list.deinit(alloc)` for cleanup.
  - **Caveat:** `block_bytes` (`types.zig:288`) is a _heterogeneous_ byte arena
    holding interleaved `MD_BLOCK`/`MD_LINE`/`MD_VERBATIMLINE` accessed by raw
    byte offset (see the `MD_BLOCK` packed-struct note). This one likely stays a
    raw byte buffer — convert it to `ArrayListUnmanaged(u8)` at most, do **not**
    try to make it typed.
  - **Caveat:** `MD_REF_DEF_LIST` (`types.zig:187`) is a flexible-array-member
    struct (header + trailing `?*MD_REF_DEF[]`). Keep its manual layout or model
    it as a header + separate slice; verify hashing/lookup unchanged.
- **Verify:** suite + **run all fuzzers** (`html ast ansi text meta heal`) for
  ≥120s each — this is the highest-risk-for-memory-safety change. Run under the
  existing sanitizer build (`./test/fuzzers/build.sh`). Watch for use-after-free
  from the `realloc` stale-pointer class called out in AGENTS.md.

### 2.2 Error unions instead of `c_int` return codes (internal fns only)

- **Goal:** replace the `return -1`/`return 0` + `goto abort` chain with
  `error{OutOfMemory}!void` (or `!T`) + `try`. This is the most idiomatic single
  change and removes the "forgot to check the return" audit class that AGENTS.md
  currently polices by hand.
- **Scope:** internal functions only. At the C-ABI boundary (`export fn md_parse`,
  `md_html`, the `md4x_to_*` wrappers, renderer entrypoints) convert the error
  back to the documented `c_int` (`-1` on OOM, callback's non-zero code on abort)
  in a thin shim. **Preserve the exact return-value contract** documented in
  `docs/parser-api.md` (0 ok / -1 runtime error / non-zero = aborting callback's
  code). Note: callback-abort codes are _not_ errors — keep those as a distinct
  return path (e.g. `!enum/usize` or an out-param), don't fold them into
  `error{}`.
- **Risk:** medium — the abort-code-vs-OOM distinction is subtle. Module by
  module, keep the public shim's behavior identical.
- **Verify:** suite + fuzzers; specifically test OOM propagation if feasible (a
  failing-allocator test would be a great new native test, see 2.5).

### 2.3 `bool` for internal predicates

- Replace `c_int` `TRUE`/`FALSE` returns on internal `md_is_*` recognizers
  (`util.zig` entity recognizers, etc.) with `bool`. Leave ABI-facing ones alone.
- Low risk; mechanical.

### 2.4 `[*c]` → slices/`[*]T` at internal boundaries

- `MD_CTX.marks`, `.containers`, `.block_bytes`, etc. never cross the ABI (the
  `types.zig` comments confirm "internal-only / never crosses the C ABI").
  Convert internal pointer params to `[]T` / `[]const T` where length is known,
  or `[*]T` where it isn't. This makes `md_lookup_line` / `md_merge_lines`
  bounds-checked in Debug and lets you delete the "cannot be hit" defensive
  fallback at `util.zig:752`.
- **Keep `[*c]`** only on ABI-facing signatures and where pointer arithmetic on a
  possibly-null C pointer is genuinely needed.
- Risk: medium (slice bounds differ subtly from pointer arithmetic at edges) →
  fuzz.

### 2.5 Native tests (`zig build test`)

- Add `test {}` blocks per module for the pure functions: `md_decode_utf8` /
  `_before`, `md_unicode_bsearch`, `md_get_unicode_fold_info`, the new
  `growArray`/ArrayList migration, `md_build_attribute` trivial vs escaped paths,
  `md_lookup_line`. Wire a `test` step in `build.zig` if not present.
- A **failing-allocator** test (Zig `std.testing.FailingAllocator`) over
  `md_build_attribute` and the grow helper would lock down the OOM paths that
  2.1/2.2 rework — high value, since those paths are otherwise only hit by fuzz.

**Phase 2 exit:** suites green, JS tests green, **all 6 fuzzers** clean ≥120s
under sanitizers, `zig build test` green, zero output diff vs the Phase-0
baseline corpus (§5).

---

## 3. Phase 3 — Full idiomatic pass

Highest churn, cosmetic-to-structural. Parity must be re-verified hard. Do this
only after Phase 2 is merged and stable.

### 3.1 Naming

- C-macro-style screaming names (`ISALNUM_`, `ISANYOF2_`, `MD_TEMP_BUFFER`) →
  Zig idiom (`isAlnum`, `tempBuffer`). Keep a mapping note; this is a large but
  mechanical rename. Consider doing it with an automated rename + full suite per
  module to keep diffs reviewable.

### 3.2 Methods & namespacing

- Turn `MD_CTX`-first-arg free functions into methods on `MD_CTX` (`ctx.ch(off)`,
  `ctx.log(msg)`), as the `md_log` comment already anticipates. Group constants
  into namespaced structs (e.g. `mark_flags.potential_opener`) instead of
  top-level `MD_MARK_*` consts — but **only** for internal-only constants;
  ABI-mirrored enums/flags stay as-is.

### 3.3 Structs/enums

- Drop `extern struct` on internal-only types (`MD_CONTAINER`,
  `MD_MARKSTACK`, `MD_LINE_ANALYSIS` — confirm each is truly ABI-free via the
  `types.zig` comments) so the compiler can lay them out optimally.
- Consider real Zig enums (with `.lower_case` members) for internal-only enums;
  keep `enum(c_int)` + exact ABI names for anything the headers reference.

### 3.4 Final docs sweep

- Reconcile `AGENTS.md` / `docs/*.md` with the de-C'd structure, update
  `CHANGELOG.md` for any build-flag/behavior-adjacent change (Phase 1's
  `single_threaded`, WASM size).

**Phase 3 exit:** same green bar as Phase 2, plus a clean reviewer pass on
naming/structure consistency.

---

## 4. Explicitly OUT of scope (do not touch)

- The **mark-resolution / emphasis mod-3 engine** semantics in `inlines.zig` and
  the block-analysis state machine in `blocks.zig`/`process.zig`. Refactor
  _plumbing_ (allocation, types, error handling) around them, never their logic
  or ordering — that's what buys md4c parity and keeps fuzz seeds meaningful.
- `unicode_tables.zig`, `entity.zig` (generated).
- Public C ABI headers and `src/cli/*.c`.
- `qsort`/`bsearch`/`memcmp` libc externs used for glibc tie-break parity
  (`util.zig:757`) — replacing with Zig sort could change tie-breaking and thus
  output. Leave them.

---

## 5. Verification protocol (run after EVERY phase, ideally every sub-step)

### 5.1 Capture a baseline ONCE, up front (Phase 0)

Before any change, on clean `feat/zig-port`, build and snapshot outputs of all
renderers over a broad corpus, then hash:

```sh
git checkout feat/zig-port && zig build               # ReleaseFast
# Corpus = test/*.txt inputs + test/fuzzers/seed-corpus/* + packages/md4x/bench fixtures
# For each input and each format, capture output and sha256 it into baseline.sha
for fmt in html text json ansi markdown heal; do
  for f in test/fuzzers/seed-corpus/* test/*.txt; do
    zig-out/bin/md4x --format=$fmt "$f" 2>/dev/null | sha256sum | sed "s|-|$fmt:$f|"
  done
done | sort > /tmp/md4x-baseline.sha
```

(Adjust to a small script; the point is a reproducible hash set. Commit the
script under `scripts/` as `diff-corpus.sh` so the delegated agent and reviewers
share it.)

### 5.2 After each change

```sh
bun fmt                                      # MANDATORY before finishing
zig build                                    # ReleaseFast
zig build test                               # native tests (after Phase 2.5)
bun scripts/run-tests.ts                     # full Python spec + extension suites
python3 test/pathological-tests.py -p zig-out/bin/md4x   # DoS/linear-time guard
# Re-run the corpus hash and diff against baseline — MUST be empty:
bash scripts/diff-corpus.sh | sort > /tmp/md4x-now.sha && diff /tmp/md4x-baseline.sha /tmp/md4x-now.sha

# JS bindings:
zig build wasm && bun vitest run packages/md4x/test/wasm.test.mjs
# (NAPI build needs node-api-headers; see docs/js-bindings.md)
bun vitest run packages/md4x/test/napi.test.mjs

# Fuzzing (REQUIRED for Phase 2; recommended for 1.2):
./test/fuzzers/build.sh
for h in html ast ansi text meta heal; do ./test/fuzzers/run.sh $h --timeout 120; done
```

### 5.3 Benchmark (Phase 1, and final)

```sh
bun packages/md4x/bench/index.mjs     # mitata vs md4w / markdown-it
ls -l packages/md4x/build/md4x.wasm   # track WASM size
```

Any non-empty corpus diff is a **stop-the-line** regression — bisect to the
sub-step, fix or revert before proceeding.

---

## 6. Delegation strategy (subagents)

This is large and parallelizable in places. Recommended decomposition:

- **Driver agent (you):** owns the branch, the Phase-0 baseline, the verification
  gate, and merges. Runs §5 after each integrated sub-step. Does NOT let parallel
  agents skip verification.

- **Phase 1** — single agent, sequential (1.1 then 1.2). Small, tightly coupled to
  benchmarking. No fan-out needed.

- **Phase 2.1 (grow helper / ArrayList migration)** — **one agent**, sequential.
  This is shared-infrastructure; parallelizing across the 8 sites invites merge
  conflicts on `MD_CTX`. Do it as one focused change, then verify hard (fuzz).

- **Phase 2.2/2.3/2.4 (error unions, bool, slices)** — can fan out **per parser
  module** (`refdefs`, `inlines`, `blocks`, `process`, `util`) **only if** each
  agent works in an isolated git worktree (`isolation: "worktree"`) to avoid
  clobbering shared edits, and the driver integrates + verifies sequentially.
  Reality check: these changes ripple across module boundaries (a fn signature
  change in `util.zig` forces edits in callers), so **prefer one agent doing all
  parser modules in dependency order** unless the codebase is cleanly separable.
  If you do fan out, give each agent the §5 corpus-diff gate and require it to
  prove zero diff before handoff.

- **Phase 2.5 (native tests)** — independent agent, can run in parallel with
  anything; only adds `test {}` blocks + a `build.zig` test step.

- **Phase 3** — single agent per sub-step (3.1 rename, 3.2 methods, 3.3 structs),
  sequential, each fully verified. Renames are too sweeping to parallelize safely.

- **Verification/fuzzing** — can be a dedicated background agent that, given a
  branch, runs the full §5 protocol and reports diffs. Useful to keep the driver
  unblocked.

**Subagent briefing checklist** (paste into each delegated task):

1. Work on `feat/zig-port` (or the integration branch the driver names).
2. Read this PLAN.md §0 constraints + the relevant `docs/*.md` + AGENTS.md
   memory-safety section before editing.
3. Internals only — never change output, ABI, or generated files.
4. Run `bun fmt` then the full §5 gate; attach the corpus-diff result (must be
   empty) and fuzzer status to your report.
5. Keep diffs reviewable; don't bundle unrelated cleanups.

---

## 7. Suggested PR sequence

1. **PR1 — Phase 1** (`single_threaded` + SIMD escape scan). Ships a measurable
   perf/size win, low risk, establishes the verification harness + `diff-corpus.sh`.
2. **PR2 — Phase 2.1** (allocator + grow helper / ArrayList). The structural core.
3. **PR3 — Phase 2.2–2.4** (error unions, bool, slices), possibly split per
   module if review size demands.
4. **PR4 — Phase 2.5** (native tests) — can land alongside or before PR3.
5. **PR5+ — Phase 3** (naming, methods, structs), one reviewable slice at a time.

Each PR: green spec suite, green JS tests, clean fuzzers, empty corpus diff, and
(PR1) bench/size numbers in the description.

---

## 8. Remaining for a fully Zig-native codebase

What's left after Phases 0–2 + the selected Phase 3 work. Items are ordered
roughly by value. Each still carries the §0 hard constraints (parity, frozen
ABI, generated files off-limits) and must clear the §5 gate.

> **Two tiers.** §8.1–8.2 are _re-architecture_ (they change the engine's
> internal contracts, not just spelling) and deserve deliberate, reviewed work.
> §8.3–8.10 are mechanical/cosmetic and could be done as bounded slices like the
> ones already landed.

### 8.1 `MD_CTX` growable arrays → `std.ArrayListUnmanaged(T)` (Approach B) — biggest remaining de-C item

2.1 landed the _minimal_ Approach A (`util.growArray` over the existing
`[*c]T` + `n_*`/`alloc_*` triplets). The preferred Approach B was **not** done:
migrate `ctx.marks`, `ctx.containers`, `ctx.ref_defs`, `ctx.block_component_info`,
`ctx.slot_info`, `ctx.block_alert_info`, `ctx.inline_attrs` (and the attribute
substr buffers) to `ArrayListUnmanaged(T)` backed by `c_allocator`. This removes
~24 `n_*`/`alloc_*` bookkeeping fields from `MD_CTX` (`types.zig`), gives `.items`
with Debug bounds-checks, and `defer list.deinit(alloc)` cleanup. It also retires
the **two-allocator split** that still exists (`std.heap.c_allocator` vs raw
`std.c.malloc`/`c_malloc_array`/`c_realloc_array`).

- **Caveats (unchanged from §2.1):** `block_bytes` is a heterogeneous byte arena
  (interleaved packed `MD_BLOCK`/`MD_LINE`/`MD_VERBATIMLINE` by raw offset) — at
  most `ArrayListUnmanaged(u8)`, never typed. `MD_REF_DEF_LIST` is a flexible-
  array-member struct — keep its manual layout or model as header + separate slice.
- **Watch:** the `realloc` stale-pointer / double-free class (AGENTS.md). Several
  call sites cache `&ctx.marks[i]` / a walking `line` pointer across pushes — those
  must be re-fetched after any growth. Fuzz hard.

### 8.2 Redesigned OOM/abort result type for the emission path (the declined part of 2.2)

The deep emission-path `c_int` chain was deliberately **left as-is**. Why: OOM
returns `-1` **and** a callback aborting with `-1` also returns `-1`, and the code
intentionally **unifies** them (both abort, both propagate `-1`; all bundled
renderers use `-1`). Splitting OOM onto `error{}` while keeping abort codes as
`c_int` forces every call site to fork these two deliberately-unified paths and
reconverge them to the identical observable result — complexity + parity risk for
**zero behavioral/perf benefit**.

- The abort-code contract is now pinned by the **`md_parse` abort-matrix native
  test** (`md4x.zig`): a NEGATIVE callback code propagates verbatim; a POSITIVE
  one stops emission but `md_parse` returns 0 (it never hits an `MD_CHECK(<0)`
  boundary and is then overwritten by a subsequent `leave_*` returning 0).
- A genuinely Zig-native version would replace the whole `c_int` return convention
  with an explicit result type, e.g. `const Outcome = union(enum) { ok, oom,
abort: c_int };` (or `error{OutOfMemory}!enum`) threaded through the engine,
  making the three outcomes type-distinct. This is a large, semantics-adjacent
  change — do it only with a strengthened abort/OOM test matrix in front of it.
  (Note: the doc contract in `docs/parser-api.md` — "returns the non-zero code of
  any aborting callback" — is _aspirational_; actual md4c-parity behavior is the
  matrix above. Reconcile the doc if/when this is redesigned.)

### 8.3 Remaining `bool` / `c_int` `TRUE`/`FALSE` predicates (rest of 2.3)

- ~~The unicode classifiers `md_is_unicode_whitespace` / `md_is_unicode_punct` still
  return `c_int` (and existing native tests assert `c_int` — update them too).~~
  **Done:** both classifiers and their `ISUNICODE*` wrappers now return `bool`;
  the native test asserts `bool`. (corpus-parity + spec + native tests verified)
- The link/HTML _tri-state_ recognizers (`md_is_link_reference_definition` returns
  `-1`/`0`/`N`, `md_is_autolink` carries an out-param + sentinel) can't be plain
  `bool`; they'd need the §8.2 result type or stay `c_int`.
- `TRUE`/`FALSE` constants are still pervasive across the parser; a full pass would
  retire them in favor of `bool` where the value is truly two-state.

### 8.4 Remaining internal `[*c]` pointers → slices/`[*]T` (rest of 2.4)

Line arrays are done. Still `[*c]`:

- `MD_CTX.marks` / `.containers` / `.ref_defs` / info arrays — folded into §8.1 if
  Approach B is taken (ArrayList → `.items` slice).
- Walking pointers `line` in `md_collect_marks` / `md_process_inlines` are kept
  `[*c]` deliberately (pointer arithmetic). With §8.1 they'd become slice indices.
- ABI-facing `[*c]` (e.g. `MD_ATTRIBUTE.text`, callback params, `md_parse` args)
  **must stay** — they cross the C ABI.

### 8.5 Failing-allocator native test (rest of 2.5)

2.5's failing-allocator test (`std.testing.FailingAllocator` over the grow helper /
`md_build_attribute`) was **not** added: those paths use libc `malloc`/`realloc`
directly, so a Zig allocator can't be injected. If §8.1 moves them onto a
`std.mem.Allocator`, a `FailingAllocator` test becomes possible and would lock down
the OOM-cleanup paths that fuzzing can't reach (no allocation-failure injection).

### 8.6 Naming (3.1) — intentionally deferred

Renaming the screaming-case macro-style helpers (`ISALNUM_`, `ISANYOF2_`,
`MD_TEMP_BUFFER`, `MD_CHECK`-style) to Zig idiom is **low-risk but deliberately
skipped**: the source is littered with `md4x.c ~NNNN` cross-references and mirrors
md4c's identifiers, so renaming hurts upstream-diff/sync for cosmetic gain. Revisit
only if the project decides to stop tracking upstream md4c. (`md_*` function names
should stay regardless, for the same reason.)

### 8.7 Methods/namespacing (rest of 3.2)

- ~~The ctx-first `ISxxx(ctx, off)` char-class predicates (`ISWHITESPACE`, `ISPUNCT`,
  `ISNEWLINE`, `ISBLANK`, `ISANYOF`…) are still free functions; converting them to
  `ctx.isWhitespace(off)` etc. would make the accessor set consistent with
  `ctx.ch`/`ctx.str`/`ctx.log` (already done).~~ **Done:** all 19 offset-based
  predicates (incl. the `ISUNICODE*` family) are now `MD_CTX` methods in
  `types.zig` (`ctx.isWhitespace(off)`, `ctx.isUnicodeWhitespaceBefore(off)`, …),
  delegating to the pure `IS*_(ch)` helpers which stay in `util.zig`. ~174 call
  sites across all parser modules updated; corpus-parity + spec + native tests +
  Zig-native fuzz smoke verified. (`types.zig` now imports `util.zig` — a benign
  mutual import, since the methods reference util only inside fn bodies.)
- Namespacing the internal `MD_MARK_*` flag constants into a struct
  (`mark_flags.resolved`, …) was skipped — they live in the sensitive
  mark-resolution engine; bundle with any future work there, not standalone.

### 8.8 Internal enums → idiomatic Zig members (rest of 3.3)

`MD_LINETYPE` is the only internal Zig enum (others — `MD_BLOCKTYPE`, etc. — come
from the C header via `@cImport`). It is internal-only (lives solely in the plain
`MD_LINE_ANALYSIS` struct; never crosses the ABI; no `@intFromEnum`/casts).

- **Done:** dropped its explicit `c_int` backing → plain `enum {}` (compiler picks
  the layout). Corpus-parity + spec + native tests verified.
- **Deferred (owner call):** renaming the members `MD_LINE_BLANK` → `.blank`, … is
  the contested half. These mirror upstream md4c's `MD_LINETYPE` identifiers, so
  renaming them is exactly the upstream-grep/diff harm §8.6 deliberately avoids.
  Left as-is pending an explicit decision to stop tracking upstream md4c (same
  rationale as §8.6 / §3.1).

### 8.9 Renderers are still C-ABI-shaped Zig (NOT covered by the original plan)

The plan targeted the parser. The renderers (`src/renderers/md4x-*.zig`) were
ported faithfully and remain C-flavored:

- **AST renderer (`md4x-ast.zig`)**: ~~`JSON_NODE` uses a C `union` + a
  `tag_is_dynamic` discriminant … a Zig tagged union would delete that bug
  class.~~ **Stale premise — already resolved during the port (verified).** The
  Zig AST renderer does **not** use a union: `JsonNode.detail` is a _flat_
  `Detail` struct (one field per variant, see `md4x-ast.zig:107`), so union
  type-confusion is structurally impossible. The node tree is **arena-allocated**
  (`JsonCtx.arena`, single lifetime, serialized once, freed wholesale), so
  `jsonNodeFree` is a deliberate **no-op** (`md4x-ast.zig:226`) — the
  `json_node_free` double-free / heap-corruption class from the C version cannot
  occur. Dispatch is a `tag_kind` enum `switch` with `tag_is_dynamic` checked
  first (still required for correct _field selection_ / serialization, not for
  memory safety). **Do NOT convert to `union(enum)`**: it would reintroduce a
  discriminant that must stay in sync with `tag_kind`/`tag_is_dynamic` — a
  regression against the safety goal — for a negligible memory gain on small
  arena nodes. (AGENTS.md "Union Safety" updated to match.)
- The OTHER renderers (`html`/`ansi`/`text`/`meta`/`markdown`) and the shared
  `md4x-props.zig` / `md4x-json.zig` modules still use `c_int` return codes,
  `[*c]` buffers, and manual `malloc`/`realloc`; the growArray/error-union/slice
  treatment could be extended to them. Lower value — these were "NOT covered by
  the original plan" — and the AST renderer already moved to an arena + Zig
  allocator, so it is **not** part of this leftover.

### 8.10 Misc smaller items spotted

- `md4x.zig` keeps a `_testing` re-export struct plus `_ = &fn;` suppression refs so
  internal fns aren't flagged unused; a tidier test-visibility scheme (or `pub`
  behind a build option) could remove the suppressions.
- `md_merge_lines` previously _ignored_ its `n_lines`; the slice conversion (2.4)
  added the missing bound — worth auditing other "count ignored / trusted" spots.
- `@intCast`/`@ptrCast` density remains high (mostly `c_uint`↔`usize` index
  juggling at the C-scalar boundary); §8.1 slices remove some, but much is intrinsic
  to mirroring C's integer model. Not worth a dedicated pass.

### 8.11 Verification assets now available

- `scripts/diff-corpus.sh` — the parity gate (git-tracked corpus; immune to fuzzer
  seed pollution).
- `src/fuzz.zig` / `zig build fuzz-zig --fuzz` — a **Zig-native, coverage-
  instrumented** fuzz harness that `@import`s the parser+renderers directly, so
  Zig's fuzzer steers by real coverage of the Zig internals (the C/libFuzzer
  harnesses can't — `zig build-obj` emits no SanitizerCoverage). Use it alongside
  the libFuzzer harnesses (which keep ASan/UBSan) for any §8 work.
- The `md_parse` abort-matrix native test — keep it green through any §8.2 redesign.
