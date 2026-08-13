// SPDX-License-Identifier: MIT
//
// Shared JSON writer + YAML-to-JSON helpers for the md4x renderers.
//
// This is the Zig counterpart of the (orphaned) header-only md4x-json.h. The C
// header's helpers are `static`, so @cImport translates them as unresolved
// external references (which the WASM linker cannot satisfy). The streaming JSON
// writer and the YAML-to-JSON conversion are therefore ported to Zig here and
// shared by the AST and meta renderers. Behavior is kept byte-for-byte identical
// to the C source, including YAML 1.1 type coercion.
//
// Imported (not @cImport'd into a clashing symbol) by each renderer lib: Zig
// compiles its own internal copy per importing artifact, so there is no
// exported-symbol collision and no build.zig change is required.

const std = @import("std");
const scan = @import("../scan.zig");

// MD_* types now come from the Zig-native abi module (replacing md4x.h).
const c = @import("abi");
// stdio.h is gone with the last `snprintf` (the `\u00xx` escape is open-coded
// below), and libyaml is gone with the pure-Zig port in src/yaml/ — this file
// has no C dependency left.
const yaml = @import("../yaml/yaml.zig");

// The YAML parser allocates (its buffers, its token queue, every scalar it
// produces). libyaml reached `malloc` directly; the port takes an allocator, and
// the renderers' idiom for one is `std.heap.c_allocator` (see md4x-ast.zig) —
// the same heap, so the allocation behaviour is unchanged.
const c_allocator = std.heap.c_allocator;

// Non-optional, like the five required SAX callbacks: every sink here is called
// unconditionally, so a null one was a null-function-pointer call (a panic in
// Debug/ReleaseSafe, UB in the shipping ReleaseFast). Making it non-optional
// turns "forgot the sink" into a compile error instead. `md_heal` already took
// a non-optional `*const fn`; this is the rest of the subsystem catching up.
pub const ProcessOutputFn = *const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void;

// Streaming JSON writer (mirrors the C JSON_WRITER struct).
//
// Writes are COALESCED through `buf` rather than handed to `process_output` one
// at a time. JSON is punctuation-dense — the AST serializer spends most of its
// calls on a single `,`, `"`, `[` or `{` — and every one of those used to cost
// an indirect call into the sink plus, in each of the three sinks, a capacity
// check and a `memcpy` of one or two bytes. Over a 1 MB document that was
// ~13% of the render in the CLI's `ArrayList.appendSlice` sink alone, before
// counting the `memcpy` calls it made.
//
// The sink is only reached once per full buffer (or once per large string, see
// below), so it sees a handful of big appends instead of ~90 000 tiny ones.
//
// **Every entry point that builds a JsonWriter must `json_flush` it before
// returning**, or the tail of the document is silently dropped. There is no
// deinit to hang it off — the struct is a plain value with no allocation.
pub const JsonWriter = struct {
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    buf: [8192]u8 = undefined,
    len: usize = 0,
};

// Strings at least this long skip the buffer and go straight to the sink: the
// copy into `buf` would cost as much as the sink's own copy, and a long run of
// them (a big code block, a raw HTML block) would otherwise flush every time.
const passthrough_threshold: usize = 1024;

pub fn json_flush(w: *JsonWriter) void {
    if (w.len > 0) {
        w.process_output(@ptrCast(&w.buf), @intCast(w.len), w.userdata);
        w.len = 0;
    }
}

pub fn json_write(w: *JsonWriter, data: [*]const u8, size: c.MD_SIZE) void {
    const n: usize = size;
    if (n >= passthrough_threshold) {
        // Ordering matters: whatever is buffered precedes this string.
        json_flush(w);
        w.process_output(@ptrCast(data), size, w.userdata);
        return;
    }
    if (w.len + n > w.buf.len)
        json_flush(w);
    @memcpy(w.buf[w.len..][0..n], data[0..n]);
    w.len += n;
}

// Write a sentinel-terminated string slice (length known at the type level).
pub fn json_write_str(w: *JsonWriter, str: [:0]const u8) void {
    json_write(w, str.ptr, @intCast(str.len));
}

// Write a NUL-terminated string pointer (length computed via strlen).
pub fn json_write_strz(w: *JsonWriter, str: [*:0]const u8) void {
    json_write(w, str, @intCast(std.mem.len(str)));
}

