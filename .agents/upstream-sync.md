# Upstream sync — mity/md4c

md4x is a Zig port of [mity/md4c](https://github.com/mity/md4c). This file is the
**append-only record of which upstream commits have been reviewed and what was decided**.
The machine-readable half — fork point, last-reviewed sha, review date, path filter — lives
in [`upstream-sync.json`](upstream-sync.json); `scripts/upstream-sync.ts` reads it.

Read it before touching upstream code again. Its main job is to stop a future sync from
re-litigating the decisions in [Do not port](#do-not-port), which are the expensive ones:
each cost a full investigation, and several are cases where **md4x is right and upstream is
wrong**.

## Where we are

|                |                                                                          |
| -------------- | ------------------------------------------------------------------------ |
| Upstream       | `https://github.com/mity/md4c.git`, branch `master`                      |
| Fork point     | `481fbfbdf72daab2912380d62bb5f2187d438408` (2024-02-25)                  |
| Last reviewed  | `c4be8625eb11725d604232b028df10c2ddf9b577` (2026-08-06)                  |
| Reviewed on    | 2026-08-13                                                               |
| Range reviewed | 120 commits, 89 of which touch `src/`, `test/`, `md2html/` or `scripts/` |

The fork point never changes. `last_reviewed` advances on **every** completed sweep,
including one that concludes "all no-op" — a sha having been _looked at_ is the durable
fact; whether code was ported is recorded per-commit in the [ledger](#ledger--2026-08-sweep-fork-point--c4be862).

## Running a sync

```sh
bun scripts/upstream-sync.ts              # commits newer than last_reviewed, oldest first
bun scripts/upstream-sync.ts --all        # include README/CHANGELOG/CI/CMake churn
bun scripts/upstream-sync.ts --no-fetch   # offline: report from the local mirror as-is
```

The script clones/fetches upstream into a bare mirror under `$TMPDIR` (override with
`$MD4C_CLONE`); it never writes to this repo and needs no network access to it. Offline with
no mirror it fails, printing the clone command to run; offline with a mirror it warns and
reports from what it has.

Then, for each commit it prints:

1. Classify it (see [Classes](#classes)) and **append a row** to the ledger — never rewrite an
   existing row. A `do-not-port` row must carry its reason.
2. Land what is worth landing. Name the upstream sha in the commit message
   (`Ports md4c <sha>.`), the cross-reference convention `.agents/conventions.md` already asks for.
3. Bump `last_reviewed`, `last_reviewed_date` and `reviewed_on` in `upstream-sync.json`.

Path filter rationale: `src/`, `test/`, `md2html/` (→ md4x's `src/cli/`) and `scripts/`
(upstream's Unicode data lives in `scripts/unicode/`, the source for
`src/unicode_tables.zig`). Over the whole fork range the filter drops 31 of 120 commits — 29
pure README/CHANGELOG/CI/CMake/`.gitignore`/version-bump commits and the 2 merge commits,
whose content appears anyway as the commits they merge. Nothing else upstream ships can reach
md4x: md4x has its own README, versions independently, and shares no CI or build system.

## Classes

| class           | meaning                                                                                      |
| --------------- | -------------------------------------------------------------------------------------------- |
| `ported`        | landed in md4x; the md4x commit is named                                                     |
| `already-fixed` | md4x was already correct, usually by construction of the Zig port                            |
| `do-not-port`   | reviewed and **deliberately declined**; the reason is the point of the row                   |
| `n/a`           | structurally inapplicable (UTF-16 build, C allocator, an extension md4x lacks, build system) |
| `open`          | actionable, reviewed, not yet landed                                                         |

Ledger rows carry a source tag naming the audit report the verdict came from, from the
2026-08 sweep's eight parallel reports: `[mem]` memory-safety, `[inl]` inline-marks,
`[auto]` autolinks, `[blk]` blocks-tables, `[rnd]` renderers, `[ext]` extensions,
`[uni]` unicode-tests, `[misc]` residue + sync process. Those reports were working documents
and are not checked in — this ledger is their durable residue. Where a report's claim was
later corrected by the work that landed, the corrected value is what appears here; see
[Corrections](#corrections-to-the-2026-08-audit).

## Do not port

### `10e96ad` — code spans keep the line-break space

**Do not port upstream's patch — but the bug it names was real, and md4x has now fixed it
independently.**

> **Corrected 2026-08-15.** The original verdict read "Upstream regression; md4x is correct
> … md4x fails 0". That measurement was taken against `test/spec.txt`, whose 652 expected
> outputs are md4x's own output — so the file agreed with md4x by construction, examples
> 335, 337 and 640 included. Against verbatim CommonMark 0.31.2, md4x failed those three,
> and GitHub's renderer agrees with the spec against md4x.
>
> **`test/spec.txt` cannot settle a question like this.** Its inputs are CommonMark's; its
> expectations are ours. It is a regression corpus, not an oracle. To check a claim about
> what is correct, fetch the upstream spec or ask GitHub — `scripts/gh-parity.ts` does the
> latter. See [`github-parity.md`](github-parity.md).

What upstream got right: a code span's line ending must contribute a space even when the
line carried trailing blanks. What it got wrong is the fix. `md_analyze_line` trims trailing
blanks off `line->end` while the loop re-emits them, so `off` ends up _past_ `line->end`,
not on it — upstream's replacement predicate double-counts the separator and regresses
examples 12 and 479.

md4x's fix (`src/parser/inlines.zig`, `md_process_inlines`) asks the question directly
instead: emit the space when `off` is standing on the line terminator and still inside the
span. The `off < span_end` half matters — `md_resolve_codespans` pulls the closer in past a
stripped leading/trailing space, so a newline at the closer was already consumed by that
strip (example 336). All 652 examples byte-match after it.

Trap for a future sync: the CommonMark normalizer collapses whitespace runs outside `<pre>`,
so `run-testsuite.py` stays green while the raw bytes are wrong. Only a `[no-normalize]`
comparison catches this class.

### `870f967` — drop the `strcspn` line-end scan

**Do not port; do not reintroduce `strcspn`.** Upstream's rationale is purely memory safety:
glibc's `strcspn` can over-read past a non-NUL-terminated buffer. `src/scan.zig`'s
`indexOfAnyPos` is bounds-driven (`off + V <= len`) and cannot over-read on any target, so the
hazard does not exist here. md4x additionally sheds the `doc_ends_with_newline` precondition
and the mid-buffer-NUL rescan, and never paid upstream's scalar-loop performance price.
`.agents/performance.md` and `src/parser/util.zig` already say so.

### `6d168ef` — test harness modernization

**Actively reject.** Its `[no-normalize]` removal would gut `test/spec-markdown.txt`, which
uses that flag **52** times for the round-trip renderer. Its per-case timeout never fires:
`Process(target=q.put(prog.to_html(inp)), …)` evaluates the parse eagerly in the parent, so
the spawned process is a no-op. Its third part — checking each child's exit status —
`scripts/run-tests.ts` already does. Worth reporting upstream.

### `16a8df7` — escape `'` as `&#x27;`

**Declined for now**; revisit only alongside another change that re-baselines corpus output.
Not exploitable in md4x: every emitted attribute is double-quoted and `"` is already escaped
(component prop keys can carry `'` but not `=` or an unescaped `"`). The cost is real — 6 of
28 tracked corpus files change their `html:` hash — while `test/*.txt` needs no edits, since
`normalize.py` decodes `&#x27;` back. This difference is the entire residual diff against
md4c HEAD in the autolink differential (see `00b9516`).

### `1ec0ff4` — remove the footnote special case in `md_disable_marks`

**Do not port.** It is predicated on upstream's `md_resolve_brackets` refactor (`193141e`),
which md4x does not have. The `326fe25` guard lives in **both** `md_rollback` and
`md_disable_marks` here; removing it upstream-style would reintroduce the #348 bug in a
tree shaped like this one. Since wiki links were removed the guard is no longer reachable
in practice (see the wiki-link section above), but the reasoning against porting the
refactor-dependent deletion is unchanged. The 2026-08 audit initially called this N/A — see
[Corrections](#corrections-to-the-2026-08-audit).

### `193141e` — refactor bracket resolution into `md_resolve_brackets()`

**Out of scope, deliberately.** A pure refactor. md4x keeps the monolithic `md_resolve_links`
and hand-fitted footnotes into it. Taking the split would churn the most delicate function in
the parser for no behavior change — and `1ec0ff4` above depends on it.

### Subscript `~x~` (`0bc75cd`, `625a49e`)

**Skip.** Upstream deliberately steals the single tilde from strikethrough. md4x documents
`~text~` **and** `~~text~~` as strikethrough (`docs/markdown-syntax.md`) and has **no
per-flag opt-out** — there is no parser flag word at all, so every consumer gets every
extension — so this would silently change the meaning of every existing `H~2~O` for every consumer. `:sub[2]`
works today via COMPONENTS.

Superscript `^x^` (`0bc75cd`, `1af4605`, `f6ad5af`) collides with nothing and is merely
**deferred** for lack of demand; it is one more globally-on delimiter with no opt-out.

### Spoilers `||x||` (`1e82998`, `84c5d92`, `3a8c180`, `86cee2b`)

**Skip.** `||` stops being a table cell boundary — upstream's own `spec-spoilers.txt`
documents the breakage. (It also broke wiki-link `[[a|b]]` delimiters, which no longer
applies now that wiki links are gone.) The output is a non-standard `<x-spoiler>`
element; `:spoiler[text]` already works via COMPONENTS. If ever ported, `84c5d92` (the O(n²)
fix) must come with it.

### Admonitions `!!! type` (`3456667` + `859d9df`, `5f9b246`, `c9e4a7c`, `9e1165f`, `56eec98`, `110011e`, `4f0b252`)

**Do not port; adopt 0 code fixes.** md4x's ALERTS (`> [!NOTE]`) matches upstream on all seven
inputs upstream pinned in `test/regressions.txt`, and accepts custom types upstream cannot.
Every upstream bugfix in the series is an artifact of detecting in `md_process_line`; md4x
detects in `md_analyze_line` from day one — the shape `c9e4a7c` refactored _toward_. This was
a tests-only item, discharged by `26038a5` (`test/spec-alerts.txt` 19 → 42 cases).

### Underline `MD_FLAG_UNDERLINE` / `MD_SPAN_U` — **removed from md4x**

**Do not re-port.** Upstream still ships the flag and the `MD_SPAN_U` span type; md4x deleted
both (see unjs/md4x#18). The flag was in `MD_DIALECT_ALL`, the dialect every md4x entry
point ran at the time — CLI, WASM and NAPI — so `_foo_` emitted `<u>`, `__foo__` emitted `<u><u>` (one
`<u>` per underscore, upstream's own semantics) and `_` emphasis was unreachable. CommonMark
and GFM both treat `*` and `_` as exact synonyms and have no underline syntax at all, so the
default silently broke every document written for either. Since md4x has no CLI toggle for
parser flags and no C ABI consumer, keeping the flag would have meant keeping an
unreachable-and-untestable code path plus its span type across five renderers.

Consequences to remember: `SpanType` ordinals after `latexmath_display` all shift down by
one, and the AST/JSON renderers no longer emit a `u` node. If a future sync brings a commit
touching `MD_SPAN_U`, it is not applicable here.

### Wiki links `MD_FLAG_WIKILINKS` / `MD_SPAN_WIKILINK` — **removed from md4x**

**Do not re-port.** Upstream still ships the flag, the span type and `test/wiki-links.txt`
(the extension arrived in md4c `e336e64`, #92, and md4x inherited it at the port). md4x
deleted all of it. Neither CommonMark nor GFM has wiki links — GitHub renders `[[x]]` as
literal text everywhere except its Gollum-backed repo wikis, which are a different renderer
— so the syntax only ever fired against documents that never opted in. It was the single
most expensive extension md4x carried: 3 CommonMark examples (548, 559, 590) and the
`md4x-extension` bucket's largest share of the GitHub parity baseline, plus a missing
flanking guard that linkified `arr[[i]]` in ordinary prose.

Consequences to remember:

- `SpanType` ordinals after `latexmath_display` shift down by one again; the AST/JSON
  renderers no longer emit a `wikilink` node and the HTML renderer no longer emits
  `<x-wikilink>`. Flag bit `0x2000` is retired rather than reused.
- `'|'` is now a mark character only for tables (unconditionally, since wave 3).
- The `326fe25` guard below is retained but is no longer reachable: a differential over
  ~30 000 bracket/footnote/link inputs plus every committed corpus found zero behavior
  difference with both copies disabled. It is kept as a cheap invariant guard, not as
  live coverage.
- If a future sync brings a commit touching `MD_SPAN_WIKILINK`, `md_resolve_bracket_wikilink`
  or `test/wiki-links.txt`, it is not applicable here.

### Six dialect-toggle flags — **removed from md4x**

**Do not re-port.** Upstream still ships all six; md4x deleted the declarations and the code
they guarded:

| Flag                           | Bit      | What it guarded                                                    |
| ------------------------------ | -------- | ------------------------------------------------------------------ |
| `MD_FLAG_COLLAPSEWHITESPACE`   | `0x0001` | whitespace fill of `mark_char_map` in `md_build_mark_char_map`     |
| `MD_FLAG_PERMISSIVEATXHEADERS` | `0x0002` | the space-after-`#` check and the trailing-`#` trim                |
| `MD_FLAG_NOINDENTEDCODEBLOCKS` | `0x0010` | `ctx.code_indent_offset` (parked at `OFF_MAX` to disable the type) |
| `MD_FLAG_NOHTMLBLOCKS`         | `0x0020` | the raw-HTML block start check in `md_analyze_line`                |
| `MD_FLAG_NOHTMLSPANS`          | `0x0040` | the raw-HTML mark arm on `<` in `md_collect_marks`                 |
| `MD_FLAG_HARD_SOFT_BREAKS`     | `0x8000` | forcing every soft break to `TextType.br`                          |

md4x has **one dialect**: every entry point (CLI, WASM, NAPI, the fuzzer, the unit tests)
hardcodes `MD_DIALECT_ALL`, and none of these six was ever a member of it. So every guard was
statically false in every build md4x ships — dead code plus six untestable branches. The
surviving behavior is exactly what the flags-off build already did, and
`scripts/diff-corpus.sh` was diff-clean across the removal.

Consequences to remember:

- Bits `0x0001`, `0x0002`, `0x0010`, `0x0020`, `0x0040` and `0x8000` are **retired, not
  reused** (same policy as `0x2000`). The surviving flags keep their values; nothing is
  renumbered. The `MD_FLAG_NOHTML` alias went with them.
- `ctx.code_indent_offset` is gone as an `MD_CTX` field; it is now
  `types.CODE_INDENT_OFFSET` (`= 4`), a module constant.
- `test/spec-hard-soft-breaks.txt` is renamed `test/spec-soft-breaks.txt` — its examples
  always pinned the flag-**off** output, so it is an anti-regression suite for soft breaks.
  `test/coverage.txt`'s `MD_FLAG_COLLAPSEWHITESPACE` section was retitled for the same
  reason.
- If a future sync brings a commit touching any of the six, it is not applicable here.

### The parser-flags parameter — **removed from md4x** (wave 2)

**Do not re-port.** Upstream threads a `MD_PARSER.flags` value in through every entry
point (`md_html(input, size, out, userdata, parser_flags, renderer_flags)`, and the same
trailing pair on every renderer). md4x **dropped the parser-flags parameter entirely**:

| Before                                                                                 | After                                                                 |
| -------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `md_html/md_ast/md_ansi/md_meta/md_text/md_markdown/md_yaml(…, parser_flags, r_flags)` | `(…, r_flags)` — one flag word                                        |
| `md_html_ex/md_ansi_ex(…, parser_flags, r_flags, opts)`                                | `(…, r_flags, opts)`                                                  |
| `Parser{ .flags = MD_DIALECT_ALL, … }` at six call sites                               | `Parser{ … }` — `flags` defaults to `MD_DIALECT_ALL` in `src/abi.zig` |

Every caller in the repo (CLI, WASM, NAPI, the fuzzer, the four unit-test drivers)
passed the literal `MD_DIALECT_ALL`; there was never a second value. The parameter was a
five-argument-deep pass-through of a constant. **The renderer-flags word stays** — it is
a live per-call knob (`DEBUG`, `SKIP_UTF8_BOM`, `FULL_HTML`, `HEADING_IDS`, `HEAL`, …).

Consequences to remember:

- The **JS-visible ABI is unchanged.** The wasm exports (`md4x_to_html(input, size,
renderer_flags)`) and the napi bindings only ever took renderer flags — `MD_DIALECT_ALL`
  was injected by the Zig wrapper — so `packages/md4x/lib/**` needed no edit.
- `MD_FLAG_*` / `MD_DIALECT_*` and `Parser.flags` survived this wave and were deleted by
  wave 3 (below). They were never a configuration surface: a sync that reintroduces a
  `parser_flags` parameter is re-adding a knob md4x deliberately deleted.
- `--replay-fuzz`'s prefix is now **4 bytes** (renderer flags only), not md4c's 8. See the
  `--replay-fuzz` note under [Open](#open--reviewed-actionable-not-landed).
- `scripts/diff-corpus.sh` was diff-clean across the change (pure signature refactor).

### The parser flag word itself — **removed from md4x** (wave 3)

**Do not re-port. md4x has no parser flag word at all.** Wave 1 deleted the six
never-set dialect toggles and wave 2 the `parser_flags` parameter; wave 3 deleted what
was left of the mechanism:

- `Parser.flags` — the `c_uint` field is gone from `abi.Parser`, which now holds the
  five required SAX callbacks plus the optional `debug_log` and nothing else.
- **Every** `MD_FLAG_*` constant, the `MD_FLAG_PERMISSIVEAUTOLINKS` composite, and all
  three `MD_DIALECT_*` constants (`COMMONMARK`, `GITHUB`, `ALL`).

The thirteen surviving bits (`PERMISSIVE{URL,EMAIL,WWW}AUTOLINKS`, `TABLES`,
`STRIKETHROUGH`, `TASKLISTS`, `LATEXMATHSPANS`, `FRONTMATTER`, `COMPONENTS`,
`ATTRIBUTES`, `ALERTS`, `HIGHLIGHT`, `FOOTNOTES`) were all members of `MD_DIALECT_ALL`,
which was `Parser.flags`'s only possible value. So every `flags & MD_FLAG_X != 0` test in
the parser was statically **true** and every `== 0` test statically **false**. Each guard
was folded away: the live arm kept, the dead branch deleted. `scripts/diff-corpus.sh` was
diff-clean across the removal (the same binary behavior, byte for byte).

**What this means for a sync.** md4c gates most of its extensions behind
`ctx->parser.flags`. Ported code must be written **unconditionally** — there is no flag
word to test, no `MD_CTX` field standing in for one, and no bit to allocate. If an
upstream hunk reads `MD_FLAG_X`, drop the condition and keep the body; if it adds a new
flag, md4x either takes the feature always-on or does not take it at all. Deciding that
is a dialect decision — see [github-parity.md](github-parity.md), not a flag.

Consequences to remember:

- **No bit value was renumbered, repurposed or resurrected.** Every bit — including the
  ones wave 1 retired (`0x0001`, `0x0002`, `0x0010`, `0x0020`, `0x0040`, `0x8000`) and
  `0x2000` from the wiki-link removal — simply ceased to exist. A future flag word, if
  anyone ever needs one, starts from a blank sheet.
- `ctx.parser` is still live: the parser calls the SAX callbacks through it
  (`enter_block` / `leave_block` / `enter_span` / `leave_span` / `text` / `debug_log`).
  Only the flag field went.
- `md_build_mark_char_map` now sets `~ $ = @ . |` unconditionally alongside the
  CommonMark mark chars — the map is a constant scan filter, not a dialect selector. The
  `md_analyze_link_contents` mark-char strings (`"*_~$="`, `"@:."`) are likewise literal,
  where md4c builds them from the flags.
- `md_resolve_attrs` and `md_resolve_block_attrs` lost their early-out; `md_resolve_
footnote_refs`, `md_build_footnote_def_hashtable` and `md_process_footnote_defs` are
  now called unconditionally from `md_analyze_inlines` / `md_process_doc`.
- The `## Parser Flags` table in `docs/parser-api.md` is gone. Nothing documents a flag
  because nothing has one.

## Deliberate deviations — md4x ahead of md4c on CommonMark

Not upstream commits: **md4x code that no longer matches upstream's, on purpose.** A future
sync will find these four sites textually diverged from md4c HEAD; that is not drift to
repair. All four were bugs inherited byte-identically from md4c, found by differential
testing against commonmark.js and fixed in unjs/md4x#23. Each is pinned by examples in
`test/regressions.txt` (§ Issue 23) and each is confirmed against CommonMark 0.31.2 —
which is what `test/spec.txt` is, and the reason spec text is quoted here rather than
commonmark.js behavior: commonmark.js 0.30 still requires an **uppercase** letter in the
third item, where 0.31.2 accepts any ASCII letter.

| site                          | md4c                                    | md4x                                             |
| ----------------------------- | --------------------------------------- | ------------------------------------------------ |
| `blocks.zig` `t1` loop        | HTML block type 1 matches a bare prefix | tag name must be followed by ` `, `\t`, `>`, EOL |
| `blocks.zig` type 4           | `ISASCII` after `<!`                    | ASCII letter after `<!`                          |
| `blocks.zig` HTML block start | no indent guard                         | `line.indent < code_indent_offset`               |
| `process.zig` verbatim lines  | indentation regenerated as spaces       | indentation re-derived from the source bytes     |

1. **Type 1 prefix.** md4c returns 1 on the bare `md_ascii_case_eq`, so `<textareaa`, `<prea`
   and `<prex y` open a raw HTML block. Spec 4.6 start condition 1 requires "a space, a tab,
   the string `>`, or the end of the line" — the check the type 6 branch two blocks down
   already performs.
2. **Type 4 `<!`.** md4c tests `ISASCII` (its own comment flags it), so `<!_`, `<!-`, `<!1`,
   `<! `, `<!>` and `<!"` all open a block. Its second consequence is that **type 5 was
   unreachable**: `<![CDATA[` matched type 4 first and CDATA ended at the first `>` instead of
   `]]>`. Fixing type 4 alone leaves type 5 dead behind two off-by-one bounds (`off + 3 <
size` for `<!--`, `off + 8 < size` for `<![CDATA[`), so both became `<=` in the same change
   — otherwise a document ending exactly at the marker regresses to a paragraph.
3. **Indent guard.** The ATX header and code fence checks immediately above already guard on
   `line.indent < ctx.code_indent_offset`; the raw HTML check did not, so `    <div>` after a
   paragraph line interrupted it instead of being a lazy continuation. md4x's guard also
   lifts inside a block component (`inside_component != 0`), because indented code is
   disabled there — matching the component-aware checks in the same function, not the plain
   ATX/fence form.
4. **Verbatim indentation.** `MD_VERBATIMLINE.indent` is a **column** count, and md4c replays
   it out of a literal space string, so a tab that survived the 4-column strip is lost
   (`\t\tj` → four spaces). md4x re-derives the residual from the source: it walks back over
   the line's whitespace run, and only where a tab was cut through does it expand to spaces
   (spec 2.2 "Tabs", examples 2 and 5). The absolute-column walk from the line start is what
   makes a tab's width knowable, and it runs only when the run actually contains a tab — the
   no-tab path stays the original space emit.

   **Frontmatter opts out** (`preserve_tabs = false`, the only `false` caller): its body is
   handed to libyaml, and YAML forbids a tab as indentation. md4c's rewrite has been quietly
   making tab-indented frontmatter parse, and preserving the tab turns `a:\n\t- 1` into a
   libyaml error and a `null` value. That is a CommonMark rule about code and HTML blocks
   being applied where it does not belong, so the carve-out is deliberate — pinned by a
   `--format=json` example in `test/regressions.txt`.

Blast radius, measured: all 17 `.txt` suites pass (1 201 examples, 17 of them the new
regression cases), and over `scripts/diff-corpus.sh`'s whole corpus × 6 formats exactly
**one** hash moves — a tab-indented line inside a fenced block in `test/spec-footnotes.txt`,
now a tab. Re-baseline `diff-corpus.sh` on that. A 3 868-input differential sweep (generated
from a whitespace/raw-HTML/container token alphabet, normalized through `test/normalize.py`)
against markdown-it's `commonmark` preset reported 0 regressions and 762 inputs that newly
agree with it.

## Deliberate deviations — an autolink's label resolves entities

Also not an upstream commit. md4c decodes entity references in an autolink's
**destination** but not in its **label**, so one link disagrees with itself.

The asymmetry is structural, not a policy: `md_build_attribute()` (`util.zig`) is handed
`MD_BUILD_ATTR_NO_ESCAPES` for autolinks, but that flag gates only the backslash branch —
the `&` branch above it is unconditional, so the destination always decodes. The label
went the other way for an unrelated reason: `md_collect_marks` (`inlines.zig`) set
`off = autolink_end` after emitting the `<`/`>` pair, jumping the interior, so no entity
mark was ever collected inside one. md4c HEAD still has both halves (md4c.c:1557-1574 and
the autolink branch of its own `md_collect_marks`); the behavior is inherited
byte-identically, and a built md4c HEAD reproduces it exactly.

md4x now collects entity marks inside the autolink interior, pre-resolved in the shape
`md_analyze_entity` would have left them, so both halves decode.

| input                        | md4c / md4x ≤0.0.28                    | md4x now                          |
| ---------------------------- | -------------------------------------- | --------------------------------- |
| `<https://e.com/?x=&copy;y>` | href `…?x=%C2%A9y`, text `…?x=&copy;y` | href `…?x=%C2%A9y`, text `…?x=©y` |

**Why the label is the half that was wrong, not the destination.** The two CommonMark
reference implementations disagree here: commonmark.js keeps the entity literal in both,
cmark decodes both. cmark is what matters — cmark-gfm is the engine GitHub runs, and
`github-parity.md` makes GitHub the target. Built from source, cmark-gfm agrees with the
new md4x byte-for-byte on every case in the `test/regressions.txt` section, including the
non-entity edges (bare `&`, unterminated `&amp`, stray `;`, unknown name, out-of-range
numeric reference). Spec 6.2 backs it: the only exemptions it names are code spans and
code blocks, and the autolink section carries no entity example at all — which is why
md4c and md4x both scored 100% on `spec.txt` while diverging.

Two related behaviors deliberately did **not** change:

- **The destination.** It was already right; the report that surfaced this asked for both
  halves to stay literal, which would have moved the destination away from GitHub.
- **Permissive (bare-URL) autolinks.** `https://e.com/?a=1&amp;b=2` unbracketed is not an
  autolink in md4x at all — the entity marks resolve first and the `:`-driven segment
  scanner never fires. GitHub links it, entity decoded. That is a separate mechanism
  (`md_analyze_permissive_autolink`), it is inherited from md4c too — verified against
  `md2html --fpermissive-autolinks` — and it is untouched here.

Blast radius, measured: over `scripts/diff-corpus.sh`'s whole corpus × 6 formats with the
corpus pinned at the pre-change tree, **zero** hashes move — no existing suite or seed
input has an entity inside a bracketed autolink. All 18 `.txt` suites and the vitest
bindings suite pass. Pinned by seven examples in `test/regressions.txt`
(§ An autolink's label resolves entities, like its destination).

## Deliberate deviations — a table may interrupt a paragraph

Also not an upstream commit. md4c gates the table underline on
`ctx.current_block->n_lines == 1`, so the header row has to be the **only** line of the
block: with no blank line above it, the underline is ordinary paragraph text and the whole
table renders as literal pipes. md4x gates on the header being the block's **last** line
instead (`blocks.zig`, the table-underline branch of `md_analyze_line`), and
`md_split_off_table_header` closes the preceding lines as their own paragraph before
`md_process_line` retypes the remainder to `table`.

Why it diverges rather than staying in sync: GitHub interrupts here, cmark-gfm has always
interrupted here, and the failure mode of not doing so is the worst in the parity baseline
— a missing blank line is a routine authoring slip and it destroys the whole block rather
than degrading it. It was `spec-tables.txt#7` in [`github-parity.md`](github-parity.md).

Two things deliberately did **not** change: the underline must still sit in the same
container as the header row (a lazy continuation line does not open a table), and the
interrupted paragraph is still closed through `md_end_current_block`, so its leading link
reference / footnote definitions are still consumed. GitHub drops the ref def in that last
case; md4x keeps CommonMark's reading. All three are pinned in `test/spec-tables.txt`.

## Deliberate deviations — `test/spec.txt` is not CommonMark 0.31.2

Everything above concerns md4x code diverging from md4c. This one is different in kind and
more dangerous to a future sync: **the spec fixture itself has been edited.**

Measured 2026-08 against `commonmark-spec` tag `0.31.2` (sha256 `257c41ad…`), aligning examples
by input string rather than index. Both sides have **652 examples**, none added, dropped or
reordered, and every input is byte-identical. **120 of the 652 expected outputs differ**, all
predating the Comark work: `dda2d56` "fix tests" (2026-02), trimmed by `8eea937`.

**`652/652` has not been a clean CommonMark conformance claim since `dda2d56`**, months before
the Comark work — but the deviation is bounded by that commit and nothing since. The 2026-08
Comark sweep briefly edited 39 more examples to expect heading ids; those edits were **reverted**
when heading ids moved behind `MD_HTML_FLAG_HEADING_IDS` (see below), and `test/spec.txt` now
runs the CLI without the flag. The fixture is byte-identical to its pre-sweep state.

The 120 divergences are:

- **8 normative** — md4x genuinely renders differently, all deliberate extensions:
  examples **96, 98** (a leading `---` is consumed as frontmatter, so the reference's `<hr />`
  is suppressed), **548, 559, 590** (wiki-links emit `<x-wikilink>` — no longer true, the
  extension has since been removed), **608, 611, 612** (permissive autolinking of bare URLs
  and emails).
- **112 cosmetic** — normalizer-equivalent, and fully explained by three mechanical rules:
  inter-tag newline placement, XHTML `<hr />`/`<br />`/`<img />` rewritten to HTML5 form, and
  five examples carrying a literal tab where the spec prints a `→` placeholder. Zero residue
  after applying those rules.

The fixture also passes with `--no-normalize`, so it matches md4x byte-for-byte and no expected
output is riding on normalizer slack.

**Heading ids are opt-in, and that is what keeps this section short.** The 2026-08 wave added
`<h1 id="hello-world">` to the HTML renderer (same slug path as the JSON/meta renderers,
de-duplication included) and edited 39 spec examples to match. That HTML behaviour now sits
behind `MD_HTML_FLAG_HEADING_IDS` — `--heading-ids` on the CLI, `{ headingIds: true }` from JS —
so the default output is bare `<hN>` again and the 39 edits were reverted. The slugger itself was
verified during the sweep against an independent reimplementation across all 58 heading tags in
those examples — 58/58 — including the cases a naive slugger gets wrong: `foo ###` → `foo-`
(trailing space not trimmed), `foo--1` (dedup on a hyphen-final base), entity resolution _before_
stripping (`&lt;a title=&quot;a lot` → `a-titlea-lot`), and soft-break-as-space. Headings with no
sluggable text correctly get no id at all. That verification still stands; only where the ids are
emitted by default changed.

Consequences a future sweep must respect:

- **Do not re-import `test/spec.txt` from upstream or from spec.commonmark.org.** A clean
  re-import silently reverts all 120 divergences and turns the suite red with no obvious cause.
- **`652/652` is not a clean CommonMark conformance statement**, because of the 120 `dda2d56`
  edits — 8 of them normative. It is not compromised by heading ids, which the suite runs without.
- **Do not re-enable heading ids by default to "simplify" the renderer.** It would put the 39
  examples back and make every differential run against md4c, commonmark.js or markdown-it report
  every heading as a difference.

The generated-id contract is pinned independently of the default HTML shape: `--format=json`
examples in `test/spec-markdown.txt` and `test/spec-attributes.txt` cover the AST/meta side, and
a `--heading-ids` example in `test/spec-attributes.txt` covers the HTML side.

Three related decisions from the same sweep, recorded so they are not re-litigated:

- **Heading ids in HTML are opt-in, deviating from `.agents/comark/markdown.md`.** That page says
  "all headings automatically get ID attributes"; md4x emits them only under
  `MD_HTML_FLAG_HEADING_IDS`. Same trade as `language` on `<pre>` below, one order of magnitude
  larger: unconditional ids cost 39 spec examples plus ~20 across the other suites, and they make
  every heading a false positive in a differential run against md4c or commonmark.js. The Comark
  contract still holds where it is checkable without touching CommonMark output — the AST and meta
  renderers publish the id unconditionally.
- **`language` on `<pre>` was implemented and then reverted.** `.agents/comark/attributes.md`
  shows `<pre language="ts" …>`, and it was briefly emitted, but a non-standard attribute on
  every fenced block cost 13 examples across four suites for one spec line. The AST `pre` node
  still carries `{"language":"ts"}`, which is where that contract lives.
- **Bare `[span]` → `<span>` is not implementable and was dropped.** Comark's block-attribute
  page expects `A paragraph [span] {attr}` to yield an attribute-less `<span>`. It was
  implemented in `md_resolve_links`, measured at **spec.txt 606/46 → 576/76** plus regressions
  +2 and coverage +1, and reverted; `inlines.zig` is unchanged. The conflict is structural:
  CommonMark requires an unresolved bracket to stay literal, inline attributes are always on,
  and both rules fire at the same point after `md_is_link_reference` fails.
  The two examples asserting it were deleted rather than left red. Do not retry without a plan
  for that collision.

## Open — reviewed, actionable, not landed

| upstream             | item                                                                                       | note                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| `323995c`, `ed89abe` | `src/cli/md4x.1` documents ~17 options the CLI rejects with exit 1                         | See below. `[misc]`                                                     |
| `f6b445d`, `99d4667` | `--replay-fuzz` is vestigial                                                               | See below. `[misc]`                                                     |
| `ce4636b`            | `MD_CHECK` should abort on any non-zero, not just `< 0`                                    | Decision, not a port. See below. `[mem]`                                |
| `377cc53`, `be7332b` | `2016-2024` → `2016-2026` (4 files); `http://github.com/unjs/md4x` → `https://` (10 files) | Trivial. `[misc]`                                                       |
| `2a0f60d`, `e90921a` | `test/spec-permissive-autolinks.txt` text drift                                            | Cosmetic. See below. `[auto]`                                           |
| `28e2fbd`            | duplicate chars in the URL-escape set (`md4x-html.zig:70`)                                 | Zero output change; the comptime `ESCAPE_MAP` is bit-identical. `[rnd]` |

- **Man page.** Verified: `--ftables`, `--github`, `--fverbatim-entities` all exit 1. md4x
  dropped every dialect/extension flag (the dialect is fixed, no entry point takes parser
  flags, and there is no parser flag word — see the wave-2 and wave-3 notes above)
  but kept md4c's page verbatim; it also omits `--heal`, lists 3 of 6 `--format` values, and
  still stamps "February 2026". The fix is a product decision: rewrite the page to describe the
  real CLI (recommended), or implement the flags — which would also change the default from ALL
  to CommonMark.
- **`--replay-fuzz`.** md4c's prefix is two words, parser flags then renderer flags. Wave 2
  dropped the parser-flags half, so md4x's prefix is **4 bytes** (renderer flags only) —
  a sync must not restore the 8-byte layout. It is still vestigial either way: nothing in
  the repo produces the format (`src/fuzz.zig` writes plain `.md` seeds via
  `std.testing.fuzz`, and `test/fuzzers/seed-corpus/` is all plain markdown), so replay on
  a real seed silently eats 4 bytes. md4x also still does the trailing zero-fill upstream
  removed ("it can actually hide a bug") and overwrites `r_flags`, losing
  `MD_HTML_FLAG_DEBUG`. Delete the mode, or apply both one-line fixes.
- **`ce4636b`.** md4x ported the callback half (`!= 0`) but not the internal propagation half
  (~60 `ret < 0` sites) and **pins the pre-`ce4636b` matrix in tests** (`src/md4x.zig:800-854`).
  Either follow upstream, or document in `docs/parser-api.md` that callbacks must abort with a
  negative code. Doing neither leaves md4x pinned to behavior upstream calls a bug.
- **Spec text drift.** `john.doe@gmail.com` → `example.com` (10 occurrences) and the typos
  `formost` → `foremost`, `username` → `user name`. md4x passes the suite either way. Do **not**
  re-add the per-example `--fpermissive-*` flag blocks or upstream's `MD4C` naming — both
  divergences are intentional.

md4x-only follow-ups the sweep raised, with no upstream counterpart, that did not land:
`.github/workflows/ci.yml` never runs `zig build fuzz-zig`, and `AGENTS.md` claims a
Linux/Windows/coverage CI matrix that does not exist.

## Landed ahead of the next sweep

Commits newer than `last_reviewed` that were ported on their own, out of order, because a
bug report forced the issue. `last_reviewed` does **not** move for these — the commits between
it and them are still unreviewed — so the next sweep will print them again; classify them
`ported` from this table rather than re-investigating.

| md4x         | upstream  | subject                                                              | note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------ | --------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| unjs/md4x#28 | `f7f9c57` | md_analyze_line: Handle blank lines in a list item in less hacky way | `last_list_item_starts_with_two_blank_lines` → `consecutive_blank_lines`, as upstream. **Upstream's fix is incomplete**: it keeps the `top_block` peek at the arena's last 8 bytes, which after a self-closing block (heading, `---`) is an `MD_LINE`, so `beg == 256k + 4` still reads as `LI` — the actual cause of both mity/md4c#413 and unjs/md4x#28 (a heading inside `::note` at byte 256). md4x adds `MD_CTX.last_block_off` and `md_top_block_is_empty_li`, which only trust the peek when a header was the last push. Worth reporting upstream (item 6 below). `[blk]` |

## Worth reporting upstream

1. `10e96ad` fixes a real bug (a code span's line ending owes a space even when the line had
   trailing blanks) but its predicate double-counts and regresses examples 12 and 479. See the
   [do-not-port entry](#10e96ad--code-spans-keep-the-line-break-space) for the shape of a fix
   that holds all 652.
2. After `589681b` removed the column cap, md4c HEAD truncates the count mod 65536 — a
   65 536-column table emits **zero** `<th>` and drops its content. md4x keeps a 65535 cap for
   exactly this reason.
3. `6d168ef`'s pathological-test timeout never fires.
4. In `d1f8a97`, a segment that consumes nothing still rolls `end` back past its own start,
   killing the whole match (`http://example.com//`, `http://ex.coma._`, `a@ex.com.-`).
5. The four CommonMark divergences in
   [Deliberate deviations](#deliberate-deviations--md4x-ahead-of-md4c-on-commonmark), all of
   which reproduce in md4c HEAD: `<textareaa` as a raw HTML block, `<!_` as one (and HTML
   block type 5 unreachable behind it), an indented `<div>` interrupting a paragraph, and a
   surviving tab rewritten as spaces in verbatim indentation.
6. `f7f9c57` (the mity/md4c#413 fix) still misreads the arena top: with two blank lines,
   `-\n  ---\n\n\n  b` ejects `b` from the item whenever the `---` content starts at byte
   `256k + 4`, and the same holds for any ATX heading at such an offset. See
   [Landed ahead of the next sweep](#landed-ahead-of-the-next-sweep).

## Ledger — 2026-08 sweep (fork point → `c4be862`)

89 rows, oldest first: one per commit in `481fbfb..c4be862` touching `src/`, `test/`,
`md2html/` or `scripts/` — exactly what `bun scripts/upstream-sync.ts` prints for that range,
in the same order. Long reasoning lives in the sections above; these notes are the index.

| sha       | subject                                                        | class                                     | note                                                                                      |
| --------- | -------------------------------------------------------------- | ----------------------------------------- | ----------------------------------------------------------------------------------------- |
| `870f967` | md_analyze_line: get rid of strcspn-based optimization         | do-not-port                               | `src/scan.zig` is bounds-driven. `[blk]`                                                  |
| `e0dcf62` | md_process_leaf_block: invalid free() in error path            | already-fixed                             | `MD_ATTRIBUTE_BUILD` is `= .{}` everywhere; free is idempotent. `[mem]`                   |
| `fab28e4` | Avoid repeated `language-` in info string                      | ported                                    | → `c108204` (HTML + AST + `lib/_shared.mjs`). `[rnd]` `[uni]`                             |
| `ce25e56` | Fix alignment issue in md_mark_store_ptr()                     | n/a                                       | md4x stores via `[*]u8` `@memcpy`; **do not "modernize"** into a pointer store. `[mem]`   |
| `ae85f71` | MD_MARK union → just beg/end                                   | n/a                                       | C-layout refactor; md4x already writes only `beg`+`end`. `[mem]`                          |
| `9b51e26` | Simplify mark pointers more                                    | n/a                                       | Same. `[mem]`                                                                             |
| `bd6a4e3` | Fix md_decode_utf16le_before\_\_() return value                | n/a                                       | UTF-16 only; md4x returns `ch(off - 1)` on every path. `[misc]`                           |
| `380ee2b` | md_is_closing_code_fence: accept trailing tabs                 | ported                                    | → `bb4ee4d`; 6 new cases, the rule's first executable coverage. `[blk]` `[uni]`           |
| `1ccedb3` | fix OFF_MAX redefinition and a potential overflow              | already-fixed                             | `src/md4x.zig:249` widens to `u64` before multiplying. `[mem]`                            |
| `44c90ca` | Disable openers/marks more carefully (#278, #294)              | ported                                    | → `9eed904`, with `c055ef5`; unbalanced SAX spans, not just HTML. `[inl]`                 |
| `ff71f00` | md_process_inlines: don't skip back to line start (#271)       | ported                                    | → `a629443` (`off = @max(off, line.beg)`). `[inl]` `[uni]`                                |
| `ce4636b` | MD_CHECK: abort on any non-zero value                          | **open**                                  | Decision needed; see [Open](#open--reviewed-actionable-not-landed). `[mem]`               |
| `3834f11` | permissive autolink: remove always-true condition              | ported                                    | → `00b9516`, subsumed by `d1f8a97`. `[auto]`                                              |
| `5d52d32` | permissive autolink: be a little more permissive               | ported                                    | → `00b9516`, subsumed by `d1f8a97`. `[auto]`                                              |
| `bd8f80e` | const up scheme_map                                            | n/a                                       | Zig's `const scheme_map` is already immutable. `[auto]`                                   |
| `fccb43a` | fix tasklist XHTML render                                      | n/a                                       | md4x has no XHTML mode. `[rnd]`                                                           |
| `8cab795` | build: CMake improvements                                      | n/a                                       | md4x builds with `zig build`. `[misc]`                                                    |
| `87258eb` | build: absolute include/lib dirs in pc file                    | n/a                                       | md4x ships no pkg-config files. `[misc]`                                                  |
| `3420ce7` | Update to Unicode 18.0                                         | ported                                    | → `d806f23`; +1003 punct, +76 folds, whitespace unchanged. `[uni]`                        |
| `f24870b` | render_open_code_block: fix buffer overflow                    | n/a                                       | Cannot recur (slice + `startsWith`), but a **constraint** on `fab28e4`. `[rnd]` `[mem]`   |
| `c4eebad` | Create initial fuzzer seed corpus                              | n/a                                       | 8-byte flag header; `src/fuzz.zig` takes raw markdown. `[uni]`                            |
| `2a0f60d` | spec-permissive-autolinks.txt: fix a typo                      | **open**                                  | Cosmetic text drift. `[auto]`                                                             |
| `e90921a` | spec-permissive-autolinks.txt: drop gmail.com                  | **open**                                  | Cosmetic text drift (10 occurrences). `[auto]`                                            |
| `1e82998` | Add spoiler span extension (#308)                              | do-not-port                               | Breaks table cells. `[ext]`                                                               |
| `f6b445d` | md2html: minor --replay-fuzz improvements                      | **open**                                  | md4x still does the zero-fill upstream removed. `[misc]`                                  |
| `5860a02` | md_collect_marks: add missing parenthesis                      | n/a                                       | The C precedence trap does not exist in Zig. `[inl]`                                      |
| `84c5d92` | Fix O(n²) with --fspoilers and nested brackets (#311)          | n/a                                       | Spoiler-only pass; the skip-resolved jump already exists here. `[inl]`                    |
| `3a8c180` | Tests for links/images inside spoiler spans                    | n/a                                       | Spoilers. `[ext]`                                                                         |
| `86cee2b` | Tests for inline spans inside spoilers                         | n/a                                       | Spoilers. `[ext]`                                                                         |
| `f169318` | Replace ISANYOF\_ with direct char comparison                  | n/a                                       | Coverage-only edit inside the spoiler loop. `[inl]`                                       |
| `f41e674` | md_analyze_link_contents: reuse md_analyze_marks()             | n/a                                       | Refactor; 0 diffs over 8 400 differential inputs. `[inl]`                                 |
| `d534ad9` | permissive autolink: accept any opener mark before it          | ported                                    | → `00b9516`; unobservable until a new mark char exists. `[auto]`                          |
| `0bc75cd` | Add superscript and subscript span extensions                  | do-not-port (sub) / deferred (super)      | Single tilde is md4x's strikethrough. `[ext]`                                             |
| `1af4605` | Remove unused caret case in md_opener_stack                    | n/a                                       | No `^` opener stack in md4x. `[misc]`                                                     |
| `625a49e` | Examples for tilde behavior in subscript spans                 | n/a                                       | Subscript. `[misc]`                                                                       |
| `f6ad5af` | Examples for caret behavior in superscript spans               | n/a                                       | Superscript. `[misc]`                                                                     |
| `377cc53` | Update copyright years                                         | **open**                                  | 4 files still say `2016-2024`. `[misc]`                                                   |
| `81b871f` | Fix python SyntaxWarning in test                               | ported                                    | → `26038a5`; the `pathological-tests.py` half was already done. `[uni]`                   |
| `07712a5` | Code cleanup (#314)                                            | n/a                                       | Comment style, include order, `MD_UNUSED`. `[inl]`                                        |
| `ed89abe` | md2html: add option --gfm                                      | **open** (design)                         | md4x's CLI has no dialect option at all. `[misc]`                                         |
| `3456667` | Implement github-style admonitions extension (#316)            | do-not-port                               | md4x ships ALERTS and already matches. `[ext]`                                            |
| `859d9df` | Fix invalid assertion at admonition recognition                | n/a                                       | Admonitions. `[ext]`                                                                      |
| `4f0b252` | md_process_all_blocks: fix stack-use-after-scope               | n/a                                       | md4x's alert attribute build is **function-scoped**; keep it that way. `[mem]`            |
| `d1f8a97` | Refactor the permissive autolink extension code (#319)         | ported                                    | → `00b9516`, the primary port; subsumes 5 earlier commits. `[auto]`                       |
| `5f9b246` | md_process_line: fix admonition handling                       | n/a                                       | Admonitions. `[ext]`                                                                      |
| `6257361` | Fix double-free on second realloc failure                      | already-fixed                             | `realloc_array_a` returns null and leaves the old slice owned. `[mem]`                    |
| `174fe05` | MD_ATTRIBUTE_BUILD: unsigned size types                        | ported                                    | → `76dff08`; counters → `usize`, refused at the opener. `[mem]`                           |
| `28e2fbd` | md_html: remove duplicate chars from strchr()                  | **open** (tidy)                           | Zero output change. `[rnd]`                                                               |
| `5faab7c` | Fix HTML tag length computation in UTF-16 builds               | n/a                                       | `mkTag` uses `name.len`, the correct unit for `u8`. `[misc]`                              |
| `c9e4a7c` | Admonitions: move detection to md_analyze_line()               | n/a                                       | md4x detects there from day one. `[ext]`                                                  |
| `192723a` | Fuzz seed corpus: add an admonition sample                     | n/a                                       | Covered by `test/fuzzers/seed-corpus/alerts.md`. `[uni]`                                  |
| `671cd93` | fix: V-001 (membuf_append size overflow)                       | ported                                    | → `76dff08`; `md4x-heal.zig`'s `+%` guard was the live bug. `[mem]`                       |
| `53852ac` | Fix multiple bugs (#325)                                       | ported (surrogate) / already-fixed (rest) | → `3583855`; CESU-8 from 4 renderers, raw NUL from meta. `[mem]` `[uni]`                  |
| `5012c8f` | Use SZ (not int) for realloc sizes                             | already-fixed / ported (arena)            | → `235d587` for the arena upstream never covered. `[mem]`                                 |
| `b8d9ee1` | permissive autolink: allow `~` in the URL path                 | ported                                    | → `00b9516`. `[auto]`                                                                     |
| `9e1165f` | md_analyze_line: fix admonition detection                      | n/a                                       | Admonitions. `[ext]`                                                                      |
| `56eec98` | Admonitions: get rid of MD_LINE_ADMONITIONTAG                  | n/a                                       | md4x sets `line.type = .blank`. `[ext]`                                                   |
| `110011e` | Admonitions: don't turn indented code into admonition          | n/a                                       | md4x's `indent < code_indent_offset` guard already does this. `[ext]`                     |
| `5add6a3` | Several fixes for the Windows UTF-16 build                     | n/a                                       | `sizeof(CHAR)` scalings; the 4 md4x sites were checked byte-correct. `[misc]`             |
| `a8b0d3e` | Add footnote reference support (#315)                          | ported                                    | → `09b10c2`; also fixed a live md4x mis-parse of `[^1]: note`. `[ext]`                    |
| `54bfec0` | Footnotes: text may be split into multiple lines               | ported                                    | → `09b10c2`. `[ext]`                                                                      |
| `915676f` | Separate the label hashtable implementation                    | ported                                    | → `09b10c2` as a comptime-generic `LabelHashTable(Def)`. `[ext]`                          |
| `19dd06f` | Heavily refactor label hashtable                               | ported + `76dff08` (sizing)               | → `09b10c2`; md4x computes `n + n/4`, never forming `n*5`. `[ext]` `[misc]`               |
| `589681b` | Tables: suppress too sparse tables (#346)                      | ported, diverged                          | → `1094346`; cap retuned to 65535, not deleted (16-bit `bits.data`). `[blk]`              |
| `326fe25` | Footnotes: fix assert for a ref inside a wiki-link dest (#348) | ported                                    | → `09b10c2`; guard in `md_rollback` **and** `md_disable_marks`, now unreachable. `[ext]`  |
| `193141e` | Refactor bracket resolution into md_resolve_brackets()         | do-not-port                               | Deliberately out of scope. `[inl]`                                                        |
| `30c1a68` | Brackets: rename some mark flags                               | n/a                                       | md4x's flag values are frozen per `.agents/conventions.md`. `[inl]`                       |
| `59af256` | Brackets: no-impact preparation for image handling             | n/a                                       | md4x collects image openers with `ch == '!'` directly. `[inl]`                            |
| `9fa747c` | Fix code indentation and add missing `_T()`                    | n/a                                       | Re-indentation; `_T()` is identity in UTF-8 builds. `[misc]`                              |
| `99d4667` | md2html: --replay-fuzz enforces debug output                   | **open**                                  | md4x's replay path overwrites `r_flags`, losing DEBUG. Prefix is 4 bytes, not 8. `[misc]` |
| `1ecb4a4` | md_process_leaf_block: fix sparse table detection              | ported                                    | → `1094346`; only the `589681b`+typo-fix form was landed. `[blk]`                         |
| `a962cdf` | md_resolve_bracket_wikilink: simplify a little                 | n/a                                       | Wiki links removed from md4x. `[inl]`                                                     |
| `ff70673` | Brackets: remove extra pass for the bracket extension          | n/a                                       | Footnotes were hand-fitted into `md_resolve_links` instead. `[inl]`                       |
| `1ec0ff4` | md_disable_marks: remove the footnote special case             | do-not-port                               | Would reintroduce the `326fe25` bug here. `[inl]` → corrected                             |
| `fb4d03d` | Regressions: add a testcase from #352                          | ported                                    | → `26038a5`, in its `6ed63d1`-corrected form. `[uni]`                                     |
| `ea20033` | Match cmark version of normalize.py                            | ported                                    | → `26038a5`, byte-identical to md4c HEAD. `[uni]`                                         |
| `be7332b` | Update links to https                                          | **open**                                  | 10 md4x sources still carry `http://github.com/unjs/md4x`. `[misc]`                       |
| `16a8df7` | Add apostrophe to HTML escaping                                | do-not-port (for now)                     | Not exploitable; 6 of 28 corpus hashes would move. `[rnd]`                                |
| `323995c` | Add man page options, clean up md2html --help (#362)           | **open**                                  | `src/cli/md4x.1` is badly stale. `[misc]`                                                 |
| `d2a08e5` | Add highlight span extension (#357)                            | ported, diverged                          | → `d59ea4e`; span carries `SpanAttrsDetail` so `==x=={.warn}` composes. `[ext]`           |
| `c055ef5` | md_resolve_brackets: check the `[` is not disabled             | ported                                    | → `9eed904`; no standalone effect, mandatory with `44c90ca`. `[inl]`                      |
| `6ed63d1` | Fix broken testcase related to #352                            | ported                                    | → `26038a5` (the corrected expectation is what was imported). `[misc]`                    |
| `755ce49` | md_is_autolink_uri: scheme must begin with alnum (#369)        | ported                                    | → `47f4485`; **63 of 128** first bytes made bogus links. `[auto]` `[uni]`                 |
| `38592ac` | Accept percent sign in auto links                              | ported                                    | → `00b9516`. `[auto]`                                                                     |
| `6d168ef` | Make the tests more like current cmark (#373)                  | do-not-port                               | Would gut `spec-markdown.txt`; its timeout never fires. `[uni]`                           |
| `ecbb091` | md_analyze_table_alignment: bound the dash scan                | ported                                    | → `76dff08`; latent, but `ctx.ch()` is never bounds-checked. `[blk]`                      |
| `10e96ad` | Code spans: keep the line-break space                          | do-not-port                               | **Upstream regression; md4x fails 0 of the affected examples.** `[blk]`                   |
| `65c6c9d` | md_html: escape raw HTML in image alt attribute                | ported                                    | → `c1a1990`; `onerror` became a live attribute. `[rnd]` `[uni]`                           |
| `c4be862` | test/regressions.txt: fix some wording                         | already-fixed                             | Wording only; no example bodies changed. `[uni]`                                          |

**Excluded from the table (31 of 120).** 29 commits touching only README/CHANGELOG/CI/CMake/
`.gitignore`/version: `05c0e7f` `09819bf` `10c0158` `2855917` `2bac75e` `2ed8e52` `313429e`
`347b528` `387b0b9` `3ab40d0` `3eade38` `472c417` `4913b5d` `4e0102e` `63f897e` `66c32f3`
`69a7e96` `795ddff` `7e19948` `8eca73a` `9de89d8` `a1072a0` `a1794a4` `bd61dfb` `bf51db2`
`ca4ef3d` `e60580d` `f232554` `f5f5594`. Plus the 2 merge commits `2347000`
(superscript/subscript) and `a4a5678` (spoilers), whose content is in the table as the commits
they merge. All were reviewed and are no-ops for md4x.

## What landed in this sweep

17 md4x commits. Every one names its upstream sha in the commit message.

| md4x      | upstream                                                          | note                                                                                                   |
| --------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `c1a1990` | `65c6c9d`                                                         | Escape raw HTML inside the image `alt` attribute.                                                      |
| `9eed904` | `44c90ca`, `c055ef5`                                              | Disable marks swallowed by an inline link URL; `md_rollback` call sites left alone.                    |
| `1094346` | `589681b`, `1ecb4a4`                                              | Sparse-table suppression; 642× amplification fixed. First `ctx.log()` reachable on non-error input.    |
| `3583855` | `53852ac` (surrogate half)                                        | Guards patched in place, **not** hoisted: the five encoders are not interchangeable.                   |
| `47f4485` | `755ce49`                                                         | Autolink scheme must begin with an alphanumeric.                                                       |
| `bb4ee4d` | `380ee2b`                                                         | Trailing tabs after a closing code fence.                                                              |
| `a629443` | `ff71f00`                                                         | Don't rewind past bytes a span closer consumed.                                                        |
| `c108204` | `fab28e4` (+ `f24870b` as constraint)                             | Only `class` is de-duplicated; the AST `language` prop stays raw for the JS highlighter.               |
| `235d587` | md4x-only (class of `5012c8f`/`174fe05`)                          | `block_bytes` arena → `usize` + `MAX_BLOCK_BYTES`. Upstream never fixed this site.                     |
| `6b48364` | md4x-only                                                         | Markdown renderer escaping, three tiers derived from the mark collector. Only `markdown:` hashes move. |
| `0fe86b9` | md4x-only                                                         | ANSI/text neutralize document control bytes; unconditional, not gated behind `NO_COLOR`.               |
| `76dff08` | `174fe05`, `671cd93`, `ecbb091`, `19dd06f` (sizing)               | Plus md4x-only: CLI/NAPI oversized-input refusal, `containers.items.len` underflow guard.              |
| `00b9516` | `d1f8a97` ⊃ `3834f11`, `5d52d32`, `d534ad9`, `b8d9ee1`, `38592ac` | Three inputs become _stricter_; upstream followed, all three pinned in `regressions.txt`.              |
| `d59ea4e` | `d2a08e5`                                                         | Highlight `==x==` → `<mark>`, `MD_FLAG_HIGHLIGHT = 0x100000`.                                          |
| `09b10c2` | `a8b0d3e`, `54bfec0`, `326fe25`, `915676f`, `19dd06f`             | `MD_FLAG_FOOTNOTES = 0x200000`, also in `MD_DIALECT_GITHUB`. `1ec0ff4` deliberately not ported.        |
| `d806f23` | `3420ce7`                                                         | Unicode 15.1 → 18.0; pipeline proved reproducible before any data changed.                             |
| `26038a5` | `ea20033`, `81b871f`, `fb4d03d`, `6ed63d1`                        | Test import + `normalize.py` refresh; `spec-alerts.txt` 19 → 42 cases.                                 |

## Corrections to the 2026-08 audit

Recorded because the ledger, not the report, is the durable artifact.

1. **Autolink scheme blast radius.** The audit said `isAscii` produced a bogus link on
   **61 of 127** possible first bytes. Measured while landing `47f4485`: **63 of 128**. Byte
   `0x3C` also changes (`<<oo:bar>` now links the inner `<oo:bar>`), and md4x agrees with md4c
   HEAD on 127 of 128 bytes afterwards.
2. **`block_bytes` arena reachability.** The audit put the overflow at ~358 MB of input. It is
   **~140 MB**: a blank line inside a fenced code block is one input byte but costs a full
   12-byte `MD_VERBATIMLINE` (12×, not 6×). The overflow is the 1.5× growth step at
   1 677 392 853 bytes; in ReleaseFast the optimizer keeps the true size in a 64-bit register
   while the `i32` field stores the negative, so the arena really is allocated and the grow test
   then reads false forever. Widening alone was not enough — `MAX_BLOCK_BYTES` is `maxInt(OFF)`,
   because `MD_CONTAINER.block_byte_off` is an `OFF` through which `md_analyze_line` writes the
   loose-list flag back.
3. **`1ec0ff4`.** `[inl]` classified it N/A ("the special case never existed in md4x") and
   `[ext]` listed it among the footnote commits to port. Both are wrong: md4x reached the
   wiki-link case through `md_rollback`, needed the `326fe25` guard in two places, and porting
   `1ec0ff4` would have reintroduced the bug. Now recorded as do-not-port. (Wiki links have
   since been removed, which makes the guard unreachable but does not change the verdict.)
4. **Missing test cases.** The audit found 19 post-fork regression examples missing, 10 of them
   failing. By the time the test import ran, **17 of the 19 had already been imported** by
   earlier commits in this series; only 2 were genuinely missing — upstream's PR-325 hard-break
   case and #352, footnote-gated until `09b10c2` — and both pass.
5. **`[no-normalize]` usage.** The audit counted 8 uses in `test/spec-markdown.txt`; the real
   count is **52**, which strengthens the `6d168ef` rejection.
6. **Autolink differential.** The audit measured 36 diffs over ~6 000 inputs. Re-run at 8 139
   inputs while landing `00b9516`: 522 → 25 diffs, with **all 25 residuals** being the `16a8df7`
   apostrophe difference, reproducible with no link present. Autolink-attributable diffs reach
   zero.
7. **Flag bits as landed.** `MD_FLAG_HIGHLIGHT = 0x100000` (`d59ea4e`),
   `MD_FLAG_FOOTNOTES = 0x200000` (`09b10c2`, also in `MD_DIALECT_GITHUB`) — upstream values.
   md4x's own assignment diverged from `0x10000` up and is now moot: wave 3 deleted the flag
   word entirely. Do not try to re-align, and do not reintroduce bits.
8. **`language-` de-duplication reach.** The audit named the HTML and AST renderers.
   `packages/md4x/lib/_shared.mjs` also had to change: it reconstructed the `<pre><code …>`
   wrapper length assuming the prefix was always present, and under-trimmed by 9 bytes once the
   prefix became conditional.
9. **Unicode regeneration coverage.** The audit recommended "at least one spec case per class";
   `d806f23` added **8** cases to `coverage.txt` (five punctuation-flanking, three folding).
   Against the pre-regeneration binary that suite is 31 passed / 7 failed; after, 38 / 0.
