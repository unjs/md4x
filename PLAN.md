# MD4X — Remaining Work

> **Context.** MD4X is a **Zig library + JS bindings**. The external C ABI
> (public `.h` headers, stable exported symbols, drop-in md4c compatibility) was
> dropped; the CLI is Zig; the only C-callable surfaces left are the wasm
> exports, the napi module registration, and the `qsort`/`bsearch` comparators
> handed to libc. The only C compiled into any artifact is the vendored libyaml.
>
> Phases 1–3 (drop the C ABI), 4a (one Zig module per artifact), 4b (de-extern
> the entry points + sink), and 4c (idiomatize the SAX interface) are **all
> landed** — see `CHANGELOG.md` and git history for the details. `src/abi.zig`
> is a pure types-only leaf; the parser and all seven renderers talk through
> plain-Zig `Parser` callbacks taking `BlockDetail`/`SpanDetail` tagged unions.
>
> All work happens on **`feat/zig-port`**, committed per step.

---

## What's left

**Landed 2026-08-12** (all behind the full gate, corpus diff-clean at 168
hashes, golden SAX trace unchanged, nothing re-recorded):

| Item                              | Commits                         |
| --------------------------------- | ------------------------------- |
| 3 — `MD_LINETYPE` member rename   | `49855c4`                       |
| 1 — `TRUE`/`FALSE` → `bool`       | `5ab9a3d`, `c501ac1`, `e648b3b` |
| 1b — renderer state fields        | `3c3d2f7`                       |
| 2 — `MD_MARK_*` → `MarkFlags`     | `dbd8720`                       |
| 6 — doc gaps (first two bullets)  | `494cf3f`, `73d6e27`            |
| 9a — quadratic `{...}` attrs scan | `521bca5`                       |
| 1c — attr builder OOM free length | _the commit adding this row_    |

Zero `TRUE`/`FALSE` tokens remain in `src/`. Verified at `3c3d2f7`: `zig build`,
`zig build test` (ReleaseFast **and** Debug), 16 spec suites / 1001 assertions,
30 pathological, corpus diff empty, fuzz smoke, wasm (309) and napi (307).

**9a** (landed after the table above, same gate — corpus diff empty at 168
hashes, 32 pathological including the two new brace cases): the document's
`{`…`}` pairing is computed **once per parse** in one linear right-to-left pass
(`md_build_brace_pairs`, lazily on the first candidate) into the new
`MD_CTX.brace_pairs` array, and both scan sites query it by binary search
(`md_match_brace`) instead of re-scanning to `ctx.size`. Two shapes were
quadratic, not one: the unbalanced `'*a*{' × N` from the report, **and** the
deeply nested `'*a*{' × N ++ '}' × N`, where every scan _succeeds_ but still
walks to the closers. PLAN's suggested `brace_fail_floor` memo was therefore not
adopted — it is also **vacuous** on its own benchmark: a failed scan from `s`
proves `bal(x) > bal(s)` for every `x > s`, so any later candidate `s'` has
`bal(s') > floor` and the O(1) test can never fire on `'*a*{' × N` (each
candidate sits one level deeper). Pairing the whole document instead is O(size),
covers both shapes, and is output-identical by construction (the depth scan from
`{` stops at the first `}` not consumed by a nearer `{` — exactly the pair the
stack pass forms). Measured on `'*a*{'`: 160 KB 3020 ms → 8 ms; 1 MB 117.5 s →
65 ms. Also verified by a 1500-document randomized differential run of the old
vs. new binary over brace-heavy inputs across all six formats (zero
mismatches).

**1c** (landed after 9a, same gate — corpus diff empty at 168 hashes, plus wasm
309 / napi 307, which also retro-covered 9a): `MD_ATTRIBUTE_BUILD` gained a
second capacity field, `types_alloc`, and `md_build_attr_append_substr` now
publishes each capacity only **after** the realloc it describes returns, so a
failure between the two reallocs leaves each array's length field describing the
block that actually exists. `md_free_attribute` frees `substr_types` by
`types_alloc` and `substr_offsets` by `substr_alloc + 1`, and no longer gates on
`substr_alloc > 0` — that guard would have stranded the already-owned `text`
buffer when the very first growth fails. Order of work matters here and was
followed: the OOM sweep document first gained a 15-substring link title
(`[t](/u "a&amp;b&amp;…&amp;h")`), which made `zig build test -Doptimize=Debug`
abort with `panic: Invalid free` inside `md_free_attribute` — the `old_alloc > 0`
growth branch had never executed in the suite at all — and only then was the fix
applied. Keep that title: without it the branch reverts to zero coverage.