// Find the next offset >= `start` needing a JSON escape — `"`, `\`, or any
// control character below 0x20 — or `size` if there is none. Exactly the set
// the switch below produces a `replacement` for; everything else is copied
// through verbatim in one run.
fn next_json_esc(str: [*]const u8, start: c.MD_OFFSET, size: c.MD_SIZE) c.MD_OFFSET {
    return @intCast(scan.indexOfAnyPos("\"\\", 0x20, str, start, size));
}

pub fn json_write_escaped(w: *JsonWriter, str: [*]const u8, size: c.MD_SIZE) void {
    var i: c.MD_OFFSET = 0;
    var beg: c.MD_OFFSET = 0;
    var esc: [8]u8 = undefined;

    // Skipping to the next escape rather than testing every byte is the single
    // biggest win in the AST renderer: this function was ~18% of a `--format=json`
    // render, and nearly every byte of a document needs no escaping at all.
    while (true) {
        i = next_json_esc(str, i, size);
        if (i >= size) break;
        const ch: u8 = str[i];
        var replacement: ?[*]const u8 = null;
        var esc_len: c_int = 0;

        switch (ch) {
            '"' => replacement = "\\\"",
            '\\' => replacement = "\\\\",
            0x08 => replacement = "\\b",
            0x0C => replacement = "\\f",
            '\n' => replacement = "\\n",
            '\r' => replacement = "\\r",
            '\t' => replacement = "\\t",
            else => {
                if (ch < 0x20) {
                    // `snprintf("\\u%04x")` open-coded: the value is always a
                    // single byte, so the two low nibbles are the whole number
                    // and the high two digits are constant.
                    const hex = "0123456789abcdef";
                    esc[0] = '\\';
                    esc[1] = 'u';
                    esc[2] = '0';
                    esc[3] = '0';
                    esc[4] = hex[ch >> 4];
                    esc[5] = hex[ch & 0x0f];
                    replacement = &esc;
                    esc_len = 6;
                }
            },
        }

        if (replacement) |rep| {
            if (i > beg)
                json_write(w, str + beg, i - beg);
            if (esc_len == 0)
                esc_len = @intCast(std.mem.len(@as([*:0]const u8, @ptrCast(rep))));
            json_write(w, rep, @intCast(esc_len));
            beg = i + 1;
        }
        i += 1;
    }

    if (i > beg)
        json_write(w, str + beg, i - beg);
}

pub fn json_write_string(w: *JsonWriter, str: [*]const u8, size: c.MD_SIZE) void {
    json_write(w, "\"", 1);
    json_write_escaped(w, str, size);
    json_write(w, "\"", 1);
}

// ---- YAML-to-JSON (md4x-json.h: json_write_yaml_*) ----

// Helper: check if a string matches a literal (case-insensitive, known length).
fn yaml_streq_ci(s: [*]const u8, len: c.MD_SIZE, lit: []const u8) bool {
    if (len != lit.len)
        return false;
    var i: c.MD_SIZE = 0;
    while (i < len) : (i += 1) {
        var ch = s[i];
        if (ch >= 'A' and ch <= 'Z')
            ch += 32;
        if (ch != lit[i])
            return false;
    }
    return true;
}

// Helper: check if a value string looks like a JSON number.
fn yaml_is_number(s: [*]const u8, len: c.MD_SIZE) bool {
    var i: c.MD_SIZE = 0;
    var has_digit = false;
    var has_dot = false;

    if (len == 0)
        return false;

    // Optional leading sign.
    if (s[0] == '-' or s[0] == '+') {
        i += 1;
        if (i >= len)
            return false;
    }

    while (i < len) : (i += 1) {
        if (s[i] >= '0' and s[i] <= '9') {
            has_digit = true;
        } else if (s[i] == '.' and !has_dot) {
            has_dot = true;
        } else {
            return false;
        }
    }
    return has_digit;
}

