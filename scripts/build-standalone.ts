#!/usr/bin/env bun
// Builds `packages/md4x/lib/standalone.mjs` — the `md4x/standalone` entry (also
// served for the `browser` condition of `md4x` and `md4x/wasm`): a single, minified,
// dependency-free ES module with the WASM binary embedded (gzip + Z85).
//
// Nothing is written to `lib/` except the bundle itself: the Z85 payload/decoder
// and the entry module are rolldown *virtual* modules, so the multi-hundred-KB
// payload never lands on disk as source. Real source (`lib/wasm/common.mjs`,
// `lib/_shared.mjs`) is bundled in from disk as usual.

import { readFileSync, statSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { constants, gzipSync } from "node:zlib";
import { rolldown } from "rolldown";

const selfPath = dirname(fileURLToPath(import.meta.url));
const projectDir = resolve(selfPath, "..");
const pkgDir = resolve(projectDir, "packages/md4x");
// ReleaseSmall build (`zig build wasm-small`) — the standalone bundle trades a little
// throughput for a smaller payload.
const wasmPath = resolve(pkgDir, "build/md4x-small.wasm");
const outPath = resolve(pkgDir, "lib/standalone.mjs");

// Import specifiers are POSIX-ish even on Windows.
const commonPath = resolve(pkgDir, "lib/wasm/common.mjs").replaceAll("\\", "/");

const ENTRY_ID = "\0md4x:standalone";
const Z85_ID = "\0md4x:z85";

// --- Z85 (ZeroMQ RFC 32) ---
// 4 bytes -> 5 ASCII chars (+25% overhead, vs +33% for base64). The alphabet
// contains no `"`, `'`, `\` or backtick, so payloads embed verbatim in a string
// literal with no escaping.

const ALPHABET =
  "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#";

export function z85Encode(bytes: Uint8Array): string {
  const padded =
    bytes.length % 4 === 0
      ? bytes
      : (() => {
          const buf = new Uint8Array(bytes.length + (4 - (bytes.length % 4)));
          buf.set(bytes);
          return buf;
        })();
  const chars = new Array<string>((padded.length / 4) * 5);
  let c = 0;
  for (let i = 0; i < padded.length; i += 4) {
    // Big-endian 32-bit word, kept as a double to stay unsigned.
    const value =
      padded[i]! * 0x100_0000 +
      padded[i + 1]! * 0x1_0000 +
      padded[i + 2]! * 0x100 +
      padded[i + 3]!;
    let divisor = 85 * 85 * 85 * 85;
    for (let k = 0; k < 5; k++) {
      chars[c++] = ALPHABET[Math.floor(value / divisor) % 85]!;
      divisor /= 85;
    }
  }
  return chars.join("");
}

/** Counterpart decoder, emitted into the bundle alongside the payload. */
function z85Module(encoded: string, gzipSize: number): string {
  return `
const ALPHABET = ${JSON.stringify(ALPHABET)};
const DECODE_MAP = new Uint8Array(128);
for (let i = 0; i < ALPHABET.length; i++) DECODE_MAP[ALPHABET.charCodeAt(i)] = i;

export const GZIP_SIZE = ${gzipSize};
export const WASM_GZIP_Z85 = "${encoded}";

/** Decodes a Z85 string, trimming the zero padding back to \`byteLength\`. */
export function z85Decode(input, byteLength) {
  const out = new Uint8Array((input.length / 5) * 4);
  for (let i = 0, j = 0; i < input.length; i += 5) {
    // Accumulates up to 0xFFFFFFFF — kept as a double to stay unsigned.
    let value = 0;
    for (let k = 0; k < 5; k++) value = value * 85 + DECODE_MAP[input.charCodeAt(i + k)];
    out[j++] = (value / 0x1000000) & 0xff;
    out[j++] = (value / 0x10000) & 0xff;
    out[j++] = (value / 0x100) & 0xff;
    out[j++] = value & 0xff;
  }
  return byteLength === out.length ? out : out.subarray(0, byteLength);
}
`;
}

/** Entry module: the public `md4x/standalone` surface. */
function entryModule(): string {
  return `
export {
  renderToHtml,
  renderToAST,
  parseAST,
  renderToAnsi,
  parseMeta,
  renderToMeta,
  renderToText,
  renderToMarkdown,
  heal,
} from ${JSON.stringify(commonPath)};

import { _setInstance, _hasInstance, _imports } from ${JSON.stringify(commonPath)};
import { z85Decode, WASM_GZIP_Z85, GZIP_SIZE } from ${JSON.stringify(Z85_ID)};

/**
 * Inflates the gzip payload.
 *
 * On Node/Bun/Deno this uses \`node:zlib\`, which inflates the payload in ~1ms
 * against ~11ms (Bun) to ~27ms (Node) for \`DecompressionStream\` — that gap is
 * first-call setup of the web-streams-to-zlib adapter, not zlib itself.
 * \`getBuiltinModule\` is a plain call rather than an import, so bundlers never
 * see a \`node:zlib\` specifier and the module stays dependency-free.
 */
async function gunzip(bytes) {
  try {
    const zlib = globalThis.process?.getBuiltinModule?.("node:zlib");
    if (zlib?.gunzipSync) return zlib.gunzipSync(bytes);
  } catch {
    // Fall through to the web platform path.
  }
  if (typeof DecompressionStream !== "function") {
    throw new Error(
      "md4x: \`md4x/standalone\` requires \`node:zlib\` or \`DecompressionStream\` (Node 18+, Deno, Bun, or a modern browser). Use \`md4x/wasm\` instead.",
    );
  }
  const stream = new DecompressionStream("gzip");
  const writer = stream.writable.getWriter();
  // Errors surface when reading the readable side — swallow here to avoid
  // unhandled rejections on the (unawaited) write/close promises.
  const noop = () => {};
  writer.write(bytes).catch(noop);
  writer.close().catch(noop);
  return new Response(stream.readable).arrayBuffer();
}

/** Normalizes an \`opts.wasm\` override to bytes. */
async function toBytes(input) {
  if (input instanceof ArrayBuffer || input instanceof Uint8Array) return input;
  const resolved = await input;
  return resolved instanceof Response ? resolved.arrayBuffer() : resolved;
}

/**
 * Instantiates the embedded WASM binary.
 *
 * \`opts.wasm\` is accepted for parity with \`md4x/wasm\` (this module is served for
 * its \`browser\` condition) — pass it to override the embedded binary.
 */
export async function init(opts) {
  if (_hasInstance()) return;
  const override = opts?.wasm;
  const source =
    override instanceof WebAssembly.Module
      ? override
      : override
        ? await toBytes(override)
        : await gunzip(z85Decode(WASM_GZIP_Z85, GZIP_SIZE));
  const { instance } = await WebAssembly.instantiate(source, _imports);
  _setInstance(instance);
}
`;
}

export async function buildStandalone(): Promise<{
  wasmSize: number;
  gzipSize: number;
  encodedSize: number;
  bundleSize: number;
}> {
  let wasm: Buffer;
  try {
    wasm = readFileSync(wasmPath);
  } catch {
    throw new Error(
      `Missing ${wasmPath}\nRun \`zig build wasm-small\` before building the standalone bundle.`,
    );
  }

  // gzip (level 9) before Z85 — the runtime inflates with `DecompressionStream("gzip")`,
  // which accepts any conforming gzip stream regardless of the encoder.
  const gzipped = gzipSync(wasm, { level: constants.Z_BEST_COMPRESSION });
  const encoded = z85Encode(new Uint8Array(gzipped));

  const bundle = await rolldown({
    input: ENTRY_ID,
    platform: "neutral",
    plugins: [
      {
        name: "md4x-inline-wasm",
        resolveId(id) {
          if (id === ENTRY_ID || id === Z85_ID) return id;
        },
        load(id) {
          if (id === ENTRY_ID) return entryModule();
          if (id === Z85_ID) return z85Module(encoded, gzipped.length);
        },
      },
    ],
  });

  await bundle.write({
    file: outPath,
    format: "esm",
    minify: true,
  });
  await bundle.close();

  return {
    wasmSize: wasm.length,
    gzipSize: gzipped.length,
    encodedSize: encoded.length,
    bundleSize: statSync(outPath).size,
  };
}

if (import.meta.main) {
  const result = await buildStandalone().catch((error: Error) => {
    console.error(error.message);
    process.exit(1);
  });
  const { wasmSize, gzipSize, encodedSize, bundleSize } = result;
  console.log(
    `Wrote ${outPath}\n` +
      `  ${basename(wasmPath)} ${wasmSize} B -> gzip ${gzipSize} B -> z85 ${encodedSize} chars\n` +
      `  bundle ${bundleSize} B (${Math.round((bundleSize / wasmSize) * 100)}% of raw wasm)`,
  );
}
