# Porting libyaml to Zig

Replace the vendored C libyaml with a pure-Zig port of its parser half, proven
event-for-event identical by a differential harness.

## Why

libyaml is the **only C compiled into any md4x artifact**. Measured on this
checkout:

| | value |
| --- | --- |
| C compiled today | `api.c` + `reader.c` + `scanner.c` + `parser.c` — 6 835 lines |
| Surface md4x uses | 5 functions, 11 event types, 2 scalar styles |
| Cost in the wasm | **~62 KB** (`-Os`, linked, minus baseline) / ~69 KB at `-O2` |
| Cost gzipped | **~17.8 KB** — against a 292 KB `md4x-small.wasm` |
| Throughput | 5.4 µs for a realistic 296-byte frontmatter — **~55 MB/s**, ~20× slower per byte than md4c-class markdown parsing, because every scalar is `strdup`ed |
| Upstream cadence | last release 0.2.5, **June 2020**; 128 open issues |

Beyond the size and the allocation churn, libyaml is the one region of the build
that is **outside Zig's coverage-guided fuzzer and outside ReleaseSafe** — where
an out-of-bounds read is undefined behaviour rather than a trap. `src/fuzz.zig`
says so in its header today.

The survey of alternatives (libfyaml, rapidyaml, fkYAML, kubkon/zig-yaml, ymlz,
devnw/zig/yaml, saphyr) found **no drop-in that is better for md4x**: the mature
ones are C++ or POSIX-heavy or YAML 1.2 (which silently changes user
frontmatter), and the pure-Zig ones are either work-in-progress, struct-hydration
only, or unproven. Porting is the same move this project already made for md4c,
at similar scale.

## Measured outcome (2026-08-13)

The port is **done and proven behaviourally identical**. The size and speed
projections above were the *motivation*; here is what actually happened, in a
same-toolchain A/B against `571aa9c` (the last commit with the C wired in).

| | C libyaml | Zig port | delta |
| --- | --- | --- | --- |
| `md4x.wasm` raw | 387,201 | 414,587 | **+27,386 (+7.1%)** |
| `md4x.wasm` gzip | 128,659 | 134,981 | +6,322 (+4.9%) |
| `md4x-small.wasm` raw | 292,407 | 286,541 | **−5,866 (−2.0%)** |
| `md4x-small.wasm` gzip | 108,514 | 108,939 | +425 (+0.4%) |
| ns / 296-byte frontmatter | ~5,500 | ~7,800 | **~1.4x slower** |

**The size and speed case did not materialise.**

A per-function breakdown of both wasm binaries (parsing the `name` section
directly) shows the growth is entirely the port, and nothing else:

| bucket | C build | Zig build | delta |
| --- | --- | --- | --- |
| YAML implementation | 62,720 | **89,011** | **+26,291 (1.42x)** |
| md4x parser/renderers | 99,006 | 99,124 | +118 |
| std / libc / runtime | 159,522 | 160,225 | +703 |

and it concentrates in the three scalar scanners — ~10.5 KB of that 26 KB:

| | C | Zig | delta |
| --- | --- | --- | --- |
| flow scalar | 9,356 | 14,292 | +4,936 |
| block scalar | 4,707 | 7,706 | +2,999 |
| plain scalar | 4,878 | 7,507 | +2,629 |

Those three are exactly where the port uses the most `errdefer`. The C has ONE
`error:` cleanup block per function that every failure `goto`s to, while Zig
emits cleanup at every error-propagation site, and each of these scanners
juggles three or four owned `String`s. Together with an `Allocator` vtable
indirect call where the C calls `malloc` directly, that is the leading
hypothesis for both the size and the runtime gap — testable, not yet tested.

Two self-inflicted costs were found and fixed, and they are the reason the
numbers are not worse:

- `Buffer.init` zeroed the whole 64 KB input window per parser. `BUFFER_INIT`
  in the C mallocs and never memsets. Worth ~11% of runtime — and for
  frontmatter this is once per document, so it was pure overhead.
- `inline` on the 74 predicate/cursor wrappers cost ~15 KB in ReleaseSmall and
  ~10 KB in ReleaseFast. The C spells them as macros, but LLVM inlines the Zig
  ones perfectly well without being forced to.

The likely remaining runtime gap is `String.toOwned`'s shrink-realloc: one
extra allocator call per scalar that libyaml does not make (it hands the whole
buffer over, because `yaml_free` needs no length). Removing it means carrying a
capacity beside every owned string.

