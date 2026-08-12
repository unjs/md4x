# Markdown Syntax Reference

## CommonMark Basics

**Block elements:** paragraphs, headings (`#` or setext), lists (unordered/ordered with nesting), blockquotes, code blocks (fenced or 4-space indent), horizontal rules, raw HTML blocks.

**Inline elements:** emphasis (`*`/`_`), strong (`**`/`__`), links, images, inline code, raw HTML spans, hard breaks (trailing spaces or `\`), soft breaks.

## Extension: Tables (`MD_FLAG_TABLES`)

```
| Column 1 | Column 2 |
|----------|----------|
| foo      | bar      |
```

- Alignment via colons: `:---` left, `:---:` center, `---:` right
- Leading/trailing pipes optional (except single-column)
- Max 128 columns (DoS protection)
- Cell content supports inline markdown

## Extension: Task Lists (`MD_FLAG_TASKLISTS`)

```
- [x] Completed
- [ ] Pending
```

## Extension: Strikethrough (`MD_FLAG_STRIKETHROUGH`)

`~text~` or `~~text~~`. Opener/closer must match length. Follows same flanking rules as emphasis.

## Extension: Permissive Autolinks

- **URL** (`MD_FLAG_PERMISSIVEURLAUTOLINKS`): `https://example.com`
- **Email** (`MD_FLAG_PERMISSIVEEMAILAUTOLINKS`): `john@example.com`
- **WWW** (`MD_FLAG_PERMISSIVEWWWAUTOLINKS`): `www.example.com`

## Extension: LaTeX Math (`MD_FLAG_LATEXMATHSPANS`)

Inline `$...$` and display `$$...$$`. Opener must not be preceded by alphanumeric; closer must not be followed by alphanumeric.

## Extension: Wiki Links (`MD_FLAG_WIKILINKS`)

`[[target]]` — Max 100 character destination.

## Extension: Underline (`MD_FLAG_UNDERLINE`)

`_text_` renders as underline instead of emphasis (disables `_` for emphasis).

## Extension: Frontmatter (`MD_FLAG_FRONTMATTER`)

YAML-style frontmatter delimited by `---` at the very start of the document. The opening `---` must be on the first line (no leading blank lines). Content is exposed as verbatim text via `MD_BLOCK_FRONTMATTER`. The HTML renderer suppresses frontmatter from body output; in full-HTML mode (`MD_HTML_FLAG_FULL_HTML`), YAML `title` and `description` fields are used in `<head>`. If unclosed, the rest of the document is treated as frontmatter content. Special fields: `depth` (max heading level for TOC, default 2), `searchDepth` (TOC search depth, default 2).

**JSON renderer YAML parsing:** The JSON renderer uses [libyaml](https://github.com/yaml/libyaml) to parse frontmatter into the element's props object. Full YAML 1.1 is supported including nested objects, arrays (block and flow), and multi-line values (literal `|` and folded `>`). Plain scalars have type coercion: numbers (int/float), booleans (`true`/`false`/`yes`/`no`/`on`/`off`), null (`null`/`~`/empty). Quoted scalars (`""`/`''`) are always strings. The raw text is preserved as a child string: `["frontmatter", {"title": "Hello", "count": 42}, "title: Hello\ncount: 42\n"]`.

## Extension: Alerts (`MD_FLAG_ALERTS`)

GitHub-style alert/admonition syntax. A blockquote whose first line is `> [!TYPE]` becomes an alert block:

```
> [!NOTE]
> This is a note

> [!WARNING]
> This is a warning
```

- TYPE is any alphanumeric/hyphenated name (`[a-zA-Z][a-zA-Z0-9_-]*`), case-insensitive
- The `[!TYPE]` line must be the **first line** of the blockquote and the **only content** on that line
- Text after `[!TYPE]` on the same line disqualifies it (treated as normal blockquote)
- `[!TYPE]` not on the first line is treated as literal text
- At most **65 536 alerts per document**, counted independently of components and slots (`types.MAX_BLOCK_INFO_RECORDS` — the alert type is stored in a side array whose index rides through the 16-bit `MD_BLOCK.bits.data`); past that the blockquote stays a plain blockquote and `[!TYPE]` renders as literal text
- Supports all GitHub types (NOTE, TIP, IMPORTANT, WARNING, CAUTION) plus custom types
- Content supports full markdown (inline formatting, lists, nested blockquotes, code blocks)

HTML renderer: `<blockquote class="alert alert-{type}">` (type lowercased in class). JSON renderer: `["alert", {"type": "NOTE"}, ...children]`. ANSI renderer: colored thick left bar (`▌`) with type-specific colors (note/info=blue, tip/success=green, important=magenta, warning=yellow, caution/danger=red). Block components `::alert{type="..."}`, `::note`, `::warning`, etc. also render with the same style.

## Extension: Inline Components (`MD_FLAG_COMPONENTS`)

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

## Extension: Block Components (`MD_FLAG_COMPONENTS`)

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
- **Nested**: Use more colons for outer containers: `:::outer\n::inner\n::\n:::`
- **Deep nesting**: `::::` > `:::` > `::` (outer must have more colons than inner)

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

## Component Frontmatter (`MD_FLAG_COMPONENTS`)

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

- The opening `---` must be the first non-blank line inside the component
- YAML content between `---` delimiters is parsed as key-value props
- If `{props}` are also present on the opening line, both are merged (YAML first, then `{props}`)
- A `---` that is not the first content is treated as a normal thematic break (`<hr>`)

HTML renderer: frontmatter is suppressed (not rendered). JSON renderer: YAML is parsed and merged into the component's props object: `["card", {"icon": "mdi:microsoft-azure", "to": "/drivers/azure", ...}, ...]`.

## Component Slots (`MD_FLAG_COMPONENTS`)

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

## Extension: Inline Attributes (`MD_FLAG_ATTRIBUTES`)

Attributes can be added to inline elements using `{...}` syntax immediately after the closing delimiter:

```
**bold**{.highlight}       → <strong class="highlight">bold</strong>
*italic*{#myid}            → <em id="myid">italic</em>
`code`{.lang}              → <code class="lang">code</code>
~~del~~{.red}              → <del class="red">del</del>
_underline_{.accent}       → <u class="accent">underline</u>
[Link](url){target="_blank"} → <a href="url" target="_blank">Link</a>
![img](pic.png){.responsive} → <img src="pic.png" alt="img" class="responsive">
```

The `[text]{.class}` syntax (brackets NOT followed by `(url)`) creates a generic `<span>`:

```
[text]{.class}             → <span class="class">text</span>
[**bold** text]{.styled}   → <span class="styled"><strong>bold</strong> text</span>
```

Property syntax is shared with components: `{key="value" bool #id .class}`. Multiple `.class` values are merged. Empty `{}` is a no-op.

Constraints:

- `{...}` must immediately follow the closing delimiter (no space)
- Only applies to resolved inline elements (not plain text — `hello{.class}` is literal)
- Spans with `MD_FLAG_ATTRIBUTES`: em/strong/code/del/u pass `MD_SPAN_ATTRS_DETAIL*` (or `NULL` without attrs), links/images extend their detail structs with `raw_attrs`/`raw_attrs_size`
- `MD_SPAN_SPAN` is emitted for `[text]{attrs}` with `MD_SPAN_SPAN_DETAIL`

HTML renderer: attributes rendered on opening tags. JSON renderer: attrs merged into node props. ANSI renderer: transparent (ignores attrs).

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

`:emoji_name:` syntax is supported (e.g. `:rocket:` → 🚀, `:wave:` → 👋). Works in text and inside components.

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
