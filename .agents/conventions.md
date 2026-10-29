# Parser & Renderer Conventions

Internal-only rules. Byte-for-byte output stays frozen; the internal calling convention does not.
Each rule below exists because the obvious "modernization" of it is wrong — check which case you have
before changing anything.

## Allocation

Every parser allocation goes through `ctx.alloc`, so the `FailingAllocator` OOM sweep can inject
failure into it and leak-check it. **`std.c.malloc` / `std.c.realloc` / `std.c.free` have zero
occurrences in `src/md4x.zig`, `src/abi.zig` and `src/parser/`. Do not add one back.** There is no
`[*c]T` + `n_*`/`alloc_*` grow idiom left either — `util.growArray` and its libc backers are deleted.
Do not hand-write `if (n >= alloc) { … realloc … }`.

Three buffer flavors, each with its own helper family:

| Kind                                                                                                                                                                        | Helper                                                    | Notes                                                                                                                                                 |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| The nine typed growable arrays (`marks`, `containers`, `ref_defs`, `footnote_defs`, `block_component_info`, `slot_info`, `block_alert_info`, `inline_attrs`, `brace_pairs`) | `std.ArrayListUnmanaged(T)` over `c_allocator`            | `.append(c_allocator, …)`, `.clearRetainingCapacity()`, `.deinit(c_allocator)`, index via `.items[i]`. Depth is `ctx.nContainers()` / `ctx.nMarks()`. |
| Raw byte arenas the parser reinterprets as typed records (`block_bytes`, the ref-def hashtable array, `MD_REF_DEF_LIST` flexible-array buckets)                             | `util.arena_alloc` / `arena_realloc` / `arena_free`       | 16-byte aligned, mirroring libc `max_align_t`. `arena_realloc` returns null on OOM and leaves the old block intact.                                   |
| Typed scratch buffers (`md_build_attribute`'s `text`/`substr_*`, `process.zig`'s `pipe_offs`/`align_arr`/code-`meta`)                                                       | `util.alloc_array_a` / `realloc_array_a` / `free_array_a` | `[*c]T` in/out, element-count tracked.                                                                                                                |

Rules that apply across all three:

- **The caller tracks the exact allocated length and passes it back on free/realloc.** The std
  allocators validate it, so a wrong length is a Debug crash.
- **One length field per buffer, published only after the block it describes exists.** A helper
  growing two arrays in one step can fail between them, so a shared capacity would describe a block
  that was never resized. `md_build_attr_append_substr` keeps `types_alloc` separate from
  `substr_alloc` and assigns each only after its own realloc returns; `md_push_block_bytes` advances
  `n_block_bytes` only after the arena grew. Do not "simplify" either into one up-front commit.
- **Shrink-to-fit where the length field is the only record of the allocation.**
  `md_parse_highlights` shrinks to `count` (`BlockCodeDetail.highlights` is a slice with no
  capacity). `md_merge_lines_alloc` allocates `end - beg` but usually writes fewer bytes, and callers
  keep only the collapsed `*_size` — the shrink is what makes that the exact free length. Keep its
  **zero-length guard** too (`n == 0` → null string, size 0): `Allocator.alloc(0)` short-circuits the
  vtable and returns a non-null `maxInt(usize)` sentinel, unlike C's `malloc(0)`.
- **Teardown order:** the ref-def hashtable indexes into `ctx.ref_defs`, so `md_free_ref_def_hashtable`
  runs **before** `md_free_ref_defs`. The footnote pair has the same dependency, and
  `md_free_footnote_defs` encodes it internally (hashtable, then the owned `content_lines`
  arrays, then the list).
- `ptr_stack` entries (merged inline-link titles, stored in a dummy mark by `md_mark_store_ptr`) are
  freed by `inlines.md_mark_free_ptr`, which reads the length back out of the same mark's `prev`
  field — the size `md_resolve_links` already writes there for the emission path.
- OOM-only internal helpers return `error{OutOfMemory}` (`md_build_attribute`, the `md_push_*` /
  `md_add_mark` pushers). Use `try` / `catch`; do not invent new `-1`-on-OOM `c_int` returns.

## Pointers, cursors, slices

- A cursor a loop can step **past the front** of an array must be a **signed index, never a
  pointer**: `items.ptr - 1` is out-of-range pointer arithmetic (poison under `getelementptr`) even
  if only compared. The permissive-autolink boundary scans (`md_scan_left_for_resolved_mark` /
  `md_scan_right_for_resolved_mark`) carry an `inlines.MarkCursor` (`isize`) for exactly this reason
  — the left walk terminates at `-1`, the right at `nMarks()`. Raw `.items.ptr` walks are fine only
  where pointer arithmetic is intrinsic (the emphasis engine).
- Functions scanning a block's lines take a `[]const MD_LINE` **slice**, not `[*c]const MD_LINE` +
  `n_lines`, so line access is bounds-checked in Debug/ReleaseSafe.