// Write a YAML scalar as a typed JSON value (YAML 1.1 resolution for plain scalars).
fn json_write_yaml_scalar(w: *JsonWriter, event: *const yaml.Event) void {
    const d = event.data.scalar;
    const val: [*]const u8 = d.value.ptr;
    const len: c.MD_SIZE = @intCast(d.value.len);
    const style = d.style;

    // Quoted scalars are always strings.
    if (style == .single_quoted or style == .double_quoted) {
        json_write_string(w, val, len);
        return;
    }

    // Plain scalars: apply type coercion.
    if (len == 0) {
        json_write_str(w, "null");
        return;
    }
    if (yaml_streq_ci(val, len, "null") or (len == 1 and val[0] == '~')) {
        json_write_str(w, "null");
        return;
    }
    if (yaml_streq_ci(val, len, "true") or yaml_streq_ci(val, len, "yes") or yaml_streq_ci(val, len, "on")) {
        json_write_str(w, "true");
        return;
    }
    if (yaml_streq_ci(val, len, "false") or yaml_streq_ci(val, len, "no") or yaml_streq_ci(val, len, "off")) {
        json_write_str(w, "false");
        return;
    }
    if (yaml_is_number(val, len)) {
        json_write(w, val, len);
        return;
    }

    // Default: string (also covers literal/folded block scalars).
    json_write_string(w, val, len);
}

// ---- Malformed-YAML contract ----
//
// `JsonWriter` streams straight through `process_output`: bytes handed to the
// sink cannot be retracted, and the YAML parser reports a syntax error only once
// it has already emitted the events preceding it. So a mid-mapping error is repaired
// *forward*, never rolled back. Every function below upholds one invariant:
//
//   **on return — success or error — the JSON it emitted is balanced.**
//
// Concretely: a container it opened is always closed, and a position that
// syntactically demands a value always receives one (`null` when nothing could
// be parsed). What is kept is therefore the prefix the parser did read, plus an
// explicit `null` for the key whose value it did not. Dropping the failing key
// instead would make a truncated document indistinguishable from one where the
// author simply omitted the field.

// ---- Nesting cap ----
//
// The functions below walk the YAML event stream RECURSIVELY (event -> mapping
// / sequence -> value -> event), so the document's nesting depth is the native
// recursion depth. The parser's own `max_nest_level` is 1000 (libyaml's
// MAX_NESTING_LEVEL, which the port carries as a field) -- far past what the
// native stack survives here -- and the markdown parser imposes
// nothing at all, handing frontmatter over as opaque bytes. So `a: [[[[...` in
// frontmatter (or in a plain `.yml` through md_yaml) used to run until the
// native stack was gone: a SIGSEGV, which also skipped the AST renderer's
// `ctx.arena.deinit()` and the parser teardown (through the wasm binding it
// trapped instead, leaking ~4 MB of linear memory per attempt, unreclaimable).
// Past the cap the writer emits `null` and ENDS the parse; see
// json_write_yaml_truncate().
//
// Ending it, rather than skipping to the end of the offending subtree, is also
// what bounds the CPU. Flow-collection handling is O(depth^2) -- libyaml's, and
// the port reproduces it exactly --
// `a: [` x n through `--format=json` measures 1.2 s at n = 25 000, 4.6 s at
// 50 000, 19.1 s at 100 000, 96.3 s at 200 000, and the same curve on a build
// from before this cap existed, so it is a separate pre-existing defect, driven
// by nesting depth alone (50 000 flat keys cost 0.03 s). Any design that keeps
// reading events past the cap pays that quadratic in full; stopping at the cap
// makes the cost of a deep document independent of how deep it is.
//
// This is the same mechanism as the AST renderer's JSON_MAX_DEPTH /
// jsonAtMaxDepth() (src/renderers/md4x-ast.zig), sized for a much heavier
// frame. Measured headroom (balanced `'[' * n + ']' * n` in frontmatter,
// binary-searched against the uncapped build under `ulimit -s`, so the numbers
// are where the recursion actually dies; measured against the libyaml-backed
// build, whose event record and frame layout the port matches):
//
//   * native, linear in the level count -- ~177 B per level in ReleaseFast
//     (what ships; 47 280 levels on an 8 MiB stack, 2 593 on a 512 KiB one),
//     ~194 B in ReleaseSafe, ~354 B in Debug. Three frames per level, each
//     holding the ~104-byte event record by value, is what makes this
//     ~3.5x the AST serializer's ~50 B per level.
//
// 256 levels is therefore ~45 KB of stack at the cap -- about the same stack
// budget as the AST renderer's 1024 levels, which is why the two numbers
// differ. That is ~185x under a native 8 MiB stack, ~11x under a 512 KiB one,
// and still ~2.8x under a musl default 128 KiB *thread* stack (Alpine; Node
// worker threads and some edge runtimes are likewise well under the 8 MiB
// main-thread default). Real frontmatter is a config document: a deeply nested
// one is ~5 levels, so 256 is ~50x past anything a human writes.
//
// Two things this cap does NOT do, both deliberate. It is not reported in the
// output the way the AST renderer's is: the frontmatter object is a user-data
// contract with no reserved key to put a marker in, and the truncation is
// already visible as a `null` in the position that overflowed. And it does not
// keep rendering the rest of the document the way the AST renderer's does --
// see json_write_yaml_truncate() for why the keys after the overflowing one are
// dropped rather than skipped to.
const YAML_MAX_DEPTH: usize = 256;

