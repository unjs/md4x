//! Differential harness: the Zig port against the vendored C libyaml.
//!
//! Both parsers are driven over the same bytes and each event stream is
//! serialised to the yaml-test-suite event format — the one libyaml's own
//! `tests/run-parser-test-suite.c` prints:
//!
//!     +STR
//!     +DOC ---
//!     +MAP
//!     =VAL :title
//!     =VAL "Hello
//!     -MAP
//!     -DOC
//!     -STR
//!
//! Two deliberate additions to that format, because a port can diverge on a
//! failure just as easily as on a success:
//!
//!   * `ERR <kind> <line>:<column> <context> / <problem>` is appended when the
//!     parse stops early. The `problem` strings are compile-time literals in
//!     both implementations, so comparing them pins the exact branch that
//!     rejected the input, not merely the fact that something did.
//!   * `=VAL` values are escaped (`\\`, `\0`, `\b`, `\n`, `\r`, `\t`) exactly
//!     as upstream's `print_escaped`, so a scalar carrying a NUL or a stray CR
//!     still round-trips through the comparison.
//!
//! Run:
//!   zig build yaml-parity                # corpus + inline cases
//!   zig build yaml-parity --fuzz         # coverage-guided differential fuzzing
//!
//! The harness is the gate for the whole port: until it is green on the corpus
//! AND under fuzzing, nothing in `src/renderers/` may be pointed at the Zig
//! side. See PLAN.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

const yaml = @import("yaml.zig");

/// The vendored C libyaml, built from the same `build.zig.zon` pin the shipped
/// artifacts use — the oracle has to be the exact code being replaced.
const c = @cImport({
    @cInclude("yaml.h");
});

/// Largest input handed to the fuzzer per iteration. The parsers have their own
/// nesting caps; this only bounds per-iteration work.
const max_input = 1 << 16;

const Sink = std.ArrayListUnmanaged(u8);

// ---- Shared formatting ----

/// `print_escaped` from `tests/run-parser-test-suite.c`.
fn appendEscaped(out: *Sink, alloc: Allocator, value: []const u8) Allocator.Error!void {
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(alloc, "\\\\"),
            0 => try out.appendSlice(alloc, "\\0"),
            8 => try out.appendSlice(alloc, "\\b"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, ch),
        }
    }
}

fn appendUsize(out: *Sink, alloc: Allocator, value: usize) Allocator.Error!void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try out.appendSlice(alloc, s);
}

/// `ERR <kind> <line>:<column> <context> / <problem>`
fn appendError(
    out: *Sink,
    alloc: Allocator,
    kind: []const u8,
    line: usize,
    column: usize,
    context: ?[]const u8,
    problem: ?[]const u8,
) Allocator.Error!void {
    try out.appendSlice(alloc, "ERR ");
    try out.appendSlice(alloc, kind);
    try out.append(alloc, ' ');
    try appendUsize(out, alloc, line);
    try out.append(alloc, ':');
    try appendUsize(out, alloc, column);
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, context orelse "-");
    try out.appendSlice(alloc, " / ");
    try out.appendSlice(alloc, problem orelse "-");
    try out.append(alloc, '\n');
}

fn errorKindName(kind: yaml.ErrorType) []const u8 {
    return switch (kind) {
        .none => "none",
        .memory => "memory",
        .reader => "reader",
        .scanner => "scanner",
        .parser => "parser",
        .composer => "composer",
        .writer => "writer",
        .emitter => "emitter",
    };
}

fn cErrorKindName(kind: c_uint) []const u8 {
    return switch (kind) {
        c.YAML_NO_ERROR => "none",
        c.YAML_MEMORY_ERROR => "memory",
        c.YAML_READER_ERROR => "reader",
        c.YAML_SCANNER_ERROR => "scanner",
        c.YAML_PARSER_ERROR => "parser",
        c.YAML_COMPOSER_ERROR => "composer",
        c.YAML_WRITER_ERROR => "writer",
        c.YAML_EMITTER_ERROR => "emitter",
        else => "?",
    };
}

