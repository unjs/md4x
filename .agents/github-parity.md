# GitHub parity

md4x has **one dialect**. There is no `commonmark` mode, no `gfm` mode, no runtime
switch — every entry point parses with every extension md4x ships, none of them takes
a parser-flags parameter, and there is no parser flag word to select otherwise with.
GitHub is what that one dialect is _measured against_, not what it is limited to.

Read this before changing parser or renderer output, and before deciding that a
difference from GitHub is a bug. Its job is the same as
[`upstream-sync.md`](upstream-sync.md)'s: stop the expensive questions from being
re-litigated. The [Not goals](#not-goals) section is the point of the file.

## Why GitHub and not CommonMark

md4x used to claim CommonMark conformance. It cannot, and the claim was never
meaningful: extensions are always on, so eight of the spec's 652 examples parse
differently by construction — `[[foo]]`, a bare URL and a leading `---` are ordinary
text to CommonMark and syntax to md4x. A conformance number that requires turning the
product off is measuring something nobody ships.

GitHub is the honest target because GitHub is in the same position: it always runs its
extensions, and it is what users compare md4x's output against in practice.

For the record, measured 2026-08-15 before the claim was dropped: with every extension
disabled, md4x rendered all 652 CommonMark 0.31.2 examples byte-for-byte, modulo void-tag
spelling (below). The core parser is exact. That is a property worth knowing and not a
gate worth maintaining.

## The one intentional output divergence

md4x emits **HTML5 void tags** — `<hr>`, `<br>`, `<img …>` — where the CommonMark spec's
reference output spells them XHTML-style (`<hr />`). This is deliberate: GitHub emits
HTML5 too, and CommonMark's own conformance comparison normalises the two. Do not
"fix" it toward `<hr />`; that would move away from the parity target.

## Running the harness

```sh
bun scripts/gh-parity.ts            # compare against the committed baseline
bun scripts/gh-parity.ts --update   # re-record after an intentional change
bun scripts/gh-parity.ts --suite=spec-alerts.txt --verbose
```

Needs a GitHub token (`gh auth token`, else `$GITHUB_TOKEN`). Responses are cached under
`node_modules/.cache/gh-parity/`, so re-runs after an md4x change cost no API calls. The
baseline lives at [`test/gh-parity.baseline.json`](../test/gh-parity.baseline.json) and
records a **cause per divergence**, not just a count — a raw score would be meaningless
when most divergences are deliberate.

It is not wired into `scripts/run-tests.ts`: it needs the network and a token, and CI has
neither by default. Run it when touching extension output.

### Two GitHub renderers, neither a superset

`POST /markdown` takes a `mode`, and the two modes are different renderers:

|               | `mode=markdown`            | `mode=gfm`                                      |
| ------------- | -------------------------- | ----------------------------------------------- |
| soft breaks   | stay soft                  | **hard-wrapped into `<br>`**                    |
| tables        | yes                        | yes, wrapped in `<markdown-accessiblity-table>` |
| strikethrough | yes                        | yes                                             |
| footnotes     | yes, clean ids             | yes, ids salted with a per-document hash        |
| task lists    | **no** — literal `[x]`     | yes                                             |
| alerts        | **no** — literal `[!NOTE]` | yes                                             |

So the harness queries **both** and counts a case as parity if md4x matches either.
Picking one is the trap: `gfm` is the more GFM-sounding name and quietly turns every soft
break in the CommonMark core into a hard one, while `markdown` scores every task list and
alert as a divergence. Per-suite selection does not work either — the suites are mixed
(`spec-gfm.txt` alone covers tables, task lists and autolinks).

Both modes are also served through GitHub's presentation layer, which the harness strips:
heading-anchor wrappers, `class="notranslate"`, syntax-highlight spans, the `<a>` around
every image, camo image proxying, `rel="nofollow"`, and the `user-content-` anchor
namespace. None of it is a Markdown-level decision.

One thing is stripped from **md4x's** side too: an alert's
`<p class="markdown-alert-title">` row. Both renderers now generate it from the `[!NOTE]`
marker rather than from anything the author wrote, so scoring it would compare two
identical decisions — and would charge md4x forever for the ~700-byte octicon GitHub
inlines and md4x deliberately does not.

## Baseline — whole corpus re-recorded 2026-08-16

798 cases. Parity by suite:

| suite                           | parity  |
| ------------------------------- | ------- |
| `spec.txt` (CommonMark core)    | 545/652 |
| `spec-gfm.txt`                  | 15/18   |
| `spec-tables.txt`               | 15/20   |
| `spec-strikethrough.txt`        | 5/5     |
| `spec-permissive-autolinks.txt` | 9/15    |
| `spec-footnotes.txt`            | 9/36    |
| `spec-alerts.txt`               | 11/43   |
| `spec-tasklists.txt`            | 1/9     |

Divergences by cause:

| cause              |   n | meaning                                                              |
| ------------------ | --: | -------------------------------------------------------------------- |
| `markup-shape`     |  63 | same words, different wrapper markup — the actionable bucket         |
| `sanitizer`        |  62 | GitHub's HTML sanitizer rewrote or dropped raw HTML — **not a goal** |
| `unclassified`     |  23 | triaged below                                                        |
| `entity-escaping`  |  21 | `&quot;` vs `"` re-serialization — **not a goal**                    |
| `md4x-extension`   |   5 | md4x syntax GitHub does not have — **not a goal**                    |
| `scheme-allowlist` |   7 | GitHub only linkifies known URL schemes — **not a goal**             |
| `autolink-rules`   |   5 | which characters may border an autolink — **not a goal**             |
| `unicode-punct`    |   2 | GitHub's older Unicode tables — **not a goal**                       |

The headline number is misleading on its own and should never be quoted bare: 102 of the
188 divergences are causes md4x will not chase, and `spec.txt`'s 545/652 is almost
entirely `sanitizer` plus `entity-escaping`. The number that matters is `unclassified`.

Whole-baseline `--update` run, 2026-08-16, after the `\|` unescape in table cells (below).
Three suites moved and nothing else did: `spec-gfm.txt` gained upstream example 200, which
now **matches** (14/17 → 15/18) and shifts that suite's later case numbers by one;
`spec-tables.txt` gained the two verbatim-context examples pinning the same fix, both
`md4x-extension` because they use math and raw HTML GitHub has no equivalent for (15/18 →
15/20). `unclassified` is unchanged at 23 — this fix closed a case that was never in the
corpus. Earlier hand-patching of single suites is what made the numbers hard to trust;
keep re-recording the whole thing.

## Not goals

Six causes, 102 of 188 divergences. Chasing any of them makes md4x worse.

### GitHub's HTML sanitizer (62)

GitHub runs raw HTML through a sanitizer and re-balancer before serving it: `<tbody>` is
inserted, unclosed tags are closed, unknown elements are dropped, malformed tags are
deleted outright (`<div class\nfoo` becomes `<div></div>`). That is a security policy
applied _after_ Markdown parsing, and it is a hosting concern, not a parser one. md4x
passes raw HTML through as CommonMark specifies; a consumer that needs sanitizing should
sanitize.

The most visible mode is outright deletion of the constructs that are not elements at
all — comments, `<?php …?>`, `<!DOCTYPE …>`, `<![CDATA[…]]>` — which CommonMark says to
pass through verbatim. Sixteen of these used to be scored elsewhere: deleting a comment
moves no visible text, so they read as `markup-shape`, and the two where GitHub's
leftovers (`?&gt;`) made its output the _longer_ one read as `unclassified`. The
classifier now recognises the construct itself, which is what the cause actually is.

### md4x's own extensions (3)

Also in this bucket by construction, though no scored suite exercises it: `{{ expr }}`
interpolation (`test/spec-binding.txt`). GitHub renders `{{ a < b }}` as text and escapes
it to `{{ a &lt; b }}`; md4x emits the run verbatim so a template engine run over the HTML
sees the expression as written. `spec-binding.txt` is excluded from the harness like every
other md4x-only suite.

Components, attributes, LaTeX math, `==highlight==`, frontmatter. GitHub
leaves the syntax as literal text because it has no such feature. These are the reason
md4x exists; parity here would mean deleting the product.

This bucket fell from 10 to 3 on 2026-08-15. The frontmatter body test took `spec.txt`
96 (`---\nFoo\n---\nBar\n---\nBaz`) and 98 (`---\n---`) to parity — an opening `---` now
only opens a block when YAML follows it, and a block with no bytes between its fences is
two thematic breaks. Removing wiki links took the rest. Frontmatter no longer costs a
single divergence here or in CommonMark; see `docs/compatibility.md`.

### Entity re-serialization (21)

GitHub parses its own output and re-serializes it, which unescapes `&quot;` back to `"`
in text where CommonMark leaves it escaped. The two are equivalent HTML. md4x follows the
spec.

Six of these (`spec.txt` 14, 91, 343, 619, 620, 632) used to be filed under `sanitizer`
because their inputs contain something tag-shaped — `<a h*#ref="hi">`, `` `<a href="`"> ``
— and the sanitizer rules ran first. Nothing is sanitized in any of them: both renderers
rejected the tag and escaped it as text, and the outputs are byte-identical once `&quot;`
is folded. The test is now ordered ahead of the sanitizer block precisely because whole
-document equality is the stronger evidence.

### Autolink scheme allowlist (7)

GitHub only linkifies a fixed set of URL schemes; CommonMark allows any, and md4x follows
CommonMark. Scored by comparing the two `href` **sets**: a document usually mixes an
`ftp://` autolink GitHub declines with `http://` ones it accepts, and the old "GitHub
produced no link at all" guard therefore missed three of these
(`spec-permissive-autolinks.txt` 9 and 13, `spec-gfm.txt` 14).

The rule fires only when every extra link is a genuine autolink — an anchor whose text
_is_ its href. `spec.txt#500` (`[link](foo\)\:)`) used to slip in because its href has no
recognised scheme, but it is an ordinary inline link that GitHub's URL filter dropped, and
it now scores as `markup-shape`. Likewise `spec-tables.txt#16`, where the extra href is
GitHub's camo image proxy wrapping an `<img>`.

### Autolink border rules (5)

md4x inherits md4c's rules for what may sit next to, and inside, a permissive autolink;
GitHub's are not the same set, and GitHub is consistently the more permissive one. All
five are pinned as deliberate by `test/spec-permissive-autolinks.txt`, and four of them
are additionally CommonMark-exact.

| case                               | md4x declines because                                                             |
| ---------------------------------- | --------------------------------------------------------------------------------- |
| `spec-permissive-autolinks.txt#3`  | `:` precedes; only `(`, `{`, `[` and opening emphasis may                         |
| `spec-permissive-autolinks.txt#8`  | a literal `*` precedes (an emphasis _opener_ may, a literal one may not)          |
| `spec-permissive-autolinks.txt#15` | `__` in the local part — every non-alphanumeric must be bordered by alphanumerics |
| `spec.txt#602`, `spec.txt#606`     | `<` precedes; both are CommonMark-exact, and GitHub is the outlier                |

Worth revisiting only if users report the opposite: the rules exist to stop autolinks
firing inside ordinary prose, which is the failure mode that costs more.

### Unicode punctuation (2)

GitHub runs an older cmark-gfm whose Unicode tables predate CommonMark 0.31, which stopped
classifying currency symbols as punctuation — so `*£*` emphasises on GitHub and not in
md4x. **md4x is the more current one**; this will resolve itself when GitHub upgrades.

## Open — the actionable gap

### `markup-shape` (63) — scaffolding differs

Both renderers understood the syntax; the wrapper around it differs. Cosmetic to a
reader, load-bearing for anyone styling md4x output with GitHub's CSS. Whether to chase
these is a product decision nobody has taken.

- **Task lists — 8 of 9 cases.** The only extension where md4x is a strict subset of
  GitHub rather than different from it. GitHub marks the list itself
  (`<ul class="contains-task-list">`), labels each checkbox for screen readers
  (`aria-label="Completed task"` / `"Incomplete task"`), spells the boolean attributes
  `disabled=""` / `checked=""`, and puts a space between the checkbox and the text. md4x
  emits the `task-list-item` and `task-list-item-checkbox` classes and nothing else.
  Every divergence is additive, so this is the cheapest parity win on the list — and the
  ARIA labels are an accessibility gap, not just a styling one.

- **Alerts — 18 of 43 cases, and they stay.** Three decisions taken, deliberately
  closing two of the three gaps and declining the third:

  1. **The element stays `<blockquote>`.** An alert _is_ a block quote; GitHub's
     `<div class="markdown-alert markdown-alert-note">` throws that away for every
     consumer that does not have GitHub's stylesheet loaded. md4x instead carries
     **both** class sets —
     `<blockquote class="alert alert-note markdown-alert markdown-alert-note">` — so
     GitHub's CSS, which is class-based, matches md4x output unchanged, and md4x's own
     `alert-` selectors (the website, the docs, 33 spec assertions) keep working.
  2. **The title row is emitted, text only.** `<p class="markdown-alert-title">Note</p>`,
     without GitHub's inline octicon: an SVG in every alert is a stylesheet's decision,
     not a parser's, and consumers who want one attach it to the same class. Before this,
     md4x emitted no title at all and a reader saw an unlabelled quote where GitHub shows
     "⚠ Warning". The label is derived from the **case-folded** type with an initial
     capital, so `[!NOTE]` / `[!note]` / `[!Note]` — one node, one class — also produce
     one label, and GitHub's five come out spelled exactly as GitHub spells them.
  3. **Any `[!label]` is still an alert** — see the `unclassified` triage below.

  The 18 do not close, and that is the arithmetic of decision 1, not an oversight: the
  only remaining difference in every one of them is `blockquote` vs `div` plus the extra
  `alert-` classes riding along. Both are chosen. Nothing further is actionable here
  without reversing decision 1.

  The harness strips the title row from **both** sides before scoring — it is
  renderer-generated on both now, and comparing it would be comparing two renderers'
  identical decision to label the block while permanently charging md4x for GitHub's SVG.

- **Footnotes — most of `spec-footnotes.txt`.** `<section class="footnotes">` vs
  `<section data-footnotes="">`; GitHub wraps each note's content in `<p>` and md4x does
  not; the backref is `&#8617;` with `class="footnote-backref"` against a literal `↩` with
  `data-footnote-backref` and an `aria-label`.

- **Tables — 1 case** (`spec-tables.txt#16`), and only because of camo image proxying the harness could not fully
  undo. Table markup is otherwise identical.

- **`spec.txt#500` — 1 case**, and not a wrapper difference: `[link](foo\)\:)` is an
  ordinary inline link that md4x renders and GitHub's URL filter drops, leaving the text
  bare. It sits here because the bucket is defined by "same words, different markup" and
  that is literally true; the cause is GitHub's href policy, which is the same hosting
  concern as [the sanitizer](#githubs-html-sanitizer-62). Nothing to chase.

### `unclassified` (23) — triaged, still open

Real behavioural differences. Three are GitHub being wrong; one (`spec-tables.txt#18`) is
md4x departing from the GFM spec on purpose.

**Tables (2).** The only two table divergences that are not cosmetic:

| case                 | difference                                                                                                                                                                                                                                                                                                                                                                  |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `spec-tables.txt#9`  | A link reference definition on the line above the header row: md4x consumes it as a ref def (CommonMark's rule for the start of a paragraph) and resolves the later `[ref]`; GitHub renders `<p>[ref]: /url</p>` and leaves the use unlinked. Both render the table. **GitHub is wrong** — cmark-gfm appears to skip the ref-def scan on the paragraph a table interrupted. |
| `spec-tables.txt#18` | GitHub does not let a **code span cross a cell boundary** — `` `foo \| bar` `` splits at the pipe into two cells. md4x keeps it as one code span and leaves the next cell empty. **Deliberate**, decided 2026-08-16 — see below.                                                                                                                                            |

The `#18` case is the one place in this file where md4x is the outlier on a documented
rule rather than on GitHub's house style. The GFM spec splits a row on every unescaped
`|` **before** inline parsing; md4x parses the row's inlines first and splits on the pipes
that are left over, so pipes inside code spans, raw HTML, autolinks and links never split
a cell.

**The escape half is closed; the splitting half stays open on purpose.** They are
independent, and 2026-08-16 took only the first:

- **Closed.** `` `\|` `` now yields `<code>|</code>`, matching GitHub. `md_emit_verbatim_text`
  (`src/parser/inlines.zig`) breaks a cell's verbatim run — code span, raw HTML, math — at
  each `\|` and emits a literal pipe; `md_process_table_cell` sets `ctx.in_table_cell`
  around the cell. Nothing else moved: the corpus sweep was diff-clean, because a `\|`
  inside a verbatim run in a table cell appears nowhere in it. This is what **GFM example
  200** tests, now imported into `test/spec-gfm.txt` and passing.
- **Open, deliberately.** Splitting still happens after inline parsing. Matching GitHub
  here would mean ``| `string \| number` |`` — the ordinary TS-union API-table cell —
  rendering as two mangled cells, which is what GitHub does and what md4x is better than.
  It would also start splitting through links, raw HTML and autolinks (verified live
  2026-08-16, `mode=markdown`: GitHub splits all of them), and silently drop the extra
  cells past `col_count`. Doing it _without_ the escape half would have been the worst of
  the three positions — no way to write a pipe in a cell's code span at all — which is why
  the escape landed first and alone.

Mechanically the splitting half is cheap and would _delete_ code (the `table_mode`
pre-pass in `md_analyze_inlines`, `md_analyze_table_cell_boundary`, the three `MD_CTX`
boundary fields, and `|` as a mark char in every paragraph). The cost is the output, not
the patch.

Everything the escape half can reach now matches byte-for-byte, verified live 2026-08-16:
`` `\|` ``, `` `x\|` ``, `` `\|y` `` and even `` `a\\|b` `` — `<code>a\|b</code>` on both,
since cmark-gfm strips one backslash while building the cell and inline parsing keeps the
other, and md4x's emitter lands on the same two characters. The one case still diverging is
`a\\|b` in **plain** cell text: GitHub keeps one cell reading `a|b`, md4x splits into `a\`
and `b`, because md4x collects `\\` as a single escape mark and the `|` is then a bare
boundary. That is the splitting rule again, not a missing unescape — it closes with the
half above, and with nothing less.

`spec-tables.txt#7` used to head this table: GitHub let a table **interrupt a paragraph**
and md4x required a blank line first, so a whole table rendered as literal pipes. Closed
on 2026-08-16 — the header row no longer has to be the block's only line, just its last
(`md_split_off_table_header`). It was the highest real-document risk in the whole
baseline, because the missing blank line is a routine authoring slip.

**Alerts (13).** Almost all one finding: **md4x treats any `[!label]` as an alert**, GitHub
only its five (`NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`). Cases 6, 17, 37, 38, 39,
40, 41 and 43 are `[!CUSTOM]`, `[!my-custom-alert]`, `[!v2_note]`, `[!123]`, `[!-x]`,
`[!_]`, `[!noteX]` and a 70-character label — md4x turns each into an alert with the
label as its class and title, GitHub leaves them as text in a plain blockquote.
**Decided: the permissiveness stays**, and these 8 will not close. `test/spec-alerts.txt`
pins custom labels as a feature, GitHub's fixed five are a product choice of GitHub's, and
a `[!DEPLOY]` block is exactly the kind of thing md4x's users define. The edges were
reviewed once and all are working as specified rather than as accidents:

| case       | class / title           | verdict                                                                                                                                |
| ---------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `[!noteX]` | `alert-notex` / `Notex` | The type is case-insensitive by design, the same way `[!NOTE]` and `[!note]` are one type. Surprising, documented, not wrong.          |
| `[!-x]`    | `alert--x` / `-x`       | The doubled hyphen is inside the identifier, which still starts `a`. `.alert--x` is a valid selector.                                  |
| `[!_]`     | `alert-_` / `_`         | Valid CSS identifier.                                                                                                                  |
| 70 chars   | full, untruncated       | Deliberate — the renderer chunks the name rather than capping it, and the case exists to pin that.                                     |
| `[!123]`   | `alert-123` / `123`     | Not a digit-leading identifier: the class is `alert-123`, which starts with `a`. Valid unescaped in both the attribute and a selector. |

None needs escaping either, in the class or in the new title text: the recognizer's
charset is `[a-zA-Z0-9_-]`, so a label can carry neither a quote nor a `<`. Widening that
charset in `blocks.zig` would turn the HTML renderer's alert path into an injection site.

The rest are structural: an alert with no body (#9), one containing a fenced block (#18), a
nested alert (#27), one inside a list item (#28), and `>[!tip]\n>-` where the `-` is a
setext underline to GitHub and a list to md4x (#22).

**Footnotes (6), autolinks (1) and CommonMark core (1).**

| case                              | difference                                                                                                                                           |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `spec-footnotes.txt#7, #36, #37`  | md4x numbers footnote anchors (`fn-1`); GitHub derives them from the **label** (`fn-a`, `fn-ünï`). Affects any deep link into a rendered document.   |
| `spec-footnotes.txt#31`           | A footnote ref inside a link: md4x nests it correctly, GitHub breaks the link apart. **GitHub is wrong.**                                            |
| `spec-footnotes.txt#34`           | `[^nf]:` on the line after a paragraph: md4x keeps it as text, GitHub **drops the content entirely**. **GitHub is wrong.**                           |
| `spec-footnotes.txt#27`           | A footnote inside an alert. Nothing new: it is the `<blockquote>`-not-`<div>` decision and the `fn-1` numbering above, landing in one case.          |
| `spec-permissive-autolinks.txt#5` | `www.example.com}` — md4x stops the URL at the `}`, GitHub swallows it into the href (`…com%7D`). md4x's is the more useful reading; **not a goal**. |
| `spec.txt#28`                     | `&#87654321;` (out of range): CommonMark says leave it literal, md4x does, GitHub emits U+FFFD. **GitHub is wrong.**                                 |

`spec.txt#180` and `#629` used to sit in this table as sanitizer cases the classifier could
not reach. It reaches them now — see [sanitizer](#githubs-html-sanitizer-62).

## Extending the harness

`scripts/gh-parity.ts` holds the corpus list, the destyling rules and the classifier.
When adding a suite, check whether either GitHub mode renders the syntax at all — if
neither does, the suite is md4x-only and does not belong in the corpus. When a new
divergence lands in `unclassified`, either teach the classifier why it is a known cause
or triage it into the table above; leaving it unexplained is what the bucket is there to
prevent.