- Never cache a pointer into a growable buffer across a call that may reallocate.
- **Renderer-owned strings are sentinel slices, never `[*:0]` + `strlen()`.** The AST renderer's
  `JsonNode` / `Detail` fields are `?[:0]u8`: the length is the exact byte count, and the NUL
  terminator survives only for the C-shaped consumers (the props parser, libyaml). A U+0000 is legal
  document content — the parser reports it as `TextType.nullchar` — so recomputing a length with
  `strlen()` silently truncates the value. An `Attribute`-derived string substitutes its `.nullchar`
  substrings with **U+FFFD** (what `render_attribute()` does in every other renderer); a raw-source
  passthrough keeps the byte and lets the JSON writer escape it.

## `bool` vs `c_int`

Two-state means `bool` — locals, parameters (`table_mode`, `enter`, `is_autolink`), out-params
(`p_missing_mailto`, `p_reached_paragraph_end`), the `md_is_*` line classifiers, entity recognizers,
raw-HTML/code-span recognizers, and the genuinely two-state `MD_CTX`/`MD_CONTAINER`/`MD_LINE_ANALYSIS`
fields. There are **no `TRUE`/`FALSE` `c_int` constants** left; write `true`/`false`, or `1`/`0` where
the value really is an integer.

Three kinds of site **deliberately stay `c_int`**:

1. **Tri-state recognizers that also signal OOM** (`-1`/`0`/`N`) — `md_is_link_reference_definition`,
   `md_is_link_reference`, `md_is_inline_link_spec`, and the `is_link` local in `md_resolve_links`.
   `-1` is truthy under the C idiom, so a `bool` here silently swallows OOM.
2. **Recognizers whose return domain is `0..N`** — `md_is_html_block_start_condition` /
   `md_is_html_block_end_condition` return the raw-HTML block type `1..7` (or `0`), compared against
   `ctx.html_block_type` and against `6`/`7`. A `TRUE` there is the literal `1`.
3. **Multi-state fields that merely look like flags** — `frontmatter_state`, `comp_fm_state` (0/1/2),
   `html_block_type` (0..7), and `MD_CONTAINER.is_loose`, a `u8` holding the **masked
   `MD_BLOCK_LOOSE_LIST` bit (value 4)**, not 1. A Zig `bool` holding byte 4 is illegal behavior, and
   the shipping build is `ReleaseFast`, where that is UB rather than a panic.

**Never convert a `c_int` field of an `extern struct`** — that is a layout change, not a type change,
and it silently desynchronizes the `block_bytes` arena, the `MD_MARK` pointer-store trick, and the
`MD_REF_DEF_LIST` buckets.

`_test_run_analyze`'s debug dump prints several `bool` fields with `{d}` and must keep an explicit
`@intFromBool(...)` at the print site so its output stays byte-identical.

The **renderer** state structs (`MD_MARKDOWN`, `MD_ANSI`, `MD_TEXT`, `MD_HTML`, `META_CTX`,
`JsonNode`) follow the same rule: two-state members are `bool`; counters and multi-state fields stay
`c_int` even when read like a flag (`*_nesting*`, `*_depth`, `ol_counter`, `current_col`, `col_count`,
`fence_len`, the `*_cap`/`*_count` pairs, `td_align`, and every `err` field — which carries a callback
abort code, not a flag).

## Structs and layout

- **Internal-only structs** (e.g. `MD_CONTAINER`) are plain `struct` (compiler-chosen layout). Keep
  `extern struct` ONLY where layout must mirror C: the `block_bytes` arena types (`MD_BLOCK`,
  `MD_LINE`, `MD_VERBATIMLINE`), `MD_MARK` (pointer-store trick), `MD_REF_DEF` / `MD_REF_DEF_LIST`.
- **Mark flags are namespaced** in `types.MarkFlags` — one `const MarkFlags = types.MarkFlags;` alias
  per file, not fourteen per-flag aliases. Do not reintroduce loose `MD_MARK_*` consts, and do **not**
  make it a `packed struct(u8)`: the upper bits are deliberately overloaded per mark type (`0x20` is
  `emph_oc` / `autolink` / `valid_permissive_autolink` / `has_nested_brackets` /
  `dummy_bracket_consumed` depending on `mark.ch` — the last on the `'D'` dummy after a bracket
  opener; `0x40` is `emph_mod3_0`, `autolink_missing_mailto` **and** `footnote_ref` — the
  last only ever set on a `'['`, which never carries either of the other two). The values are
  frozen.
- **`MD_BLOCK.getType()` vs `typeIsRaw()`:** `getType()` decodes the stored byte with `@enumFromInt`
  and is only valid on a real block header. `md_analyze_line`'s two-blank-lines hack peeks at the tail
  of `block_bytes`, which may be an `MD_LINE` payload instead — use `typeIsRaw(.li)` there (a raw byte
  compare), never `getType()`, or an adversarial input becomes illegal behavior.