---

Items 4–8 are **ordinary idiomatization or doc upkeep**. The structural work is
finished and there is no remaining C-ABI seam. Land them in any order, each
behind the full verification gate.

**Items 9–11 are different.** They are live bugs found by an independent audit,
verified by reproduction — item 9 is user-visible on ordinary MDC prose. They
are not refactors, they must not ride along with one, and item 9 deliberately
**breaks the "corpus diff must be empty" rule** because the baseline currently
encodes the bug. Read the gate exception on item 9 before touching it. (9a, the
reachable DoS, is **landed** — see the table above.)

**Suggested priority.** `8` next (it is why three of these bugs went unseen),
then the rest.

**Ordering constraint.** Items 7/5 and bug 9b all rewrite overlapping parser
files and must stay **serial**. Renderer-only and docs-only work parallelizes
freely.

**Do not fold a bug fix into a refactor commit**, and do not let a refactor
"tidy" an adjacent bug — constraint #4 makes the refactors type/name-only, and
the audit's value came from each finding being independently reviewable.

### 4. General naming (§3.1/§8.6)

Function and local naming is still largely md4c's `md_snake_case`. Upstream
grep-ability is no longer a requirement (the C source it cross-referenced is
gone), so this is now free to idiomatize. Low value, high churn — **lowest
priority, and fine to never do**. If it happens, do it file-by-file.

### 5. Route the `md_merge_lines_alloc` buffers through `ctx.alloc`

The last libc allocations in the parser: the ref-def label/title and merged
autolink/link-label strings. They `c_allocator.alloc` `end-beg` bytes but keep
only the collapsed `*_size`, and some are freed via the `ptr_stack`
(`md_mark_get_ptr` + `std.c.free`, no length). Routing them needs a
shrink-to-fit plus a length-carrying `ptr_stack` free, so that every parser
allocation goes through the injectable allocator and the exact-length rule.

See the "Raw byte arenas" bullet in `AGENTS.md` for the allocation discipline
these must adopt.

**Audit verdict: this is PURE IDIOMATIZATION, not a bug fix.** The current
arrangement was independently verified leak-correct: no wrong-length free (these
are `u8` allocs with alignment 1, so `CAllocator.allocStrat` picks `.raw` /
plain `malloc` on every shipping target — including Windows, where an
over-aligned request would otherwise route through `_aligned_malloc` and make
the bare `std.c.free` corrupt the CRT heap), and no leak on any path (the
`md_is_link_reference_definition` abort path frees the merged label before
returning; `md_is_link_reference` frees its multiline label unconditionally;
`md_is_inline_link_spec`'s title reaches **either** `inlines.zig:1229` **or**
the `ptr_stack` walk at `process.zig:275`, never both).

**The real justification is test coverage, not correctness.** Because these
bypass `ctx.alloc`, the `FailingAllocator` sweep can neither inject OOM into
them nor leak-check them — so every path above is correct only _by inspection_.
Prioritize accordingly; this is lower value than it looks.

**Item 1c is landed**, so the builder these would join now frees every buffer at
its exact length. Follow the same discipline: one length field per buffer,
published only after the block it describes exists.

**Fold in while you are here (preventive, not live):** `md_merge_lines_alloc`
(`util.zig:407`) has no zero-length guard. In Zig 0.16
`Allocator.allocBytesWithAlignment` short-circuits `byte_count == 0` and returns
`@ptrFromInt(maxInt(usize))` **without calling the vtable**; that sentinel would
reach `std.c.free` at `refdefs.zig:782`, the `ptr_stack` walk, and
`inlines.zig:1229`. It diverges from C (where `malloc(0)` returns a freeable
pointer) and from the two sibling helpers in the same file that _do_
special-case zero (`arena_alloc`, `alloc_array_a`). Currently **unreachable** —
all three call sites are guarded by non-local invariants
(`contents_beg < contents_end`; multiline implies `lines[i+1].beg > lines[i].end`;
`refdefs.zig:867` gates on `title_contents_beg < title_contents_end`) — but it
is a one-line guard protecting a catastrophic outcome via invariants three call
frames away, and item 5 disturbs exactly those call sites:
`if (n == 0) { p_str.* = null; p_size.* = 0; return 0; }` (callers already
tolerate a null title).

### 6. Doc gaps

