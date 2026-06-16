# Parser Port (`src/md4x.c` → `src/md4x.zig`) — multi-pass handoff

Goal: port the 8047-LoC C parser to `src/md4x.zig`, byte-for-byte identical, exporting the
exact `md4x.h` C ABI (`int md_parse(const MD_CHAR*, MD_SIZE, const MD_PARSER*, void*)` — the ONLY
non-static symbol). Done across SEVERAL agent passes that each extend `md4x.zig` and verify the
subsystems they complete. **The build stays on the C parser (`src/md4x.c`) until the FINAL pass**
wires `md4x.zig` and the full gate is green. Do NOT wire a half-finished parser.

## Conventions

- `@cInclude("md4x.h")` for the public ABI types (MD*PARSER, MD*\*\_DETAIL, enums, flags, MD_ATTRIBUTE)
  so renderers see identical layouts. Internal structs (MD_CTX, MD_MARK, MD_BLOCK, MD_LINE_ANALYSIS,
  MD_CONTAINER, ref-def types …) are defined in Zig, matching the C `md4x.c` layout.
- `std.heap.c_allocator`. Hardcode UTF-8 (`-DMD4X_USE_UTF8`); skip ASCII/UTF-16 variants.
- Preserve ALL DoS/linear-time caps EXACTLY: `CODESPAN_MARK_MAXLEN=32`, `TABLE_MAXCOLCOUNT=128`,
  ref-def abuse limits, emphasis/bracket bounds. (`test/pathological-tests.py` checks these.)
- Translate `goto`/labeled control flow to labeled `while`/`break`/`continue` blocks; keep the
  `opener_stacks` mod-3 emphasis layout intact.
- Reference C source: `git show HEAD:src/md4x.c` (or the working `src/md4x.c`, which now also has
  the `md_process_doc` `line_buf` zero-init fix — match the FIXED behavior).

## Oracle

`/tmp/cparser-ref` = `[fixed C parser + Zig renderers]` binary. Final differential: for each
`--format=html|json|ansi|text|markdown`, diff new `[Zig parser + Zig renderers]` vs `/tmp/cparser-ref`.
Per-pass: unit-differential each ported C function by extracting it (compile a renamed copy of the
relevant `md4x.c` static function) and comparing outputs over targeted inputs — the way the Unicode
tables were verified over all 1,114,113 codepoints.

## Dependency-ordered subsystems (status)

- [x] **Unicode tables** → `src/unicode_tables.zig` (+ `scripts/_gen-tables-zig.py`). Verified identical
      over all 1,114,113 codepoints (bsearch, whitespace/punct classifiers, full case-fold incl. ranges).
- [x] **A. Foundation**: MD_CTX struct; char-class helpers (CH/STR/ISxxx, md_strchr); UTF-8 decode
      (`md_decode_utf8`/`_before`/`md_decode_unicode`; NOTE: md4x.c has NO `md_encode_utf8` — encoding
      lives in the renderers, not the parser); growable buffers + `MD_CHECK`/realloc/`MD_TEMP_BUFFER`
      (manual `std.c.realloc`); wire in unicode_tables (whitespace/punct/fold + bsearch); entity hook
      (`entity_lookup` via entity.h — present but parser-internal recognizers `md_is_entity_str` etc. do
      the work; resolution is a renderer concern); `MD_ATTRIBUTE` building + text-collecting buffer.
      Verified 0-diff vs md4x.c (see Pass A log).
- [x] **B. Ref-defs + links**: ref-def dictionary build/lookup (qsort/bsearch ordering via libc, verified
      0-diff incl. case-fold-collision complex buckets); `<...>`-autolink + link-destination/title/label +
      inline-link-spec + link-reference recognizers. Permissive autolinks + wiki links DEFERRED to Pass C
      (entangled with the mark engine). See Pass B log.
- [x] **C. Inline engine**: `md_analyze_inlines` and the whole mark-resolution machine (`opener_stacks[16]`
      mod-3 emphasis, brackets, code spans, entities, autolinks, latex, components, attributes) → span/text
      emission. COMPLETE. Also ported the `md_is_html_*` raw-HTML recognizer family (needed by
      `md_collect_marks`; was tentatively flagged Pass D but is self-contained — do NOT re-port in Pass D).
      0-diff over 5200 SAX-event comparisons + valgrind-clean. See Pass C log.
- [x] **D. Block analysis**: `md_analyze_line` (line classification), `md_start_new_block`/`md_add_line…`,
      block-bytes buffer, container (quote/list/component/slot) push/pop + indentation, HTML-block
      start/end conditions. COMPLETE. 0-diff over 55,566 classification comparisons + valgrind-clean.
      See Pass D log.
- [x] **E. Block processing + glue**: `md_process_*_block_contents` (normal/verbatim/code/table + table
      row/cell + alignment), `md_parse_highlights`, `md_setup_fenced_code_detail`, `md_process_leaf_block`,
      `md_process_all_blocks`, `md_process_line`, `md_process_doc`, `md_parse` setup/teardown. COMPLETE +
      WIRED (build.zig now links `addParserLib(src/md4x.zig)`; `src/md4x.c` removed). FULLY GREEN gate +
      per-format differential (0 divergences) + pathological-tests.py linear. See Pass E log.

## Log