fn cStr(p: ?[*:0]const u8) ?[]const u8 {
    return if (p) |s| std.mem.span(s) else null;
}

// ---- The Zig port ----

pub fn dumpZig(alloc: Allocator, input: []const u8, out: *Sink) Allocator.Error!void {
    var p = yaml.init(alloc) catch |e| return e;
    defer yaml.deinit(&p);
    yaml.setInputString(&p, input);

    while (true) {
        var event: yaml.Event = .{};
        yaml.parse(&p, &event) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            try appendError(
                out,
                alloc,
                errorKindName(p.err),
                p.problem_mark.line,
                p.problem_mark.column,
                p.context,
                p.problem,
            );
            return;
        };
        defer event.deinit(alloc);

        switch (event.data) {
            .none => try out.appendSlice(alloc, "???\n"),
            .stream_start => try out.appendSlice(alloc, "+STR\n"),
            .stream_end => try out.appendSlice(alloc, "-STR\n"),
            .document_start => |d| {
                try out.appendSlice(alloc, "+DOC");
                if (!d.implicit) try out.appendSlice(alloc, " ---");
                try out.append(alloc, '\n');
            },
            .document_end => |d| {
                try out.appendSlice(alloc, "-DOC");
                if (!d.implicit) try out.appendSlice(alloc, " ...");
                try out.append(alloc, '\n');
            },
            .mapping_start => |d| {
                try out.appendSlice(alloc, "+MAP");
                if (d.anchor) |a| {
                    try out.appendSlice(alloc, " &");
                    try out.appendSlice(alloc, a);
                }
                if (d.tag) |t| {
                    try out.appendSlice(alloc, " <");
                    try out.appendSlice(alloc, t);
                    try out.append(alloc, '>');
                }
                try out.append(alloc, '\n');
            },
            .mapping_end => try out.appendSlice(alloc, "-MAP\n"),
            .sequence_start => |d| {
                try out.appendSlice(alloc, "+SEQ");
                if (d.anchor) |a| {
                    try out.appendSlice(alloc, " &");
                    try out.appendSlice(alloc, a);
                }
                if (d.tag) |t| {
                    try out.appendSlice(alloc, " <");
                    try out.appendSlice(alloc, t);
                    try out.append(alloc, '>');
                }
                try out.append(alloc, '\n');
            },
            .sequence_end => try out.appendSlice(alloc, "-SEQ\n"),
            .scalar => |d| {
                try out.appendSlice(alloc, "=VAL");
                if (d.anchor) |a| {
                    try out.appendSlice(alloc, " &");
                    try out.appendSlice(alloc, a);
                }
                if (d.tag) |t| {
                    try out.appendSlice(alloc, " <");
                    try out.appendSlice(alloc, t);
                    try out.append(alloc, '>');
                }
                try out.appendSlice(alloc, switch (d.style) {
                    .plain => " :",
                    .single_quoted => " '",
                    .double_quoted => " \"",
                    .literal => " |",
                    .folded => " >",
                    // upstream aborts here; recording it keeps the harness from
                    // hiding a port bug behind a crash
                    .any => " ?",
                });
                try appendEscaped(out, alloc, d.value);
                try out.append(alloc, '\n');
            },
            .alias => |d| {
                try out.appendSlice(alloc, "=ALI *");
                try out.appendSlice(alloc, d.anchor);
                try out.append(alloc, '\n');
            },
        }

        if (event.data == .stream_end) break;
    }
}

// ---- The C oracle ----

