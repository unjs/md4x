import {
  parseHtmlWithHighlighting,
  parseAnsiWithHighlighting,
} from "../_shared.mjs";

// --- internal ---

let _instance;

export function _hasInstance() {
  return !!_instance;
}

export function _setInstance(instance) {
  _instance = instance;
}

export function _getExports() {
  if (!_instance?.exports) {
    throw new Error("md4x: WASM not initialized. Call `await init()` first.", {
      cause: { instance: _instance },
    });
  }
  return _instance.exports;
}

export const _imports = {
  wasi_snapshot_preview1: {
    fd_close: () => 0,
    fd_filestat_get: () => 0,
    fd_pwrite: () => 0,
    fd_read: () => 0,
    fd_seek: () => 0,
    fd_write: () => 0,
    proc_exit: () => {},
    random_get: (buf, len) => {
      const bytes = new Uint8Array(_instance.exports.memory.buffer, buf, len);
      crypto.getRandomValues(bytes);
      return 0;
    },
  },
};

function str(input) {
  if (input == null) return "";
  if (typeof input !== "string")
    throw new TypeError("md4x: input must be a string");
  return input;
}

function render(exports, fn, input, ...extra) {
  const { memory, md4x_alloc, md4x_free, md4x_result_ptr, md4x_result_size } =
    exports;
  const encoded = new TextEncoder().encode(str(input));
  const ptr = md4x_alloc(encoded.length);
  new Uint8Array(memory.buffer).set(encoded, ptr);
  const ret = fn(ptr, encoded.length, ...extra);
  md4x_free(ptr);
  if (ret !== 0) {
    throw new Error("md4x: render failed");
  }
  const outPtr = md4x_result_ptr();
  const outSize = md4x_result_size();
  const result = new TextDecoder().decode(
    new Uint8Array(memory.buffer, outPtr, outSize),
  );
  md4x_free(outPtr);
  return result;
}

/* Render with a meta function, returning raw bytes for highlighter processing. */
function renderMetaBytes(exports, metaFn, input) {
  const { memory, md4x_alloc, md4x_free, md4x_result_ptr, md4x_result_size } =
    exports;
  const encoded = new TextEncoder().encode(str(input));
  const ptr = md4x_alloc(encoded.length);
  new Uint8Array(memory.buffer).set(encoded, ptr);
  const ret = metaFn(ptr, encoded.length);
  md4x_free(ptr);
  if (ret !== 0) {
    throw new Error("md4x: render failed");
  }
  const outPtr = md4x_result_ptr();
  const outSize = md4x_result_size();
  const bytes = new Uint8Array(memory.buffer, outPtr, outSize);
  return { bytes, outPtr };
}

const HEAL_FLAG = 0x0100;

export function renderToHtml(input, opts) {
  let flags = opts?.full ? 0x0008 : 0;
  if (opts?.heal) flags |= HEAL_FLAG;
  const exports = _getExports();
  if (!opts?.highlighter && !opts?.math) {
    return render(exports, exports.md4x_to_html, input, flags);
  }
  const { bytes, outPtr } = renderMetaBytes(
    exports,
    exports.md4x_to_html_meta,
    input,
  );
  const result = parseHtmlWithHighlighting(bytes, opts?.highlighter, opts?.math);
  exports.md4x_free(outPtr);
  return result;
}

export function renderToAST(input, opts) {
  const flags = opts?.heal ? HEAL_FLAG : 0;
  const exports = _getExports();
  return render(exports, exports.md4x_to_ast, input, flags);
}

export function parseAST(input, opts) {
  return JSON.parse(renderToAST(input, opts));
}

export function renderToAnsi(input, opts) {
  let flags = opts?.heal ? HEAL_FLAG : 0;
  if (opts?.showUrls) flags |= 0x0010;
  if (opts?.showFrontmatter) flags |= 0x0020;
  const exports = _getExports();
  if (!opts?.highlighter && !opts?.math) {
    return render(exports, exports.md4x_to_ansi, input, flags);
  }
  const s = opts?.heal ? heal(str(input)) : str(input);
  const { bytes, outPtr } = renderMetaBytes(
    exports,
    exports.md4x_to_ansi_meta,
    s,
  );
  const result = parseAnsiWithHighlighting(bytes, opts?.highlighter, opts?.math);
  exports.md4x_free(outPtr);
  return result;
}

export function renderToMeta(input, opts) {
  const flags = opts?.heal ? HEAL_FLAG : 0;
  const exports = _getExports();
  return render(exports, exports.md4x_to_meta, input, flags);
}

export function renderToText(input, opts) {
  const flags = opts?.heal ? HEAL_FLAG : 0;
  const exports = _getExports();
  return render(exports, exports.md4x_to_text, input, flags);
}

export function renderToMarkdown(input, opts) {
  const flags = opts?.heal ? HEAL_FLAG : 0;
  const exports = _getExports();
  return render(exports, exports.md4x_to_markdown, input, flags);
}

export function parseMeta(input, opts) {
  const meta = JSON.parse(renderToMeta(input, opts));
  if (!meta.title && meta.headings?.[0]) {
    meta.title = meta.headings[0].text;
  }
  return meta;
}

export function heal(input) {
  const exports = _getExports();
  return render(exports, exports.md4x_heal, input);
}
