# Markdown Syntax Reference

## CommonMark Basics

**Block elements:** paragraphs, headings (`#` or setext), lists (unordered/ordered with nesting), blockquotes, code blocks (fenced or 4-space indent), horizontal rules, raw HTML blocks.

**Inline elements:** emphasis (`*`/`_`), strong (`**`/`__`), links, images, inline code, raw HTML spans, hard breaks (trailing spaces or `\`), soft breaks.

### Heading IDs

Headings carry a generated `id`, slugged from their text and de-duplicated within the document:

```
# Hello World      → <h1 id="hello-world">Hello World</h1>
```

All renderers agree on the slug (`src/renderers/md4x-slug.zig`); the JSON renderer also exposes it
on `meta.headings` for TOC building. A `{#custom-id}` block attribute overrides the generated value.

> **Not CommonMark**, so in HTML it is opt-in: md4c and the CommonMark reference implementations
> emit bare `<hN>`, and so does md4x unless the caller asks for ids — `--heading-ids` on the CLI,
> `{ headingIds: true }` from JS, `MD_HTML_FLAG_HEADING_IDS` in Zig. `test/spec.txt` runs without
> the flag and stays an unmodified CommonMark conformance check. The JSON/meta outputs are Comark's
> own rather than CommonMark's, so they always carry the id.

## Extension: Tables

```
| Column 1 | Column 2 |
|----------|----------|
| foo      | bar      |
```

- Alignment via colons: `:---` left, `:---:` center, `---:` right
- Leading/trailing pipes optional (except single-column)
- **A table may interrupt a paragraph** — no blank line needed above it. The line directly
  above the `---|---` underline is the header row; anything before that stays a paragraph.
  (An underline that is only a lazy continuation line does not open a table: it has to sit
  in the same container as the header row.)
- Max 128 columns (DoS protection)
- Cell content supports inline markdown
- A pipe inside a code span, raw HTML tag, autolink or link does **not** split the cell, so
  ``| `string | number` |`` is one cell (GitHub splits it — see
  [compatibility.md](compatibility.md))
- `\|` is a literal pipe anywhere in a cell, including inside a code span, raw HTML or
  math, where a backslash escape is otherwise inert: `` `a\|b` `` is `<code>a|b</code>`.
  This is GitHub's escape, so tables written for GitHub render the same here

## Extension: Task Lists

```
- [x] Completed
- [ ] Pending
```

## Extension: Strikethrough

`~text~` or `~~text~~`. Opener/closer must match length. Follows same flanking rules as emphasis.

## Extension: Highlight

`==text==` renders as `<mark>text</mark>`. Exactly two `=` on each side — `=x=`,
`===x===` and longer runs stay literal. Unlike emphasis and strikethrough the
delimiter is gated on **whitespace adjacency only**, not on the flanking rules:
it cannot open when followed by whitespace and cannot close when preceded by
whitespace, but an intra-word `a==b==c` is a highlight. Setext underlines are
block-level and are unaffected.

## Extension: Footnotes

```
Text with a footnote[^1] and again[^1].

[^1]: The footnote content.
```

- **Reference** `[^label]` — the label is a non-empty run of characters that are
  not whitespace, `[` or `]`. Labels are matched case-insensitively (the same
  case-folding link reference labels use), so `[^AB]` and `[^ab]` are one
  footnote.
- **Definition** `[^label]:` at the **start of a paragraph block**. Like a link
  reference definition it cannot interrupt a paragraph. The body is the rest of
  that first line plus the remaining lines of the same paragraph block, stopping
  before a line that itself starts a new `[^…]:` definition. A blank line ends it,
  because a blank line ends the block — so, unlike GFM, an indented
  multi-paragraph footnote body is not supported.
- Definitions are emitted **at the very end of the document**, in order of
  **first reference**, not definition order. A definition that is never
  referenced is consumed and never emitted; a reference whose label has no
  definition stays literal text. Duplicate labels: the first definition wins.
- The reference renders `<sup><a href="#fn-N" id="fnref-N-K">N</a></sup>`, and the
  definitions render inside `<section class="footnotes"><ol><li id="fn-N">…`, with
  one `↩` back-reference anchor per reference.

Interactions with the other MD4X extensions:

- `[^1]{.cls}` — **footnote wins**, the `{...}` stays literal. The span is
  self-contained, so there is no content for inline attributes to attach to.
- A reference that lands inside a link **destination** is swallowed by the
  destination and never resolves.
- Alerts (`[!TYPE]`) and components (`:name[…]`, `::name`) do not overlap `[^`.

## Extension: Permissive Autolinks

- **URL**: `https://example.com`
- **Email**: `john@example.com`
- **WWW**: `www.example.com`

## Extension: LaTeX Math

Inline `$...$` and display `$$...$$`. Opener must not be preceded by alphanumeric; closer must not be followed by alphanumeric.

## Extension: Frontmatter

YAML-style frontmatter delimited by `---` at the very start of the document. The opening `---` must be on the first line (no leading blank lines). Content is exposed as verbatim text via the `.frontmatter` block. The HTML renderer suppresses frontmatter from body output; in full-HTML mode (`MD_HTML_FLAG_FULL_HTML`), YAML `title` and `description` fields are used in `<head>`. An **unclosed** `---` is not frontmatter: the opener falls back to a thematic break and the rest of the document parses as ordinary blocks.

```
---            → <hr>
title: Hello     <p>title: Hello</p>
```

A closed block additionally has to _contain_ YAML. The classifier skips blank lines and `#` comments below the opener and requires a mapping line — `key:` followed by a space or the line end. A body that reads as markdown is not frontmatter, so `---` / `Foo` / `---` is a thematic break and a setext heading rather than a swallowed `Foo`:

```
---            → <hr>
Foo              <h2>Foo</h2>
---
```

A block with **no characters at all** between its fences opens nothing either: `---` / `---`
is two thematic breaks, and so is `---` / blank line / `---`. One character is enough to make
it frontmatter again — a single space, a comment, a second blank line (whose separating
newline is itself a character) — and the result is an empty `frontmatter` object. That
threshold is Comark's, verified against `comark@0.6.2`; `test/spec-frontmatter.txt` pins
each side of it, and [compatibility.md](compatibility.md#frontmatter) explains why.

In a **component's** props position the empty case goes the other way: `::card` / `---` / `---`
consumes the block, because there is no document content there to protect. Comark agrees.

Frontmatter keys carry no special meaning to the parser: every key is passed through to the `frontmatter` object as-is. (`title` and `description` are read only by the HTML renderer's full-HTML mode, as above.)

**JSON renderer YAML parsing:** The JSON renderer uses [libyaml](https://github.com/yaml/libyaml) to parse frontmatter into the tree's top-level `frontmatter` object. Full YAML 1.1 is supported including nested objects, arrays (block and flow), and multi-line values (literal `|` and folded `>`). Plain scalars have type coercion: numbers (int/float), booleans (`true`/`false`/`yes`/`no`/`on`/`off`), null (`null`/`~`/empty). Quoted scalars (`""`/`''`) are always strings. Frontmatter is not a node — it sits beside `nodes` on the tree, and the raw text is not preserved: `{"nodes": [...], "frontmatter": {"title": "Hello", "count": 42}, "meta": {...}}`. Content that is not a YAML mapping (a bare scalar) is consumed but yields `{}`.

## Extension: Alerts

GitHub-style alert/admonition syntax. A blockquote whose first line is `> [!TYPE]` becomes an alert block:

```
> [!NOTE]
> This is a note

> [!WARNING]
> This is a warning
```

- TYPE is any non-empty ASCII name matching `[a-zA-Z0-9_-]+`, case-insensitive. The charset is applied uniformly from the first character, so a type may also begin with a digit, `-` or `_` (`[!123]`, `[!-x]`, `[!_]` are all alerts). Non-ASCII letters are not accepted
- The parser reports the type as **source text** (`"NOTE"`), and each renderer decides what to do with it: HTML and JSON/AST case-fold it (`alert-note`, `{"type":"note"}`), the markdown renderer round-trips the author's spelling, and the ANSI and plain-text renderers print it as written
- The `[!TYPE]` line must be the **first line** of the blockquote and the **only content** on that line
- Text after `[!TYPE]` on the same line disqualifies it (treated as normal blockquote)
- `[!TYPE]` not on the first line is treated as literal text
- At most **65 536 alerts per document**, counted independently of components and slots (`types.MAX_BLOCK_INFO_RECORDS` — the alert type is stored in a side array whose index rides through the 16-bit `MD_BLOCK.bits.data`); past that the blockquote stays a plain blockquote and `[!TYPE]` renders as literal text
- Supports all GitHub types (NOTE, TIP, IMPORTANT, WARNING, CAUTION) plus custom types
- Content supports full markdown (inline formatting, lists, nested blockquotes, code blocks)

HTML renderer:

```html
<blockquote class="alert alert-note markdown-alert markdown-alert-note">
  <p class="markdown-alert-title">Note</p>
  <p>This is a note</p>
</blockquote>
```

The element stays a `<blockquote>` — an alert _is_ a block quote, and GitHub's `<div>` substitution loses that for every consumer without the stylesheet — but carries **both** class sets, so GitHub's class-based alert CSS matches md4x output unchanged. The title row is GitHub's, **minus the inline octicon**: the icon is a stylesheet's business, and consumers who want one attach it to `.markdown-alert-title`. Its label is derived from the case-folded type with an initial capital (`[!NOTE]`, `[!note]` and `[!Note]` are one node, one class, one label — `Note`), which spells GitHub's five exactly as GitHub does and gives a custom `[!DEPLOY]` the label `Deploy`.

JSON renderer: `["alert", {"type": "note"}, ...children]` (type lowercased). ANSI renderer: colored thick left bar (`▌`) with type-specific colors (note/info=blue, tip/success=green, important=magenta, warning=yellow, caution/danger=red), and a title line that keeps the **author's** casing rather than the HTML renderer's derived label — see [renderers.md](renderers.md). Block components `::alert{type="..."}`, `::note`, `::warning`, etc. also render with the same style.

## Extension: Inline Components

Inline components use the MDC syntax: `:component-name`, `:component[content]`, `:component[content]{props}`, `:component{props}`.

- **Standalone**: `:icon-star` — requires hyphen in name (to avoid URL/email conflicts)
- **With content**: `:badge[New]` — content supports inline markdown (emphasis, links, etc.)
- **With props**: `:badge[New]{color="blue"}` — raw props passed to renderers
- **Props only**: `:tooltip{text="Hover"}`

Constraints:

- `:` must not be preceded by an alphanumeric character
- Component name: `[a-zA-Z][a-zA-Z0-9-]*`
- Standalone components (no `[content]` or `{props}`) require a hyphen in the name

Property syntax in `{...}`: `key="value"`, `key='value'`, `bool` (boolean true), `#id`, `.class`, `:key='json'` (JSON passthrough). Multiple `.class` values are merged.

HTML renderer: `<component-name ...attrs>content</component-name>`. JSON renderer: `["component-name", {props}, ...children]`. ANSI renderer: cyan-colored text.

## Extension: Block Components

Block components use the MDC syntax with `::` fences. They are container blocks — content between open and close is parsed as normal markdown.

```
::alert{type="info"}
This is **important** content.
::
```

- **Basic**: `::name\ncontent\n::` — content is parsed as markdown blocks
- **With props**: `::name{key="value" bool #id .class}\ncontent\n::`
- **With title**: `:::name Title text\ncontent\n:::` — VitePress-style custom container with title
- **With title and props**: `:::name Title text {key="value"}\ncontent\n:::`
- **Empty**: `::divider\n::` — no content between open/close
- **Nested**: `:::outer\n::inner\n::\n:::`
- **Deep nesting**: nesting is resolved by matching each opener with its closer; the colon count is
  not a constraint. Increasing it inward (`::` > `:::` > `::::`), decreasing it inward
  (`::::` > `:::` > `::`) and keeping it constant all nest identically. Varying it is a readability
  convention only.

VitePress-style custom containers are supported via the title syntax:

```
:::info
This is an info box.
:::

:::danger STOP
Danger zone, do not proceed
:::

:::details Click me to toggle
Hidden content here
:::
```

The title text appears after the component name, separated by a space. It is passed to renderers as a `title` attribute/prop. Props in `{...}` can follow the title.

Constraints:

- Block components **cannot interrupt paragraphs** (require blank line before)
- Opening line: `::name`, `::name{props}`, or `::name Title {props}` (2+ colons, component name, optional title, optional props)
- Closing line: `::` (2+ colons only, no name)
- A closer with N colons closes the innermost open component with ≤N colons
- Component name: `[a-zA-Z][a-zA-Z0-9-]*` (same as inline components)
- Content is always treated as loose (paragraphs wrapped in `<p>`)
- At most **65 536 block components per document**; past that the opener is no longer recognized and the line renders as literal text (see below)

Implementation: Block components use the container mechanism (`MD_CONTAINER` with `ch = ':'`). Component info (name/props/title source offsets) is stored in a growing array on `MD_CTX`, indexed by the block's `data` field. That field is 16 bits wide and its layout is frozen, so the array is capped at `types.MAX_BLOCK_INFO_RECORDS` (65 536) records — beyond it the index would wrap onto an earlier record and render the wrong name/props/title. The opener therefore stops matching at the cap, and `::name` falls through line classification like any other text.

HTML renderer: `<component-name title="..." ...attrs>content</component-name>`. JSON renderer: `["component-name", {"title": "...", ...props}, ...children]`. ANSI renderer: title used as display label for alert-style components.

## Component Frontmatter

Block components support YAML frontmatter as an alternative (or addition) to `{props}` syntax. A `---` delimited YAML block as the **first content** inside a component is parsed as component props:

```
::card

---
icon: mdi:microsoft-azure
to: /drivers/azure
title: Azure
color: gray
---

Store data in Azure available storages.
::
```

The same block can be written as a fenced `yaml` block whose info string names `props`, which is the
spelling Comark's documentation leads with. The two forms are equivalent:

````
::card
```yaml [props]
icon: mdi:microsoft-azure
title: Azure
```
Store data in Azure available storages.
::
````

- The opening `---` (or the ` ```yaml [props] ` fence) must be the first non-blank line inside the component
- YAML content between the delimiters is parsed as key-value props
- If `{props}` are also present on the opening line, both are merged and **inline props win**: a key
  present in both appears once, carrying the inline value. A `class` given inline **replaces** any
  YAML `class` rather than merging with it — precedence means replacement, and `.class`
  accumulation is a shorthand rule within a single `{...}` run
- Block props must precede any `#slot` definitions
- A `---` that is not the first content is treated as a normal thematic break (`<hr>`)
- So is a `---` whose body is markdown rather than YAML: the same mapping-line test the
  document fence applies gates this one, so a thematic break written at the top of a
  component no longer swallows the lines below it. An empty or comment-only block stays
  props (and yields no props), matching Comark

HTML renderer: frontmatter is suppressed (not rendered). JSON renderer: YAML is parsed and merged into the component's props object: `["card", {"icon": "mdi:microsoft-azure", "to": "/drivers/azure", ...}, ...]`.

## Component Slots

Inside a block component, `#slot-name` at line start creates a named slot. Content after `#slot-name` until the next `#slot` or `::` closing is the slot body. Content before the first `#slot` stays as direct children (default slot).

```
::card
#header
## Card Title

#content
Main content

#footer
Footer text
::
```

Constraints:

- `#slot-name` must be at the start of a line (after container prefixes)
- Slot name: `[a-zA-Z][a-zA-Z0-9-]*` (same as component names)
- Slots **cannot interrupt paragraphs** (require blank line before)
- Slots are only recognized inside block component containers
- `#slot-name` outside a component is treated as literal text
- At most **65 536 slots per document**, counted independently of components; past that `#slot-name` is treated as literal text too

Implementation: Slots use the container mechanism (`MD_CONTAINER` with `ch = '#'`). Slot info (name offsets) is stored in a growing array on `MD_CTX`, indexed by the block's `data` field, and is capped at `types.MAX_BLOCK_INFO_RECORDS` for the same 16-bit reason as block components. A new `#slot` implicitly closes any existing slot within the current component.

HTML renderer: `<template name="slot-name">...content...</template>`. JSON renderer: `["template", {"name": "slot-name"}, ...children]`. ANSI renderer: transparent (content renders normally).

## Extension: Inline Attributes

Attributes can be added to inline elements using `{...}` syntax immediately after the closing delimiter:

```
**bold**{.highlight}       → <strong class="highlight">bold</strong>
*italic*{#myid}            → <em id="myid">italic</em>
`code`{.lang}              → <code class="lang">code</code>
~~del~~{.red}              → <del class="red">del</del>
==mark=={.hit}             → <mark class="hit">mark</mark>
_italic_{.accent}          → <em class="accent">italic</em>
[Link](url){target="_blank"} → <a href="url" target="_blank">Link</a>
![img](pic.png){.responsive} → <img src="pic.png" alt="img" class="responsive">
```

The `[text]{.class}` syntax (brackets NOT followed by `(url)`) creates a generic `<span>`:

```
[text]{.class}             → <span class="class">text</span>
[**bold** text]{.styled}   → <span class="styled"><strong>bold</strong> text</span>
```

Property syntax is shared with components: `{key="value" bool #id .class}`. Multiple `.class` values are merged into one `class`. Empty `{}` is a no-op.

Attributes are emitted in **source order**, with the merged `class` taking the position of the
first `.class` in the run — `{#status .badge .success data-state="active"}` yields
`id`, `class`, `data-state`. This is observable in JSON key order, so AST consumers can rely on it.

Constraints:

- `{...}` must immediately follow the closing delimiter (no space)
- Only applies to resolved inline elements (not plain text — `hello{.class}` is literal). A `{...}`
  run separated from the element by a space is not an inline attribute; it may instead be consumed
  as a **block attribute** (below).
- A doubled brace never opens an attribute run, inline or block: `{{ expr }}` is
  [interpolation](#extension-interpolation--expr--and-expressions-expr) syntax and is carried
  through verbatim, so `Hello {{ site.name }}` renders `<p>Hello {{ site.name }}</p>`, not
  `<p { site.name>Hello</p>`.
- The content must be a well-formed list — blank-separated `#id`, `.class`, `key`, `:key`, or
  `key="…"` / `key='…'` / `key=value` items, where a key is `[A-Za-z_][A-Za-z0-9_-]*` (Comark's
  key grammar — `data-x` and `aria-label` are keys, `props.title` and `fn()` are not), an id or
  class does not start with another `.` or `#`, and names and unquoted values contain none of
  blank, control, `{`, `}`, `"`, `'`, `=`, `<`, `>`, `/`, `\`.
  Anything else (`{"}`, `{=b}`, `{a=}`, `{.a {b}}`, `{x.y}`, `{f()}`, `{...props}`, an unclosed
  quote) leaves the **whole** run alone — escaped text when it touches an inline element, a
  verbatim expression run after a blank — so a JSX-style `{expr}` survives. An empty `{}` is a
  no-op on inline elements (`[text]{}` is a bare `<span>`) and literal on a block.
- A run of **bare keys only** is a boolean prop on the inline element it touches (`**b**{title}`
  → `<strong title>`) but an expression after a blank (`Hello {title}`, `# H {title}`,
  `- item {title}` all keep the braces, verbatim): the blank marks it as a JSX-style expression
  in running text rather than a prop on the block. One `#id`, `.class`, `:key` or `key=value` item makes the
  whole run a block attribute again (`Hello {title .cls}` → `<p title class="cls">`). Comark
  reads the spaced form as a prop too — see [compatibility.md](compatibility.md).
- Spans: em/strong/code/del/u/mark pass `MD_SPAN_ATTRS_DETAIL*` (or `NULL` without attrs), links/images extend their detail structs with `raw_attrs`/`raw_attrs_size`
- `MD_SPAN_SPAN` is emitted for `[text]{attrs}` with `MD_SPAN_SPAN_DETAIL`

HTML renderer: attributes rendered on opening tags. JSON renderer: attrs merged into node props. ANSI renderer: transparent (ignores attrs).

### Block attributes

A `{...}` run at the end of a block's last line attaches to that **block** rather than to an inline
element. It is consumed before the block's content is processed, so it never reaches the output as
text and never contaminates a heading's generated slug:

```
A paragraph {attr="value"}          → <p attr="value">A paragraph</p>
# Heading {.intro}                  → <h1 id="heading" class="intro">Heading</h1>
- a list item {attr="value"}        → <li attr="value">a list item</li>
- [ ] Task {attr="value"}           → <li class="task-list-item" attr="value">…
```

Blockquotes depend on paragraph count, and the two forms differ in shape as well as in target:

```
> Blockquote {attr="value"}         → <blockquote attr="value">Blockquote</blockquote>

> P1 {attr="value"}                 → <blockquote>
>                                        <p attr="value">P1</p>
> P2 {attr2="value2"}                    <p attr2="value2">P2</p>
                                       </blockquote>
```

A single-paragraph blockquote puts the attributes on the `<blockquote>` and drops the `<p>` wrapper;
a multi-paragraph one attaches each run to its own paragraph and leaves the blockquote bare.

Because a space before the brace makes the run a block attribute, `A paragraph [span] {attr="value"}`
attaches `attr` to the paragraph, while `A paragraph [span]{attr="value"}` (no space) attaches it to
the span.

> **Divergence.** Comark additionally renders the bare `[span]` in the spaced form as an
> attribute-less `<span>`; md4x leaves it as literal text. Implementing it conflicts with CommonMark
> bracket resolution — see `.agents/upstream-sync.md`.

### Wrapper folding

`::ul`, `::ol`, `::table`, `::blockquote` and `::pre` wrapping a **single** same-tagged child fold
into one element carrying the wrapper's attributes. This is how attributes reach elements that have
no trailing-brace slot of their own:

```mdc
::ul{attr="value"}
- item 1
- item 2
::
```

```html
<ul attr="value">
  <li>item 1</li>
  <li>item 2</li>
</ul>
```

Folding requires exactly one child and a matching tag; anything else nests normally.

## Extension: Interpolation (`{{ expr }}`) and Expressions (`{expr}`)

A `{{ expr }}` or `{{{ expr }}}` run is a placeholder for a template engine run over
md4x's output — [rendu](https://github.com/h3js/rendu), Nuxt Content / MDC, Comark's binding
plugin — and a single-brace `{expr}` in running text is a JSX-style expression (Astro, MDX).
md4x passes either through **verbatim**:

- nothing inside is inline syntax — `{{ a*b*c }}`, ``{{ `x` }}``, `{{ $x }}`, `{{ [i] }}` stay as written;
- no entity or backslash escape is resolved, and the HTML renderer does not escape it —
  `{{ a < b && c }}` renders `{{ a < b && c }}`, not `{{ a &lt; b &amp;&amp; c }}`;
- inside a link or image destination it is one token: `[a]({{ url }})` → `<a href="{{ url }}">`,
  with no percent-encoding; same in titles, alt text and `{attrs}` values.

The rule is rendu's: `{{{` ends at the first `}}}` (falling back to a `{{` run ending at the
first `}}` when there is none), the content must be at least one byte, and a run may span lines
within one paragraph. Code spans and code blocks win over it. A trailing run is never an
attribute list (`Hi {{ x }}` is text, not `<p { x>`).

The single-brace form (`test/spec-binding.txt`, second half) differs in three ways:

- It is an expression only where it **cannot be an attribute list**: after a blank, at a line
  start, after ordinary text, after another run. Right after a possible inline-element closer —
  `*`, `_`, `~`, `=`, a backtick, `]` or `)` — the run belongs to the
  [attribute machinery](#extension-inline-attributes), and a malformed one there is ordinary
  escaped text (`**b**{a*b*c}` → `<strong>b</strong>{a<em>b</em>c}`). A trailing block attribute
  run (`Hello {.cls}`) is cut off the line before inlines run, so it is never an expression.
- Its closer is the document's **matched brace pair** — the same pairing inline attributes use,
  linear over the whole document — so nested braces balance (`{fn({a: 1})}`, ``{`t ${x}`}``)
  but quotes and escapes are not understood: `{fn("}")}` ends at the first `}`, `{a \} b}` is
  the whole run, backslash included. `{}` and an unbalanced `{` are plain text.
- It is **not** recognized in link destinations, titles or image alt text; only the doubled
  form is.

The parser reports both as `TextType.binding`; the AST, text, ANSI and markdown renderers
treat them as ordinary text. GitHub escapes the operators instead — a deliberate divergence,
see `.agents/github-parity.md`.

```
Hello {{ user.name }}                → <p>Hello {{ user.name }}</p>
[Profile]({{ user.url }})            → <p><a href="{{ user.url }}">Profile</a></p>
{{{ rawHtml }}}                      → <p>{{{ rawHtml }}}</p>
Hello {user.name}, {a < b && c}      → <p>Hello {user.name}, {a < b && c}</p>
**b**{.cls} but **b** {a*b}          → <p><strong class="cls">b</strong> but <strong>b</strong> {a*b}</p>
```

rendu's other syntaxes — `<? code ?>`, `<?= expr ?>` and `<script server>` — need no
special handling: they are CommonMark raw HTML (a processing instruction and a `<script>`
block) and pass through verbatim already.

## Extension: JSX Component Tags

Raw HTML is CommonMark's, with three extensions to the tag grammar so an Astro / MDX component tag
passes through **verbatim** instead of being escaped as text (`test/spec-jsx.txt`):

```
<Card n={1 + 2} style={{color: "red"}} on={() => go()} />   → unchanged
<Card {...props} />                                          → unchanged
<Card.Item x={1} />                                          → unchanged
```

- **Brace value** — `key={…}` runs to the balanced `}`, skipping braces inside `"…"`, `'…'` and
  `` `…` `` strings (`\` escapes the next byte), where CommonMark's unquoted value would stop at
  the first blank. A value that does not balance, or is not followed by a blank, `>` or `/`, is read
  the CommonMark way, so `<a b={x>` and `<a b={x}}>` are the tags they always were.
- **Spread** — `{...expr}` where an attribute name is expected. Only that shape: `<Card {x} />`
  stays text.
- **Member-expression name** — a `.` inside a tag name that starts with an **uppercase** letter
  (`<Card.Item>`, `<Motion.div>`). `<foo.bar.baz>` is CommonMark spec example 606 and stays text;
  Astro requires a component name to be capitalized anyway.

Everything else is CommonMark: a tag alone on its line is an HTML block (type 7) and a tag in
running text is an inline raw-HTML span; a tag split across lines is an inline span (the block form
needs the whole tag on one line). Children are parsed as markdown only when **blank lines** separate
them from the opening and closing tags — without them the HTML block keeps the children verbatim,
which is what MDX and Astro document too. `{expr}` in running text is its own
[extension](#extension-interpolation--expr--and-expressions-expr): verbatim wherever it cannot be an
attribute list. Not supported: `<>…</>` fragments, `import` / `export` lines, and a multi-line
`{expression}` block at the top level.

GitHub escapes all three shapes; recorded in `.agents/github-parity.md`.

## Code Block Metadata

Fenced code blocks support filename and line highlighting metadata:

````
```javascript [app.js] {1-3,5}
code here
````

```

- **Filename**: `[filename]` — stored as `filename` prop in AST
- **Highlights**: `{3}` single line, `{1-5}` range, `{1,3,5}` multiple, `{1-3,7,10-12}` combined — stored as `highlights` array in AST
- **Escape**: backslash for special chars in filename: `[@[...slug\].ts]`
- All metadata can be combined in any order

## Emojis

`:emoji_name:` syntax (e.g. `:rocket:` → 🚀, `:wave:` → 👋) is a **build-time opt-in**, off by default: the 1913-entry shortcode table costs ~26 KB gzipped on the standalone bundle, so no shipped artifact carries it and a shortcode reaches the output verbatim. Build with `zig build -Demoji=true` (or `bun scripts/js-artifacts.ts build -Demoji=true` for the JS artifacts) to enable it; it then works in text and inside components.

## Excerpts

`<!-- more -->` comment splits content into excerpt and body:

```

# Title

Intro paragraph (excerpt)

<!-- more -->

Full content (body only)

```

Available as `result.excerpt` (content before marker) and `result.body` (full content) from the parse API.
```