pub fn dumpC(alloc: Allocator, input: []const u8, out: *Sink) Allocator.Error!void {
    var p: c.yaml_parser_t = undefined;
    if (c.yaml_parser_initialize(&p) == 0) return error.OutOfMemory;
    defer c.yaml_parser_delete(&p);
    c.yaml_parser_set_input_string(&p, input.ptr, input.len);

    while (true) {
        var event: c.yaml_event_t = undefined;
        if (c.yaml_parser_parse(&p, &event) == 0) {
            try appendError(
                out,
                alloc,
                cErrorKindName(p.@"error"),
                p.problem_mark.line,
                p.problem_mark.column,
                cStr(p.context),
                cStr(p.problem),
            );
            return;
        }
        defer c.yaml_event_delete(&event);

        switch (event.type) {
            c.YAML_NO_EVENT => try out.appendSlice(alloc, "???\n"),
            c.YAML_STREAM_START_EVENT => try out.appendSlice(alloc, "+STR\n"),
            c.YAML_STREAM_END_EVENT => try out.appendSlice(alloc, "-STR\n"),
            c.YAML_DOCUMENT_START_EVENT => {
                try out.appendSlice(alloc, "+DOC");
                if (event.data.document_start.implicit == 0) try out.appendSlice(alloc, " ---");
                try out.append(alloc, '\n');
            },
            c.YAML_DOCUMENT_END_EVENT => {
                try out.appendSlice(alloc, "-DOC");
                if (event.data.document_end.implicit == 0) try out.appendSlice(alloc, " ...");
                try out.append(alloc, '\n');
            },
            c.YAML_MAPPING_START_EVENT => {
                try out.appendSlice(alloc, "+MAP");
                try appendCAnchorTag(out, alloc, event.data.mapping_start.anchor, event.data.mapping_start.tag);
                try out.append(alloc, '\n');
            },
            c.YAML_MAPPING_END_EVENT => try out.appendSlice(alloc, "-MAP\n"),
            c.YAML_SEQUENCE_START_EVENT => {
                try out.appendSlice(alloc, "+SEQ");
                try appendCAnchorTag(out, alloc, event.data.sequence_start.anchor, event.data.sequence_start.tag);
                try out.append(alloc, '\n');
            },
            c.YAML_SEQUENCE_END_EVENT => try out.appendSlice(alloc, "-SEQ\n"),
            c.YAML_SCALAR_EVENT => {
                try out.appendSlice(alloc, "=VAL");
                try appendCAnchorTag(out, alloc, event.data.scalar.anchor, event.data.scalar.tag);
                try out.appendSlice(alloc, switch (event.data.scalar.style) {
                    c.YAML_PLAIN_SCALAR_STYLE => " :",
                    c.YAML_SINGLE_QUOTED_SCALAR_STYLE => " '",
                    c.YAML_DOUBLE_QUOTED_SCALAR_STYLE => " \"",
                    c.YAML_LITERAL_SCALAR_STYLE => " |",
                    c.YAML_FOLDED_SCALAR_STYLE => " >",
                    else => " ?",
                });
                try appendEscaped(out, alloc, event.data.scalar.value[0..event.data.scalar.length]);
                try out.append(alloc, '\n');
            },
            c.YAML_ALIAS_EVENT => {
                try out.appendSlice(alloc, "=ALI *");
                try out.appendSlice(alloc, std.mem.span(event.data.alias.anchor));
                try out.append(alloc, '\n');
            },
            else => try out.appendSlice(alloc, "???\n"),
        }

        if (event.type == c.YAML_STREAM_END_EVENT) break;
    }
}

fn appendCAnchorTag(out: *Sink, alloc: Allocator, anchor: ?[*:0]u8, tag: ?[*:0]u8) Allocator.Error!void {
    if (anchor) |a| {
        try out.appendSlice(alloc, " &");
        try out.appendSlice(alloc, std.mem.span(a));
    }
    if (tag) |t| {
        try out.appendSlice(alloc, " <");
        try out.appendSlice(alloc, std.mem.span(t));
        try out.append(alloc, '>');
    }
}

// ---- Comparison ----

