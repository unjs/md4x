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

**Landed 2026-08-12** (all behind the full gate, golden SAX trace unchanged,
nothing re-recorded; corpus diff-clean at 168 hashes for every item except 9,
whose six changed hashes are the `test/regressions.txt` **input file** growing —
see its section below):

| Item                              | Commits                         |
| --------------------------------- | ------------------------------- |
| 3 — `MD_LINETYPE` member rename   | `49855c4`                       |
| 1 — `TRUE`/`FALSE` → `bool`       | `5ab9a3d`, `c501ac1`, `e648b3b` |
| 1b — renderer state fields        | `3c3d2f7`                       |
| 2 — `MD_MARK_*` → `MarkFlags`     | `dbd8720`                       |
| 6 — doc gaps (first two bullets)  | `494cf3f`, `73d6e27`            |
| 9a — quadratic `{...}` attrs scan | `521bca5`                       |
| 1c — attr builder OOM free length | `efd4025`                       |
| 8 — `zig build test` in CI + safe | `4855d1b`                       |
| 9b — out-of-range mark cursor     | `c666da4`                       |
| 9 — list loosened by `::` / `#`   | `ce1db56`                       |
| 10 — 16-bit comp/slot/alert index | `7db8d1b`                       |
| 11 — required `Parser` callbacks  | `7785acc`                       |
| 7 — delete the dead `growArray`   | _the commit adding this row_    |

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
are not refactors and must not ride along with one. **All of them — 9, 9a, 9b,
10 and 11 — are landed**; see the table above. Only the idiomatization/doc items
4, 5 and 6 remain.

**Suggested priority.** `8` is **landed** (it was why three of these bugs went
unseen); take the rest in any order.

**Ordering constraint.** Items 7 and 5 rewrote overlapping parser files and had
to stay **serial**; 7 is now landed, so 5 is unblocked. Renderer-only and
docs-only work parallelizes freely.

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

### ~~7. Delete the dead `growArray` / `c_realloc_array` idiom~~ — LANDED

