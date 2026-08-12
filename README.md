# 📄 MD4X

[![npm version][npm version]][npm link]
![][wasm size]

Fast and Small markdown parser and renderer based on [mity/md4c](https://github.com/mity/md4c/).

**[Online Playground](https://md4x.unjs.io/#/playground)**

## Features

- **Fast** — Written in C, **~6x** faster than markdown-it
- **CLI** — Render local files, remote URLs, GitHub repos, npm packages
- **Small** — **~100KB** gzip WASM binary works in Node.js and Browser
- **Multi-format output** — HTML, JSON AST, ANSI terminal, plain text, markdown, metadata
- **Streaming heal** — Fix incomplete markdown from LLM output in real-time
- **Full CommonMark** — Passes the CommonMark spec
- **GitHub Flavored Markdown** — Tables, task lists, strikethrough, autolinks, alerts
- **Built-in YAML frontmatter** — Parsed via libyaml into structured data
- **Extra extensions** — LaTeX math, wiki links, underline, inline attributes
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

A single, minified, dependency-free ES module (~126 KB) with the same API as `md4x/wasm` fully embeded into single chunk.

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
clk: ~5.54 GHz
cpu: AMD Ryzen 9 9950X3D 16-Core Processor
runtime: bun 1.3.9 (x64-linux)

benchmark                      avg (min … max) p75 / p99    (min … top 1%)
md4x-napi                         3.32 µs/iter   3.34 µs   3.40 µs ▂▃▅█▅▂█▂▃▂▂
md4x-wasm                         5.76 µs/iter   5.82 µs   9.46 µs █▇▄▂▁▁▁▁▁▁▁
md4w                              5.77 µs/iter   5.77 µs   9.82 µs ▃█▄▂▁▁▁▁▁▁▁
markdown-it                      21.41 µs/iter  20.98 µs  41.88 µs ▁█▃▁▁▁▁▁▁▁▁
markdown-exit                    23.59 µs/iter  23.65 µs  41.84 µs ▁▄█▃▁▁▁▁▁▁▁

summary
  md4x-napi
   1.74x faster than md4x-wasm
   1.74x faster than md4w
   6.45x faster than markdown-it
   7.11x faster than markdown-exit

md4x (napi) ast (medium)          6.91 µs/iter   6.94 µs   6.96 µs ▂▄█▄▄▂▂▄▅▁▂
md4x (wasm) ast (medium)          8.28 µs/iter   8.36 µs   8.40 µs ▆▃█▁▁█▆▃▃▆▃

summary
  md4x (napi) ast (medium)
   1.2x faster than md4x (wasm) ast (medium)

md4x (napi) parseAST (medium)    11.42 µs/iter  11.39 µs  11.77 µs ▅▃█▅▁▁▁▁▁▁▅
md4x (wasm) parseAST (medium)    12.64 µs/iter  12.71 µs  12.74 µs ▃▁▃▁▁▁▁▁██▃
md4w parseAST (medium)           11.79 µs/iter  11.94 µs  11.99 µs █▅▅▅▁▁▁▁██▅
markdown-it parseAST (medium)    15.96 µs/iter  16.01 µs  16.19 µs ▅▅▅█▅▅▁▁█▅▅
markdown-exit parseAST (medium)  18.42 µs/iter  18.62 µs  19.26 µs ▂▂▁█▂▁▂▁▂▁▂

summary
  md4x (napi) parseAST (medium)
   1.03x faster than md4w parseAST (medium)
   1.11x faster than md4x (wasm) parseAST (medium)
   1.4x faster than markdown-it parseAST (medium)
   1.61x faster than markdown-exit parseAST (medium)
```

Note: markdown-it parser returns an array of tokens while md4x returns nested comark AST.

</details>

### Code Highlighting

`renderToHtml` supports a `highlighter` option for custom syntax highlighting of fenced code blocks. The highlighter receives the raw code (HTML-unescaped) and block metadata (language, filename, highlighted lines), and returns a replacement HTML string or `undefined` to keep the default.

````js
import { renderToHtml } from "md4x";
import { createHighlighter } from "shiki";

const highlighter = await createHighlighter({
  themes: ["github-dark"],
  langs: ["js", "ts", "html", "css"],
});

const html = renderToHtml("```js\nconst x = 1;\n```", {
  highlighter: (code, block) => {
    if (!block.lang) return; // keep default for unknown languages
    return highlighter.codeToHtml(code, {
      lang: block.lang,
      theme: "github-dark",
    });
  },
});
````

Code block metadata from the info string is parsed automatically:

````md
```ts [app.ts] {1,3-5}
// block.lang = "ts"
// block.filename = "app.ts"
// block.highlights = [1, 3, 4, 5]
```
````

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

benchmark                      avg (min … max) p75 / p99    (min … top 1%)
md4x-napi heal (small)          702.85 ns/iter
md4x-wasm heal (small)            1.57 µs/iter
remend heal (small)                3.71 µs/iter

summary
  md4x-napi heal (small)
   2.23x faster than md4x-wasm heal (small)
   5.28x faster than remend heal (small)

md4x-napi heal (medium)          2.13 µs/iter
md4x-wasm heal (medium)          3.23 µs/iter
remend heal (medium)             24.59 µs/iter

summary
  md4x-napi heal (medium)
   1.52x faster than md4x-wasm heal (medium)
   11.55x faster than remend heal (medium)

md4x-napi heal (large)          95.09 µs/iter
md4x-wasm heal (large)         137.68 µs/iter
remend heal (large)             10.95 ms/iter

summary
  md4x-napi heal (large)
   1.45x faster than md4x-wasm heal (large)
   115.18x faster than remend heal (large)
```

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