/// Compare the two event streams for one input. Returns null when they agree,
/// or an owned diff report naming the first line that differs.
pub fn diff(alloc: Allocator, input: []const u8) Allocator.Error!?[]u8 {
    var zig_out: Sink = .empty;
    defer zig_out.deinit(alloc);
    var c_out: Sink = .empty;
    defer c_out.deinit(alloc);

    try dumpZig(alloc, input, &zig_out);
    try dumpC(alloc, input, &c_out);

    if (std.mem.eql(u8, zig_out.items, c_out.items)) return null;

    var report: Sink = .empty;
    errdefer report.deinit(alloc);

    var zig_lines = std.mem.splitScalar(u8, zig_out.items, '\n');
    var c_lines = std.mem.splitScalar(u8, c_out.items, '\n');
    var line_no: usize = 1;
    while (true) : (line_no += 1) {
        const z = zig_lines.next();
        const cl = c_lines.next();
        if (z == null and cl == null) break;
        const zs = z orelse "<end>";
        const cs = cl orelse "<end>";
        if (!std.mem.eql(u8, zs, cs)) {
            try report.appendSlice(alloc, "first divergence at event line ");
            try appendUsize(&report, alloc, line_no);
            try report.appendSlice(alloc, "\n  C  : ");
            try report.appendSlice(alloc, cs);
            try report.appendSlice(alloc, "\n  zig: ");
            try report.appendSlice(alloc, zs);
            try report.append(alloc, '\n');
            break;
        }
    }

    try report.appendSlice(alloc, "--- input ---\n");
    try appendEscaped(&report, alloc, input);
    try report.appendSlice(alloc, "\n--- C ---\n");
    try report.appendSlice(alloc, c_out.items);
    try report.appendSlice(alloc, "--- zig ---\n");
    try report.appendSlice(alloc, zig_out.items);

    return try report.toOwnedSlice(alloc);
}

/// Fail the current test if the two implementations disagree on `input`.
pub fn expectParity(alloc: Allocator, input: []const u8) !void {
    const report = try diff(alloc, input) orelse return;
    defer alloc.free(report);
    std.debug.print("\nYAML parity divergence\n{s}\n", .{report});
    return error.YamlParityDivergence;
}

// ---- Corpus ----

/// Directories walked by the corpus test, relative to the build root.
///
/// `test/fuzzers/yaml-seed` is tracked; `test/fuzzers/yaml-corpus` is where
/// `scripts/fetch-yaml-corpus.sh` drops the official yaml-test-suite (gitignored,
/// several hundred cases) and is skipped when absent.
const corpus_dirs = [_][]const u8{
    "test/fuzzers/yaml-seed",
    "test/fuzzers/yaml-corpus",
};

/// Directory listing and file reads go through libc, not `std.Io`.
///
/// `src/cli/md4x-cli.zig` already reaches for libc `fopen`/`fread` for exactly
/// this reason, and this binary links libc anyway (it has to — it embeds C
/// libyaml). Keeping the harness on the same footing avoids re-churning it
/// every time `std.Io` moves, and the corpus walk is dev tooling: it is skipped
/// entirely on Windows, where CI does not run it.
const libc = if (@import("builtin").os.tag == .windows) struct {} else struct {
    const DIR = opaque {};
    const FILE = opaque {};
    // Only `d_name` is read, and always through the accessor below, so the
    // layout difference between the glibc/musl/BSD `dirent` shapes does not
    // matter: `d_name` is last on all of them and NUL-terminated.
    extern fn opendir(name: [*:0]const u8) ?*DIR;
    extern fn readdir(dir: *DIR) ?*align(8) anyopaque;
    extern fn closedir(dir: *DIR) c_int;
    extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
    extern fn fclose(stream: *FILE) c_int;

    /// `d_name`'s offset in `struct dirent`: 8 (ino) + 8 (off) + 2 (reclen) +
    /// 1 (type) on Linux, and 8 + 2 + 1 + 1 on the BSDs/Darwin.
    const d_name_offset: usize = switch (@import("builtin").os.tag) {
        .linux => 19,
        else => 21,
    };

    fn entryName(entry: *align(8) anyopaque) [:0]const u8 {
        const base: [*]const u8 = @ptrCast(entry);
        return std.mem.span(@as([*:0]const u8, @ptrCast(base + d_name_offset)));
    }
};

fn readFileAlloc(alloc: Allocator, path: [:0]const u8) !?[]u8 {
    const f = libc.fopen(path.ptr, "rb") orelse return null;
    defer _ = libc.fclose(f);

    var out: Sink = .empty;
    errdefer out.deinit(alloc);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = libc.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        try out.appendSlice(alloc, chunk[0..n]);
        if (out.items.len > max_input) break;
    }
    return try out.toOwnedSlice(alloc);
}

