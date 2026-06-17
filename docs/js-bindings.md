# JS Bindings

## WASM Target

```sh
zig build wasm                     # outputs packages/md4x/build/md4x.wasm (~324K)
```

Builds a `wasm32-wasi` WASM binary with exported functions. Uses `ReleaseFast` optimization (`pkg_optimize` in `build.zig`, shared with the NAPI targets). The WASM module requires minimal WASI imports (`fd_close`, `fd_seek`, `fd_write`, `proc_exit`) which can be stubbed for browser use.

> **Note on WASM performance:** The WASM target is built `ReleaseFast` (same as NAPI), but it is consistently slower than the native NAPI binding (roughly 3x on `renderToHtml`, 2x on `parseAST` for the medium fixture) due to the WebAssembly runtime plus the cost of copying input/output across the JS↔WASM memory boundary on every call. Renderer-side allocation optimizations (e.g. the AST arena, HTML output buffering) help the native path more than WASM, since wasm's linear-memory allocator has a different cost profile than the system `malloc`. Prefer NAPI where raw throughput matters; WASM is the portable fallback for non-Node environments.

**Exported functions:**

| Function                         | Description                              |
| -------------------------------- | ---------------------------------------- |
| `md4x_alloc(size) -> ptr`        | Allocate memory in WASM linear memory    |
| `md4x_free(ptr)`                 | Free previously allocated memory         |
| `md4x_to_html(ptr, size) -> int` | Render to HTML (0=ok, -1=error)          |
| `md4x_to_ast(ptr, size) -> int`  | Render to JSON AST                       |
| `md4x_to_ansi(ptr, size) -> int` | Render to ANSI                           |
| `md4x_to_meta(ptr, size) -> int` | Render to meta JSON                      |
| `md4x_to_text(ptr, size) -> int` | Render to plain text                     |
| `md4x_heal(ptr, size) -> int`    | Heal incomplete streaming markdown       |
| `md4x_result_ptr() -> ptr`       | Get output buffer pointer (after render) |
| `md4x_result_size() -> size`     | Get output buffer size (after render)    |

**Usage from JS (via `lib/wasm.mjs` wrapper):**

```js
import { init, renderToHtml } from "md4x/wasm";

await init(); // load WASM binary (call once before using render methods)

const html = renderToHtml("# Hello"); // sync after init
```

`init(opts?)` accepts an optional options object with a `wasm` property: `ArrayBuffer`, `Uint8Array`, `WebAssembly.Module`, `Response`, or `Promise<Response>`. When called with no arguments in Node.js, it reads the bundled `.wasm` file from disk. All render methods are **sync** after initialization. All extensions are enabled by default (`MD_DIALECT_ALL`).

## NAPI Target (Node.js)

```sh
bunx nypm add node-api-headers
zig build napi-all -Dnapi-include=node_modules/node-api-headers/include  # all 9 platforms
```

Individual platform targets:

```sh
zig build napi-linux-x64 -Dnapi-include=node_modules/node-api-headers/include
zig build napi-linux-x64-musl -Dnapi-include=node_modules/node-api-headers/include
zig build napi-linux-arm64 -Dnapi-include=node_modules/node-api-headers/include
zig build napi-linux-arm64-musl -Dnapi-include=node_modules/node-api-headers/include
zig build napi-linux-arm -Dnapi-include=node_modules/node-api-headers/include
zig build napi-darwin-x64 -Dnapi-include=node_modules/node-api-headers/include
zig build napi-darwin-arm64 -Dnapi-include=node_modules/node-api-headers/include
zig build napi-win32-x64 -Dnapi-include=node_modules/node-api-headers/include
zig build napi-win32-arm64 -Dnapi-include=node_modules/node-api-headers/include
```

`zig build napi-all` outputs platform-specific binaries to `packages/md4x/build/`:

