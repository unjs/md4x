# Compatibility Matrix

md4x has **one dialect**. This document records how that dialect lines up against the
three references it is measured against — CommonMark 0.31.2, GitHub, and Comark — at the
**default preset**, meaning what a JS caller gets from `renderToHtml(input)` with no
options.

Everything here is measured, not asserted. See [Reproducing these numbers](#reproducing-these-numbers).

## The default preset

**The parser is not configurable — from JS or from Zig.** There is no parser flag
word: `abi.Parser` holds the SAX callbacks and nothing else, and no entry point takes
a parser-flags parameter. The CLI, the WASM exports, the NAPI addon, the fuzzer and
the unit tests therefore all run the same dialect, so the `.txt` suites exercise
exactly the JS parser preset.

Permissive URL / email / WWW autolinks, tables, strikethrough, task lists, LaTeX math,
frontmatter, components, attributes, alerts, highlight and footnotes are all
**unconditionally on**. There is no "off" column: the six dialect toggles that used to
sit there (collapse-whitespace, permissive ATX headers, no-indented-code-blocks,
no-HTML-blocks, no-HTML-spans, hard-soft-breaks) were dead in every build and have been
deleted along with the code they guarded, so their former behavior is now simply the
parser's behavior.

That is GitHub's extension set plus exactly the five md4x-only extensions (latex,
frontmatter, components, attributes, highlight). **Raw HTML passes through unsanitized.**

**Renderer flags default to `SKIP_UTF8_BOM` only** (`packages/md4x/lib/wasm/common.mjs`,
mirrored in `napi.mjs`). Notably absent by default: `HEADING_IDS` (`0x20`), `FULL_HTML`
(`0x08`), `HEAL` (`0x100`).

> `SKIP_UTF8_BOM` is always on and not overridable — a BOM is an encoding artifact, and
> leaving it in derails the first block (`﻿---` stops reading as a frontmatter fence).
> The bit is `0x0004` for HTML and `0x0002` for every other renderer. The CLI additionally
> sets `DEBUG`, which is inert for output; that is now the only flag difference between the
> suite runner and the JS library.

## Matrix

✅ matches · ➕ md4x extension — the reference has no such syntax · ⚠️ diverges on purpose ·
❌ gap or unsupported · — not applicable

| Feature                                | CommonMark |                  GitHub                   |            Comark             |
| -------------------------------------- | :--------: | :---------------------------------------: | :---------------------------: |
| Core blocks & inlines                  |     ✅     |                    ✅                     |              ✅               |
| Void tag spelling (`<hr>` vs `<hr />`) |     ⚠️     |                    ✅                     |              ✅               |
| Nested strong (`****foo****`)          |     ✅     |                    ⚠️                     |              ✅               |
| Code fence info (`class="language-x"`) |     ✅     |                    ⚠️                     |              ✅               |
| Raw HTML                               |     ✅     |              ⚠️ unsanitized               |              ✅               |
| Entity escaping in attributes          |     ✅     |                    ⚠️                     |              ✅               |
| Tables                                 |     —      | ⚠️ no split inside code spans (by choice) |              ✅               |
| Task lists                             |     —      |      ❌ missing classes / a11y attrs      |            ⚠️ same            |
| Strikethrough                          |     —      |                    ✅                     |              ✅               |
| Permissive autolinks                   |     ➕     |            ⚠️ scheme allowlist            |              ✅               |
| Alerts                                 |     —      |  ⚠️ `<blockquote>` not `<div>`; superset  |              ✅               |
| Footnotes                              |     —      |        ❌ scaffolding + anchor ids        |              ✅               |
| Frontmatter                            |     ➕     |                    ➕                     |              ✅               |
| Components (`:c`, `::c`)               |     ➕     |                    ➕                     |              ✅               |
| Attributes (`{#id .cls}`)              |     ➕     |                    ➕                     |      ⚠️ spaced `[span]`       |
| Highlight (`==x==`)                    |     ➕     |                    ➕                     |              ✅               |
| LaTeX math (`$x$`)                     |     ➕     |                    ➕                     |      ➕ non-Comark node       |
| Heading ids                            | ⚠️ opt-in  |             ❌ off by default             | ❌ off by default (HTML only) |
| Emoji shortcodes                       |     —      |           ❌ build-time opt-in            |     ❌ build-time opt-in      |
| Comments hidden from output            |     —      |                     —                     |  ❌ HTML renderer emits them  |

