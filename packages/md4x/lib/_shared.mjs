const decoder = new TextDecoder();

function parseCodeMeta(bytes, extraFields) {
  const nullIdx = bytes.indexOf(0);
  if (nullIdx === -1) {
    return { output: decoder.decode(bytes), codeBlocks: [] };
  }
  const outBytes = bytes.subarray(0, nullIdx);
  const metaBytes = bytes.subarray(nullIdx + 1);
  const output = decoder.decode(outBytes);
  const meta = JSON.parse(decoder.decode(metaBytes));
  const rawCodeBlocks = Array.isArray(meta) ? meta : meta.c || [];
  const rawMathBlocks = Array.isArray(meta) ? [] : meta.m || [];

  const codeBlocks = rawCodeBlocks.map((m) => {
    const start = decoder.decode(outBytes.subarray(0, m.s)).length;
    const end = decoder.decode(outBytes.subarray(0, m.e)).length;
    const block = { start, end, lang: m.l || "" };
    if (m.f) block.filename = m.f;
    if (m.h) block.highlights = m.h;
    if (extraFields) extraFields(block, m);
    return block;
  });

  const mathBlocks = rawMathBlocks.map((m) => {
    const start = decoder.decode(outBytes.subarray(0, m.s)).length;
    const end = decoder.decode(outBytes.subarray(0, m.e)).length;
    return { start, end, display: m.d === 1 };
  });

  return { output, codeBlocks, mathBlocks };
}

export function parseHtmlMeta(bytes) {
  const { output, codeBlocks, mathBlocks } = parseCodeMeta(bytes);
  return { html: output, codeBlocks, mathBlocks };
}

export function parseHtmlWithHighlighting(bytes, highlighter, math) {
  const { html, codeBlocks, mathBlocks } = parseHtmlMeta(bytes);
  if (codeBlocks.length === 0 && mathBlocks.length === 0) return html;

  // Combine and sort blocks to replace sequentially from start to end
  const allBlocks = [
    ...codeBlocks.map(b => ({ ...b, type: 'code' })),
    ...mathBlocks.map(b => ({ ...b, type: 'math' }))
  ].sort((a, b) => a.start - b.start);

  let out = "";
  let pos = 0;
  for (const block of allBlocks) {
    if (block.type === 'code' && highlighter) {
      const code = unescapeHtml(html.slice(block.start, block.end));
      const highlighted = highlighter(code, block);
      if (highlighted === undefined) {
        out += html.slice(pos, block.end);
      } else {
        // Calculate <pre><code...> prefix length to replace the full wrapper
        const preLen = block.lang
          ? '<pre><code class="language-'.length + block.lang.length + '">'.length
          : "<pre><code>".length;
        out += html.slice(pos, block.start - preLen);
        out += highlighted;
        pos = block.end + "</code></pre>\n".length;
        continue;
      }
    } else if (block.type === 'math' && math) {
      const code = unescapeHtml(html.slice(block.start, block.end));
      const rendered = math(code, block.display);
      if (rendered === undefined) {
        out += html.slice(pos, block.end);
      } else {
        const preLen = block.display ? '<x-equation type="display">'.length : '<x-equation>'.length;
        out += html.slice(pos, block.start - preLen);
        out += rendered;
        pos = block.end + "</x-equation>".length;
        continue;
      }
    } else {
      out += html.slice(pos, block.end);
    }
    pos = block.end;
  }
  out += html.slice(pos);
  return out;
}

function unescapeHtml(str) {
  if (!str.includes("&")) return str;
  return str
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"');
}

const DIM = "\x1b[2m";
const DIM_OFF = "\x1b[22m";

export function parseAnsiMeta(bytes) {
  const { output, codeBlocks, mathBlocks } = parseCodeMeta(bytes, (block, m) => {
    if (m.i) block.prefix = m.i;
  });
  return { ansi: output, codeBlocks, mathBlocks };
}

export function parseAnsiWithHighlighting(bytes, highlighter, math) {
  const { ansi, codeBlocks, mathBlocks } = parseAnsiMeta(bytes);
  if (codeBlocks.length === 0 && mathBlocks.length === 0) return ansi;

  const allBlocks = [
    ...codeBlocks.map(b => ({ ...b, type: 'code' })),
    ...mathBlocks.map(b => ({ ...b, type: 'math' }))
  ].sort((a, b) => a.start - b.start);

  let out = "";
  let pos = 0;
  for (const block of allBlocks) {
    const region = ansi.slice(block.start, block.end);
    // Strip DIM/YELLOW wrappers
    let inner = region;
    let escapeCode = block.type === 'code' ? DIM : "\x1b[33m"; // ANSI_COLOR_YELLOW
    let escapeOffCode = block.type === 'code' ? DIM_OFF : "\x1b[39m"; // ANSI_COLOR_DEFAULT

    // Sometimes the prefix might be mixed, we gently remove them if they match what we expect.
    // md4x-ansi puts ANSI_COLOR_YELLOW before the span contents.
    if (inner.startsWith(escapeCode)) inner = inner.slice(escapeCode.length);
    if (inner.endsWith(escapeOffCode)) inner = inner.slice(0, -escapeOffCode.length);

    if (block.type === 'code' && highlighter) {
      const prefix = block.prefix || "  ";
      const code = inner
        .split("\n")
        .filter((l) => l.length > 0)
        .map((l) => (l.startsWith(prefix) ? l.slice(prefix.length) : l))
        .join("\n");
      const highlighted = highlighter(code, block);
      if (highlighted === undefined) {
        out += ansi.slice(pos, block.end);
      } else {
        out += ansi.slice(pos, block.start);
        // Wrap each line with the indent prefix
        const lines = highlighted.split("\n");
        for (let i = 0; i < lines.length; i++) {
          if (lines[i].length > 0) {
            out += prefix + lines[i];
          }
          if (i < lines.length - 1) {
            out += "\n";
          }
        }
        // Ensure trailing newline
        if (!highlighted.endsWith("\n")) out += "\n";
        pos = block.end;
        continue;
      }
    } else if (block.type === 'math' && math) {
      const code = inner;
      const rendered = math(code, block.display);
      if (rendered === undefined) {
        out += ansi.slice(pos, block.end);
      } else {
        out += ansi.slice(pos, block.start - "\x1b[33m".length); // Remove the starting YELLOW color
        out += rendered;
        pos = block.end + "\x1b[39m".length; // Remove the trailing DEFAULT color
        continue;
      }
    } else {
      out += ansi.slice(pos, block.end);
    }
    pos = block.end;
  }
  out += ansi.slice(pos);
  return out;
}