- (Pass A — Foundation, COMPLETE) `src/md4x.zig`, 1080 LoC, compiles clean:
  `zig build-obj src/md4x.zig -I src -I src/renderers -lc -femit-bin=/tmp/x.o` → exit 0.
  NOT wired into build.zig (build still uses src/md4x.c). `md_parse` is a STUB (returns -1).

  **Ported functions (Zig name → C origin, all faithful):**
  - Char/class helpers: `CH`/`STR` (take `*const MD_CTX`), `uval`, `md_strchr` (NUL-matching, returns
    `?[*:0]const u8`), `ISIN_/ISANYOF*/ISASCII_/ISBLANK_/ISNEWLINE_/ISWHITESPACE_/ISCNTRL_/ISPUNCT_/`
    `ISUPPER_/ISLOWER_/ISALPHA_/ISDIGIT_/ISXDIGIT_/ISALNUM_` (+ offset wrappers), `md_ascii_case_eq`,
    `md_ascii_eq`.
  - Text/buffer: `md_text_with_null_replacement(ctx,ttype,str,size)->c_int`,
    `md_temp_buffer(ctx,sz)->c_int` (= C `MD_TEMP_BUFFER`; growth `(sz + sz/2 + 128) & ~127` via
    wrapping ops, raw `std.c.realloc`), `md_merge_lines`/`md_merge_lines_alloc`,
    `md_skip_unicode_whitespace`.
  - UTF-8 codec: `md_decode_utf8(str,str_size,?*p_size)->c_uint`, `md_decode_utf8_before(ctx,off)`,
    `md_decode_unicode` (inline), IS_UTF8_LEAD1..4/TAIL, ISUNICODE\* wrappers.
  - Unicode (wired to `unicode_tables.zig`): `md_unicode_bsearch(cp, map[])->c_int`,
    `md_is_unicode_whitespace`, `md_is_unicode_punct`, `md_get_unicode_fold_info(cp,*MD_UNICODE_FOLD_INFO)`
    (FOLD_MAP_LIST 1/2/3 with the alternating-range + range-to-range offset logic).
  - Entities (recognition only): `md_is_hex/dec/named_entity_contents`, `md_is_entity_str`, `md_is_entity`.
  - Attributes: `MD_ATTRIBUTE_BUILD` struct (mirrors C incl. `trivial_types[1]`/`trivial_offsets[2]`),
    `md_build_attr_append_substr`, `md_free_attribute`, `md_build_attribute(ctx,raw,sz,flags,*MD_ATTRIBUTE,
*MD_ATTRIBUTE_BUILD)->c_int` (trivial fast-path + entity/escape/NUL handling), `MD_BUILD_ATTR_NO_ESCAPES`.
  - `entity_lookup_wrap` (thin `@cInclude("entity.h")` hook for Pass C).
  - `pub const _testing` re-exports the above for the diff harness.

  **MD_CTX:** full field layout mirroring `struct MD_CTX_tag` is present (all `alloc_*`/`n_*` counters,
  hashtable ptrs, `opener_stacks[16]` mod-3 layout w/ index comments, html horizons, block/container
  arrays, component/slot/alert/inline-attr info arrays). Internal sub-structs are real Zig structs
  EXCEPT `MD_MARK`/`MD_BLOCK`/`MD_CONTAINER`/`MD_REF_DEF` which are `anyopaque` placeholders — **Pass B/C/D
  must replace these with full layouts matching md4x.c.** `parser`/details use `@cImport("md4x.h")` for ABI.

  **Buffer/alloc pattern (USE THIS in later passes, do NOT use std.ArrayList):** raw libc via
  `c_malloc_array(T, count) -> [*c]T` and `c_realloc_array(T, old, count) -> [*c]T`. CRITICAL: they
  return a **plain `[*c]T` (nullable C pointer)**, checked with `== null`. Do **NOT** return `?[*c]T` —
  an optional-of-C-pointer is malformed in Zig and yields garbage payloads (this caused a real
  use-after-free/double-free, found via valgrind; fixed). For ctx growable buffers that DO track a
  byte length, raw realloc + manual cap tracking mirrors the C `MD_CHECK`/realloc macros 1:1.

  **`char` signedness GOTCHA (important for Pass B+):** Zig `@cImport` maps C `char`→`u8` (unsigned),
  but the C parser is built by Zig's clang where `char` is **signed** on our targets (x86-64/aarch64
  Linux + Windows). So `MD_CHAR` is `u8` in Zig. `uval(ch)` reinterprets the byte as `i8` then
  sign-extends through `c_int` to reproduce C's `(unsigned)(char)0x80 == 0xFFFFFF80`. Any new code that
  does `(unsigned)ch` / `(int)ch` on a `CHAR` must go through `uval` (or replicate the sign-extend),
  or it will diverge on bytes >= 0x80. (Only observably matters for the invalid-byte fallback of
  `md_decode_utf8`, but be consistent.)

  **Unit-differential results (all 0-diff vs the real md4x.c):**
  - `md_decode_utf8`: every codepoint 0..0x10FFFF (excl. surrogates) round-trip-encoded → 1,112,064
    inputs, fold(cp,size) hash identical. Plus all 256×256 two-byte sequences at sizes 1&2 (131,072
    invalid/truncated inputs) → identical (this is where the signed-char fix landed).
  - `md_decode_utf8_before`: every position of a 15-byte mixed-width buffer → identical.
  - `md_strchr`: all 256 char values (incl. NUL terminator match) vs libc `strchr` → identical.
  - Unicode classifiers vs md4x.c (compiled via `#define static` include trick): `md_is_unicode_whitespace`,
    `md_is_unicode_punct`, `md_get_unicode_fold_info` (n_codepoints + codepoints) swept over ALL
    1,114,112 codepoints → 3/3 hashes identical.
  - `md_build_attribute`: 13 representative inputs (trivial, empty, named/dec/hex entities, bad entity,
    backslash-escape punct/newline/non-punct, embedded NULs, mixed, trailing backslash) — text bytes,
    substr_count, substr_types[], substr_offsets[] all byte-identical; valgrind clean (0 errors).

  **Files touched:** only `src/md4x.zig` (+ this doc). Harnesses were temporary (`/tmp/cref*.c`,
  removed `src/_z*_tmp.zig`); nothing else changed. build.zig / md4x.c / renderers / entity untouched.

  **Guidance for Pass B (ref-defs + qsort/bsearch ordering + links):**
  - Replace the `MD_REF_DEF = anyopaque` placeholder with the real `struct MD_REF_DEF_tag` layout
    (`CHAR* label; CHAR* title; unsigned hash; SZ label_size; ...` — see md4x.c ~line 1635) and the
    hashtable types. FNV-1a is at md4x.c ~1616 (`MD_FNV1A_BASE/PRIME`, `md_fnv1a`).
  - The HIGHEST correctness risk is the qsort comparator + bsearch ordering for ref-def lookup. Port the
    comparator EXACTLY (tie-breaking, case-fold via `md_get_unicode_fold_info`, label normalization). Use
    `md_build_attribute`/`md_merge_lines_alloc` (already ported) for label/title text. Differential it the
    same way: extract the C `md_*ref_def*` statics into a harness and compare sorted order + lookup
    results over crafted label sets (incl. unicode case-fold collisions, duplicate labels, hash
    collisions).
  - Reuse `c_malloc_array`/`c_realloc_array` (nullable `[*c]T`, check `== null`) for the ref_defs array
    and hashtable; mirror the realloc growth and the `alloc_ref_defs` doubling from md4x.c.
  - The `md_is_html_*` family and `md_lookup_line` are NOT yet ported (they take `lines/n_lines` and
    belong to Pass D block analysis) — port them there.
  - Keep using `uval` for any `(unsigned)CHAR` and remember `MD_CHAR == u8` in Zig.

