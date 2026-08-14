// Bundle-size comparison: how much does each markdown library cost to ship to a
// browser? Every target is bundled with rolldown from a realistic entry (import
// the renderer, render a string) — minified and tree-shaken — and the resulting
// bytes are measured raw, gzipped and brotli'd.
//
// WASM-backed libraries are only comparable if their payload is counted too, so
// each target declares the runtime assets a real deployment has to serve
// alongside the JS. `md4x/standalone` embeds its (gzip + Z85) WASM in the bundle
// itself, so its JS column *is* its total; `md4x/wasm` and `md4w` fetch a
// separate `.wasm` file, counted in the WASM column. Compressed totals compress
// each file on its own — that is how a CDN serves them.
//
// Native NAPI-only libraries (satteri, @ox-content/napi) have no browser bundle
// at all and are reported as such rather than silently omitted.
//
// Feature parity matters as much as file parity: md4x's binary includes a YAML
// parser for front matter, so a library without one is not doing the same job.
// Those targets get the smallest JS YAML parser on hand added to their entry
// (picked by measuring the candidates, not by assertion), and the bytes it costs
// them are broken out in the `yaml` column.
//
//   bun packages/md4x/bench/bundle.mjs

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";
import { rolldown } from "rolldown";

/** Absolute path of a specifier, resolved from this file. */
function resolvePath(specifier) {
  return fileURLToPath(import.meta.resolve(specifier));
}

/** Reads a runtime asset, pointing at the build step when it is missing. */
function readAsset(path) {
  try {
    return readFileSync(path);
  } catch {
    throw new Error(`missing ${path} — run \`bun run build:js\``);
  }
}

/** Sibling file of a package entry (e.g. the `.wasm` next to its loader). */
function siblingOf(specifier, file) {
  return fileURLToPath(new URL(file, import.meta.resolve(specifier)));
}

/** JSON string literal of a resolved path, for embedding in generated source. */
function importPath(specifier) {
  return JSON.stringify(resolvePath(specifier).replaceAll("\\", "/"));
}

// Front-matter parity: candidates for the YAML parser the non-md4x targets have
// to bundle. The cheapest one by gzip is the one they get — measured below, so
// this stays honest if the field changes.
const yamlCandidates = [
  {
    name: "js-yaml",
    source: () => `
      import { load } from ${importPath("js-yaml")};
      export const parseFrontmatter = (input) => load(input);
    `,
  },
  {
    name: "confbox/yaml",
    source: () => `
      import { parseYAML } from ${importPath("confbox/yaml")};
      export const parseFrontmatter = (input) => parseYAML(input);
    `,
  },
  {
    name: "yaml",
    source: () => `
      import { parse } from ${importPath("yaml")};
      export const parseFrontmatter = (input) => parse(input);
    `,
  },
];

// Each target's `entry` is a virtual module: what an app that only wants
// markdown-to-HTML would actually write. `assets` are the extra files the
// runtime fetches at load time. `needsYaml` marks the libraries that parse no
// front matter of their own.
const targets = [
  {
    name: "md4x/standalone",
    note: "wasm embedded (gzip+z85), yaml built in",
    entry: () => `
      import { init, renderToHtml } from ${importPath("../lib/standalone.mjs")};
      await init();
      export const render = (md) => renderToHtml(md);
    `,
  },
  {
    name: "md4x/wasm",
    note: "external md4x.wasm (ReleaseFast)",
    entry: () => `
      import { init, renderToHtml } from ${importPath("../lib/wasm/default.mjs")};
      await init({ wasm: fetch(new URL("md4x.wasm", import.meta.url)) });
      export const render = (md) => renderToHtml(md);
    `,
    assets: () => [resolvePath("../build/md4x.wasm")],
  },
  {
    name: "md4x/wasm (small)",
    note: "external md4x-small.wasm (ReleaseSmall)",
    entry: () => `
      import { init, renderToHtml } from ${importPath("../lib/wasm/default.mjs")};
      await init({ wasm: fetch(new URL("md4x-small.wasm", import.meta.url)) });
      export const render = (md) => renderToHtml(md);
    `,
    assets: () => [resolvePath("../build/md4x-small.wasm")],
  },
  {
    name: "md4w",
    note: "external md4w-small.wasm (browser default)",
    entry: () => `
      import { init, mdToHtml } from ${importPath("md4w")};
      await init("small");
      export const render = (md) => mdToHtml(md);
    `,
    assets: () => [siblingOf("md4w", "md4w-small.wasm")],
    needsYaml: true,
  },
  {
    name: "md4w (fast)",
    note: "external md4w-fast.wasm",
    entry: () => `
      import { init, mdToHtml } from ${importPath("md4w")};
      await init("fast");
      export const render = (md) => mdToHtml(md);
    `,
    assets: () => [siblingOf("md4w", "md4w-fast.wasm")],
    needsYaml: true,
  },
  {
    name: "markdown-it",
    note: "pure JS",
    entry: () => `
      import MarkdownIt from ${importPath("markdown-it")};
      const md = new MarkdownIt();
      export const render = (input) => md.render(input);
    `,
    needsYaml: true,
  },
  {
    name: "markdown-exit",
    note: "pure JS",
    entry: () => `
      import { createMarkdownExit } from ${importPath("markdown-exit")};
      const md = createMarkdownExit();
      export const render = (input) => md.render(input);
    `,
    needsYaml: true,
  },
  { name: "satteri", native: true },
  { name: "@ox-content/napi", native: true },
];

const ENTRY_ID = "\0md4x:bundle-bench";