- **`CHANGELOG.md`'s WIP heading says `v0.0.18` but the last tag is `v0.0.26`.**
  The accumulated WIP entries are correct; only the heading is wrong. This is a
  release-process question, not a doc-sync one — resolve it at the next release.

### 7. Delete the dead `growArray` / `c_realloc_array` idiom

`AGENTS.md` currently instructs: _"Any remaining `[*c]T` buffer still grows via
`util.growArray(...)`"_. **That set is empty.** Census: `growArray` has zero
production callers (only the `md4x.zig:840` unit test); `c_realloc_array` is
called only from inside `growArray` itself; the three aliases (`md4x.zig:170`,
`blocks.zig:45`, `inlines.zig:51`) are never called; `c_malloc_array`'s single
use is the test-only `_test_run_inline` driver at `md4x.zig:384`.

So the doc actively steers contributors toward a raw-libc path the
`FailingAllocator` sweep cannot see — a doc bug that manufactures future bugs.
Delete `growArray` + `c_realloc_array` + the three aliases (~45 lines), and
switch `_test_run_inline` to `alloc_array_a` — at which point `std.c.malloc` /
`std.c.realloc` disappear from the parser entirely and the reworded `AGENTS.md`
bullet can state that absolutely rather than conditionally.

### 8. `zig build test` runs in neither CI nor safe mode

Two independent problems with the verification infrastructure:

- **Not in CI.** `zig build test` appears in neither `.github/workflows/` nor
  `scripts/run-tests.ts` (which runs only the Python HTML-diff suites +
  pathological tests). So the abort matrix, the OOM sweep and the golden SAX
  trace — which `AGENTS.md` correctly calls the only guards on parser-internal
  behavior — **never run on a PR**.
- **Defaults to ReleaseFast.** `build.zig:42` defaults `optimize` to
  `.ReleaseFast` and `build.zig:89-99` hands it to the test artifact, so a bare
  `zig build test` runs with bounds checks, `@intCast` range checks, overflow
  checks and `unreachable` panics **disabled** — exactly the checks that make
  the OOM sweep meaningful. Its "never a crash" assertion degrades to "no hard
  segfault". PLAN's gate is fine because it also runs
  `-Doptimize=Debug`, but anyone following `AGENTS.md`'s Testing section alone
  believes they checked something they did not.

Fix: add `zig build test` to CI (or `run-tests.ts`), and pin the test artifact
independently of the global default —
`.optimize = if (optimize == .Debug) .Debug else .ReleaseSafe`.