fn yaml_at_max_depth(depth: usize) bool {
    return depth >= YAML_MAX_DEPTH;
}

// Give up on the document at the cap: write the value the position demands and
// report an error, which every caller already knows how to handle -- each one
// closes what it opened and returns without asking for another event, so the
// output stays balanced and the walk unwinds without touching the parser again.
// `json_write_yaml_props` / `md_yaml` then run their normal `yaml.deinit`
// teardown, which frees the parser's buffers, its token queue (deleting each
// queued token) and its indent/simple-key/state/mark stacks whatever state the
// parse was left in. No event is owned here either -- the START event was deleted
// by the caller before the check -- so abandoning mid-stream leaks nothing.
//
// **Stopping is the point, not a shortcut.** Consuming the rest of the subtree
// (walking to its matching END so the siblings after it could still be emitted)
// keeps the output prettier but makes the parser scan the whole nesting anyway --
// and its flow-collection handling is O(depth^2) (see the note above
// YAML_MAX_DEPTH), so a 200 KB document still burned ~96 s of one core. Ending
// the parse bounds the work at the cap instead: what is dropped is the tail of a
// document already established to be pathological.
fn json_write_yaml_truncate(w: *JsonWriter) c_int {
    json_write_str(w, "null");
    return -1;
}

// Write a YAML mapping as JSON object key-value pairs (without outer braces).
// Assumes MAPPING_START consumed. `depth` is the nesting depth of the VALUES in
// this mapping (the number of collections enclosing them). Returns 0 on
// success, -1 on error; `n_written` is incremented once per pair actually
// emitted (including a pair whose value had to be repaired to `null`, since its
// key bytes are already on the wire).
fn json_write_yaml_mapping(w: *JsonWriter, yp: *yaml.Parser, n_written: *c_int, depth: usize) c_int {
    var event: yaml.Event = .{};

    while (true) {
        yaml.parse(yp, &event) catch
            return -1;

        if (event.data == .mapping_end) {
            event.deinit(c_allocator);
            break;
        }

        const key = switch (event.data) {
            .scalar => |d| d.value,
            else => {
                // A non-scalar key (a complex `? key` mapping, or a stray
                // structural event). No byte of this pair has been written yet —
                // not even the separating comma — so stopping here already leaves
                // the object well-formed.
                event.deinit(c_allocator);
                return -1;
            },
        };

        if (n_written.* > 0)
            json_write(w, ",", 1);

        // Write key.
        json_write(w, "\"", 1);
        json_write_escaped(w, key.ptr, @intCast(key.len));
        json_write_str(w, "\":");
        event.deinit(c_allocator);

        // Write value (recursive). Past this point the key is committed, so the
        // pair counts as written whatever happens: `json_write_yaml_value`
        // guarantees it emitted *some* value at this position.
        const ret = json_write_yaml_value(w, yp, depth);
        n_written.* += 1;
        if (ret < 0)
            return -1;
    }
    return 0;
}

// Write a YAML sequence as a JSON array.
// Assumes SEQUENCE_START consumed. `depth` is the nesting depth of this
// sequence's ELEMENTS. Returns 0 on success, -1 on error.
fn json_write_yaml_sequence(w: *JsonWriter, yp: *yaml.Parser, depth: usize) c_int {
    var event: yaml.Event = .{};
    var n: c_int = 0;
    var ret: c_int = 0;

    json_write(w, "[", 1);

    while (true) {
        yaml.parse(yp, &event) catch {
            // Nothing is pending here: the comma is written only after an event
            // has been parsed successfully, so the array closes cleanly on the
            // elements seen so far.
            ret = -1;
            break;
        };

        if (event.data == .sequence_end) {
            event.deinit(c_allocator);
            break;
        }

        if (n > 0)
            json_write(w, ",", 1);

        if (json_write_yaml_event(w, yp, &event, depth) < 0) {
            ret = -1;
            break;
        }

        n += 1;
    }

    json_write(w, "]", 1);
    return ret;
}