- (Pass B — Ref-defs + Links, COMPLETE) `src/md4x.zig`, 2158 LoC (+~1078 over Pass A), compiles clean:
  `zig build-obj src/md4x.zig -I src -I src/renderers -lc -femit-bin=/tmp/x.o` → exit 0. Still NOT wired
  into build.zig (build still uses src/md4x.c); `md_parse` still a STUB. All 4 in-file `zig test`s pass.

  **Structs added (replacing placeholders):**
  - `MD_REF_DEF` (extern struct): `label`/`title` (`[*c]CHAR`), `hash` (`c_uint`), `label_size`/`title_size`
    (`SZ`), `dest_beg`/`dest_end` (`OFF`), `label_needs_free`/`title_needs_free` (`bool`). The C uses two
    `unsigned char : 1` bitfields; modelled as two `bool` fields (only the _values_ matter — never crosses
    the C ABI). `MD_CTX.ref_defs` retyped `anyopaque → [*c]MD_REF_DEF`.
  - `MD_REF_DEF_LIST` (extern struct header `{ n_ref_defs, alloc_ref_defs }`) + a flexible array
    `MD_REF_DEF*[]` that follows in memory. Accessed via `md_ref_def_list_items(list) -> [*c]?*MD_REF_DEF`
    (pointer past `@sizeOf(MD_REF_DEF_LIST)`), allocated as `@sizeOf(header) + n*@sizeOf(?*MD_REF_DEF)`.
  - `MD_LINK_ATTR` (Zig struct, internal): `dest_beg/dest_end` (OFF), `title` (`[*c]CHAR`), `title_size`
    (SZ), `title_needs_free` (c_int). Consumed by inline link resolution in Pass C.

  **Functions ported (Zig name → C origin, all faithful):**
  - `md_lookup_line(off, lines, n_lines, ?*line_index) -> *const MD_LINE` (md4x.c ~558; binary search; gap
    returns following line). Listed in Pass A guidance as "Pass D" but it is shared by the link recognizers,
    so it was needed here — ported now, reuse it in Pass D (do NOT re-port).
  - `md_fnv1a(base, [*]u8, n) -> c_uint` (wrapping `*%=`), `md_fnv1a_uint` (hashes a `c_uint`'s native
    bytes, matching C `md_fnv1a(h,&cp,sizeof(unsigned))`).
  - `md_link_label_hash`, `md_link_label_cmp_load_fold_info`, `md_link_label_cmp` (case-fold via
    `md_get_unicode_fold_info`, whitespace-collapse via `md_skip_unicode_whitespace`). `md_link_label_cmp`
    returns a sign-significant `c_int` from a wrapping-unsigned `b-a` then `@bitCast` (mirrors C's
    `unsigned`→`int` assignment exactly).
  - `md_build_ref_def_hashtable`, `md_free_ref_def_hashtable`, `md_lookup_ref_def`, `md_free_ref_defs`
    (incl. `free(ctx->ref_defs)`), and the two comparators `md_ref_def_cmp` / `md_ref_def_cmp_for_sort`.
  - Link recognizers: `md_is_link_label`, `md_is_link_destination_A/B`, `md_is_link_destination`,
    `md_is_link_title`, `md_is_link_reference_definition` (+ `_abort` helper for the goto cleanup),
    `md_is_link_reference`, `md_is_inline_link_spec`.
  - `<...>`-autolinks: `md_is_autolink_uri`, `md_is_autolink_email`, `md_is_autolink`.

  **qsort/bsearch ordering (the high-risk piece) — what I did:** I call **libc `qsort`/`bsearch`**
  (declared `extern "c"`; `std.c` in this Zig has neither) with `callconv(.c)` comparators that mirror
  `md_ref_def_cmp`/`md_ref_def_cmp_for_sort` byte-for-byte. This guarantees the SAME ordering and
  tie-breaking as the C parser on the same glibc runtime. The comparators read only `MD_REF_DEF` fields
  (`hash`, then `md_link_label_cmp`) and, for sort stability, the raw pointer values (`@intFromPtr`) — these
  pointers index into `ctx->ref_defs[]`, so ties resolve to array order exactly as C. The comparators need
  no `ctx`, so they are pure. The post-sort duplicate-collapse loop (force dup records to the 1st ref-def)
  is replicated. The two bucket-classification range checks (`ref_defs <= bucket < ref_defs+n`) are done via
  `@intFromPtr` address comparisons.

  **Memory/realloc:** raw `std.c.malloc/realloc/free` (NOT `c_malloc_array`, since these are byte-sized
  flexible-array + ctx-array allocations matching C's exact `realloc` calls). `alloc_ref_defs` doubling
  (`+ /2`, seed 16), the `MD_REF_DEF_LIST` `+ /2` growth, and the `(n*5)/4` hashtable size are 1:1 with C.
  All allocations NULL-checked → `-1`/log. The `md_is_link_reference_definition` `abort:` cleanup (free
  label/title on OOM) is factored into `md_is_link_reference_definition_abort` (Zig has no goto). DoS caps
  preserved: link-label 999-char limit, dest paren-nesting 32, scheme len 32, email label 63,
  `max_ref_def_output` output-size accounting in `md_is_link_reference`.

  **Unit-differential results (all 0-diff vs the real md4x.c via the `#define static`/`#define inline`
  include trick):**
  - Ref-def build+lookup (`/tmp/oracle_{c,zig}` driven by a shared binary corpus, `/tmp/gen_corpus.py`):
    **3785 output lines, 0 diff.** Covers: single/multiple ref-defs, duplicate labels (first wins),
    **case-fold collisions producing identical hashes → complex buckets** (straße/STRASSE, ß/ss, café/CAFÉ,
    Σ/σ/ς), whitespace-collapse + unicode-whitespace (NBSP) labels, multiline labels and titles
    (`label_needs_free`/`title_needs_free` allocated paths verified, `lf=1 tf=1` hit), angle-bracket and
    balanced-paren destinations, 200-ref-def set, 30 random hash-collision trials (~1000 labels, upper/lower
    variants + misses), and abusive 500-duplicate set. Dump compared label offset/size, dest range, title
    offset/size, hash, needs-free flags, and every lookup's resolved ref-def index + dest + title size.
  - `<...>`-autolink + inline-link-spec (`/tmp/oracle2_{c,zig}`, `/tmp/gen_corpus2.py`): **851 lines,
    0 diff** (URI/email/missing-mailto flags, scheme-len/label edge cases, non-ASCII usernames, titles in
    `'`/`"`/`()`, balanced/mismatched parens, empty dest, 400 randomized fuzz inputs each for `A` and `S`).
  - Zig harness valgrind-clean (exit 0) over the full ref-def corpus → ref-def alloc/build/lookup/free
    lifecycle has no UAF/double-free (the AGENTS-flagged risk). (The C oracle shows valgrind noise localized
    to the harness's own stack frame from the `#define static/inline` debug-info distortion — NOT in md4x.c
    functions; outputs are byte-identical regardless.)

  **DEFERRED to Pass C (with reasons — these are entangled with the mark / `opener_stacks` engine):**
  - **Permissive URL/WWW/email autolinks** — recognized inside `md_collect_marks` (md4x.c ~3306/3320/3435/ 3472) and resolved in `md_analyze_permissive_autolink` (~4204); both operate on `ctx->marks[]`. The
    pure `<...>` recognizers (`md_is_autolink*`) are done; the permissive variants are not separable.
  - **Wiki links** — recognized/resolved in `md_resolve_links` (~3719) using bracket-opener marks; no
    standalone `md_is_wiki_link` helper exists. Port with the inline engine.
  - `md_is_link_reference` / `md_is_inline_link_spec` ARE ported (they only need `lines`+`md_lookup_line`+
    `md_merge_lines_alloc`, no marks), but their _callers_ (`md_resolve_links`) are Pass C.

  **Guidance for Pass C (the inline engine, ~2700 LoC, many gotos):**
  - `MD_MARK` / `MD_MARKSTACK` flags are the next placeholder to flesh out (`MD_MARK` is still `anyopaque`;
    `MD_MARKSTACK` only has `top`). The C `MD_MARK` carries `beg/end/prev/next/ch/flags`. The mark-flag
    `#define`s (e.g. `MD_MARK_POTENTIAL_OPENER/CLOSER`, `MD_MARK_VALIDPERMISSIVEAUTOLINK 0x20`,
    `MD_MARK_RESOLVED`, …) start ~md4x.c 2560/2605 and must be ported verbatim.
  - The `opener_stacks[16]` mod-3 emphasis index layout is already documented in `MD_CTX`. Preserve it.
  - Use the already-ported Pass B recognizers (`md_is_link_reference`, `md_is_inline_link_spec`,
    `md_is_autolink`, `md_lookup_line`, `MD_LINK_ATTR`) directly from `md_resolve_links`.
  - Keep the libc-`qsort` pattern (declared `extern "c"` near the bsearch decl) for any further ordered
    structures, and `uval` for `(unsigned)CHAR`.

- (Pass C — Inline engine, COMPLETE) `src/md4x.zig`, 4578 LoC (+2420 over Pass B), compiles clean:
  `zig build-obj src/md4x.zig -I src -I src/renderers -lc -femit-bin=/tmp/x.o` → exit 0. Still NOT wired
  into build.zig; `md_parse` still a STUB. All 4 in-file `zig test`s still pass.

  **Structs added (replacing the `MD_MARK = anyopaque` placeholder):**
  - `MD_MARK` (extern struct): `beg`/`end` (`OFF`), `prev`/`next` (`c_int`), `ch` (`CHAR`), `flags` (`u8`).
    Matches `struct MD_MARK_tag` field order/size so `md_mark_store_ptr`/`get_ptr` can memcpy a `?*anyopaque`
    over the first `@sizeOf(?*anyopaque)` bytes (beg+end) exactly like the C `void*` punning. `MD_CTX.marks`
    retyped `?*MD_MARK → [*c]MD_MARK`. All mark-flag `#define`s ported verbatim as `u8` consts
    (`MD_MARK_POTENTIAL_OPENER/CLOSER`, `OPENER/CLOSER/RESOLVED`, `EMPH_OC`, `EMPH_MOD3_{0,1,2,MASK}`,
    `AUTOLINK`, `AUTOLINK_MISSING_MAILTO`, `VALIDPERMISSIVEAUTOLINK`, `HASNESTEDBRACKETS`). `CODESPAN_MARK_MAXLEN=32`.

  **Functions ported (Zig name → C origin, all faithful):**
  - Raw-HTML recognizers (needed by `md_collect_marks`; self-contained, do NOT re-port in Pass D):
    `md_is_html_tag`/`_comment`/`_processing_instruction`/`_declaration`/`_cdata`/`_any`, `md_scan_for_html_closer`
    (uses the `html_*_horizon` ctx fields).
  - Mark plumbing: `md_emph_stack_index`/`md_emph_stack` (the mod-3 +3-for-OC stack picker), `md_opener_stack`,
    `md_add_mark`, `addMark` (= `ADD_MARK`), `md_mark_stack_push`/`pop`, `md_mark_store_ptr`/`get_ptr`,
    `md_resolve_range`, `md_rollback` (CROSSING/ALL), `md_build_mark_char_map`, `md_split_emph_mark`.
  - Recognizer: `md_is_code_span` (backtick-run matching, `last_potential_closers[32]` rescan-avoidance,
    `reached_paragraph_end`, opener/closer space/eol trimming).
  - Collector: `md_collect_marks` (backslash, emphasis `*`/`_` with left/right flanking + mod3 + dummy 'D'
    padding, code spans, entities `&`/`;`, `<` raw-HTML/autolink, brackets `[`/`!`/`]`, permissive `@`/`:`/`.`
    incl. http/https/ftp scheme_map and www, inline components `C` with the `deferred_comp_closers[16]` +
    `skip_regions[16]` insertion-sort + memmove reindex, table/wiki `|`, `$`/`~`, whitespace collapse, NUL,
    trailing-127 sentinel). All fixed-size caps (16/16, CODESPAN 32) and the DoS guards preserved.
  - Analyzers: `md_analyze_bracket`, `md_resolve_links` (wiki links + full/shortcut/collapsed reference via
    `md_is_link_reference`, inline via `md_is_inline_link_spec`, `[text]{attrs}` 'S' spans, nested-link
    suppression, permissive-autolink-in-linktext suppression), `md_analyze_entity`,
    `md_analyze_table_cell_boundary`, `md_analyze_emph` (the rule-of-3 `opener_stacks[6]` peek/split/resolve),
    `md_analyze_tilde`, `md_analyze_dollar`, `md_scan_left/right_for_resolved_mark`,
    `md_analyze_permissive_autolink` (the `URL_MAP[4]` host/path/query/fragment scanner), `md_analyze_marks`,
    `md_push_inline_attr`/`md_find_inline_attr`/`md_resolve_attrs`, `md_analyze_inlines`,
    `md_analyze_link_contents`.
  - Emission: `md_enter_leave_span_a`/`_a_with_attrs`/`_wikilink`/`_component`/`_span`, `md_process_inlines`
    (the big render loop) + extracted helpers `emitEmphasis` (em/strong attr handling, the `attr_skip_to`
    out-param routed back to the main loop) and `emitPermissiveAutolink` (the `<`/`>`-autolink + `@`/`:`/`.`
    mailto:/http:// prefix via `MD_TEMP_BUFFER`). `MD_ENTER/LEAVE_SPAN`/`MD_TEXT` macros → `mdEnterSpan`/
    `mdLeaveSpan`/`mdText` inline helpers (the `if(size>0)` guard preserved). `MD_SPAN_*_DETAIL` populated via
    the `@cImport("md4x.h")` ABI types.

  **opener_stacks mod-3 + gotos — how handled:** the 16 `opener_stacks` `#define` aliases became index
  constants (`ASTERISK_OPENERS_oo_mod3_0=0`, `UNDERSCORE_…=6`, `TILDE_OPENERS_1=12`, `_2=13`, `BRACKET=14`,
  `DOLLAR=15`); `md_emph_stack_index` reproduces the `+3` (EMPH_OC) and `+0/1/2` (mod3) offsets exactly, so the
  rule-of-3 in `md_analyze_emph` (6-stack peek with the MOD3_1/MOD3_2 exclusions) is byte-faithful. All
  `goto abort` in OOM paths → `ret=-1; return ret`. `md_collect_marks`'s big `goto continue/not_component`
  scanner → a labeled `scan: while(true)` with `continue :scan`, the `not_component` goto → a `comp:` labeled
  block with `break :comp`. `md_process_inlines`'s `goto abort` (sentinel 127) → `break :main`. The C
  pointer-arithmetic permissive-autolink-suppression block (`opener+1`, `closer-1`) was rewritten with indices
  (single-item Zig pointers don't do arithmetic), preserving the md4c quirk where the 2nd while tests
  `first_nested->ch` not `last_nested->ch`.

  **Signedness/overflow GOTCHA (NEW, important for Pass D):** Zig panics on unsigned `OFF` underflow in safe
  builds where C relies on defined unsigned wraparound. The wiki-link check `next_opener->beg == opener->beg-1`
  underflows when `opener.beg==0`; fixed with `-%` (`opener.beg -% 1`) so the comparison is false exactly as in
  C. **Pass D must audit every `OFF`/`SZ` subtraction (`x-1`, `x-n`) for the same: use `-%` wherever C's
  unsigned subtraction can underflow and the result feeds a comparison (not an index).** Also the 4 offset-form
  `ISUNICODEWHITESPACE(ctx,off)`/`…BEFORE`/`ISUNICODEPUNCT…` wrappers were changed `c_int → bool` (only used in
  boolean contexts here); the `_`-suffixed codepoint forms stay `c_int` (Pass B uses them as ints).

  **Unit-differential (0-diff vs the real md4x.c):** built a C oracle (`md4x.c` + an appended in-TU driver that
  sees the statics) and a Zig oracle (`_testing.fn_run_inline`, a test-only driver mirroring
  `md_process_normal_block_contents` setup: ctx init + `md_build_mark_char_map` + line-split + `md_analyze_inlines`
  - `md_process_inlines` + `ptr_stack` cleanup). Both dump every `enter_span`/`leave_span`/`text` event (with the
    full `MD_SPAN_*_DETAIL` fields) to a stable textual form. **5200 comparisons, 0 diffs:** 60 hand-crafted inputs
    (emphasis/strong/mod-3/crossing, code spans incl. multiline + 32-cap overflow, entities, inline/ref/shortcut/
    collapsed/nested links + images, `<...>`/permissive url/www/email autolinks incl. balanced parens, raw HTML
    tag/comment/PI, strikethrough/latex/wiki, inline components with content+props, `{attrs}` on emph/code/span/
    link, hard/soft breaks, escapes, whitespace) × 6 flag sets (DIALECT\*ALL `0xf7f0c`, COMMONMARK `0`,
    ALL+COLLAPSE `0xf7f0d`, COLLAPSE-only `0x1`, ALERTS-only `0x80000`, COMPONENTS+ATTRIBUTES `0x60000`); plus
    1000 randomized fuzz inputs (mark-char-biased alphabet) and 10 pathological inputs (200 backticks, 300
    asterisks, 100 nested brackets, code-cap overflow, `\**~`×100, `[a](b)`×50, 100 `$`, autolink/wiki/comp spam) ×
    4 flag sets. The Zig oracle is **valgrind-clean** (no UAF/double-free/leak) on the link-title `ptr_stack`,
    component, and `{attrs}` paths — verifying the AGENTS-flagged double-free/realloc/union risks don't recur
    (the only "leak" valgrind found was the harness's own input buffer, in oracle_zig.zig main, not the parser).

  **Compile-only (not unit-diffed), validated end-to-end at Pass E:** nothing in subsystem C is compile-only —
  every ported function is exercised by the SAX differential above EXCEPT the multi-line code-span/HTML
  `md_lookup_line` line-advance branches (`off > line.end`), which need real multi-line paragraph `MD_LINE[]`
  arrays the block layer produces; the harness splits on `\n` so simple multi-line cases ARE covered, but the
  block-layer's wrapped-line cases (continuation indents, container prefixes) are only reachable once Pass D/E
  feed real line arrays. Note them for the Pass E end-to-end gate.

  **Guidance for Pass D (block analysis — `md_analyze_line`, block/container start/add):**
  - `md_is_html_*` and `md_lookup_line` are DONE — call them, do not re-port. `md_is_html_tag(…, n_lines==0, …)`
    is the block-start type-7 probe (single-line) the block layer uses.
  - Replace the `MD_BLOCK = anyopaque` / `MD_CONTAINER = anyopaque` placeholders with the full
    `struct MD_BLOCK_tag` / `struct MD_CONTAINER_tag` layouts (md4x.c). The block layer stores `MD_BLOCK` AND
    `MD_LINE`/`MD_VERBATIMLINE` interleaved in `ctx.block_bytes` — mirror the byte-offset accounting exactly.
  - The component/slot/alert info arrays (`block_component_info`, `slot_info`, `block_alert_info`) and their
    `n_*`/`alloc_*` counters are already in `MD_CTX`; the line classifier populates them.
  - **AUDIT every `OFF`/`SZ` subtraction for underflow** (see the GOTCHA above) — the block layer does a LOT of
    `off - indent`, `end - beg`, `line->indent - code_indent_offset` arithmetic. Use `-%` where C wraps and the
    value feeds a comparison; keep plain `-` only where the result indexes memory (and is provably >= 0).
  - `md_process_inlines`/`md_analyze_inlines` are the inline entry points the block layer calls per normal block
    (`md_process_normal_block_contents`) and per table cell (`table_mode=TRUE`, single line). The `ptr_stack`
    cleanup loop (`for i=ptr_stack.top; i>=0; i=marks[i].next free(get_ptr)`) belongs in that caller — see
    `_test_run_inline` for the exact pattern.

- (Pass D — Block / line analysis, COMPLETE) `src/md4x.zig`, 6503 LoC (+1925 over Pass C), compiles clean:
  `zig build-obj src/md4x.zig -I src -I src/renderers -lc -femit-bin=/tmp/x.o` → exit 0. Still NOT wired into
  build.zig (build still uses src/md4x.c; `zig build` green); `md_parse` still a STUB. All 4 in-file `zig test`s
  still pass. ONLY `src/md4x.zig` (+ this doc) changed in this pass — build.zig / md4x.c / renderers / entity
  untouched (the modified build.zig/md4x.c + deleted .c renderers in `git status` are pre-existing from the
  zig-migration branch setup, not this pass).

  **Structs added (replacing the `MD_BLOCK = anyopaque` / `MD_CONTAINER = anyopaque` placeholders):**
  - `MD_BLOCK` (extern struct): C uses bitfields `MD_BLOCKTYPE type:8; unsigned flags:8; unsigned data:16; MD_SIZE
n_lines;`. Blocks are stored **interleaved** with `MD_LINE`/`MD_VERBATIMLINE` in `ctx.block_bytes` and accessed
    by raw byte offset, so the in-memory layout MUST match C. Modelled as `bits: packed struct(u32){type:u8,
flags:u8, data:u16}` + `n_lines: MD_SIZE` (8 bytes, little-endian field order = C). Helpers `getType()`/`setType()`
    cast the `u8` type byte ↔ `MD_BLOCKTYPE`. Block-flag `#define`s ported as `c_uint` consts
    (`MD_BLOCK_CONTAINER_OPENER/CLOSER`, `MD_BLOCK_LOOSE_LIST`, `MD_BLOCK_SETEXT_HEADER`).
  - `MD_CONTAINER` (extern struct): `ch`(CHAR), `is_loose/is_task/is_alert`(u8), `start/mark_indent/contents_indent`
    (c_uint), `block_byte_off/task_mark_off`(OFF), `colon_count`(c_uint), `comp_fm_state`(c_uint). C uses several
    `unsigned :8`/`:2` bitfields; modelled as plain ints (containers live in `ctx.containers`, a distinct array —
    never block_bytes/C-ABI — so exact bit packing is irrelevant, same call as the Pass-B MD_REF_DEF bitfields).
    `MD_CTX.current_block`/`containers` retyped `?*… → [*c]…`.

  **Functions ported (Zig name → C origin, all faithful):**
  - Block-bytes buffer: `md_push_block_bytes` (realloc + `current_block` fixup; growth `>0 ? +/2 : 512`; returns
    raw `?*anyopaque`, null on OOM), `md_start_new_block`, `md_consume_link_reference_definitions` (the memmove
    line-removal + whole-block-removal cases), `md_end_current_block` (ref-def consume + setext-underline strip),
    `md_add_line_into_current_block` (MD_VERBATIMLINE for code/html/frontmatter, else MD_LINE),
    `md_push_container_bytes`.
  - Info arrays: `md_push_block_component_info`, `md_push_slot_info`, `md_push_block_alert_info` (each `>0 ? +/2 : 16`).
  - Line classifiers: `md_is_hr_line`, `md_is_atxheader_line`, `md_is_setext_underline`, `md_is_table_underline`
    (TABLE_MAXCOLCOUNT=128 cap), `md_is_opening_code_fence`, `md_is_closing_code_fence`.
  - HTML block: the `TAG`/`t1`/`a6..u6`/`map6` two-level tables (`i6`/`u6` renamed `tag_i6`/`tag_u6` — they shadow
    Zig primitive type names), `md_is_html_block_start_condition` (types 1-7; type-7 via the Pass-C `md_is_html_tag`),
    `md_line_contains`, `md_is_html_block_end_condition`.
  - Block component / slot recognizers: `md_is_block_component_opener` (name/title/{props} + the trailing-whitespace
    title trim), `md_is_block_component_closer`, `md_is_slot_opener`.
  - Containers: `md_is_container_compatible`, `md_push_container`, `md_enter_child_containers`,
    `md_leave_child_containers` (the `MD_FALLTHROUGH` ordered/bullet handling done by duplicating the body in the
    `)`/`.` and `-`/`+`/`*` switch arms; `block_component_nesting--` on `:` close), `md_is_container_mark`
    (quote/bullet/ordered, ordered `start` accumulation via `uval`), `md_line_indentation` (tab→`(n+4)&~3`).
  - **`md_analyze_line`** (the ~760-line classifier): blank/ATX/setext/fenced+indented-code/HTML/HR/table/list-item/
    blockquote/frontmatter/**block-component open+close (the `matched`/`line.type==BLANK`-flag fixed path)**/slot
    detection + the parent/brother/child container accounting, the two issue-#6 "list item starts with two blank
    lines" hacks, the alert `> [!TYPE]` detection, component-frontmatter `---` opener, task-mark, the
    `doc_ends_with_newline`+`strcspn` EOL fast-path, ATX trailing-`#` trim, trailing-space trim, and the
    loose-list flagging. The C `goto abort` (OOM) → early `return ret`; the big `while(TRUE){…}` classifier loop →
    a labeled `classify: while(true)` with `break :classify`/`continue :classify`; the `pivot_line` reassignment to
    `&md_dummy_blank_line` preserved.

  **The block-component `matched`-flag path (AGENTS-flagged risk) — how handled:** the closer branch walks
  `containers[]` innermost→outer for a `:` container with `colon_count <= closer_colons`; on match it
  `md_leave_child_containers(ctx, i)` (only if `n_children==0`), sets `line.type=BLANK`, advances `off`, and
  `break`s the _inner for-loop_ — then the outer `if(line.type==BLANK) break :classify`. This two-stage break (C
  uses an inner `break` + an outer `if`) is reproduced exactly so a closer that does NOT find a matching open
  component falls through to normal classification (not treated as a closer). The opener path pushes
  `block_component_info`, a `:` container with `comp_fm_state=0`, increments `block_component_nesting`, and sets
  `line.type=BLANK`.

  **Underflow audit (the Pass-C GOTCHA):** I audited every `OFF`/`SZ` subtraction in the new code. **None require
  `-%`** — unlike Pass C's wiki-link `opener.beg-1`. Every subtraction that feeds a comparison is provably
  non-underflowing: `off-beg` (off starts at beg, only increments), `tmp-off` (tmp starts at off), `x-1` guards
  (`while(tmp>line.beg)`, `title_end>title_start`, `line.end>line.beg`), `line.indent-=ci` guarded by
  `line.indent>=ci` / `>ci`, and `n_block_bytes-sizeof(MD_BLOCK)` guarded by `>sizeof(MD_BLOCK)`. Signed `c_int`
  index decrements (`n_containers-1`, `n_parents-1`) are guarded by `>0`/`>=0`. (Plain `-` kept throughout, matching
  C, since C's unsigned values here never wrap into a live comparison.)

  **Latent base-file bug FIXED:** `md_ascii_case_eq` (Pass A) had `ch1 +%= ('A' - @as(CHAR,'a'))` which is a
  comptime overflow (`-32` doesn't fit `u8`/CHAR) — it only escaped detection because no _exported_ path reached it
  in `build-obj`. Pass D's `md_is_html_block_start_condition`/`_end_condition` call it, so it's now compiled. Fixed
  to `if (ISLOWER_(ch1)) ch1 -%= 32;` (C `ch += ('A'-'a')` == `ch - 32` in the byte domain). Also confirmed
  `MD_CHAR`/`CHAR` is **`u8`** in this Zig (`@cImport` maps `char→u8`), despite the Pass-A comment saying "signed
  char" — the comment is about the _C_ compilation; in Zig CHAR is u8 and `uval` does the signed-promotion where C
  semantics need it. `extern "c"` decls added for `memcmp`/`strcspn` (not in this Zig's `std.c`).

  **Unit-differential (0-diff vs the real md4x.c):** built a C oracle (`/tmp/oracle_c.c`: `#define static`/`#define
inline` include of md4x.c + a driver replicating `md_process_doc`'s line loop — `md_analyze_line` +
  `md_process_line` — dumping per-line classification `{type,data,enforce,beg,end,indent}` + all ctx block/container
  state + the full container stack) and a Zig oracle (`/tmp/oracle_zig.zig` driving the test-only
  `_testing.fn_run_analyze`, which carries a faithful local copy of `md_process_line` — officially Pass-E glue, but
  needed to drive `md_analyze_line`'s `pivot_line`/`current_block` feedback exactly; emits NO SAX callbacks).
  Flags via `MDFLAGS` env. **Results, all byte-identical:**
  - Crafted+fuzz corpus (`/tmp/gen_corpus_d.py`, 4113 inputs: every line type + all extensions — headers/setext/HR/
    fenced+indented code/lists+nesting/quotes/tables/frontmatter/alerts/block-components+slots+component-frontmatter/
    HTML-blocks types 1-7/task-lists/deep-mixed-nesting/CRLF/tabs + 2000 mark-biased fuzz + 2000 menu-line fuzz) ×
    **12 flag sets** (0, COLLAPSE 0x1, DIALECT_ALL 0xf7f0c, ALL+COLLAPSE 0xf7f0d, ALERTS 0x80000, COMPONENTS+ATTRS
    0x60000, COMPONENTS 0x20000, TABLES 0x100, TASKLISTS 0x800, FRONTMATTER 0x10000, ATTRS 0x40000, ALL+0xe) →
    **49,356 comparisons, 0 diff.**
  - Real-world corpus (`/tmp/corpus_real`, 1035 inputs: every `test/fuzzers/seed-corpus/*.md` + the markdown side of
    every example in all `test/*.txt` spec suites) × 6 flag sets → **6,210 comparisons, 0 diff.**
  - Pathological/DoS inputs (`/tmp/patho`: 5000-col tables, 10000-char HR/fence/ATX, 5000-deep quotes, 5000 colons,
    1000 nested components, 2000 slots, nested quote-lists) → **11/11 identical**, no hang (TABLE_MAXCOLCOUNT and the
    other caps verified to fire identically).
  - **Valgrind-clean:** 339 crafted runs (×3 flag sets) + 235 fuzz runs, **0 real errors** (`--error-exitcode=99`;
    the only stderr noise is DWARF2-reader debug-info warnings, not memory errors) → the block-bytes realloc +
    `current_block` fixup, container realloc, and component/slot/alert array growth have no UAF/double-free/OOB.

  **Compile-only (not unit-diffed), validated end-to-end at Pass E:** the block-bytes accumulation side-effects ARE
  exercised by the differential (the harness's local `md_process_line` drives `md_start_new_block`/`md_add_line…`/
  `md_end_current_block`/`md_consume_link_reference_definitions`/`md_enter`/`md_leave_child_containers`/
  `md_push_container_bytes`, and the dump reads `n_block_bytes`/container state back), so nothing in D is purely
  compile-checked EXCEPT the actual byte _contents_ of the emitted MD_BLOCK/MD_LINE records beyond `n_lines`/`type`/
  `flags`/`data` (the renderers consume those at Pass E) — the dump verifies the COUNTS and the classifier inputs,
  Pass E's per-format differential verifies the record payloads end-to-end.

  **Guidance for Pass E (block processing + `md_parse` glue + WIRE build.zig + the full gate):**
  - Port `md_process_block`/`md_process_all_blocks` (md4x.c ~5447..5970 + the loop ~5815), `md_process_line`
    (~7862 — a faithful copy already exists as `_test_process_line` in the `_testing` region; lift it to a real
    static fn, it is byte-for-byte the C), `md_process_doc` (~7938 — note the `line_buf[2]` ping-pong on
    `line==pivot_line` and the **`memset(line_buf,0,…)` zero-init** the FIXED md4x.c added — the Zig `line_buf` must
    likewise be zero-initialized; `_test_run_analyze` already does `[2]…{ .{}, .{} }`), `md_setup_*`, and the real
    `md_parse` setup/teardown (replace the STUB; see `_test_run_inline`/`_test_run_analyze` for the ctx init +
    cleanup pattern — note the full free list: `block_bytes`, `containers`, `block_component_info`, `slot_info`,
    `block_alert_info`, `ref_defs`+hashtable, `buffer`, `marks`, `inline_attrs`, and the `ptr_stack` dummy frees).
  - The verbatim/code/table block processors read records back from `block_bytes` via `(MD_BLOCK*)(block+1)` casts —
    in Zig use `@as([*c]MD_LINE, @ptrCast(@alignCast(block+1)))` (the `+1` is one `MD_BLOCK` stride). `block->n_lines`
    is the count. The fence line for code blocks is `(const MD_VERBATIMLINE*)(block+1)` (1st verbatim line).
  - WIRE build.zig: replace the 4 `addCSourceFile(parser_source,…)` with an `addParserLib` static lib mirroring
    `addEntityLib` (the renderers already build from `.zig`); `git rm -f src/md4x.c`. Then run the FULL gate:
    `bun scripts/run-tests.ts` (all spec suites) + `test/pathological-tests.py` + the per-format
    differential (`--format=html|json|ansi|text|markdown`) vs the oracle.
  - **Oracle-refresh TODO:** `/tmp/cparser-ref` (the `[fixed C parser + Zig renderers]` baseline binary) MUST be
    rebuilt from the FIXED `src/md4x.c` before the Pass-E end-to-end differential (the per-format diff compares the
    new `[Zig parser + Zig renderers]` against it). The current `/tmp/oracle_c`/`/tmp/oracle_zig` are Pass-D
    classification oracles only — rebuild the full-pipeline oracle for E.
  - `MD_BLOCK.getType()`/`setType()` and `bits.{flags,data}` are the accessors for the packed-bitfield block header;
    use them (not raw field writes) so the 8/8/16 packing stays correct. `MD_BLOCK_LOOSE_LIST` etc. OR into
    `bits.flags` (a u8) — truncate the `c_uint` const.

- (Pass E — Block processing + glue + WIRE + FINAL CUTOVER, COMPLETE) `src/md4x.zig`, **7453 LoC** (+950 over
  Pass D). **The parser is now FULLY ported, wired into build.zig, `src/md4x.c` is removed, and the full gate is
  GREEN.** `md_parse` is the real exported entry point (no longer a stub).

  **Step 1 — md_analyze_line `matched` fix (vs the FIXED C):** the Pass-D orphaned-`::`-closer branch read
  `line.type == .MD_LINE_BLANK` after the container-walk loop (the OLD behavior). Replaced with a local
  `matched: c_int` set inside the loop + `if (matched != 0) break :classify;` — byte-for-byte the FIXED
  `src/md4x.c`. Since `MD_LINE_BLANK == 0` and `line_buf` is zero-inited, the old logic wrongly dropped orphaned
  `::` closers; the new logic only treats a `::` line as a closer when a matching open `:` container is actually
  found. Verified the orphaned-closer cases now MATCH the oracle (both sides fixed).

  **Step 2 — functions ported (all faithful, md4x.c origin):** `md_analyze_table_alignment` (~5205), the
  `align_map[4]` index logic), `md_process_table_cell`/`_row`/`_block_contents` (the `pipe_offs` malloc + the
  `table_cell_boundaries_head` linked-list walk + the `k < col_count` padding; the C `goto abort` cleanup —
  `free(pipe_offs)` + reset head/tail — replicated at every early return), `md_process_normal_block_contents`
  (+ the `ptr_stack` free loop), `md_process_verbatim_block_contents` (the 16-space `indent_chunk` chunked
  emission), `md_process_code_block_contents` (fence-skip + blank-line trim), `md_parse_highlights` (the
  `1-3,5,7` range parser, 100000/10000 DoS caps, `realloc` doubling), `md_setup_fenced_code_detail` (info/lang/
  filename `md_build_attribute` + `[filename]`/`{highlights}` scan + meta-buffer build with `memmove` trim),
  `md_process_leaf_block` (the H/CODE/TABLE detail union + the `is_in_tight_list` `<p>` suppression + the
  `clean_fence_code_detail` cleanup of info/lang/filename builds + `det.code.meta`/`.highlights` free —
  replicated at all 4 exit points since Zig has no `goto abort`), `md_process_all_blocks` (the UL/OL/LI/
  COMPONENT/TEMPLATE/ALERT detail union, `MD_BLOCK_CONTAINER` opener/closer enter/leave + `n_containers`
  loose-flag reuse, the `n_lines * sizeof(MD_LINE|MD_VERBATIMLINE)` byte_off advance, `comp_name_build` cleanup),
  `md_process_line` (promoted from the Pass-D `_test_process_line` draft — now a real fn driving the SAX layer),
  `md_process_doc` (**`line_buf` is zero-initialized** via `[2]MD_LINE_ANALYSIS{ .{}, .{} }`, matching the C
  `memset` fix; the ping-pong `line == pivot_line` swap; ENTER/LEAVE MD_BLOCK_DOC; ref-def hashtable build +
  `md_leave_child_containers(0)` + `md_process_all_blocks`), and the real **`md_parse`** (abi_version check,
  zero-init ctx, `md_build_mark_char_map`, `max_ref_def_output = MIN(MIN(16*size, 1MB), SZ_MAX)`, reset all 16
  opener stacks + ptr/link/table-boundary heads to -1, `md_process_doc`, then the FULL free list: ref_defs +
  hashtable, buffer, marks, block_bytes, containers, block_component_info, slot_info, block_alert_info,
  inline_attrs). New block helpers `mdEnterBlock`/`mdLeaveBlock`/`mdTextInsecure` mirror the C macros; the
  `(MD_BLOCK*)(block+1)` casts → `@as([*]const MD_BLOCK, @ptrCast(block)) + 1` reinterpreted as
  `[*c]const MD_LINE`/`MD_VERBATIMLINE`. Added `extern "c" fn memmove`.

  **Step 3 — build.zig wiring:** added `addParserLib(b, target, optimize, strip, include_paths)` mirroring
  `addEntityLib` (static lib, `root_source_file = src/md4x.zig`, `link_libc`, project include paths). Replaced the
  3 `addCSourceFile(parser_source, c_flags_utf8)` sites (CLI exe, wasm exe, all 9 napi targets) with
  `linkLibrary(addParserLib(...))`; removed `parser_source` + now-unused `c_flags_utf8`. `md4x.h` UNCHANGED.
  `git rm -f src/md4x.c`. `zig fmt` clean.

  **Step 4 — FULL GATE (all GREEN):**
  - `zig build` → 0; `zig build wasm` → 0; `zig build napi-linux-x64 -Dnapi-include=…` → 0.
  - `bun scripts/run-tests.ts` → **all 16 suites pass**: coverage 30, regressions 67, spec-alerts 19,
    spec-attributes 22, spec-components 58, spec-frontmatter 14, spec-hard-soft-breaks 2, spec-latex-math 6,
    spec-markdown 37, spec-permissive-autolinks 15, spec-strikethrough 5, spec-tables 12, spec-tasklists 5,
    spec-underline 4, spec-wiki-links 23, **spec.txt 652**, **+ 30 pathological** (all 0 failed/errored).
  - `python3 test/pathological-tests.py -p zig-out/bin/md4x` → **30 passed**, linear timings (worst case
    "many references" 0.078s, "huge table" 0.002s — DoS caps fire identically, no blow-up).
  - `bunx vitest run packages/md4x/test/` → **616 passed, 6 skipped** (napi 310+3skip, wasm 312+3skip).
  - **Per-format differential vs `/tmp/cparser-ref`** (`/tmp/diff_harness.py 100000`): corpus = 13,723
    (all seed-corpus + all `test/*.txt` whole-file + line-splits) + 80,707 prefix-cuts + 100,000 randomized
    (4 generators: mark-char alphabet, snippet-concat, mixed, utf-8 incl. é/🚀) = **194,430 inputs per format**.
    Results: html 0, json 0, ansi 0, text 0, markdown 0 → **TOTAL DIVERGENCES: 0** (exit 0). The orphaned-`::`-
    closer cases now MATCH (both sides fixed) — spot-verified separately.

  **Files touched in Pass E:** `src/md4x.zig` (Pass-E functions + the `matched` fix + `memmove` decl), `build.zig`
  (addParserLib wiring), `src/md4x.c` REMOVED, this doc. Renderers/entity/md4x.h untouched.