- **`MD_BLOCK.bits.data` is 16 bits, and three container kinds put an array index in it.**
  `::component`, `#slot` and `> [!ALERT]` keep their name/props/title source offsets in
  `ctx.block_component_info` / `slot_info` / `block_alert_info` and route the record's **index**
  through `bits.data`. The width is frozen (an `MD_BLOCK` is interleaved with `MD_LINE` /
  `MD_VERBATIMLINE` in the raw arena), so each opener refuses to match once
  `types.MAX_BLOCK_INFO_RECORDS` (65 536) records of its kind exist, and the line falls through line
  classification as literal text. Without the guard the index wraps and an earlier record's data is
  emitted. **Refuse at the opener, never at emission** — no container pushed means no unbalanced
  enter/leave. Any new side array indexed through `bits.data` needs the same cap.

## SAX surface

See [docs/parser-api.md](../docs/parser-api.md) for the full type listing. The rules that are easy to
break:

- Detail types (`Attribute`, `Block*Detail`, `Span*Detail` in `src/abi.zig`) are plain structs with
  **slices** and `bool`. Slice lengths are **exact** (`substr_types.len == substr_count`,
  `substr_offsets.len == substr_count + 1`, `Attribute.size() == text.len`). An absent value is the
  **empty slice** — do not reintroduce a nullable pointer or a parallel `*_size`/`*_count` field, and
  do not treat empty as different from absent. Walk an `Attribute` with a bounded loop
  (`i < attr.substr_types.len and attr.substr_offsets[i] < attr.size()`), never a bare terminator walk.
- Type codes are real Zig enums (`BlockType`, `SpanType`, `TextType`, `Align` — numeric values and
  declaration order frozen) and details reach callbacks only through the tagged unions `BlockDetail` /
  `SpanDetail`. A callback takes `(*const BlockDetail, ?*anyopaque)` — the type _is_ the active tag —
  and resolves the payload with an exhaustive `switch (detail.*)` and a `|*d|` capture. Do not
  reintroduce a separate type parameter, a `?*anyopaque` detail, or an unchecked field access.
  `BlockDetail.default(ty)` materializes the arm for a runtime `BlockType` on the emission path.
- The em/strong/code/del/u spans **always** carry a `SpanAttrsDetail`; **empty** `raw_attrs` means
  "no attributes".
- **The five SAX callbacks are required; only `debug_log` is optional.** `enter_block` /
  `leave_block` / `enter_span` / `leave_span` / `text` are non-optional and un-defaulted, so
  `Parser{}` and `md_parse(text, size, &.{}, null)` must fail to **compile**. Do not re-add `?` or
  `= null`, and do not guard the call sites with `if (cb) |f|` instead. `debug_log` stays
  `?*const fn ... = null`, guarded at its single call site (`MD_CTX.log`). `types.noop_parser` is the
  all-no-op table keeping `MD_CTX`'s all-default initializer working for unit tests that never emit.
- **The renderer sinks follow the same rule.** Every renderer's `process_output` (and the
  `JsonWriter` / `MD_HTML` fields holding it) is a **non-optional** `*const fn`, because every sink
  call is unconditional — a null one was a null-function-pointer call, not a way to discard output.
  `md_heal` was already spelled this way. Do not re-add `?`, and do not guard the call sites.
  `MD_HTML`'s two sink fields also carry **no default**, so `MD_HTML{}` fails to compile; `MD_ANSI` /
  `MD_TEXT` / `MD_MARKDOWN` are built with `std.mem.zeroInit(..., .{ .process_output = … })` rather
  than `std.mem.zeroes`, which has no zero value for a non-optional pointer.
- Callbacks return `abi.CallbackResult` (`i32`), **not** an error union: the abort contract must carry
  an arbitrary caller-chosen code through, and OOM must stay unified with `-1`.
- **Abort-code contract:** `md_parse` propagates a NEGATIVE callback code verbatim but returns 0 for a
  POSITIVE one (md4c parity), except at the `.doc` bookends where both signs propagate. OOM and a
  callback returning `-1` are intentionally indistinguishable. Pinned by the abort-matrix unit tests —
  see [testing.md](testing.md).

## Ctx accessors

Use the `MD_CTX` methods — `ctx.ch(off)`, `ctx.str(off)`, `ctx.log(msg)`, and the offset-based
predicates `ctx.isWhitespace(off)` / `isNewline` / `isAlnum` / `isAnyOf(off, "...")` /
`isUnicodeWhitespace` — not free `CH`/`STR`/`md_log`/`ISxxx(ctx, off)`. The pure `IS*_(ch)` helpers
taking a raw `CHAR` (e.g. `util.ISWHITESPACE_`) stay free functions; they mirror md4c and are kept for
upstream cross-reference.

## `export` / `callconv(.c)`

Internal entry points (`md_parse`, `md_html`/`md_html_ex`, `md_ast`, `md_ansi`, `md_text`,
`md_markdown`, `md_meta`, `md_heal`, `entity_lookup`), the SAX callbacks and the `process_output` sink
are **plain Zig**. Do not add either back. They survive in exactly three genuine boundaries: the
**wasm exports**, the **napi** module registration and its registered callbacks, and the
**`qsort`/`bsearch` comparators** in `refdefs.zig` handed to libc (constraint: glibc tie-break parity).