What *did* improve is real but not what was advertised: YAML now runs under
ReleaseSafe and Zig's coverage-guided fuzzer instead of being the one
UB-capable region of the build, and three upstream hazards (notably the
unsigned-wrap `memmove` in `roll_indent`) now trap rather than corrupt memory.

**This is a decision point, not a finished argument.** Keep and optimise, keep
as-is for the safety, or revert — the parity harness and corpus are worth
keeping either way.

## Non-goals

- **The emitter, writer, loader and dumper are not ported.** md4x consumes an
  event stream from a byte slice; it never emits YAML and never composes a
  document tree. Note this is **not a size saving**: `build.zig` never compiled
  those four files, and the linker had already dropped every unreachable
  function from `api.c` — only 42 libyaml functions, all live, were in the
  pre-port wasm.
- **File input is not ported.** `yaml_parser_set_input_string` only; the wasm
  build has no filesystem.
- **No semantic changes.** Not YAML 1.2, not a different scalar schema, not
  better error messages. The port reproduces the C's quirks, including the ones
  that are arguably bugs. Anything else is a separate, separately-justified PR.

## The parity contract

The port must produce the **same event stream as the vendored C, byte for byte,
for every input** — including the failure cases. `src/yaml/parity.zig` drives
both implementations over the same bytes, serialises each event stream to the
yaml-test-suite event format, and diffs them:

```
+STR
+DOC ---
+MAP
=VAL :title
=VAL "Hello
-MAP
-DOC
-STR
```

with two additions over upstream's `tests/run-parser-test-suite.c`:

- `ERR <kind> <line>:<column> <context> / <problem>` when a parse stops early.
  The `problem` strings are compile-time literals on both sides, so comparing
  them pins the exact branch that rejected the input — not merely that
  *something* did.
- `=VAL` payloads are escaped as upstream's `print_escaped` does, so a scalar
  carrying a NUL or a stray CR still round-trips through the comparison.

Corpus: 27 tracked seeds in `test/fuzzers/yaml-seed/` (frontmatter shapes plus
the edge cases that historically diverge between YAML implementations) and the
402-case official yaml-test-suite, fetched on demand by
`scripts/fetch-yaml-corpus.sh` into a gitignored directory.

```sh
bash scripts/fetch-yaml-corpus.sh   # 402 upstream cases (once)
zig build yaml-parity               # corpus + inline cases + the port's unit tests
zig build yaml-parity --fuzz        # coverage-guided differential fuzzing
```

The harness binary is built **ReleaseSafe regardless of `-Doptimize`**: a port
that only agrees with C because an out-of-bounds read landed on the right byte
is not a port, and only the safety checks can tell the difference.

## Layout

```
src/yaml/
  yaml.zig        # public API: init / setInputString / parse / deinit
  types.zig       # enums, Mark, Token, Event, Parser + the cursor macros   [done]
  mem.zig         # String / Buffer / Stack / Queue                          [done]
  chars.zig       # the IS_* / AS_* / WIDTH predicates                       [done]
  api.zig         # parser lifecycle (src/api.c subset)                      [done]
  reader.zig      # src/reader.c        —   469 lines                        [step 1]
  scanner.zig     # src/scanner.c driver — ~1 190 lines                      [step 2]
  scan_token.zig  # src/scanner.c tokens — ~ 820 lines                       [step 3]
  scan_scalar.zig # src/scanner.c scalars — ~ 860 lines                      [step 4]
  parser.zig      # src/parser.c        — 1 240 lines                        [step 5]
  parity.zig      # the differential harness                                 [done]
```

The C being ported is the exact source `build.zig.zon` pins, unpacked at
`zig-pkg/N-V-__8AAGzPCAAGFPs7xJsG7yEFGaafTjL8aDMXQGObSLD0/` — libyaml master
(post-0.2.5), which is what the shipped artifacts already compile.

## How the C maps onto the Zig

Fixed for every step, so five agents produce one codebase and not five dialects.
The full table lives in `src/yaml/types.zig`'s header; the load-bearing rows:

| C | Zig |
| --- | --- |
| `int f(...)` — 1 ok / 0 fail | `fn f(...) Error!void` |
| `if (!f(...)) return 0;` | `try f(...);` |
| `return 1;` / `return 0;` after an error | `return;` / `return error.Yaml;` |
| `goto error;` + cleanup | `errdefer` on the owning local |
| `token->type == YAML_KEY_TOKEN` | `token.data == .key` |
| `token->data.scalar.length` | `token.data.scalar.value.len` |
| `IS_BLANKZ(parser->buffer)` | `parser.isBlankz()` |
| `CACHE(parser, n)` / `SKIP(parser)` | `try parser.cache(n)` / `parser.skip()` |
| `READ(parser, s)` / `READ_LINE(parser, s)` | `try parser.read(&s)` / `try parser.readLine(&s)` |
| `PUSH(parser, stack, v)` | `try stack.push(parser.alloc, v)` |
| `STACK_LIMIT(parser, stack, n)` | `stack.underLimit(n)` |
| `yaml_malloc` / `yaml_free` | `parser.alloc` — never `std.c.malloc` |