// Write the value denoted by an already-parsed `event` as JSON. Takes ownership
// of `event` and deletes it. `depth` is the nesting depth of this value itself
// (0 for a document's root node). Returns 0 on success, -1 on error; the output
// is balanced either way (see the malformed-YAML contract above).
fn json_write_yaml_event(w: *JsonWriter, yp: *yaml.Parser, event: *yaml.Event, depth: usize) c_int {
    switch (event.data) {
        .scalar => {
            json_write_yaml_scalar(w, event);
            event.deinit(c_allocator);
            return 0;
        },
        .mapping_start => {
            event.deinit(c_allocator);
            // Too deep to nest any further (see YAML_MAX_DEPTH): the position gets
            // `null` and the walk unwinds.
            if (yaml_at_max_depth(depth))
                return json_write_yaml_truncate(w);
            json_write(w, "{", 1);
            var n: c_int = 0;
            const ret = json_write_yaml_mapping(w, yp, &n, depth + 1);
            json_write(w, "}", 1);
            return ret;
        },
        .sequence_start => {
            event.deinit(c_allocator);
            if (yaml_at_max_depth(depth))
                return json_write_yaml_truncate(w);
            return json_write_yaml_sequence(w, yp, depth + 1);
        },
        .alias => {
            // The parser does not compose, so anchors are never resolved; an
            // alias is a defined `null` rather than an error.
            event.deinit(c_allocator);
            json_write_str(w, "null");
            return 0;
        },
        else => {
            // Anything else is a structural event where a value was expected. The
            // position still needs one.
            event.deinit(c_allocator);
            json_write_str(w, "null");
            return -1;
        },
    }
}

// Write the next YAML value (scalar, mapping, or sequence) as JSON. `depth` is
// the nesting depth of that value. Returns 0 on success, -1 on error; a value
// is always emitted.
fn json_write_yaml_value(w: *JsonWriter, yp: *yaml.Parser, depth: usize) c_int {
    var event: yaml.Event = .{};

    yaml.parse(yp, &event) catch {
        json_write_str(w, "null");
        return -1;
    };

    return json_write_yaml_event(w, yp, &event, depth);
}

// Write parsed YAML frontmatter as JSON props.
// Returns the number of top-level props actually written to the output. A
// malformed document still reports what it emitted (never 0 after writing
// bytes) — callers use the count to decide whether a separating comma is
// needed before whatever they append next.
pub fn json_write_yaml_props(w: *JsonWriter, text: [*]const u8, size: c.MD_SIZE) c_int {
    var event: yaml.Event = .{};
    var n_written: c_int = 0;

    // An allocation failure here is the C's `yaml_parser_initialize` returning
    // 0: nothing has been written, so nothing is reported.
    var yp = yaml.init(c_allocator) catch
        return 0;

    yaml.setInputString(&yp, text[0..size]);

    // Consume STREAM_START.
    yaml.parse(&yp, &event) catch {
        yaml.deinit(&yp);
        return n_written;
    };
    if (event.data != .stream_start) {
        event.deinit(c_allocator);
        yaml.deinit(&yp);
        return n_written;
    }
    event.deinit(c_allocator);

    // Consume DOCUMENT_START.
    yaml.parse(&yp, &event) catch {
        yaml.deinit(&yp);
        return n_written;
    };
    if (event.data != .document_start) {
        event.deinit(c_allocator);
        yaml.deinit(&yp);
        return n_written;
    }
    event.deinit(c_allocator);

    // Expect top-level MAPPING_START.
    yaml.parse(&yp, &event) catch {
        yaml.deinit(&yp);
        return n_written;
    };
    if (event.data != .mapping_start) {
        event.deinit(c_allocator);
        yaml.deinit(&yp);
        return n_written;
    }
    event.deinit(c_allocator);

    // A mid-mapping error is already repaired in the output stream, so the
    // status is not actionable here; `n_written` is what matters. The root
    // mapping consumed just above is depth 0, so its values sit at depth 1.
    _ = json_write_yaml_mapping(w, &yp, &n_written, 1);

    yaml.deinit(&yp);
    return n_written;
}