Also add abort-matrix cases pinning the **doc-level** abort behavior (constraint
#6): `md_parse` must return `5` for a `+5` and `-7` for a `-7` on the `.doc`
block. The matrix currently excludes doc explicitly (`detail.* != .doc`,
`md4x.zig:695` / `:700`), so nothing catches a regression in either direction.

---

## Bugs found by audit (live, user-visible — not idiomatization)

> These are **not** refactors and must not ride along with one. Each needs its
> own commit and its own regression test.

### 9b. Out-of-range pointer in `md_scan_left_for_resolved_mark`

`inlines.zig:1482`. The walk is
`while (@intFromPtr(mark) >= @intFromPtr(ctx.marks.items.ptr)) : (mark -= 1)`.
At index 0 the continue-expression forms `items.ptr - 1`. Zig lowers `[*c]T`
arithmetic through `getelementptr`; an out-of-range result is **poison**, and
the `@intFromPtr` comparison propagates it. That pointer is also **stored** into
`left_cursor` and fed back in on the next call (`:1557`). Never dereferenced, so
nothing mis-renders today.

Trigger (hand-traced): input `a.b@c.d` produces `marks[0]='@'(beg=3)`,
`marks[1]='D'(beg=0,end=7)`; the permissive-autolink username back-scan calls
`md_scan_left_for_resolved_mark(ctx, &marks[0], 1, &left_cursor)`, and
`marks[0].beg(3) > off(1)` → continue → `&marks[-1]`.

Fix: switch the `left_cursor`/`right_cursor` pair to **indices** rather than
pointers. This is control-flow-adjacent, so under constraint #4 it must **not**
ride along with item 2's mechanical renaming — separate commit, preferably
_after_ item 2 so that diff stays purely mechanical. (The sibling
`md_scan_right_for_resolved_mark` at `:1498` is fine; one-past-the-end is legal.)

### 9. `::component` / `#slot` retroactively flips an earlier list to loose

**Live output-correctness bug, reproduced.** `blocks.zig:1688-1693` uses
`cont.ch != '>'` to mean "is a list":

```zig
if (prev_line_has_list_loosening_effect and line.type != .blank and n_parents + n_brothers > 0) {
    const cont = &ctx.containers.items[@intCast(n_parents + n_brothers - 1)];
    if (cont.ch != '>') {                    // "not a blockquote" ≠ "is a list"
        const block: *MD_BLOCK = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.block_bytes)) + cont.block_byte_off));
        block.bits.flags |= @as(u8, @truncate(MD_BLOCK_LOOSE_LIST));
    }
}
```

`block_byte_off` defaults to 0 (`types.zig:139`) and is assigned at exactly two
sites (`blocks.zig:819`, `:829`) — both list arms of
`md_enter_child_containers`. The MDC-only container kinds `ch=':'` (pushed
`:1467`) and `ch='#'` (pushed `:1203`) never assign it, so it stays 0, and
`!= '>'` admits them. The loose-flag write therefore lands on `block_bytes[0]`
— whatever block is first in the arena. When that is a `ul`/`ol` opener, an
earlier unrelated list flips loose.

Upstream md4c only ever has `'>'` and list marks on the container stack, so
`!= '>'` was a valid "is a list" test _there_; md4x's two extra container kinds
broke the invariant. The deleted C had identical code — **pre-existing md4x bug,
faithfully ported, not a port regression.**

```
$ printf -- '- a\n- b\n\n::c\n\nd\n::\n' | md4x
<ul>
<li><p>a</p>      <-- LOOSE, wrong
...
$ printf -- '- a\n- b\n\npara\n' | md4x     # control: correctly TIGHT
$ printf -- '- a\n- b\n\n> q\n\nd\n' | md4x # blockquote: correctly TIGHT
```

Reachable from ordinary MDC prose: any document opening with a list that later
contains a blank line inside a `::component` or `#slot`. Given md4x targets MDC,
real Nuxt Content documents plausibly hit this.

Fix: make the guard positive — `if (ISANYOF_(cont.ch, "-+*.)"))`. The same
`!= '>'`-means-list assumption also drives `blocks.zig:1237`, `:1243` and the
two-blank-lines hack at `:1256`; tightening `:1690` alone fixes the corruption,
but all four deserve the positive test.

> **GATE EXCEPTION — the corpus baseline currently ENCODES this bug.** If the
> seed corpus contains any list-then-component document, its 168 hashes bake in
> the wrong loose rendering. This is one of the rare changes that **must**
> produce a non-empty `diff-corpus.sh` diff. It requires a deliberate
> re-baseline plus a `test/regressions.txt` case, and **cannot** ride the
> "diff must be empty" rule.

### 10. Component/slot/alert index truncated to 16 bits

`blocks.zig:242` does `block.bits.data = @truncate(data)` into a `u16`
(`types.zig:98`). For ul/ol/li/h/table the payload is a mark char / level /
≤128 column count — all fit. But md4x also routes the **array index** of the
component/slot/alert info record through that field
(`container.start = @intCast(comp_idx)`, pushed `:843` / `:886`). Past 65,536
records the index wraps and `process.zig:724` / `:750` / `:765` reads the wrong
record — wrong tag name, wrong props, wrong slot name. Confirmed with a 775 KB /
65,537-component input: the 65,537th renders as `<first>` instead of `<c65536>`.

Not a memory-safety hole (the wrapped index is always < 65536 ≤ `items.len`, and
`process.zig` range-checks) — purely wrong output. Cheapest fix is a
`>= 0x10000` guard at the three `container.start = @intCast(idx)` sites,
refusing to open the component rather than silently aliasing. Widening
`bits.data` is a real `MD_BLOCK` layout change (it is `extern` and interleaved
in `block_bytes`).

### 11. All five `Parser` callbacks are nullable but unwrapped `.?`

`abi.zig:345-349` defaults all five to `= null`, but they are unwrapped `.?` at
7 sites (`process.zig:60`, `:66`; `inlines.zig:1795`, `:1801`, `:1811`;
`util.zig:144`, `:153`). `md_parse(text, size, &.{}, null)` is well-typed and is
**UB in ReleaseFast**. `debug_log` is the only one properly guarded.

Cheapest fix is compile-time: drop the `= null` defaults on the five and make
them non-optional. All 7 in-tree callers already set all five, so it costs
nothing and deletes 7 UB sites.

---

## Hard constraints (apply to all remaining work)

1. **Byte-for-byte output parity** for all 6 renderers + `md_heal`, the CLI's
   stdout per format/flag, and the wasm/napi/Comark-AST JS surface.
2. **Edge ABI stays C:** the wasm exported function set, the napi module
   registration, and the `qsort`/`bsearch` comparators in `refdefs.zig` (glibc
   tie-break parity) keep `export` / `callconv(.c)`. Nothing else may.
3. **Generated files off-limits** — `src/unicode_tables.zig`, `src/entity.zig`.
   Change the generator if output must change; it shouldn't.
4. **Do not touch engine logic** — the mark-resolution/emphasis mod-3 engine
   (`inlines.zig`) and the block-analysis state machine (`blocks.zig` /
   `process.zig`). Types and names may change; ordering and control flow may not.
5. **No Debug-vs-Release behavior**, and no `unreachable` on
   adversarially-reachable paths (prefer defensive guards). Note that
   `@enumFromInt` on an out-of-range value is a Debug panic and **ReleaseFast
   UB** — see `MD_BLOCK.typeIsRaw` in `types.zig` for the one place in the
   parser where a type byte may legitimately be garbage.
6. **Abort-code contract (do not break):** at the INTERMEDIATE block/span/text
   boundaries, `md_parse` propagates a NEGATIVE callback code verbatim but
   returns 0 for a POSITIVE one (md4c parity), because those boundaries test
   `ret < 0`. OOM and a callback returning `-1` are intentionally unified as
   `-1`.

   **DOC-level exception — the code is right, the old wording was wrong.**
   `md_process_doc`'s own bookends test `!= 0`, not `< 0`
   (`process.zig:934` `mdEnterBlock(.doc)`, `process.zig:958`
   `mdLeaveBlock(.doc)`), so a callback returning a POSITIVE code on the `.doc`
   block DOES propagate: `md_parse` returns 5, not 0. This is genuine md4c
   parity (upstream `MD_ENTER_BLOCK` aborts on `!= 0`).

   **Do NOT "fix" those two `!= 0` tests into `< 0`.** That would silently break
   md4c parity, and the corpus gate would stay green. The abort-matrix test does
   not currently pin this: it explicitly excludes the doc block
   (`detail.* != .doc`, `md4x.zig:695` / `:700`), so nothing catches a
   regression in either direction — see item 8.

7. **Keep docs in sync** — `AGENTS.md` / `docs/*.md` / `CHANGELOG.md`.

---

## Verification gate (run after every change)

```sh
bun fmt
zig build
zig build test                                      # ReleaseFast (default)
zig build test -Doptimize=Debug                     # undefined-fill + allocator length checks
bun scripts/run-tests.ts                            # 16 spec suites + pathological (1001 assertions)
python3 test/pathological-tests.py -p zig-out/bin/md4x
bash scripts/diff-corpus.sh > /tmp/md4x-now.sha
diff /home/dev/.md4x-gate/baseline.sha /tmp/md4x-now.sha   # MUST be empty
# Memory-touching changes also:
zig build fuzz-zig                                  # ReleaseSafe smoke
zig build wasm && bun vitest run packages/md4x/test/wasm.test.mjs
zig build napi-linux-x64 -Dnapi-include=node_modules/node-api-headers/include \
  && bun vitest run packages/md4x/test/napi.test.mjs
```

Use `bun`/`bunx` only — never npm/pnpm/yarn/npx.

**Corpus baseline:** `/home/dev/.md4x-gate/baseline.sha` (168 hashes). Every
commit from `83abae9` onward is output-identical, so it can be re-captured from
any of them if lost (build that commit, run `diff-corpus.sh`). Any non-empty
diff is a **stop-the-line** regression — bisect, fix, or revert. The hash lines
are labelled `fmt:file`, so a diff immediately localizes which renderer broke.

**The golden SAX event trace** (`zig build test`) is the authoritative check for
anything touching the emission path: the corpus compares only each renderer's
final bytes, so a detail-packaging change two renderers paper over can pass it.
The expected value is a _recorded_ baseline. Treat a trace diff as
stop-the-line; to re-record after a deliberate change, temporarily
`std.debug.print` `probe.out.items` from the test and justify the change in the
commit message.

Known pre-existing noise: `zig fmt --check` fails on `src/md4x.zig` (an aligned
debug-dump block) and `src/unicode_tables.zig` (generated). Both predate this
work — leave them.