Deliberate deviations, all documented at their definition:

- **Scalar values are `[:0]u8` sentinel slices.** A YAML scalar may contain NUL,
  so libyaml carries a separate `length`; a sentinel slice carries the exact
  length in `.len` *and* keeps the terminator the C-shaped consumers want.
- **`MAX_NESTING_LEVEL` is `Parser.max_nest_level`,** not a process-global with
  a non-thread-safe setter.
- **Pointer triples become slice + index,** so every access is bounds-checked in
  Debug and ReleaseSafe (`.agents/conventions.md`).

## Steps

Each step is one agent, one file, one acceptance gate. Steps 1–4 can run
concurrently — they share only `types.zig`/`mem.zig`/`chars.zig`, which are
frozen. Step 5 depends on nothing but the same contract, so it can start
concurrently too; it is listed last only because it is the one that turns the
harness green.

| # | File | C source | Functions |
| --- | --- | --- | --- |
| 1 | `reader.zig` | `src/reader.c` | `yaml_parser_update_buffer`, `yaml_parser_determine_encoding` |
| 2 | `scanner.zig` | `src/scanner.c` L749–1937 | `scan`, `fetch_more_tokens`, `fetch_next_token`, `stale_simple_keys`, `save_simple_key`, `remove_simple_key`, `increase_flow_level`, `decrease_flow_level`, `roll_indent`, `unroll_indent`, and all 15 `fetch_*` |
| 3 | `scan_token.zig` | `src/scanner.c` L1938–2758 | `scan_to_next_token`, `scan_directive*`, `scan_version_directive*`, `scan_tag_directive_value`, `scan_anchor`, `scan_tag`, `scan_tag_handle`, `scan_tag_uri`, `scan_uri_escapes` |
| 4 | `scan_scalar.zig` | `src/scanner.c` L2759–3616 | `scan_block_scalar`, `scan_block_scalar_breaks`, `scan_flow_scalar`, `scan_plain_scalar` |
| 5 | `parser.zig` | `src/parser.c` | `parse`, `state_machine`, all 14 `parse_*` states, `process_empty_scalar`, `process_directives`, `append_tag_directive` |

**Acceptance for every step:** the file compiles, `zig build yaml-parity`
progresses (its diff shrinks and no previously-passing case regresses), and no
`@panic("TODO")` remains in the file. A step that cannot reproduce a C behaviour
exactly stops and says so rather than approximating.

### Step 6 — integrate

1. `zig build yaml-parity` green on all 27 seeds and all 402 suite cases.
2. `zig build yaml-parity --fuzz` clean for a sustained run; anything it finds
   gets added to `test/fuzzers/yaml-seed/`.
3. Point `src/renderers/md4x-json.zig` and `md4x-html.zig` at `src/yaml/`,
   behind a build flag so both paths stay runnable.
4. `bash scripts/diff-corpus.sh` **diff-clean** against the pre-port baseline —
   the whole-repo, all-six-renderers gate.
5. `bun scripts/run-tests.ts` green.
6. Drop the C: `build.zig.zon` dependency, `addCSourceFiles`, the `yaml.h`
   `@cImport`s — except in `parity.zig`, which keeps the C forever as the
   oracle. Re-measure the wasm.

### Step 7 — the improvements the port unlocks

Only after step 6 is merged, each with its own corpus diff:

- Zero-copy scalars — point into the input instead of `strdup`ing every one.
- Replace the renderer-side `YAML_MAX_DEPTH` truncation in `md4x-json.zig` with
  the parser's own bounded stack.
- Drop `link_libc` from the wasm target once `std.c.malloc` and the stdio diag
  sink are the only remaining users.

## Risks

- **Silent divergence on inputs the corpus does not reach.** Mitigated by
  differential fuzzing being the gate, not an afterthought — and by keeping the
  C oracle in-tree permanently.
- **Scanner subtleties** (simple-key rewind, indent rolling, the 1024-character
  implicit-key limit, tab handling) are where every YAML implementation
  disagrees. These are ported verbatim, not re-derived.
- **Zig `std` churn.** The harness reads files through libc, as
  `src/cli/md4x-cli.zig` already does, rather than through the moving `std.Io`.
