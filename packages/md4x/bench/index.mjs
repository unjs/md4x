import { bench, compact, run, summary } from "mitata";
import * as napi from "../lib/napi.mjs";
import * as wasm from "../lib/wasm/default.mjs";
// Latest published md4x (C version) aliased as `md4x-c`, for old-vs-new comparison.
import * as napiC from "md4x-c/napi";
import * as wasmC from "md4x-c/wasm";
import * as md4w from "md4w";
import MarkdownIt from "markdown-it";
import { createMarkdownExit } from "markdown-exit";
import * as fixtures from "./_fixtures.mjs";

const markdownIt = new MarkdownIt();
const markdownExit = createMarkdownExit();

// Initialize WASM instances
await wasm.init();
await napi.init();
await wasmC.init();
await napiC.init();
await md4w.init();

const inputs = {
  // small: fixtures.small,
  medium: fixtures.medium,
  // large: fixtures.large,
};

for (const [name, input] of Object.entries(inputs)) {
  compact(() => {
    summary(() => {
      bench(`md4x.napi (renderToHtml)`, () => napi.renderToHtml(input));
      bench(`md4x-c.napi (renderToHtml)`, () => napiC.renderToHtml(input));
      bench(`md4x.wasm (renderToHtml)`, () => wasm.renderToHtml(input));
      bench(`md4x-c.wasm (renderToHtml)`, () => wasmC.renderToHtml(input));
      bench(`md4w (renderToHtml)`, () => md4w.mdToHtml(input));
      bench(`markdown-it (renderToHtml)`, () => markdownIt.render(input));
      bench(`markdown-exit (renderToHtml)`, () => markdownExit.render(input));
      // const bunToHTML = global.Bun.markdown.html;
      // if (bunToHTML) {
      //   bench(`Bun.markdown.html`, () => bunToHTML(input));
      // }
    });

    // summary(() => {
    //   bench(`md4x.napi (ast) (${name})`, () => napi.renderToAST(input));
    //   bench(`md4x.wasm (ast) (${name})`, () => wasm.renderToAST(input));
    // });

    summary(() => {
      bench(`md4x.napi (parseAST) (${name})`, () => napi.parseAST(input));
      bench(`md4x-c.napi (parseAST) (${name})`, () => napiC.parseAST(input));
      bench(`md4x.wasm (parseAST) (${name})`, () => wasm.parseAST(input));
      bench(`md4x-c.wasm (parseAST) (${name})`, () => wasmC.parseAST(input));
      bench(`md4w (parseAST) (${name})`, () => md4w.mdToJSON(input));
      bench(`markdown-it (parseAST) (${name})`, () =>
        markdownIt.parse(input, {}),
      );
      bench(`markdown-exit (parseAST) (${name})`, () =>
        markdownExit.parse(input, {}),
      );
    });
  });
}

await run();
