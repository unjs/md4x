import { bench, compact, run, summary } from "mitata";
import * as napi from "../lib/napi.mjs";
import * as wasm from "../lib/wasm/default.mjs";
import MarkdownIt from "markdown-it";
import { createMarkdownExit } from "markdown-exit";
import { medium } from "./_fixtures.mjs";

await wasm.init();
await napi.init();

function fakeHighlight(code, lang) {
  return code.replace(
    /\b(const|let|var|function|return|import|export|from|if|else)\b/g,
    '<span class="kw">$1</span>',
  );
}

const highlighter = (code, block) =>
  `<pre class="language-${block.lang}"><code>${fakeHighlight(code)}</code></pre>`;

const hlOption = (code, lang) =>
  `<pre class="language-${lang}"><code>${fakeHighlight(code, lang)}</code></pre>`;

const markdownIt = new MarkdownIt({ highlight: hlOption });
const markdownExit = createMarkdownExit({ highlight: hlOption });

// Normalize HTML for comparison: collapse whitespace differences and known tag variants
function normalize(html) {
  return html
    .replace(/ align="(left|center|right)"/g, ' style="text-align:$1"') // align attr → style
    .replace(/<(hr|br)\s*\/?>/g, "<$1 />") // self-closing tags
    .replace(/<del>/g, "<s>")
    .replace(/<\/del>/g, "</s>")
    .replace(/\s*(<\/?[a-z][^>]*>)\s*/gi, "$1") // strip whitespace around tags
    .trim();
}

// Pretest: verify md4x and markdown-it produce equivalent output
const md4xOut = normalize(napi.renderToHtml(medium, { highlighter }));
const markdownItOut = normalize(markdownIt.render(medium));
if (md4xOut !== markdownItOut) {
  // Find first divergence and show context around it
  const maxDiffs = 5;
  let shown = 0;
  console.log("⚠ Output diff (md4x vs markdown-it):");
  for (let i = 0; i < Math.max(md4xOut.length, markdownItOut.length); i++) {
    if (md4xOut[i] !== markdownItOut[i]) {
      const ctx = 30;
      console.log(`  at pos ${i}:`);
      console.log(
        `    - ...${md4xOut.slice(Math.max(0, i - ctx), i + ctx)}...`,
      );
      console.log(
        `    + ...${markdownItOut.slice(Math.max(0, i - ctx), i + ctx)}...`,
      );
      // Skip ahead past this diff region
      while (i < md4xOut.length && md4xOut[i] !== markdownItOut[i]) i++;
      if (++shown >= maxDiffs) {
        console.log(`  ... (${maxDiffs} diffs shown, more may exist)`);
        break;
      }
    }
  }
}

compact(() => {
  summary(() => {
    bench("napi.renderToHtml", () => napi.renderToHtml(medium));
    bench("napi.renderToHtml + highlight", () =>
      napi.renderToHtml(medium, { highlighter }),
    );
    bench("wasm.renderToHtml", () => wasm.renderToHtml(medium));
    bench("wasm.renderToHtml + highlight", () =>
      wasm.renderToHtml(medium, { highlighter }),
    );
    bench("markdown-it + highlight", () => markdownIt.render(medium));
    bench("markdown-exit + highlight", () => markdownExit.render(medium));
  });
});

await run();
