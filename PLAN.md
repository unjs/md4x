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

Items 1–8 are **ordinary idiomatization or doc upkeep**: the structural work is
finished, there is no remaining C-ABI seam, and none of it is load-bearing for
correctness. Land them in any order, each behind the full verification gate.

**Items 9–11 are different.** They are live bugs found by an independent audit
during this session — one of them (item 9) is user-visible and reproduces on
ordinary MDC prose. They are not refactors, they must not ride along with one,
and item 9 deliberately **breaks the "corpus diff must be empty" rule** because
the baseline currently encodes the bug. Read the gate exception on item 9 before
touching it.

**Ordering.** Items 1c/2/7/5 all rewrite overlapping parser files and must stay
serial. Item 1b is renderer-only and runs in parallel with them. Current chain:
`1 → 1c → 2 → 7 → 5`, with `1b` alongside, and the bug items sequenced by
whoever picks them up.

### 1. `TRUE` / `FALSE` → `bool` (~213 sites)

The two `c_int` constants survive across the parser where the value is
genuinely two-state:

| File                     | Uses |
| ------------------------ | ---: |
| `src/parser/blocks.zig`  |   77 |
| `src/parser/inlines.zig` |   62 |
| `src/parser/refdefs.zig` |   59 |
| `src/parser/util.zig`    |    5 |
| `src/parser/process.zig` |    5 |
| `src/md4x.zig`           |    5 |
| `src/parser/types.zig`   |    2 |

**Exception — do not convert:** tri-state recognizers that also signal OOM keep
returning `c_int` (`-1` / `0` / `N`). Check each site before flipping it; a
"boolean" that can also be `-1` is not a `bool`.

**Named must-not-convert sites** (found by audit; a token-level sweep hits all
of these because they contain `TRUE`/`FALSE` tokens whose real return domain is
`0..7`, not two-state):

- `md_is_html_block_end_condition` (`blocks.zig:592`) — returns 0..7. Its
  `return TRUE` is the literal HTML-block **type 1**. Call sites test `> 0`,
  `== 6 or == 7`, and — the critical one — `== ctx.html_block_type`
  (`blocks.zig:1580`), the primary close-detection test, which under `bool`
  degrades to "any end condition closes any block type". **The corpus gate
  cannot catch this.** Sub-trap: four arms are
  `return if (md_line_contains(...) != 0) N else FALSE` — integer-valued, so if
  `md_line_contains` becomes `bool` those `else FALSE` must become `else 0`.
- `md_is_html_block_start_condition` (`blocks.zig:504`) — returns 0..7; its lone
  `FALSE` token is a C-ism for 0. Its doc comment ("or FALSE (0)") is what
  should be fixed, not the function.
- `is_link` in `md_resolve_links` (`inlines.zig:1102`) — **already correct as
  `c_int`**; it carries `-1` OOM and is read `< 0` in three places. Do not
  "finish" it. This is the one case where the right answer looks like an
  unfinished conversion.
- `MD_CONTAINER.is_loose` (`types.zig:134`) — holds the value **4**, not 1
  (assigned `flags & MD_BLOCK_LOOSE_LIST`, mask `0x04`). A Zig `bool` holding
  byte 4 is **illegal behavior — UB in the shipping ReleaseFast build**.
  Converting it requires rewriting the assignment as `!= 0`; an
  `@intCast`/`@truncate` "fix" is wrong. Default action: skip.
- `MD_CTX.frontmatter_state` (0/1/2), `MD_CTX.html_block_type` (0..7),
  `MD_CONTAINER.comp_fm_state` — tri-state, no `TRUE`/`FALSE` tokens. Safe under
  a token grep; a "flip the `c_int` flags in `MD_CTX`" sweep would eat them.

