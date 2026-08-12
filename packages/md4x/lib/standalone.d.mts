export type {
  ComarkTree,
  ComarkNode,
  ComarkElement,
  ComarkText,
  ComarkElementAttributes,
  ComarkHeading,
  ComarkMeta,
  HtmlOptions,
  AnsiOptions,
  RenderOptions,
} from "./types.mjs";

export type { InitOptions } from "./wasm/index.mjs";

export {
  renderToHtml,
  renderToAST,
  parseAST,
  renderToAnsi,
  renderToMeta,
  parseMeta,
  renderToText,
  renderToMarkdown,
  heal,
} from "./wasm/index.mjs";

import type { InitOptions } from "./wasm/index.mjs";

/**
 * Decodes, inflates and instantiates the embedded WASM binary.
 *
 * Requires `DecompressionStream` (Node 18+, Deno, Bun, workers, modern browsers).
 * `opts.wasm` overrides the embedded binary — accepted for parity with `md4x/wasm`,
 * for which this module is served under the `browser` condition.
 */
export declare function init(opts?: InitOptions): Promise<void>;
