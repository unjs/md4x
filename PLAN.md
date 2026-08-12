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

Everything below is **ordinary idiomatization or doc upkeep**. The structural
work is finished — there is no remaining C-ABI seam, and nothing here is
load-bearing for correctness. Land these in any order, each behind the full
verification gate.

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
6. **Abort-code contract (do not break):** `md_parse` propagates a NEGATIVE
   callback code verbatim but returns 0 for a POSITIVE one (md4c parity). OOM
   and a callback returning `-1` are intentionally unified as `-1`.
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