**Golden-trace hazard.** `src/md4x.zig` `_test_run_analyze` prints six flag
fields with `{d}`: `line.enforce_new_block`, `co.is_loose`, `co.is_task`,
`co.is_alert`, `ctx.last_line_has_list_loosening_effect`,
`ctx.last_list_item_starts_with_two_blank_lines`. `{d}` on a `bool` does not
compile, and the obvious fix (`{}`/`{any}`) prints `true`/`false` where the
recorded baseline has `1`/`0` — a stop-the-line trace diff. Keep the output
byte-identical with an explicit `@intFromBool(...)` at each print site.
**Do not re-record the baseline.**

### 1b. `TRUE` / `FALSE` → `bool` in the renderers (24 sites)

Item 1's scope names only `md4x-ast.zig`'s `tag_is_dynamic`, but that is 1 of 25
boolean-like `c_int` fields in the renderers. As scoped, item 1 leaves the parser
on `bool` and six renderers on `c_int` for the identical idiom.

| File                | Count | Fields                                                                                                                              |
| ------------------- | ----: | ----------------------------------------------------------------------------------------------------------------------------------- |
| `md4x-markdown.zig` |     9 | `in_code_block`, `in_code_span`, `need_newline`, `need_indent`, `li_opened`, `in_frontmatter`, `in_table`, `in_thead`, `thead_done` |
| `md4x-ansi.zig`     |     6 | `in_code_block`, `need_newline`, `need_indent`, `li_opened`, `in_alert`, `in_comp_frontmatter`                                      |
| `md4x-text.zig`     |     5 | `in_code_block`, `need_newline`, `need_indent`, `li_opened`, `in_frontmatter`                                                       |
| `md4x-html.zig`     |     2 | `in_frontmatter`, `in_code_block`                                                                                                   |
| `md4x-meta.zig`     |     2 | `in_frontmatter`, `in_heading`                                                                                                      |

All are plain (non-`extern`) renderer state structs, so layout-safe. Each still
needs the individual assigned-a-non-0/1 audit — that has **not** been cleared.
The `tag_is_dynamic`-first dispatch rule must survive its own type change.

Renderer-only, so this runs **in parallel** with the parser chain.

### 1c. `md_build_attr_append_substr` frees at the wrong length on OOM

**A real bug**, not idiomatization. `util.zig:511-536` commits
`build.substr_alloc` to the new capacity _before_ either realloc runs, and can
return `error.OutOfMemory` between them; `md_free_attribute`
(`util.zig:546-550`) derives **both** freed lengths from that advanced value.
Growing from `substr_alloc == 8`: if the types realloc fails, `substr_types` is
still 8 but freed as 12 **and** `substr_offsets` is still 9 but freed as 13 (two
mismatches); if the offsets realloc fails, offsets is still 9 but freed as 13.
No leak or double-free — purely a wrong freed length, i.e. exactly the
exact-length invariant `AGENTS.md` pins to these helpers.

Production is **unaffected** (ReleaseFast + `c_allocator`, whose `free` ignores
the length). It matters under `std.testing.allocator`, where a large allocation
(`substr_alloc > 512`) takes the large-alloc path and the length drives the
unmap size — and it blocks making `ctx.alloc` freely injectable.

**Why the gate never caught it:** the OOM sweep's richest attribute is the title
`"a &amp; b"` — 3 substrings — so `substr_alloc` never leaves 8 and the
`old_alloc > 0` growth branch **has never executed in the test suite at all**.

Fix: a second `types_alloc` capacity field (the two arrays legitimately diverge
mid-growth, so one field cannot express the state); don't publish capacity until
both blocks exist; free `substr_types` by `types_alloc` and `substr_offsets` by
`substr_alloc + 1`. `md_push_block_bytes` (`blocks.zig:82`) already does this
correctly and is the in-repo model. **Extend the OOM sweep document with a
≥8-substring attribute** (e.g. `[t](/u "a&amp;b&amp;c&amp;d&amp;e&amp;f&amp;g&amp;h")`) so the growth
path is covered at all — demonstrate the failure before fixing it.