// ---- Standalone YAML entry point ----

/// Convert a YAML document to JSON.
///
/// The YAML parser is already there for frontmatter, and consumers had no way to
/// reach it: parsing a plain `.yml` file meant wrapping it in `---` fences,
/// running it through the *markdown* meta renderer, and stripping the heading
/// list back off the result.
///
/// Unlike `json_write_yaml_props`, this accepts any root node — a sequence or a
/// bare scalar as readily as a mapping — and a stream with no document at all
/// converts to `null`, YAML's own reading of an empty file. It takes the
/// renderer signature (both trailing flag words unused) so it drops straight
/// into the existing wasm/napi wrappers.
pub fn md_yaml(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    parser_flags: c_uint,
    renderer_flags: c_uint,
) c_int {
    _ = parser_flags;
    _ = renderer_flags;

    var w: JsonWriter = .{ .process_output = process_output, .userdata = userdata };
    var event: yaml.Event = .{};

    var yp = yaml.init(c_allocator) catch
        return -1;
    defer yaml.deinit(&yp);
    // Every `return` below is a success path that has already written output.
    defer json_flush(&w);

    yaml.setInputString(&yp, input[0..input_size]);

    // Walk to the root node of the first document. Anything other than the
    // expected event -- including a syntax error and including a stream that
    // ends immediately -- means there is no value to convert.
    for ([_]yaml.EventType{ .stream_start, .document_start }) |expected| {
        yaml.parse(&yp, &event) catch {
            json_write_str(&w, "null\n");
            return 0;
        };
        const actual = event.getType();
        event.deinit(c_allocator);
        if (actual != expected) {
            json_write_str(&w, "null\n");
            return 0;
        }
    }

    yaml.parse(&yp, &event) catch {
        json_write_str(&w, "null\n");
        return 0;
    };
    // Emits a balanced value whatever the outcome (see the malformed-YAML
    // contract above), so a truncated document still yields parseable JSON.
    // The root node is depth 0 -- unlike json_write_yaml_props, no enclosing
    // mapping was consumed on the way here.
    _ = json_write_yaml_event(&w, &yp, &event, 0);
    json_write_str(&w, "\n");
    return 0;
}

// ============================================================================
// Tests
//
// These pin YAML_MAX_DEPTH itself, which no .txt suite can: `test/regressions.txt`
// can only assert on one rendered document, and the value it encodes is the cap
// *minus* the frontmatter mapping the AST path has already descended through.
// They live here rather than in src/md4x.zig because the `zig build test`
// artifact is the parser alone -- it compiles neither the renderers nor
// libyaml. `zig build fuzz-zig` compiles this file (through src/lib.zig) and
// runs them, the same way it already runs the md4x-slug.zig and md4x-heal.zig
// unit tests.
// ============================================================================

const testing = std.testing;

const TestSink = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,

    fn write(data: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) void {
        const self: *TestSink = @ptrCast(@alignCast(userdata.?));
        const bytes: [*]const u8 = @ptrCast(data);
        self.out.appendSlice(testing.allocator, bytes[0..size]) catch @panic("OOM");
    }
};

/// Run `md_yaml` over `input` and hand back the JSON it produced.
fn testYaml(input: []const u8) ![]u8 {
    var sink: TestSink = .{};
    errdefer sink.out.deinit(testing.allocator);
    try testing.expectEqual(@as(c_int, 0), md_yaml(@ptrCast(input.ptr), @intCast(input.len), TestSink.write, &sink, 0, 0));
    return sink.out.toOwnedSlice(testing.allocator);
}

/// `unit` repeated `n` times.
fn testRepeat(unit: []const u8, n: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    for (0..n) |_| try buf.appendSlice(testing.allocator, unit);
    return buf.toOwnedSlice(testing.allocator);
}

