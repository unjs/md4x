# 📄 MD4X

[![npm version][npm version]][npm link]
![][wasm size]

Fast and Small markdown parser and renderer based on [mity/md4c](https://github.com/mity/md4c/).

**[Online Playground](https://md4x.unjs.io/#/playground)**

## Features

- **Fast** — **~8x** faster than markdown-it
- **CLI** — Render local files, remote URLs, GitHub repos, npm packages
- **Small** — **~135KB** gzip WASM binary works in Node.js and Browser
- **Multi-format output** — HTML, JSON AST, ANSI terminal, plain text, markdown, metadata
- **Streaming heal** — Fix incomplete markdown from LLM output in real-time
- **Full CommonMark** — Passes the CommonMark spec
- **GitHub Flavored Markdown** — Tables, task lists, strikethrough, autolinks, alerts
- **Built-in YAML parser** — Frontmatter and standalone YAML, no external dependency
- **Extra extensions** — LaTeX math, highlight (`==mark==`), footnotes, inline attributes
- **Comark (MDC) support** — Block and inline components with props, slots
- **Universal JS** — Native Node.js addon (NAPI) + portable WASM for browsers, Deno, Bun, edge workers
- **Zig library** — SAX-like streaming parser, zero-copy, no AST allocation overhead

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
npx md4x README.md --heal -t ast            # Heal + JSON AST output

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

The examples above are the npm CLI (`npx md4x`). The native binary — the one `zig build`
produces and `md4x(1)` documents — is a smaller tool: it reads a local file or stdin, with
no URL, `gh:` or `npm:` shorthands, and its formats are `html` (the default), `text`,
`json`, `ansi`, `markdown` and `heal`, where the npm CLI spells the AST format `ast` and
adds `meta`.

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

A single, minified, dependency-free ES module (~140 KB) with the same API as `md4x/wasm`, the WASM binary embedded into the same chunk.

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
runtime: bun 1.4.2 (x64-linux)

benchmark                        avg (min … max) p75 / p99    (min … top 1%)
md4x.napi (renderToHtml)            7.38 µs/iter   7.43 µs   7.47 µs ▆█▆▁▆▃▆▃▃▆▆
md4x.wasm (renderToHtml)           15.08 µs/iter  15.41 µs  30.75 µs █▅▃▂▁▁▁▁▁▁▁
md4w (renderToHtml)                17.40 µs/iter  17.71 µs  37.11 µs ▄█▅▂▁▁▁▁▁▁▁
markdown-it (renderToHtml)         72.68 µs/iter  73.10 µs 191.23 µs █▇▃▂▂▁▁▁▁▁▁
markdown-exit (renderToHtml)       53.66 µs/iter  55.23 µs 106.47 µs ▁█▃▂▂▂▁▁▁▁▁
satteri (renderToHtml)             14.84 µs/iter  15.52 µs  27.61 µs █▇▅▂▂▁▁▁▁▁▁
ox-content (renderToHtml)          12.72 µs/iter  13.52 µs  22.70 µs ██▅▃▂▁▁▁▁▁▁
qip.wasm (renderToHtml)            20.17 µs/iter  20.45 µs  34.41 µs █▅▃▁▁▁▁▁▁▁▁

summary
  md4x.napi (renderToHtml)
   1.72x faster than ox-content (renderToHtml)
   2.01x faster than satteri (renderToHtml)
   2.05x faster than md4x.wasm (renderToHtml)
   2.36x faster than md4w (renderToHtml)
   2.73x faster than qip.wasm (renderToHtml)
   7.28x faster than markdown-exit (renderToHtml)
   9.85x faster than markdown-it (renderToHtml)

md4x.napi (parseAST) (medium)      21.16 µs/iter  21.80 µs  34.83 µs ▆█▇▂▂▁▁▁▁▁▁
md4x.wasm (parseAST) (medium)      28.12 µs/iter  28.56 µs  45.51 µs ▄█▅▂▂▂▁▁▁▁▁
md4w (parseAST) (medium)           23.07 µs/iter  23.53 µs  24.73 µs ██▃▁▃▃▃▁▁▁▃
markdown-it (parseAST) (medium)    50.44 µs/iter  51.52 µs  53.98 µs ▃▃█▃▃▁▃▃▁▁▃
markdown-exit (parseAST) (medium)  30.15 µs/iter  30.70 µs  31.38 µs ▃▃▁▁▆█▁▃▃▃▃
satteri (parseAST) (medium)        32.27 µs/iter  32.38 µs  67.77 µs ▂█▃▂▁▁▁▁▁▁▁
ox-content (parseAST) (medium)     17.54 µs/iter  18.19 µs  18.72 µs ▃▃█▆▁▁▃▁▃▁▆

summary
  ox-content (parseAST) (medium)
   1.21x faster than md4x.napi (parseAST) (medium)
   1.32x faster than md4w (parseAST) (medium)
   1.6x faster than md4x.wasm (parseAST) (medium)
   1.72x faster than markdown-exit (parseAST) (medium)
   1.84x faster than satteri (parseAST) (medium)
   2.88x faster than markdown-it (parseAST) (medium)
```

Notes:

- The `parseAST` group at the top (ox-content, md4x.napi, md4w) sits within ~20% of each other, which is close to run-to-run noise on this machine — repeat runs reorder them. Treat them as roughly tied; the clear gaps are further down the list.
- The parsers do not all return the same thing: markdown-it yields a flat array of tokens where md4x returns a nested comark AST, satteri's mdast carries full `position` data on every node, and ox-content hands back the tree as a JSON string (the bench `JSON.parse`s it so every entry ends at a materialized tree).
- ox-content ships with GFM off, so the bench passes `{ gfm: true }` to put it on the same fixture as the rest.
- [qip](https://qip.dev/markdown-to-html) is the `gfm-commonmark.0.31.2` WASM component, not an npm package — the bench fetches it once into `bench/.cache/` (gitignored) and skips the entry if the download fails. It renders through fixed 2 MiB in/out buffers with no imports, and exposes HTML only, so it does not appear in the `parseAST` group.

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
runtime: bun 1.4.2 (x64-linux)

benchmark                   avg (min … max) p75 / p99    (min … top 1%)
md4x-napi heal (small)         1.23 µs/iter   1.22 µs   1.79 µs ▇█▂▁▁▁▁▁▁▁▁
md4x-wasm heal (small)         1.80 µs/iter   1.80 µs   2.16 µs ▆█▃▂▁▁▁▁▁▁▁
remend heal (small)            3.16 µs/iter   3.17 µs   9.27 µs █▄▂▁▁▁▁▁▁▁▁

summary
  md4x-napi heal (small)
   1.47x faster than md4x-wasm heal (small)
   2.57x faster than remend heal (small)

md4x-napi heal (medium)        3.14 µs/iter   3.16 µs   3.44 µs ▃▂▅█▃▁▁▁▁▁▁
md4x-wasm heal (medium)        4.17 µs/iter   4.26 µs   4.38 µs ▅▅▂▁▂▃█▆▅▃▃
remend heal (medium)          19.24 µs/iter  18.97 µs  32.81 µs █▇▂▂▁▁▂▁▁▁▁

summary
  md4x-napi heal (medium)
   1.33x faster than md4x-wasm heal (medium)
   6.12x faster than remend heal (medium)

md4x-napi heal (large)       148.63 µs/iter 147.74 µs 230.79 µs ▂█▂▁▁▁▁▁▁▁▁
md4x-wasm heal (large)       184.50 µs/iter 186.32 µs 259.67 µs ▅▆█▂▁▁▁▁▁▁▁
remend heal (large)          603.85 µs/iter 604.93 µs 762.44 µs ▃█▃▂▁▁▁▁▁▁▁

summary
  md4x-napi heal (large)
   1.24x faster than md4x-wasm heal (large)
   4.06x faster than remend heal (large)
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
runtime: bun 1.4.2 (x64-linux)

benchmark                      avg (min … max) p75 / p99    (min … top 1%)
md4x.napi (parseYAML) (medium)   21.87 µs/iter  21.80 µs  22.98 µs ▅▃▃▃▃█▁▁▁▁▃
md4x.wasm (parseYAML) (medium)   31.16 µs/iter  33.67 µs  34.15 µs ▅█▅▁█▅▅▁▁█▅
js-yaml (parseYAML) (medium)     46.59 µs/iter  46.55 µs  83.79 µs ▃█▄▂▁▁▁▁▁▁▁
yaml (parseYAML) (medium)       292.90 µs/iter 301.71 µs 527.77 µs ▂█▄▂▂▁▁▁▁▁▁
confbox (parseYAML) (medium)     44.69 µs/iter  45.34 µs  76.02 µs ▃█▅▂▁▁▁▁▁▁▁

summary
  md4x.napi (parseYAML) (medium)
   1.42x faster than md4x.wasm (parseYAML) (medium)
   2.04x faster than confbox (parseYAML) (medium)
   2.13x faster than js-yaml (parseYAML) (medium)
   13.39x faster than yaml (parseYAML) (medium)

md4x.napi (yamlToJson) (medium)  17.24 µs/iter  17.36 µs  17.45 µs ▅▁▁█▁█▅▅▅█▅
md4x.wasm (yamlToJson) (medium)  24.42 µs/iter  24.81 µs  25.12 µs ▃▁▁▁▆█▃▁▃▃▆
js-yaml (yamlToJson) (medium)    43.13 µs/iter  43.01 µs  45.38 µs ▆▁▆▆█▁▁▃▁▁▃
yaml (yamlToJson) (medium)      253.26 µs/iter 253.56 µs 412.91 µs ▂█▃▂▁▁▁▁▁▁▁

summary
  md4x.napi (yamlToJson) (medium)
   1.42x faster than md4x.wasm (yamlToJson) (medium)
   2.5x faster than js-yaml (yamlToJson) (medium)
   14.69x faster than yaml (yamlToJson) (medium)
```

Notes:

- The bench asserts every parser returns the same value as js-yaml on each fixture before timing anything, so the numbers are for identical work.
- The `parseYAML` group ends at a materialized JS value for every entry. The `yamlToJson` group compares md4x's native JSON-string output against the JS libs' parse-then-`JSON.stringify`; confbox has no string-output path, so it only appears in the first group.
- `confbox` bundles js-yaml 4, which is why it tracks js-yaml closely.
- `yaml` builds a full CST and `Document` on every parse, which accounts for its much larger gap.

</details>

## Zig Library

MD4X is written in Zig. `src/lib.zig` is the library root: it pulls the parser, the entity
table and every renderer into a single module and re-exports their entry points, so they
call each other directly.

| Entry point              | Output                                                               |
| ------------------------ | -------------------------------------------------------------------- |
| `md_html` / `md_html_ex` | HTML (`_ex` adds full-document output and the syntax-highlight hook) |
| `md_ast`                 | Comark AST as JSON                                                   |
| `md_ansi` / `md_ansi_ex` | ANSI terminal output (`_ex` adds the syntax-highlight hook)          |
| `md_text`                | Plain text (markdown stripped)                                       |
| `md_meta`                | Frontmatter + headings as JSON                                       |
| `md_markdown`            | Clean, normalized markdown                                           |
| `md_heal`                | Healed markdown (a text transform — it does not parse)               |
| `md_yaml`                | Standalone YAML document as JSON                                     |
| `md_parse`               | The SAX parser itself, for custom rendering                          |

Every renderer takes the same shape — input bytes, an output callback, `userdata`, and a
word of renderer flags — and streams its result through the callback without building an
AST:

```zig
const md4x = @import("md4x"); // src/lib.zig

fn sink(text: [*c]const u8, size: c_uint, userdata: ?*anyopaque) void {
    const out: *std.ArrayListUnmanaged(u8) = @ptrCast(@alignCast(userdata.?));
    out.appendSlice(gpa, text[0..size]) catch {};
}

var out: std.ArrayListUnmanaged(u8) = .empty;
_ = md4x.md_html(input.ptr, @intCast(input.len), sink, &out, 0);
```

`md_parse` is the five-callback SAX interface the renderers themselves are written
against (`enter_block` / `leave_block` / `enter_span` / `leave_span` / `text`), for when
none of the bundled renderers fit. The markdown dialect is fixed: no entry point takes
parser flags, and there is nothing to select. See [docs/parser-api.md](./docs/parser-api.md)
for the callback table and [docs/renderers.md](./docs/renderers.md) for each renderer's
flags and behavior.

## Building

Requires [Zig](https://ziglang.org/). No other external dependencies (libyaml is fetched
by `build.zig.zon`).

```sh
zig build                      # CLI at zig-out/bin/md4x (ReleaseFast, the default)
zig build -Doptimize=Debug     # Debug build
zig build wasm                 # WASM     → packages/md4x/build/md4x.wasm
zig build napi-all             # NAPI addon for all 9 platforms
bun run build:js               # wasm + host NAPI + standalone bundle (what the JS package loads)
```

## License

[MIT](./LICENSE.md)

[npm version]: https://badgen.net/npm/v/md4x?color=F0DB4F
[npm link]: https://npmx.dev/package/md4x
[wasm size]: https://badgen.net/https/md4x.unjs.io/_badges/wasm-size.json?1