Land this **before** item 5: routing three more buffers into a builder that
already gets one exact length wrong is backwards.

`inlines.zig` and `blocks.zig` are the mark engine and block state machine —
**constraint #4 applies**, so change the type only, never the control flow.
The internal `MD_CTX` / `MD_CONTAINER` `c_int` flags (`is_task`, `is_alert`,
`is_ordered_list`, …) and the AST renderer's `tag_is_dynamic: c_int` are part of
this sweep.

### 2. `MD_MARK_*` namespacing (§8.7) (~150 sites)

The mark flags are still loose `MD_MARK_*` consts. Group them into a namespaced
declaration (or a packed flags struct) the way `BlockType`/`SpanType` were
handled in 4c.

**This lives in the emphasis/mark-resolution engine — the single most
delicate file in the project.** Do it as its own commit, gate it hard, and
never combine it with a logic change.

### 3. `MD_LINETYPE` member rename (§8.8)

`src/parser/types.zig:40` — members are still `MD_LINE_BLANK`, `MD_LINE_HR`, …
on an otherwise idiomatic Zig enum. Rename to `.blank`, `.hr`, … matching the
`BlockType`/`SpanType` convention 4c established. Mechanical; the compiler finds
every site.

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

### 6. Doc gaps

- **`docs/renderers.md` has no markdown-renderer section.** `md_markdown` ships,
  has a CLI format (`--format=markdown`), and is covered by `spec-markdown.txt`
  and the corpus, but is the only renderer with no API section. Add one matching
  the others (signature, flags, rendering details).
- **`docs/renderers.md`'s `MD_HTML_OPTS` snippet is stale** — it shows
  `[*c]const u8` fields where the real type is `?[*:0]const u8`.
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

### 9a. Quadratic blow-up in the `{...}` attributes scan — HIGHEST PRIORITY

**Measured, reproduced, and security-relevant.** `inlines.zig:1730`
(`md_resolve_attrs`) and `:1257` (`md_resolve_links`) both scan forward to
`ctx.size` — the whole **document**, not the block — and bail only when brace
depth returns to 0. With **unbalanced** braces depth never reaches 0, so every
candidate closer re-scans the entire remaining document.

Measured on `zig-out/bin/md4x`, no flags:

| Input  | Size   | Unbalanced `'*a*{'` | Control `'*a* '` |
| ------ | ------ | ------------------: | ---------------: |
| ×10000 | 40 KB  |              185 ms |             3 ms |
| ×20000 | 80 KB  |              717 ms |             4 ms |
| ×40000 | 160 KB |             2952 ms |             7 ms |

Clean 4× per doubling. The `[t]{` variant via `:1257` behaves identically.
Extrapolated, a 1 MB paste is ~2 minutes.

`MD_FLAG_ATTRIBUTES` is **on by default** in the CLI and in both JS bindings, so
this is reachable from untrusted input — anyone pasting markdown into a service
built on md4x. `docs/parser-api.md` explicitly advertises a **"Linear time
guarantee"**, and `test/pathological-tests.py` has **no brace-based case**,
which is why it was never caught. The identical loop is in the deleted C, so
this is inherited, not a port defect — but it ships.

Fix (output-preserving, O(size)): add an `MD_CTX` field in the style of the
existing `html_*_horizon` cache. Let `bal(x)` be the running `'{'`−`'}'` prefix
balance. A scan from `s` succeeds iff some `x > s` has `bal(x) = bal(s) − 1`; a
**failed** scan from `s` proves `bal(x) >= bal(s)` for all `x >= s`. So record
`brace_fail_floor = bal(s)` on first failure, and any later candidate `s'` with
`bal(s') <= brace_fail_floor` fails in O(1). Candidates are visited in
increasing `mark.end` in `md_resolve_attrs`, so maintaining `bal` incrementally
makes the pass linear.

Add `'*a*{' ×50000` and `'[t]{' ×50000` cases to `test/pathological-tests.py`.

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