/** Bundles `source` as a standalone browser ES module; returns the emitted JS. */
async function bundleJs(source) {
  const bundle = await rolldown({
    input: ENTRY_ID,
    platform: "browser",
    // Both patterns only ever appear behind a guarded fallback (a Node-only
    // loader path, or the `?url` asset import a framework bundler would rewrite)
    // — the browser path never reaches them. Leaving them external also dodges a
    // rolldown panic on md4w's variable dynamic `import(u)` of `node:fs/promises`.
    external: [/^node:/, /\.wasm(\?.*)?$/],
    // Third-party sources emit resolution/annotation warnings that say nothing
    // about size; the numbers are the point here.
    onLog: () => {},
    plugins: [
      {
        name: "bench-entry",
        resolveId: (id) => (id === ENTRY_ID ? id : undefined),
        load: (id) => (id === ENTRY_ID ? source : undefined),
      },
    ],
  });
  const { output } = await bundle.generate({ format: "esm", minify: true });
  await bundle.close();
  // Chunks only — an emitted asset would be an input file already counted below.
  return Buffer.concat(
    output
      .filter((part) => part.type === "chunk")
      .map((chunk) => Buffer.from(chunk.code, "utf8")),
  );
}

const gzip = (buf) =>
  gzipSync(buf, { level: constants.Z_BEST_COMPRESSION }).length;

const brotli = (buf) =>
  brotliCompressSync(buf, {
    params: {
      [constants.BROTLI_PARAM_QUALITY]: constants.BROTLI_MAX_QUALITY,
      [constants.BROTLI_PARAM_SIZE_HINT]: buf.length,
    },
  }).length;

const results = [];
const skipped = [];

// Cheapest YAML parser wins the front-matter slot; the runners-up are printed so
// the choice is visible rather than taken on trust.
const yamlSizes = [];
for (const candidate of yamlCandidates) {
  try {
    const js = await bundleJs(candidate.source());
    yamlSizes.push({ ...candidate, raw: js.length, gzip: gzip(js) });
  } catch (error) {
    skipped.push(
      `${candidate.name} (yaml) — ${error.message.replaceAll("\n", " ").trim()}`,
    );
  }
}
yamlSizes.sort((a, b) => a.gzip - b.gzip);
const yamlPick = yamlSizes[0];

for (const target of targets) {
  if (target.native) {
    skipped.push(`${target.name} — NAPI only, no browser bundle`);
    continue;
  }
  try {
    const entry = target.entry();
    const base = await bundleJs(entry);
    // Bundled together rather than added as a separate number: the parser shares
    // whatever the markdown library already pulls in, so the honest cost of front
    // matter is the difference between the two bundles.
    const withYaml =
      target.needsYaml && yamlPick
        ? await bundleJs(entry + yamlPick.source())
        : base;
    const assets = (target.assets?.() ?? []).map((path) => readAsset(path));
    const files = [withYaml, ...assets];
    results.push({
      name: target.name,
      note: target.note,
      js: base.length,
      yaml: withYaml.length - base.length,
      wasm: assets.reduce((total, asset) => total + asset.length, 0),
      raw: files.reduce((total, file) => total + file.length, 0),
      gzip: files.reduce((total, file) => total + gzip(file), 0),
      brotli: files.reduce((total, file) => total + brotli(file), 0),
    });
  } catch (error) {
    skipped.push(
      `${target.name} — ${error.message.replaceAll("\n", " ").trim()}`,
    );
  }
}

// --- Report ---

const kib = (bytes) => (bytes === 0 ? "—" : `${(bytes / 1024).toFixed(1)} KiB`);

results.sort((a, b) => a.gzip - b.gzip);
const best = results[0]?.gzip ?? 1;

const columns = [
  { header: "target", align: "left", of: (r) => r.name },
  { header: "js", align: "right", of: (r) => kib(r.js) },
  { header: "yaml", align: "right", of: (r) => kib(r.yaml) },
  { header: "wasm", align: "right", of: (r) => kib(r.wasm) },
  { header: "total", align: "right", of: (r) => kib(r.raw) },
  { header: "gzip", align: "right", of: (r) => kib(r.gzip) },
  { header: "brotli", align: "right", of: (r) => kib(r.brotli) },
  {
    header: "vs best",
    align: "right",
    of: (r) => (r.gzip === best ? "—" : `${(r.gzip / best).toFixed(2)}x`),
  },
  { header: "", align: "left", of: (r) => r.note ?? "" },
];

const rows = results.map((r) => columns.map((column) => column.of(r)));
const widths = columns.map((column, i) =>
  Math.max(column.header.length, ...rows.map((row) => row[i].length)),
);
const line = (cells) =>
  cells
    .map((cell, i) =>
      columns[i].align === "right"
        ? cell.padStart(widths[i])
        : cell.padEnd(widths[i]),
    )
    .join("  ")
    .trimEnd();

console.log(`\nBundle size (rolldown, minified, browser platform)\n`);
console.log(line(columns.map((column) => column.header)));
console.log(line(widths.map((width) => "-".repeat(width))));
for (const row of rows) console.log(line(row));

console.log(
  `\ntotal = js + yaml + wasm; gzip/brotli compress each file separately, as a CDN would.` +
    `\nranked by gzip — what a first visit actually downloads.`,
);

if (yamlPick) {
  const cost = yamlSizes.map((c) => `${c.name} ${kib(c.gzip)} gzip`).join(", ");
  console.log(
    `\nyaml = front-matter parser added to libraries that have none, so every row` +
      `\nparses front matter like md4x does. Picked ${yamlPick.name} (cheapest of: ${cost}).` +
      `\nThe block-splitting plugin those libraries also need is not counted — the yaml` +
      `\ncolumn is a floor, not the full bill.`,
  );
}

if (skipped.length > 0) {
  console.log(`\nnot compared:`);
  for (const reason of skipped) console.log(`  ${reason}`);
}
console.log();