test "YAML nesting is capped at YAML_MAX_DEPTH (sequences)" {
    // Deeper than the cap by a wide margin, and balanced, so what stops the
    // descent is the cap and not a syntax error. The root sequence is depth 0,
    // so exactly YAML_MAX_DEPTH levels are kept and the next one becomes `null`.
    const n = YAML_MAX_DEPTH + 64;
    const opens = try testRepeat("[", n);
    defer testing.allocator.free(opens);
    const closes = try testRepeat("]", n);
    defer testing.allocator.free(closes);

    const input = try std.mem.concat(testing.allocator, u8, &.{ opens, closes });
    defer testing.allocator.free(input);
    const got = try testYaml(input);
    defer testing.allocator.free(got);

    const kept_open = try testRepeat("[", YAML_MAX_DEPTH);
    defer testing.allocator.free(kept_open);
    const kept_close = try testRepeat("]", YAML_MAX_DEPTH);
    defer testing.allocator.free(kept_close);
    const expected = try std.mem.concat(testing.allocator, u8, &.{ kept_open, "null", kept_close, "\n" });
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, got);
}

test "YAML nesting is capped at YAML_MAX_DEPTH (mappings)" {
    const n = YAML_MAX_DEPTH + 64;
    const opens = try testRepeat("{a: ", n);
    defer testing.allocator.free(opens);
    const closes = try testRepeat("}", n);
    defer testing.allocator.free(closes);

    const input = try std.mem.concat(testing.allocator, u8, &.{ opens, closes });
    defer testing.allocator.free(input);
    const got = try testYaml(input);
    defer testing.allocator.free(got);

    const kept_open = try testRepeat("{\"a\":", YAML_MAX_DEPTH);
    defer testing.allocator.free(kept_open);
    const kept_close = try testRepeat("}", YAML_MAX_DEPTH);
    defer testing.allocator.free(kept_close);
    const expected = try std.mem.concat(testing.allocator, u8, &.{ kept_open, "null", kept_close, "\n" });
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, got);
}

test "a YAML document is abandoned at the cap, and closes every container" {
    // The walk must unwind without reading another event -- that is what keeps
    // the cost of a deep document independent of its depth -- while still
    // closing everything it opened. So the keys after the overflowing one are
    // NOT emitted (`after` is absent), and the output is still balanced JSON.
    const n = YAML_MAX_DEPTH + 64;
    const opens = try testRepeat("[", n);
    defer testing.allocator.free(opens);
    const closes = try testRepeat("]", n);
    defer testing.allocator.free(closes);

    const input = try std.mem.concat(testing.allocator, u8, &.{ "{deep: ", opens, closes, ", after: 1}" });
    defer testing.allocator.free(input);
    const got = try testYaml(input);
    defer testing.allocator.free(got);

    try testing.expect(std.mem.startsWith(u8, got, "{\"deep\":["));
    try testing.expect(std.mem.endsWith(u8, got, "]}\n"));
    try testing.expect(std.mem.indexOf(u8, got, "after") == null);
    // One level is spent on the enclosing mapping, so the sequence keeps one
    // fewer than the two cases above.
    try testing.expectEqual(YAML_MAX_DEPTH - 1, std.mem.count(u8, got, "["));
    try testing.expectEqual(YAML_MAX_DEPTH - 1, std.mem.count(u8, got, "]"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "{"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "}"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "null"));
}

test "an unterminated deep YAML document still closes every container" {
    // Same shape, minus the closing brackets: the cap is reached before libyaml
    // ever reports the syntax error, so this must come out exactly like the
    // balanced case rather than picking up the malformed-YAML repair path.
    const n = YAML_MAX_DEPTH + 64;
    const opens = try testRepeat("[", n);
    defer testing.allocator.free(opens);

    const input = try std.mem.concat(testing.allocator, u8, &.{ "{deep: ", opens });
    defer testing.allocator.free(input);
    const got = try testYaml(input);
    defer testing.allocator.free(got);

    try testing.expect(std.mem.endsWith(u8, got, "]}\n"));
    try testing.expectEqual(std.mem.count(u8, got, "["), std.mem.count(u8, got, "]"));
    try testing.expectEqual(std.mem.count(u8, got, "{"), std.mem.count(u8, got, "}"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "null"));
}

test "YAML nesting under the cap is untouched" {
    const got = try testYaml("[[[{a: [b, {c: [d]}]}]]]");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[[[{\"a\":[\"b\",{\"c\":[\"d\"]}]}]]]\n", got);
}
