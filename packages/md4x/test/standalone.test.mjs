import { beforeAll, describe, it, expect } from "vitest";
import { readFileSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import {
  init,
  renderToHtml,
  renderToAST,
  renderToAnsi,
  parseAST,
  renderToMeta,
  parseMeta,
  renderToText,
  heal,
} from "md4x/standalone";
import { defineSuite } from "./_suite.mjs";

const bundleUrl = new URL("../lib/standalone.mjs", import.meta.url);

beforeAll(async () => {
  await init();
});

defineSuite({
  renderToHtml,
  renderToAST,
  renderToAnsi,
  parseAST,
  renderToMeta,
  parseMeta,
  renderToText,
  heal,
});

describe("standalone: bundle", () => {
  // Drop the banner comment — it names md4x.wasm and the build script.
  const code = readFileSync(bundleUrl, "utf8").replace(
    /^\/\*![\s\S]*?\*\/\n/,
    "",
  );

  // Assertions compare booleans, not the ~126 KB source, to keep failures readable.
  it("is a single self-contained module (no imports)", () => {
    expect(/\bimport\s*[({'"]/.test(code)).toBe(false);
    expect(/\brequire\s*\(/.test(code)).toBe(false);
  });

  it("loads no external asset", () => {
    // `.wasm` alone would match the `opts.wasm` override, so check the ways an
    // asset could actually be fetched instead.
    expect(/\bfetch\s*\(/.test(code)).toBe(false);
    expect(/\bnew URL\s*\(/.test(code)).toBe(false);
    expect(code.includes("import.meta")).toBe(false);
  });

  it("is minified", () => {
    // Payload aside, minified output has very few newlines.
    expect(code.split("\n").length).toBeLessThan(20);
  });

  it("is much smaller than the raw wasm binary", () => {
    const wasmSize = statSync(
      new URL("../build/md4x.wasm", import.meta.url),
    ).size;
    expect(statSync(bundleUrl).size).toBeLessThan(wasmSize / 2);
  });

  it("falls back to DecompressionStream when node:zlib is unavailable", () => {
    // The browser path: no `process.getBuiltinModule`, so `init()` must inflate
    // via the web platform API instead.
    const script = `delete process.getBuiltinModule;
      const m = await import(${JSON.stringify(bundleUrl.href)});
      await m.init();
      process.stdout.write(m.renderToHtml("# Hi").trim());`;
    const out = execFileSync(
      process.execPath,
      ["--input-type=module", "-e", script],
      {
        encoding: "utf8",
      },
    );
    expect(out).toBe("<h1>Hi</h1>");
  });

  it("renders identically to the uncompressed wasm entry", async () => {
    const wasm = await import("md4x/wasm");
    await wasm.init();
    const md = readFileSync(
      new URL("./fixtures/nitro-index.md", import.meta.url),
      "utf8",
    );
    expect(renderToHtml(md)).toBe(wasm.renderToHtml(md));
    expect(renderToAST(md)).toBe(wasm.renderToAST(md));
  });
});
