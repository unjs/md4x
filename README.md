# 📄 MD4X

[![npm version][npm version]][npm link]
![][wasm size]

Fast and Small markdown parser and renderer based on [mity/md4c](https://github.com/mity/md4c/).

**[Online Playground](https://md4x.unjs.io/#/playground)**

## Features

- **Fast** — **~8x** faster than markdown-it
- **CLI** — Render local files, remote URLs, GitHub repos, npm packages
- **Small** — **~100KB** gzip WASM binary works in Node.js and Browser
- **Multi-format output** — HTML, JSON AST, ANSI terminal, plain text, markdown, metadata
- **Streaming heal** — Fix incomplete markdown from LLM output in real-time
- **Full CommonMark** — Passes the CommonMark spec
- **GitHub Flavored Markdown** — Tables, task lists, strikethrough, autolinks, alerts
- **Built-in YAML parser** — Frontmatter and standalone YAML, no external dependency
- **Extra extensions** — LaTeX math, wiki links, underline, highlight, footnotes, inline attributes
- **Comark (MDC) support** — Block and inline components with props, slots
- **Universal JS** — Native Node.js addon (NAPI) + portable WASM for browsers, Deno, Bun, edge workers
- **C library** — SAX-like streaming parser, zero-copy, no AST allocation overhead
- **Zig package** — Consumable as a Zig dependency

## Showcase

- [pi0/mdshot](https://github.com/pi0/mdshot) — Render beautiful screenshots from Markdown.
- [pi0/mdzilla](https://github.com/pi0/mdzilla) — Markdown browser for humans and agents.

## CLI

```sh
# Local files
npx md4x README.md                          # ANSI output
npx md4x README.md -t html                  # HTML output
npx md4x README.md -t text                  # Plain text output (strip markdown)
npx md4x README.md -t ast                   # JSON AST output (comark)
npx md4x README.md -t meta                  # Metadata JSON output
npx md4x README.md -t markdown              # Clean markdown (strip MDC/frontmatter/HTML)
npx md4x README.md -t heal                  # Heal incomplete markdown
npx md4x README.md --heal                   # Heal before rendering (any format)
npx md4x README.md --heal -t json           # Heal + JSON AST output

# Remote sources
npx md4x https://nitro.build/guide          # Fetch and render any URL
npx md4x gh:nitrojs/nitro                   # GitHub repo → README.md
npx md4x npm:vue@3                          # npm package at specific version

# Stdin
echo "# Hello" | npx md4x -t text
cat README.md | npx md4x  -t html

# Output to file
npx md4x README.md -t meta -o README.json

# Full HTML document
npx md4x README.md -t html -f --html-title="My Docs"  # Wrap in full HTML with <head>
npx md4x README.md -t html -f --html-css=style.css    # Add CSS link
```

### Install from AUR

```sh
yay -S md4x # md4x-git
```

## JavaScript

Available as a native Node.js addon (NAPI) for maximum performance, or as a portable WASM module that works in any JavaScript runtime (Node.js, Deno, Bun, browsers, edge workers, etc.).

The bare `md4x` import auto-selects NAPI on Node.js and WASM elsewhere.

```js
import {
  init,
  renderToHtml,
  renderToAST,
  parseAST,
  renderToAnsi,
  renderToText,
  renderToMarkdown,
  renderToMeta,
  parseMeta,
  parseYAML,
  heal,
} from "md4x";

// await init(); // required for WASM, optional for NAPI

const html = renderToHtml("# Hello, **world**!");
const json = renderToAST("# Hello, **world**!"); // raw JSON string
const ast = parseAST("# Hello, **world**!"); // parsed ComarkTree object
const ansi = renderToAnsi("# Hello, **world**!");
const text = renderToText("# Hello, **world**!"); // plain text (stripped)
const md = renderToMarkdown("# Hello, **world**!"); // clean standard markdown
const metaJson = renderToMeta("# Hello, **world**!"); // raw JSON string
const meta = parseMeta("# Hello, **world**!"); // parsed meta
const yaml = parseYAML("title: Hello"); // standalone YAML -> JS value

const healed = heal("**incomplete streaming mark"); // "**incomplete streaming mark**"
```

Both NAPI and WASM export a unified API with `init()`. For WASM, `init()` must be called before rendering. For NAPI, it is optional (the native binding loads lazily on first render call).

#### NAPI (Node.js native)

Synchronous, zero-overhead native addon. Best performance for server-side use.

```js
import { renderToHtml } from "md4x/napi";
```

#### WASM (universal)

Works anywhere with WebAssembly support. Requires a one-time async initialization.

```js
import { init, renderToHtml } from "md4x/wasm";

await init(); // call once before rendering
const html = renderToHtml("# Hello");
```

`init()` accepts an optional options object with a `wasm` property (`ArrayBuffer`, `Response`, `WebAssembly.Module`, or `Promise<Response>`). When called with no arguments, it loads the bundled `.wasm` file automatically.

#### Standalone (inlined WASM)

A single, minified, dependency-free ES module (~137 KiB) with the same API as `md4x/wasm` fully embeded into single chunk.

```js
import { init, renderToHtml } from "md4x/standalone";

await init(); // inflates and instantiates the inlined binary
const html = renderToHtml("# Hello");
```

This is also what `md4x` and `md4x/wasm` resolve to under the **`browser`** export condition, so browser bundlers get the self-contained module automatically (the explicit `unwasm` condition still wins where it is set).

<details>
<summary>Benchmarks</summary>

(source: [packages/md4x/bench](./packages/md4x/bench))

```
bun packages/md4x/bench/index.mjs
cpu: Intel(R) Core(TM) i7-10700K CPU @ 3.80GHz
runtime: bun 1.3.14 (x64-linux)

benchmark                        avg (min … max) p75 / p99    (min … top 1%)
md4x.napi (renderToHtml)            6.84 µs/iter   6.89 µs   7.01 µs ▂█▂▄▄▂▅▄▂▂▄
md4x.wasm (renderToHtml)           14.75 µs/iter  15.20 µs  29.38 µs █▆▄▂▂▁▁▁▁▁▁
md4w (renderToHtml)                17.07 µs/iter  17.65 µs  39.78 µs ██▄▂▁▁▁▁▁▁▁
markdown-it (renderToHtml)         54.38 µs/iter  53.77 µs 122.02 µs ▅█▂▂▂▂▁▁▁▁▁
markdown-exit (renderToHtml)       53.24 µs/iter  52.64 µs 105.82 µs ▃█▂▂▁▁▁▁▁▁▁
satteri (renderToHtml)             25.59 µs/iter  26.40 µs  43.70 µs ▄█▆▃▂▁▁▁▁▁▁
ox-content (renderToHtml)          10.87 µs/iter  10.98 µs  11.09 µs ▃▃▁▁▅▁▅▁█▁▃

summary
  md4x.napi (renderToHtml)
   1.59x faster than ox-content (renderToHtml)
   2.16x faster than md4x.wasm (renderToHtml)
   2.5x faster than md4w (renderToHtml)
   3.74x faster than satteri (renderToHtml)
   7.79x faster than markdown-exit (renderToHtml)
   7.95x faster than markdown-it (renderToHtml)

md4x.napi (parseAST) (medium)      22.56 µs/iter  23.77 µs  24.89 µs ▃█▆▁▃▃▁▃▁▃▃
md4x.wasm (parseAST) (medium)      36.44 µs/iter  37.98 µs  58.69 µs ▅▇█▄▃▂▂▁▁▁▁
md4w (parseAST) (medium)           29.40 µs/iter  30.76 µs  50.24 µs ▇█▇▄▂▂▁▁▁▁▁
markdown-it (parseAST) (medium)    40.33 µs/iter  41.40 µs  73.95 µs ▃█▄▂▂▂▁▁▁▁▁
markdown-exit (parseAST) (medium)  36.96 µs/iter  36.70 µs  38.13 µs ▃▁▁▆▃█▃▆▁▁▃
satteri (parseAST) (medium)        21.56 µs/iter  21.86 µs  40.67 µs ▃█▃▂▂▁▁▁▁▁▁
ox-content (parseAST) (medium)     22.75 µs/iter  23.12 µs  25.86 µs █▅▁▁▂▁▁▂▁▁▂

summary
  satteri (parseAST) (medium)
   1.05x faster than md4x.napi (parseAST) (medium)
   1.06x faster than ox-content (parseAST) (medium)
   1.36x faster than md4w (parseAST) (medium)
   1.69x faster than md4x.wasm (parseAST) (medium)
   1.71x faster than markdown-exit (parseAST) (medium)
   1.87x faster than markdown-it (parseAST) (medium)
```

Notes:

- The `parseAST` trio at the top (satteri, md4x.napi, ox-content) sits within ~6% of each other, which is inside run-to-run noise on this machine — repeat runs reorder them. Treat them as tied; the clear gaps are further down the list.
- The parsers do not all return the same thing: markdown-it yields a flat array of tokens where md4x returns a nested comark AST, satteri's mdast carries full `position` data on every node, and ox-content hands back the tree as a JSON string (the bench `JSON.parse`s it so every entry ends at a materialized tree).
- ox-content ships with GFM off, so the bench passes `{ gfm: true }` to put it on the same fixture as the rest.

</details>

<details>
<summary>Bundle size</summary>

(source: [packages/md4x/bench/bundle.mjs](./packages/md4x/bench/bundle.mjs))

Each library is bundled with rolldown from a markdown-to-HTML entry — minified, tree-shaken, browser platform — and every file a real deployment has to serve is counted, WASM payloads included. md4x parses YAML front matter in the binary, so libraries that do not get the cheapest JS YAML parser added to their entry, broken out in `yaml`.

```
bun packages/md4x/bench/bundle.mjs

target                    js      yaml       wasm      total       gzip     brotli  vs best
-----------------  ---------  --------  ---------  ---------  ---------  ---------  -------
md4w                 2.4 KiB  40.6 KiB   59.0 KiB  102.0 KiB   39.4 KiB   35.3 KiB        —
markdown-it        100.1 KiB  40.8 KiB          —  140.9 KiB   54.7 KiB   46.0 KiB    1.39x
markdown-exit      106.4 KiB  40.8 KiB          —  147.1 KiB   56.0 KiB   50.2 KiB    1.42x
md4x/wasm (small)    2.9 KiB         —  277.3 KiB  280.2 KiB  107.3 KiB   90.7 KiB    2.72x
md4x/standalone    135.7 KiB         —          —  135.7 KiB  110.3 KiB  108.8 KiB    2.80x
md4x/wasm            2.9 KiB         —  392.6 KiB  395.4 KiB  131.3 KiB  106.4 KiB    3.33x
md4w (fast)          2.4 KiB  40.6 KiB  862.3 KiB  905.4 KiB  280.3 KiB  227.3 KiB    7.11x
```

Notes:

- `total` is `js + yaml + wasm`; `gzip`/`brotli` compress each file separately, the way a CDN serves them. Ranked by gzip — what a first visit actually downloads.
- The `yaml` column is the measured difference between bundling the library alone and bundling it with a YAML parser, so it credits any code the two already share. The bench picks the cheapest candidate by gzip — js-yaml (11.7 KiB gzip), ahead of confbox/yaml (12.8 KiB) and yaml (29.1 KiB). It is a floor: the front-matter block-splitting plugin those libraries also need is not counted.
- `md4x/standalone` has no `wasm` column because its binary is embedded in the bundle (gzip + Z85). That payload is already compressed, so its gzip and brotli numbers barely move: the trade is one request and zero asset wiring against ~3 KiB more over the wire than `md4x/wasm (small)`.
- md4x is still bigger than md4w, largely because it carries more: MDC/comark components and the AST/text/ANSI/markdown/meta renderers all live in the same binary.
- satteri and `@ox-content/napi` are NAPI-only — they have no browser bundle to measure.

</details>

### Code Highlighting

`renderToHtml` and `renderToAnsi` support a `highlighter` option for custom syntax highlighting of fenced code blocks. It receives the raw code (HTML-unescaped) and the block's metadata (language, filename, highlighted lines), and returns a replacement string or `undefined` to keep the default rendering.

````js
import { renderToHtml } from "md4x";
import { codeToHtml } from "rangi";
import { githubDark } from "rangi/themes";

const html = renderToHtml("```js\nconst x = 1;\n```", {
  highlighter: (code, block) => {
    if (!block.lang) return; // keep default for fences with no language
    return codeToHtml(code, { lang: block.lang, theme: githubDark });
  },
});
````

Any synchronous highlighter works. These examples use [rangi](https://github.com/pi0/rangi) (a separate install: `npm i rangi`) because it needs no async setup and inlines its theme colors, so the markup is self-contained.

Code block metadata from the info string is parsed automatically:

````md
```ts [app.ts] {1,3-5}
// block.lang = "ts"
// block.filename = "app.ts"
// block.highlights = [1, 3, 4, 5]
```
````

### Terminal Output (TUI)

`renderToAnsi` renders a document straight to ANSI escape sequences — headings, emphasis, tables, lists, blockquotes, alerts and OSC 8 clickable links — ready to `console.log` in a CLI or TUI.

```js
import { renderToAnsi } from "md4x";
import { codeToAnsi } from "rangi";

console.log(
  renderToAnsi(doc, {
    highlighter: (code, block) =>
      block.lang ? codeToAnsi(code, { lang: block.lang }) : undefined,
  }),
);
```

The highlighter is the same hook as for HTML, returning terminal escapes instead of markup. Code arrives with the block's indentation stripped, and md4x re-applies it to every line that comes back — so a block nested in a blockquote or list keeps its bars and indent without the highlighter knowing anything about the surrounding document. Control bytes in the source are neutralized before the code is handed over, so a fenced block cannot smuggle escape sequences into the terminal.

Options: `showUrls` prints link targets after the text (for terminals without OSC 8 support), `showFrontmatter` renders frontmatter as dim text instead of hiding it, and `heal: true` closes unterminated markup — the combination that makes streaming LLM output render cleanly frame by frame.

```js
renderToAnsi(chunk, { heal: true, showUrls: true });
```

The CLI is this renderer with a file argument: `npx md4x README.md` previews any document in the terminal, since it defaults to `ansi` when stdout is a TTY (and `text` when piped — pass `--format=ansi` to force escapes into a pipe).

### Markdown Healing

`heal()` fixes incomplete markdown from streaming LLM output — closing unclosed bold, italic, strikethrough, inline code, code blocks, links, and more. Useful for rendering partial markdown in real-time as tokens arrive (inspired by [streamdown/remend](https://github.com/vercel/streamdown/tree/main/packages/remend)).

````js
import { heal } from "md4x";

heal("**bold"); // "**bold**"
heal("*ita"); // "*ita*"
heal("~~strike"); // "~~strike~~"
heal("`code"); // "`code`"
heal("```js\ncode"); // "```js\ncode\n```"
heal("[text](http:"); // ""  (strips broken links)
````

All render functions also accept a `{ heal: true }` option to heal input before rendering in a single pass:

```js
import { renderToHtml, parseAST, renderToAnsi, renderToText } from "md4x";

// Heal + render in one call — ideal for streaming LLM output
renderToHtml("# Hello **world", { heal: true });
// "<h1>Hello <strong>world</strong></h1>\n"

parseAST("# Hello **world", { heal: true });
// { nodes: [["h1", {}, "Hello ", ["strong", {}, "world"]]], ... }

renderToAnsi("# Hello **world", { heal: true });
renderToText("# Hello **world", { heal: true });

// Combines with other options
renderToHtml("# Hello **world", { heal: true, full: true });
```

<details>
<summary>Benchmarks</summary>

```
bun packages/md4x/bench/heal.mjs
cpu: Intel(R) Core(TM) i7-10700K CPU @ 3.80GHz
runtime: bun 1.3.14 (x64-linux)

benchmark                   avg (min … max) p75 / p99    (min … top 1%)
md4x-napi heal (small)         1.28 µs/iter   1.32 µs   1.81 µs ▃█▂▂▁▂▁▁▁▂▁
md4x-wasm heal (small)         3.34 µs/iter   3.08 µs   9.29 µs █▃▁▂▁▁▁▁▁▁▁
remend heal (small)            9.09 µs/iter   9.77 µs  22.17 µs ██▅▃▂▂▁▁▁▁▁

summary
  md4x-napi heal (small)
   2.61x faster than md4x-wasm heal (small)
   7.12x faster than remend heal (small)

md4x-napi heal (medium)        3.21 µs/iter   3.24 µs   3.39 µs ▄█▆▄▃▂▂▂▄▂▂
md4x-wasm heal (medium)        4.40 µs/iter   4.45 µs   4.93 µs █▅█▅▅▃▁▂▁▁▂
remend heal (medium)          53.67 µs/iter  57.84 µs  78.92 µs █▅▂▃▃▂▁▁▁▁▁

summary
  md4x-napi heal (medium)
   1.37x faster than md4x-wasm heal (medium)
   16.71x faster than remend heal (medium)

md4x-napi heal (large)       147.94 µs/iter 148.21 µs 229.58 µs ▅█▃▁▁▁▁▁▁▁▁
md4x-wasm heal (large)       175.43 µs/iter 177.00 µs 292.66 µs ▄█▂▁▁▁▁▁▁▁▁
remend heal (large)           18.63 ms/iter  18.79 ms  19.46 ms ▅▂▅█▂▄▂▂▁▁▂

summary
  md4x-napi heal (large)
   1.19x faster than md4x-wasm heal (large)
   125.91x faster than remend heal (large)
```

</details>

### YAML

MD4X ships its own YAML parser — a Zig port of [libyaml](https://github.com/yaml/libyaml), with no C dependency in the shipped artifacts. It backs frontmatter parsing, and is exposed directly for standalone YAML documents. Any root node is accepted (mapping, sequence, or bare scalar); an empty document yields `null`.

```js
import { parseYAML, yamlToJson } from "md4x";

parseYAML("title: Hello\ncount: 42\ndraft: true");
// { title: "Hello", count: 42, draft: true }

yamlToJson("title: Hello"); // '{"title":"Hello"}'  (raw JSON string)
```

`yamlToJson` is `parseYAML` without the `JSON.parse` — use it when the value is headed straight back out as JSON.

<details>
<summary>Benchmarks</summary>

```
bun packages/md4x/bench/yaml.mjs
cpu: Intel(R) Core(TM) i7-10700K CPU @ 3.80GHz
runtime: bun 1.3.14 (x64-linux)

benchmark                      avg (min … max) p75 / p99    (min … top 1%)
md4x.napi (parseYAML) (medium)   22.34 µs/iter  22.32 µs  22.35 µs ▆▁▆▁▁▁▃▆▃▁█
md4x.wasm (parseYAML) (medium)   41.11 µs/iter  49.34 µs  80.21 µs ▄█▃▂▂▂▂▂▁▁▁
js-yaml (parseYAML) (medium)     50.69 µs/iter  53.59 µs  98.25 µs ▅█▅▃▂▂▂▂▁▁▁
yaml (parseYAML) (medium)       377.44 µs/iter 392.99 µs 728.75 µs ▃█▃▂▁▁▂▂▂▁▁
confbox (parseYAML) (medium)     40.27 µs/iter  43.47 µs  44.08 µs ▅▅█▅▅▅▅▁▁▅█

summary
  md4x.napi (parseYAML) (medium)
   1.8x faster than confbox (parseYAML) (medium)
   1.84x faster than md4x.wasm (parseYAML) (medium)
   2.27x faster than js-yaml (parseYAML) (medium)
   16.89x faster than yaml (parseYAML) (medium)

md4x.napi (yamlToJson) (medium)  17.78 µs/iter  17.83 µs  19.29 µs ▂▂▂▂█▂▁▁▁▁▂
md4x.wasm (yamlToJson) (medium)  28.63 µs/iter  29.35 µs  29.61 µs ▃▁▁▁▆▁▁█▆▆▃
js-yaml (yamlToJson) (medium)    44.24 µs/iter  43.28 µs  47.30 µs ▂▂█▂▁▁▁▁▁▁▂
yaml (yamlToJson) (medium)      321.22 µs/iter 310.31 µs 644.56 µs ▅█▂▁▁▁▁▁▁▁▁

summary
  md4x.napi (yamlToJson) (medium)
   1.61x faster than md4x.wasm (yamlToJson) (medium)
   2.49x faster than js-yaml (yamlToJson) (medium)
   18.07x faster than yaml (yamlToJson) (medium)
```

Notes:

- The bench asserts every parser returns the same value as js-yaml on each fixture before timing anything, so the numbers are for identical work.
- The `parseYAML` group ends at a materialized JS value for every entry. The `yamlToJson` group compares md4x's native JSON-string output against the JS libs' parse-then-`JSON.stringify`; confbox has no string-output path, so it only appears in the first group.
- `confbox` bundles js-yaml 4, which is why it tracks js-yaml closely.
- `yaml` builds a full CST and `Document` on every parse, which accounts for its much larger gap.

</details>

## Zig Package

MD4X can be consumed as a Zig package dependency via `build.zig.zon`.

## Building

Requires [Zig](https://ziglang.org/). No other external dependencies.

```sh
zig build                      # ReleaseFast (default)
zig build -Doptimize=Debug     # Debug build
zig build wasm                 # WASM target (~163K)
zig build napi                 # Node.js NAPI addon
```

## C Library

SAX-like streaming parser with no AST construction. Link against `libmd4x` and the renderer you need.

#### HTML Renderer

```c
#include "md4x.h"
#include "md4x-html.h"

void output(const MD_CHAR* text, MD_SIZE size, void* userdata) {
    fwrite(text, 1, size, (FILE*) userdata);
}

md_html(input, input_size, output, stdout, MD_DIALECT_GITHUB, 0);
```

#### JSON Renderer

```c
#include "md4x.h"
#include "md4x-ast.h"

md_ast(input, input_size, output, stdout, MD_DIALECT_GITHUB, 0);
```

#### ANSI Renderer

```c
#include "md4x.h"
#include "md4x-ansi.h"

md_ansi(input, input_size, output, stdout, MD_DIALECT_GITHUB, 0);
```

#### Text Renderer

Strips markdown formatting and produces plain text:

```c
#include "md4x.h"
#include "md4x-text.h"

md_text(input, input_size, output, stdout, MD_DIALECT_GITHUB, 0);
```

#### Markdown Renderer

Converts extended markdown (MDC/Comark) to clean, standard markdown. Strips frontmatter, HTML comments, raw HTML, and inline attributes. Converts block/inline components to HTML tags, wiki links to regular links.

```c
#include "md4x.h"
#include "md4x-markdown.h"

md_markdown(input, input_size, output, stdout, MD_DIALECT_ALL, 0);
```

#### Meta Renderer

Extracts frontmatter and headings as a flat JSON object:

```c
#include "md4x.h"
#include "md4x-meta.h"

md_meta(input, input_size, output, stdout, MD_DIALECT_GITHUB, 0);
// {"title":"Hello","headings":[{"level":1,"text":"Hello"}]}
```

#### Heal Utility

Fixes incomplete/streaming markdown by closing unclosed delimiters:

```c
#include "md4x-heal.h"

md_heal(input, input_size, output, stdout);
```

#### Low-Level Parser

For custom rendering, use the SAX-like parser directly:

```c
#include "md4x.h"

int enter_block(MD_BLOCKTYPE type, void* detail, void* userdata) { return 0; }
int leave_block(MD_BLOCKTYPE type, void* detail, void* userdata) { return 0; }
int enter_span(MD_SPANTYPE type, void* detail, void* userdata) { return 0; }
int leave_span(MD_SPANTYPE type, void* detail, void* userdata) { return 0; }
int text(MD_TEXTTYPE type, const MD_CHAR* text, MD_SIZE size, void* userdata) { return 0; }

MD_PARSER parser = {
    .abi_version = 0,
    .flags = MD_DIALECT_GITHUB,
    .enter_block = enter_block,
    .leave_block = leave_block,
    .enter_span = enter_span,
    .leave_span = leave_span,
    .text = text,
};

md_parse(input, input_size, &parser, NULL);
```

## License

[MIT](./LICENSE.md)

[npm version]: https://badgen.net/npm/v/md4x?color=F0DB4F
[npm link]: https://npmx.dev/package/md4x
[wasm size]: https://badgen.net/https/md4x.unjs.io/_badges/wasm-size.json?1