fn checkCorpusDir(alloc: Allocator, path: []const u8, checked: *usize) !void {
    if (@import("builtin").os.tag == .windows) return;

    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);
    const dir = libc.opendir(path_z.ptr) orelse return; // absent corpus is fine
    defer _ = libc.closedir(dir);

    while (libc.readdir(dir)) |entry| {
        const name = libc.entryName(entry);
        if (name.len == 0 or name[0] == '.') continue;

        const full = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ path, name }, 0);
        defer alloc.free(full);

        const bytes = (try readFileAlloc(alloc, full)) orelse continue;
        defer alloc.free(bytes);

        expectParity(alloc, bytes) catch |e| {
            std.debug.print("  (input: {s})\n", .{full});
            return e;
        };
        checked.* += 1;
    }
}

// ---- Tests ----

const testing = std.testing;

/// The shapes md4x actually meets in frontmatter, plus the ones that have
/// historically diverged between YAML implementations.
const inline_cases = [_][]const u8{
    "",
    "\n",
    "---\n",
    "title: Hello\n",
    "title: Hello\ndescription: A test\n",
    "count: 42\nratio: 1.5\nflag: true\nnope: no\nnil: ~\n",
    "tags: [a, b, c]\n",
    "nested:\n  a: 1\n  b:\n    - x\n    - y\n",
    "quoted: \"a \\\"b\\\" c\"\nsingle: 'it''s'\n",
    "literal: |\n  line one\n  line two\n",
    "folded: >\n  line one\n  line two\n",
    "keep: |+\n  text\n\n\nstrip: |-\n  text\n",
    "anchor: &a value\nalias: *a\n",
    "merge:\n  <<: *a\n  b: 2\n",
    "tagged: !!str 123\ncustom: !mytag value\n",
    "%YAML 1.1\n---\nkey: value\n",
    "%TAG !e! tag:example.com,2000:\n---\n!e!foo bar\n",
    "empty:\nnull_value: null\n",
    "? complex\n: mapping\n",
    "- a\n- b\n- c\n",
    "a: 1\n---\nb: 2\n",
    "a: 1\n...\n",
    "key: value # comment\n# full line\n",
    "\tleading tab\n",
    "key:\tvalue\n",
    "unclosed: [a, b\n",
    "unclosed: \"a\n",
    "bad indent:\n a: 1\n  b: 2\n",
    ": no key\n",
    "a: b: c\n",
    "\x00\n",
    "key: v\x00alue\n",
    "\xef\xbb\xbfkey: value\n",
    "key: \xc3\xa9\xe2\x82\xac\xf0\x9f\x92\xa9\n",
    "key: \xff\xfe invalid utf8\n",
    "[[[[[[[[[[[[[[[[[[[[",
    "{{{{{{{{{{{{{{{{{{{{",
    "- - - - - - - - - -\n",
    "a:\n- 1\n- 2\n",
    "very_long_plain: " ++ "x" ** 300 ++ "\n",
};

test {
    // Pull the port's own unit tests into this binary, so `zig build
    // yaml-parity` is the single command for everything under src/yaml/.
    _ = @import("mem.zig");
    _ = @import("chars.zig");
    _ = @import("types.zig");
    _ = @import("api.zig");
    _ = @import("yaml.zig");
}

test "parity: inline cases" {
    for (inline_cases) |input| try expectParity(testing.allocator, input);
}

test "parity: corpus" {
    var checked: usize = 0;
    for (corpus_dirs) |dir| try checkCorpusDir(testing.allocator, dir, &checked);
    // Not an assertion on the count: the fetched suite is optional, and the
    // tracked seed dir is small on purpose.
    if (checked == 0) std.debug.print("(no corpus files found; ran inline cases only)\n", .{});
}

test "parity: fuzz" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            @disableInstrumentation();
            var buf: [max_input]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            try expectParity(testing.allocator, input);
        }
    }.one, .{ .corpus = &inline_cases });
}