| Output file                  | Platform                |
| ---------------------------- | ----------------------- |
| `md4x.linux-x64.node`        | Linux x86_64 (glibc)    |
| `md4x.linux-x64-musl.node`   | Linux x86_64 (musl)     |
| `md4x.linux-arm64.node`      | Linux aarch64 (glibc)   |
| `md4x.linux-arm64-musl.node` | Linux aarch64 (musl)    |
| `md4x.linux-arm.node`        | Linux ARMv7 (gnueabihf) |
| `md4x.darwin-x64.node`       | macOS x86_64            |
| `md4x.darwin-arm64.node`     | macOS Apple Silicon     |
| `md4x.win32-x64.node`        | Windows x86_64          |
| `md4x.win32-arm64.node`      | Windows ARM64           |

Windows targets use `zig dlltool` to generate import libraries from `node_modules/node-api-headers/def/node_api.def`. The `-Dnapi-def` build option can override the `.def` path.

**Exported functions (C-level, raw strings):**

| Function       | Signature                                 |
| -------------- | ----------------------------------------- |
| `renderToHtml` | `(input: string) => string`               |
| `renderToAST`  | `(input: string) => string` (JSON string) |
| `renderToAnsi` | `(input: string) => string`               |
| `renderToMeta` | `(input: string) => string` (JSON string) |
| `renderToText` | `(input: string) => string`               |
| `heal`         | `(input: string) => string`               |

**Usage (via `lib/napi.mjs` wrapper, which parses JSON):**

```js
import { renderToHtml } from "md4x/napi";

const html = renderToHtml("# Hello");
```

The NAPI API is sync. All extensions are enabled by default (`MD_DIALECT_ALL`). `renderToAST` returns the raw JSON string from the C renderer. `parseAST` parses it into a `ComarkTree` object.

`init(opts?)` is optional for NAPI — the native binding loads lazily on first render call. It accepts an optional options object with a `binding` property to provide a custom NAPI binding.

The JS loader (`lib/napi.mjs`) auto-detects the platform via `process.platform` and `process.arch`, loading `md4x.{platform}-{arch}.node`.

## JS Package Exports

Configured in `packages/md4x/package.json` via `exports`:

| Subpath       | Module                                           | Description                                  |
| ------------- | ------------------------------------------------ | -------------------------------------------- |
| `md4x` (bare) | `lib/napi.mjs` (node) / `lib/wasm.mjs` (default) | Auto-selects NAPI on Node.js, WASM elsewhere |
| `md4x/wasm`   | `lib/wasm.mjs`                                   | WASM-based API (sync after `init()`)         |
| `md4x/napi`   | `lib/napi.mjs`                                   | Sync NAPI-based API (ESM only)               |

All extensions (`MD_DIALECT_ALL`) are enabled by default. No parser/renderer flag configuration is exposed to JS consumers.

**JS API functions (unified across NAPI and WASM):**

| Function                      | NAPI                                     | WASM                                     |
| ----------------------------- | ---------------------------------------- | ---------------------------------------- |
| `init(opts?)`                 | `Promise<void>` (optional, lazy loading) | `Promise<void>` (required before render) |
| `renderToHtml(input: string)` | `string`                                 | `string`                                 |
| `renderToAST(input: string)`  | `string`                                 | `string`                                 |
| `parseAST(input: string)`     | `ComarkTree`                             | `ComarkTree`                             |
| `renderToAnsi(input: string)` | `string`                                 | `string`                                 |
| `renderToMeta(input: string)` | `string`                                 | `string`                                 |
| `parseMeta(input: string)`    | `ComarkMeta`                             | `ComarkMeta`                             |
| `renderToText(input: string)` | `string`                                 | `string`                                 |
| `heal(input: string)`         | `string`                                 | `string`                                 |

`renderToAST` returns the raw JSON string from the C renderer. `parseAST` calls `renderToAST` and parses the result into a `ComarkTree` object. `renderToMeta` returns the raw JSON string from the meta renderer. `parseMeta` calls `renderToMeta`, parses the result, and falls back to the first heading as `title` if no frontmatter title exists. See `lib/types.d.ts` for types.

Both `renderToHtml` and `renderToAnsi` accept an optional `highlighter` callback for custom code block highlighting:

````js
const ansi = renderToAnsi("```js\nconst x = 1;\n```", {
  highlighter: (code, block) => {
    // code = "const x = 1;"
    // block = { lang: "js", filename?: string, highlights?: number[], prefix: "  " }
    return "\x1b[33mconst\x1b[0m x = 1;"; // custom ANSI highlighted
  },
});
````

When `highlighter` is provided, code blocks are rendered with metadata tracking. For each fenced code block, the highlighter receives the raw code text (with indentation stripped) and a metadata object containing `lang`, optional `filename`, optional `highlights` array, and the `prefix` string used for line indentation (including ANSI escapes for nested contexts like blockquotes). If the highlighter returns a string, the code block content is replaced with the highlighted output (automatically re-indented with the prefix). If it returns `undefined`, the default dim rendering is used.

## TypeScript Types (`lib/types.d.ts`)

The package exports TypeScript types for the Comark AST:

- `ComarkTree` — Root container: `{ nodes: ComarkNode[], frontmatter: Record<string, unknown>, meta: Record<string, unknown> }`
- `ComarkNode` — Either a `ComarkElement` (tuple array) or `ComarkText` (plain string)
- `ComarkElement` — Tuple: `[tag: string | null, props: ComarkElementAttributes, ...children: ComarkNode[]]`
- `ComarkText` — Plain string representing text content
- `ComarkElementAttributes` — Key-value record: `{ [key: string]: unknown }`
- `ComarkMeta` — Metadata object: `{ title?: string, headings: ComarkHeading[], [key: string]: unknown }`
- `ComarkHeading` — Heading entry: `{ level: number, text: string }`

The website playground includes both Vue and React examples that render this AST format (`website/components/ComarkVueRenderer.vue`, `website/components/ComarkReactRenderer.vue`).

## Comark AST Format

The JSON renderer produces a **Comark AST** — a lightweight, array-based format: `{"nodes":[...],"frontmatter":{...},"meta":{}}`. Each node is either a plain string (text) or an element tuple `[tag, props, ...children]`. Frontmatter YAML is parsed into the top-level `frontmatter` object (not included in `nodes`). HTML comments are represented as `[null, {}, "comment body"]`.

**Property type conventions in AST output:**

| MDC Syntax              | AST Props                        | Description                 |
| ----------------------- | -------------------------------- | --------------------------- |
| `prop="value"`          | `"prop": "value"`                | String prop                 |
| `bool`                  | `":bool": "true"`                | Boolean (`:` prefix in key) |
| `:count="5"`            | `":count": "5"`                  | Number/bind (`:` prefix)    |
| `:data='{"k":"v"}'`     | `":data": "{\"k\":\"v\"}"`       | JSON passthrough            |
| `#my-id`                | `"id": "my-id"`                  | ID shorthand                |
| `.class-one .class-two` | `"class": "class-one class-two"` | Class shorthand (merged)    |

**Key AST mappings:**

- Code blocks: `["pre", {"language": "js", "filename": "app.js", "highlights": [1,2]}, ["code", {"class": "language-js"}, "..."]]`
- Components: `["component-name", {props}, ...children]`
- Slots: `["template", {"name": "slot-name"}, ...children]`
- Images: `["img", {"src": "url", "alt": "text"}]` (void, no children)
- HTML comments: `[null, {}, " comment text "]`

## JS Package Testing

Tests use vitest with a shared test suite (`packages/md4x/test/_suite.mjs`) that validates both NAPI and WASM bindings:

```sh
pnpm vitest run packages/md4x/test/napi.test.mjs   # NAPI tests
pnpm vitest run packages/md4x/test/wasm.test.mjs   # WASM tests
```

## JS Package Benchmarks

Benchmarks use `mitata` and compare against `md4w` and `markdown-it`:

```sh
bun packages/md4x/bench/index.mjs
```

## Workspace Setup

The root `package.json` defines a bun workspace (`"workspaces": ["packages/*"]`) with:

- `node-api-headers` — Required for NAPI builds
- `prettier` — Code formatting
- Package manager: `bun@1.3.9`