Census re-verified at `7785acc` before deleting anything (line numbers had
drifted from PLAN's, but the shape was exactly as described): `growArray`
(`util.zig:754`) had zero production callers — only the unit test at
`md4x.zig:1165`; `c_realloc_array` (`util.zig:741`) was called only from inside
`growArray` (`util.zig:760`); its three aliases (`md4x.zig:155`,
`blocks.zig:44`, `inlines.zig:38`) were never called; and `c_malloc_array`
(`util.zig:733`) had one use, the test-only `_test_run_inline` driver at
`md4x.zig:368`. Nothing had gained a production caller — in particular item 9a's
new `brace_pairs` array is an `ArrayListUnmanaged`, not a `[*c]T`.

All three helpers plus the three aliases are deleted, and `_test_run_inline`
allocates its line array through `ctx.alloc` (`alloc_array_a`, freed by
`free_array_a` at the identical `size + 2` count). **`std.c.malloc` and
`std.c.realloc` now have zero occurrences in `src/md4x.zig`, `src/abi.zig` and
`src/parser/`**, so the `AGENTS.md` "Growable arrays" bullet states the absolute
instead of steering new code onto a raw-libc path the `FailingAllocator` sweep
cannot inject into.

**Residual libc in the parser (item 5's remit):** eight `std.c.free` calls, all
freeing `md_merge_lines_alloc` buffers — `refdefs.zig:391`, `:393`, `:735`,
`:736`, `:780`; `inlines.zig:1274`; `process.zig:273` (the `ptr_stack` walk);
and `md4x.zig:392` (the same walk in the test-only `_test_run_inline`). No
`std.c.malloc`/`realloc` anywhere; the five `extern "c"` declarations in
`util.zig` (`qsort`/`bsearch`/`memcmp`/`strcspn`/`memmove`) are not allocation.

The retired `growArray` test is replaced by one over the **live** helpers
(`alloc_array_a` / `realloc_array_a` / `free_array_a`), which had no direct
coverage: it pins zero-count → null, data survival across a grow **and** across
the `md_parse_highlights` shrink-to-fit, a null `old` meaning "fresh alloc", and
the injected-OOM contract (null return, old block intact and still freeable).
The one property genuinely lost is `growArray`'s 1.5× schedule, which no longer
exists in any form.

### ~~8. `zig build test` runs in neither CI nor safe mode~~ — LANDED

All three sub-problems are fixed; see the landed table above.

- **Now in CI, twice over.** `scripts/run-tests.ts` runs `zig build test` before
  the `.txt` suites (so the documented "run all test suites" entry point covers
  parser internals), and `.github/workflows/ci.yml` gained a dedicated
  `Zig unit tests` step running both `zig build test` and
  `zig build test -Doptimize=Debug`. That workflow's single `build` job triggers
  on `pull_request`, so both now run on every PR.
- **Test artifact pinned to a safe mode.** `build.zig` no longer hands the
  global `-Doptimize` (default `.ReleaseFast`) to the test artifact:
  `.optimize = if (optimize == .Debug) .Debug else .ReleaseSafe`. Confirmed as
  `-OReleaseSafe` by `zig build test --summary all`. The pin is self-checking —
  the `test artifact is built with runtime safety armed` case asserts
  `std.debug.runtime_safety`, so removing it fails the suite. Enabling
  ReleaseSafe surfaced **no** new failures.
- **Doc-level abort behavior pinned.** `AbortProbe` gained `abort_on_enter_doc`
  / `abort_on_leave_doc` (deliberately separate from the `!= .doc` block flags,
  because the doc block has a different observable contract), and two new tests
  pin constraint #6's doc-level exception in both directions: `md_parse`
  returns `5` for a `+5` and `-7` for a `-7` on `.doc`, and an
  `enter_block(.doc)` abort emits nothing at all. Verified by mutation: flipping
  `process.zig`'s two `!= 0` bookends to `< 0` (the exact "fix" constraint #6
  forbids) fails both new tests with `expected 5, found 0`, while the corpus
  gate, the spec suites and the golden SAX trace all stay green — which is
  precisely why they were needed. Mutation reverted.

---

## Bugs found by audit (live, user-visible — not idiomatization)

> These are **not** refactors and must not ride along with one. Each needs its
> own commit and its own regression test.

### ~~9b. Out-of-range pointer in `md_scan_left_for_resolved_mark`~~ — LANDED

Confirmed before fixing, with temporary instrumentation on a Debug build: the
hand-traced trigger was right (the real mark table has 3 entries, not 2, but the
mechanism is exactly as described). `a.b@c.d` prints
`cursor index -1 ... off=1`; `a.b.c@d.e` forms the terminal at `off=3` and then
**re-enters the scan with it** at `off=1`; `a-b_c.d@e.f` re-enters three times.

The `left_cursor`/`right_cursor` pair is now a signed mark index
(`inlines.MarkCursor` = `isize`), and the two scans return `?*MD_MARK` instead
of `[*c]MD_MARK`. Both terminals are representable — `-1` on the left,
`nMarks()` on the right — with no pointer formed. Traversal order, the visited
mark set and every early exit are unchanged (constraint #4): the loop bound
`mark >= items.ptr` became `idx >= 0` and `mark < end_ptr` became
`idx < nMarks()`, nothing else. Corpus diff empty at 168 hashes, golden SAX
trace unchanged.

Regression coverage: a unit test pinning both helpers' cursor terminals _and_
the inert re-feed of a terminal cursor, plus an end-to-end `md_parse` case over
eight back-scan inputs. Both run in the ReleaseSafe test artifact item 8 pinned,
so the new `items[@intCast(idx)]` bounds checks are armed on this path — which
is the only kind of proof a no-output-change UB fix can have.

**No `test/regressions.txt` case, on purpose.** Output never changed, so a
rendered-HTML diff has no signal here; and `test/*.txt` is itself a
`diff-corpus.sh` **input**, so adding cases mutates six corpus hashes (one per
format) and forces a re-baseline. Item 9b was granted no gate exception, so the
cost buys nothing. If a `.txt` case is ever wanted for this, land it alongside
item 9, which already requires a deliberate re-baseline.

### ~~9. `::component` / `#slot` retroactively flips an earlier list to loose~~ — LANDED

**Live output-correctness bug, reproduced.** `blocks.zig:1688-1693` used
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

**Fixed by making that one guard positive** — `if (ISANYOF_(cont.ch, "-+*.)"))`
— and **only** that one. PLAN proposed the same positive test for the other
three `!= '>'`-means-list sites (`blocks.zig:1238`, `:1244`, and the
two-blank-lines hack at `:1258`); all three were evaluated with dedicated
binaries and rejected, because both turn out to be behaviorally load-bearing:

- **`:1238`** (`last_line_has_list_loosening_effect`) — the flag's only consumer
  is `:1690`, so narrowing it is redundant _and_ harmful. A differential run of
  11 825 generated container-shaped documents found 22 where it changes output,
  all one shape: an indented blank line inside a component/slot that is itself
  inside a list item, followed by a new list item (`- ::c` / `␠␠` / `- b`). The
  blank line genuinely separates two list items, so CommonMark makes that list
  **loose** — which the current code gets right and the positive test would
  break. Pinned as the third case in `test/regressions.txt`.
- **`:1244` / `:1258`** (the empty-list-item two-blank-lines hack) — a 15 994
  document differential found one divergence
  (`::c` / `x` / `␠␠- ` / `␠␠` / `1. ` / `- #s`). There the hack fires off a
  **garbage type byte**: `x\n  -` is a setext `h2`, so the tail of `block_bytes`
  is an `MD_LINE` payload whose `beg == 4` reads back as the `li` ordinal —
  exactly the misread `MD_BLOCK.typeIsRaw` exists to tolerate. Today that makes
  `n_parents -= 1` pop the **component** and close it early; the positive test
  would keep it open. Arguably an improvement, but it is a distinct defect with
  its own output change, so it does not belong in this commit and is not covered
  by the gate exception below.

> **GATE EXCEPTION — the corpus baseline currently ENCODES this bug.** If the
> seed corpus contains any list-then-component document, its 168 hashes bake in
> the wrong loose rendering. This is one of the rare changes that **must**
> produce a non-empty `diff-corpus.sh` diff. It requires a deliberate
> re-baseline plus a `test/regressions.txt` case, and **cannot** ride the
> "diff must be empty" rule.

**The exception turned out not to be needed for the parser fix.** Two-staged as
required. **Stage A** (parser fix alone, `test/regressions.txt` untouched): the
corpus diff is **empty**. The seed corpus contains no document that both opens
with a list and later blanks a line inside a component/slot — every `::` in the
spec `.txt` files sits inside a 32-backtick `example` fence, and
`seed-corpus/components.md`, which does have real components and blank lines
inside them, has no list at all (its `block_bytes[0]` is the `:icon-star`
paragraph, and `MD_BLOCK_LOOSE_LIST` on a non-list block is simply ignored).
**Stage B** (regression cases added): exactly six hashes change, one per format,
all `test/regressions.txt` — the file is itself a corpus input, so appending
~70 lines of test text moves them. Attribution proved directly: the **pre-fix**
binary produces byte-identical hashes to the fixed one over the new file for all
six formats, so zero of the six is caused by the parser change. Baseline
re-captured at 168 hashes; the pre-item-9 copy is kept at
`/home/dev/.md4x-gate/baseline-pre-item9.sha`.

Golden SAX trace unchanged. Regression coverage is bidirectional: the two bug
cases fail against the pre-fix binary, and the third case fails against the
"all four positive" variant.

### ~~10. Component/slot/alert index truncated to 16 bits~~ — LANDED

**All three sites confirmed drivable, not just the component one.** Reproduced
against the pre-fix binary with three generated documents, each 65,537 records:

| Site        | Input                         | Size   | Parse | 65,537th rendered as     |
| ----------- | ----------------------------- | ------ | ----- | ------------------------ |
| `component` | `::cN` / `::` × N (flat)      | 775 KB | 20 ms | `<c0>` (want `<c65536>`) |
| `template`  | `::box` + `#sN` + blank × N   | 578 KB | 20 ms | `name="s0"`              |
| `alert`     | `> [!tN]` / `> x` / blank × N | 1.1 MB | 36 ms | `class="alert alert-t0"` |

Slots are the cheapest per record (4 bytes), not components — and the _nested_
component form (`::cN` × N with no closers) costs 3.2 s for a 65,537-deep
container stack, while the flat form above is 20 ms, so none of the three is
expensive to reach.

Fixed as PLAN suggested, with the guard moved **before** the info-record push
rather than at `container.start = @intCast(idx)`: `types.MAX_BLOCK_INFO_RECORDS`
(`0x10000`) now gates the three openers' recognition conditions
(`blocks.zig` component / slot / alert). Placing it before the push also means
no `@intCast` ever sees an out-of-range index — relevant because item 8 made
`zig build test` ReleaseSafe, where an `@intCast` range violation panics, and
ReleaseFast, where it is UB.

**The refusal renders as literal text**, which is exactly what each construct
degrades to with its extension disabled: `<p>::c65536\n::</p>`,
`<p>#s65536</p>`, and a plain `<blockquote><p>[!t65536]\nx</p></blockquote>`
(the last is already the documented behavior for a disqualified alert). The
line simply falls through the rest of line classification. Refusing at the
_opener_ is what keeps SAX emission balanced (AGENTS.md memory-safety pattern
#4): no container is pushed, so none is popped — verified as 65,536 enters and
65,536 leaves on all three paths.

Corpus diff empty at 168 hashes (nothing in the corpus is within four orders of
magnitude of the cap), golden SAX trace unchanged. Pinned by a Zig unit test
(`16-bit info index: component/slot/alert openers stop at the cap`) that drives
all three sites to `cap + 2` records and asserts the count, the last record's
name, enter/leave balance, and that no later record re-emits the first one's
name. It fails against the pre-fix parser (`expected 65536, found 65538`). It
is deliberately **not** a `test/regressions.txt` case: the smallest input that
reaches the cap is ~578 KB, and that file is itself a `diff-corpus.sh` input.

### ~~11. All five `Parser` callbacks are nullable but unwrapped `.?`~~ — LANDED

Fixed exactly as PLAN proposed: the five fields in `src/abi.zig` are now
non-optional **and** un-defaulted, and all 7 `.?` unwraps are plain calls
(`process.zig:58`, `:64`; `inlines.zig:1840`, `:1846`, `:1856`; `util.zig:144`,
`:153`). Being un-defaulted is what carries the guarantee: with a default of
`undefined` or a no-op, `Parser{}` would still compile and a _partially_ filled
table would still be constructible. `md_parse(text, size, &.{}, null)` now fails
to compile with `error: missing struct field: enter_block` (+4 notes) — verified
by temporarily adding exactly that call. `debug_log` stays optional.

**PLAN's "all 7 in-tree callers already set all five" was right in substance but
undercounted.** There are **11** constructors, not 7 — the six renderers, the
`fuzz.zig` parser-only harness, and **four** probes in `md4x.zig` (`AbortProbe`,
`HrefProbe`, `CapProbe`, `TraceProbe`) — and every one of them did already set
all five, so no caller's behavior changed. All 11 moved from
`var p: c.Parser = .{}` + field assignments to a single struct literal, which is
what the un-defaulted fields force.

**One site PLAN did not mention:** `MD_CTX.parser` (`types.zig:293`) was
`c.Parser = .{}` — a field default that no longer exists. It is now
`types.noop_parser`, an all-no-op table declared next to `MD_CTX`. It is never
observable in production (`md_parse` overwrites `ctx.parser` before any
emission); it exists only so the six `MD_CTX = .{ … }` sites — three of which
are unit tests that build a bare context and never emit — keep working.

Pinned by a `zig build test` case (`Parser: the five SAX callbacks are
non-optional and required`) that asserts, via `@typeInfo`, that each of the five
is a non-optional pointer with **no default**, and that `debug_log` is still
optional-with-default. A true negative compile test is not expressible in Zig's
test runner, so this asserts the shape of the type that produces the compile
error instead.

Corpus diff empty at 168 hashes, golden SAX trace unchanged.

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
   md4c parity, and the corpus gate would stay green. This IS now pinned (item
   8, landed): the abort matrix still excludes the doc block from its
   intermediate-boundary cases (`detail.* != .doc`), but the companion test
   `callback abort: doc-level enter/leave propagate BOTH signs (md4c parity)`
   asserts `md_parse` returns `5` for a `+5` and `-7` for a `-7` on `.doc`.

7. **Keep docs in sync** — `AGENTS.md` / `docs/*.md` / `CHANGELOG.md`.

---

## Verification gate (run after every change)

```sh
bun fmt
zig build
zig build test                                      # ReleaseSafe (pinned in build.zig)
zig build test -Doptimize=Debug                     # undefined-fill + allocator length checks
bun scripts/run-tests.ts                            # zig build test + 16 spec suites + pathological (1001 assertions)
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
commit from `83abae9` onward is output-identical **except item 9's**, which
changes the six `test/regressions.txt` hashes by growing that input file (the
parser fix itself is diff-clean); re-capture from `HEAD` if lost, or from any
earlier commit for the pre-item-9 set, also kept at
`/home/dev/.md4x-gate/baseline-pre-item9.sha`. Any non-empty
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