➕ marks syntax md4x adds; it is additive by nature, so a reference that lacks it is not a
failure on either side. No row carries **➕ ⚠️** any more — that mark was for an extension
whose delimiter collides with syntax the reference already uses, changing the rendering of
documents that never opted in. Both are gone: wiki links were removed outright, so `[[x]]`
is literal text again, and frontmatter now declines any `---` block that does not contain
YAML (see [Frontmatter](#frontmatter)).

## CommonMark 0.31.2

> `test/spec.txt` in this repo has been **re-recorded to md4x's dialect** — it is not the
> upstream file (148 insertions / 224 deletions since the 0.31.2 import at `485619f`).
> That is why the suite reports 652/652. The numbers below are against pristine upstream.

| Run                            |    Pass |  Fail |
| ------------------------------ | ------: | ----: |
| Default preset, normalized     | **649** | **3** |
| Default preset, byte-exact     |     591 |    61 |
| All extensions off, normalized | **652** | **0** |

The 58 extra byte-exact failures are **entirely void-tag spelling** — `<hr>` ×27,
`<img>` ×22, `<br>` ×9. Zero whitespace or entity divergence: the core parser is exact.

All 3 semantic divergences are extension-driven and intentional:

| Examples      | Cause                  | Effect                                                                    |
| ------------- | ---------------------- | ------------------------------------------------------------------------- |
| 608, 611, 612 | `PERMISSIVE*AUTOLINKS` | Bare URLs and emails linkified (GitHub agrees; CommonMark is the outlier) |

Removing wiki links returned examples 548, 559 and 590 (`[[…]]` as literal text or a
reference link) to exact; the frontmatter body test returned 96 and 98.

### Frontmatter

Frontmatter costs **zero** spec examples, which it did not before. An opening `---` only
opens a block when a closing fence follows it _and_ what lies between reads as YAML:
blank lines and `#` comments are skipped, and the first line of substance has to be a
`key:` mapping line. A body that reads as markdown is a thematic break plus ordinary
content, which is example 96 (`---\nFoo\n---\nBar\n---\nBaz`) exactly — and no document
loses content to a `---` its author meant as a rule.

A body with **no characters at all** between the fences does not open a block either, so
example 98 (`---\n---`) is two thematic breaks. One character is enough to make it
frontmatter again (`---\n \n---`), and so is a comment. That threshold is not invented
here: it is where Comark draws the line, verified against `comark@0.6.2` case by case,
and `test/spec-frontmatter.txt` (`# Empty Frontmatter`) pins each side of it.

Component block props keep consuming an empty `---` block rather than rendering it —
also Comark's behaviour, and there is no document content at that position to protect.

Every other extension costs **zero** spec examples too. Collision probes confirm the guarding:
`Costs $5 to $10`, `a == b`, `{#id}`, `x :: y`, `a[i][j]` all stay literal.

## GitHub

Measured live against `api.github.com/markdown` in both `markdown` and `gfm` modes; a case
counts as parity if it matches either. Baseline: `test/gh-parity.baseline.json`,
rationale in [.agents/github-parity.md](../.agents/github-parity.md).

**188 divergences over 798 cases.** Whole-baseline re-record on 2026-08-16, after `\|`
started unescaping inside table cells. All three new cases are the tests for that fix: GFM
example 200, imported into `spec-gfm.txt` and **matching**, plus two `spec-tables.txt`
cases pinning the same fix in math and raw HTML, which GitHub has no equivalent for and so
count as `md4x-extension`. Every other total is unchanged — the fix closed a case that was
never in the corpus.

Earlier movement, for the record: 192 → 186 over two changes, when the frontmatter body
test took `spec.txt` 96 and 98 to parity and removing wiki links took 548 and 559 (590
dropped to a plain `entity-escaping` divergence, and the two wiki cases in
`spec-footnotes.txt` are gone). `md4x-extension` fell from 10 to 3 between them.

| Suite                         |  Parity |
| ----------------------------- | ------: |
| spec.txt                      | 545/652 |
| spec-gfm.txt                  |   15/18 |
| spec-tables.txt               |   15/20 |
| spec-tasklists.txt            |     1/9 |
| spec-footnotes.txt            |    9/36 |
| spec-alerts.txt               |   11/43 |
| spec-strikethrough.txt        |     5/5 |
| spec-permissive-autolinks.txt |    9/15 |

| Cause              |   n | Status                                             |
| ------------------ | --: | -------------------------------------------------- |
| `markup-shape`     |  63 | open — but only 47 actionable, see below           |
| `sanitizer`        |  62 | not-goal — GitHub strips raw HTML, md4x does not   |
| `unclassified`     |  23 | triaged, all documented                            |
| `entity-escaping`  |  21 | not-goal                                           |
| `md4x-extension`   |   5 | not-goal                                           |
| `scheme-allowlist` |   7 | not-goal — GitHub linkifies only http(s)/mailto    |
| `autolink-rules`   |   5 | not-goal — which characters may border an autolink |
| `unicode-punct`    |   2 | not-goal — GitHub's tables predate 0.31            |

102 of 188 are declared not-goals. **No divergence is an outright "md4x emits wrong HTML"
bug** — each reduces to a not-goal, a decision already taken, a GitHub defect, or an open
gap. Cases where md4x is the correct one include CommonMark-exact nested strong (8),
`&#87654321;` (GitHub emits U+FFFD), footnote-in-link, `[^nf]:` after a paragraph, and a
link reference definition on the line above a table header (GitHub leaves it as text).

Open, undecided gaps:

- **Task lists** (8 cases) — md4x is a strict _subset_: no `<ul class="contains-task-list">`,
  no `aria-label="Completed task"`, no `disabled`/`checked`. Renderer-only fix; real
  screen-reader gap.
- **Footnote scaffolding** (19 cases) — `class="footnotes"` vs `data-footnotes`, no `<p>`
  wrap, `&#8617;` vs `↩` + `data-footnote-backref` + `aria-label`.
- **Footnote anchor ids** (3–4 cases) — numbered `fn-1`/`fnref-1-1` instead of
  label-derived `fn-a`. Breaks deep links into GitHub-rendered documents.
- **Pipes inside code spans in a table cell** (1 case, `spec-tables.txt#18`) — the one
  divergence md4x holds against the spec rather than against GitHub's house style, and
  since 2026-08-16 a **decision, not a gap**. GFM splits a row on every unescaped `|`
  _before_ inline parsing, so `` `foo | bar` `` is two cells there; md4x parses inlines
  first and splits on what is left, so it stays one code span. Matching GFM would mangle
  ``| `string | number` |`` — the everyday API-table cell — and would also start
  splitting through links, raw HTML and autolinks, which is what GitHub does to all three.
  The spec's own escape now works either way: `` `\|` `` renders `<code>|</code>` as of
  2026-08-16 (GFM example 200, imported into `test/spec-gfm.txt` and passing), so a
  document written for GitHub renders correctly here too. Reasoning in
  [.agents/github-parity.md](../.agents/github-parity.md).

_(Tables not being able to interrupt a paragraph used to be the fourth entry, and the
highest real-document risk on it: a missing blank line turned an entire table into
paragraph text. Closed 2026-08-16 — the header row now only has to be the **last** line of
the paragraph, not its only line, and the lines above it stay a paragraph. `spec-tables.txt`
pins the split, the lazy-continuation case that still declines, and the ref-def
interaction.)_

The other 16 `markup-shape` cases are not gaps: 8 are CommonMark-exact nested strong, 6
are the `class="language-x"` fence spelling, and 2 are hosting artifacts (GitHub's camo
image proxy, and its URL filter dropping `[link](foo\)\:)`).

## Comark

Spec: [.agents/comark/](../.agents/comark/) · AST: [comark-ast.md](comark-ast.md) ·
conformance: `test/spec-comark.txt`.

All Comark suites are green at the default preset — `spec-comark.txt` 122, `spec-components.txt`
109, `spec-attributes.txt` 75, `spec-frontmatter.txt` 56, `spec-highlight.txt` 49,
`spec-markdown.txt` 82, all 0 failures — and, since the BOM fix, green through the JS
bindings too (`test/spec-frontmatter.txt:621` used to pass only on the CLI).

On by default: components, attributes, frontmatter, `==mark==`, alerts, tables, task lists,
strikethrough, autolinks, footnotes. Off: HTML heading ids, emoji, `heal`.

Gaps between the Comark spec and md4x:

| Item                                      | Spec says                                                | md4x does                                            | Class                                                              |
| ----------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------ |
| `$`-prefixed component names              | "must start with a letter or `$`" (`spec-comark.txt:34`) | `:$slot` stays literal                               | **spec vs impl**, untested                                         |
| `[span] {attr}` with a space              | `<span>` element (`attributes.md:329`)                   | `[span]` stays literal                               | documented divergence, **unpinned**                                |
| Comments in output                        | "not rendered" (`markdown.md:422`)                       | HTML renderer emits them verbatim; AST is correct    | **spec vs impl**                                                   |
| Heading ids                               | every heading gets one                                   | HTML omits, AST always includes                      | off by default — `renderToHtml` and `parseAST` disagree            |
| Emoji `:wave:`                            | 👋                                                       | literal                                              | build-time `-Demoji=true` (~26 KB gz)                              |
| `<ul class="contains-task-list">`         | present                                                  | absent                                               | documented not-goal                                                |
| Non-Comark node types                     | —                                                        | `math`, `mark`, `footnote-ref`                       | superset by design, **not disableable from JS**                    |
| `{{ expr }}` interpolation                | binding plugin, opt-in                                   | always verbatim text (`spec-binding.txt`)            | deliberate — the HTML renderer never escapes the run               |
| Malformed `{…}` run                       | consumed; a non-`[a-z_][a-z0-9_-]*` key is dropped       | whole run stays literal (`{x.y}`, `{f()}`, `{...p}`) | deliberate — keeps JSX-style `{expr}` text (`spec-attributes.txt`) |
| `Hello {title}` (bare keys after a blank) | boolean prop on the block                                | literal text; `**b**{title}` still binds             | deliberate — a spaced bare-key run is a JSX-style `{expr}`         |
| `meta` shape                              | `{toc, summary}`                                         | `{headings}` (+`title`)                              | deliberate, declared                                               |
| Lone inline component                     | inline                                                   | lifted to block                                      | deliberate — matches `markdown-it-mdc`                             |

## Known bugs

None currently tracked.

_(Wiki links used to be listed here as bug 1 — `[[…]]` had no flanking guard, so
`arr[[i]] index` linkified inside code-ish prose and `[[[foo]]]` rendered as
`[<x-wikilink>foo</x-wikilink>]`. Fixed by removing the extension: neither CommonMark nor
GitHub-flavored Markdown has wiki links, and `[[x]]` is literal text again.)_

_(Frontmatter used to be listed here as bug 2 — `---\nFoo\n---\nBar` silently deleted an
`<hr>` and an `<h2>`. Fixed: an opening fence now has to be followed by YAML, not by
markdown, in both the document and the block-props position. See
[Frontmatter](#frontmatter) for the one case left, and `spec-frontmatter.txt`, `# An
Opening Fence Only Opens Frontmatter When YAML Follows It`.)_

## Reproducing these numbers

```sh
zig build                                    # CLI at zig-out/bin/md4x
bun run build:js                             # wasm + napi + standalone
bun scripts/run-tests.ts                     # every suite
python3 test/run-testsuite.py -s test/spec.txt        # one suite, normalized
python3 test/run-testsuite.py -s test/spec.txt --no-normalize
bun scripts/gh-parity.ts                     # GitHub parity (needs a token)
```

For the true CommonMark score, diff against upstream 0.31.2 rather than the committed
`test/spec.txt`:

```sh
git show 485619f:test/spec.txt > /tmp/spec-upstream.txt   # == upstream 0.31.2
python3 test/run-testsuite.py -s /tmp/spec-upstream.txt
```

> The committed `test/spec.txt` is dialect-adjusted, so it can never report a CommonMark
> divergence again — a future regression in, say, autolink flanking would be invisible to
> it. Treat 652/652 as a no-regression signal, not a conformance claim.
