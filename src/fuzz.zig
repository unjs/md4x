//! Zig-native, coverage-instrumented fuzz harness.
//!
//! Complements the C/libFuzzer harnesses in `test/fuzzers/`. Those call the
//! public C ABI through prebuilt, NON-instrumented static libs (see the caveat
//! in `test/fuzzers/build.sh`: `zig build-obj` emits no SanitizerCoverage tables,
//! so libFuzzer gets no coverage feedback on the Zig library — it only "sees"
//! the C harness + libyaml). This file instead `@import`s the parser + renderer
//! Zig sources directly, so they are compiled into THIS test binary and Zig's
//! own fuzzer instruments them, steering inputs by real coverage of the library
//! internals.
//!
//! Run:
//!   zig build fuzz-zig --fuzz          # coverage-guided fuzzing (serves a web UI)
//!   zig build fuzz-zig                 # smoke-run: exercise each harness once
//!   zig build fuzz-zig --fuzz -- md_html   # fuzz a single named test
//!
//! Trade-offs vs the C/libFuzzer harnesses:
//!   + real coverage feedback on the Zig parser/renderers (the whole point)
//!   + single toolchain, no clang / build.sh
//!   - no ASan/UBSan; relies on Zig's runtime safety checks (the artifact is
//!     built ReleaseSafe in build.zig), which still catch OOB indexing, integer
//!     overflow, unreachable, invalid casts, etc.
//!
//! libyaml (C) is linked but not instrumented — the AST/meta/HTML renderers call
//! into it, same as the C harnesses; it is exercised, just without coverage.

const std = @import("std");

// Pulling the sources into this module (rather than linking the prebuilt static
// libs) is what gets them instrumented by `--fuzz`. Their `export fn`s
// (md_parse, md_html, ... md_heal — all distinct symbols) are emitted into the
// test binary; the matching callable declarations come from the C headers via
// the `@cImport` below, and the linker wires the two together.
// Importing the library root pulls the parser + every renderer into THIS
// module, which is what gets them instrumented by `--fuzz`.
const lib = @import("lib.zig");

// MD_* types + parser/renderer entry points come from the Zig abi module; the
// definitions are pulled into this module by the `@import` statements above, so
// abi's extern declarations resolve locally.
const c = @import("abi");

// Largest input handed to a harness per iteration. The parser has its own
// linear-time guards; this just bounds per-iteration work.
const max_input = 1 << 16;

/// No-op renderer output sink. Matches the C `void(const MD_CHAR*, MD_SIZE, void*)`
/// callback the renderers invoke; we discard output and fuzz only for crashes /
/// safety-check trips, exactly like the C harnesses' `process_output`.
fn sink(_: [*c]const c.MD_CHAR, _: c.MD_SIZE, _: ?*anyopaque) void {}

/// No-op heal output sink (heal uses `const char*, unsigned, void*`).
fn healSink(_: [*c]const u8, _: c_uint, _: ?*anyopaque) void {}

/// Gate inputs to valid, NUL-free UTF-8 — matching the C harnesses' `is_valid_utf8`
/// and the JS binding surface (where input is always a valid UTF-8 string). This
/// keeps the fuzzer on inputs reachable in production rather than chasing code
/// paths that real callers can never hit. `utf8ValidateSlice` already rejects
/// surrogates and overlong encodings.
fn accept(input: []const u8) bool {
    if (input.len == 0) return false;
    if (std.mem.indexOfScalar(u8, input, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(input);
}

/// Shared driver for the renderer harnesses. `render` is one of the `md_*`
/// entry points; all share the same signature.
fn fuzzRenderer(
    comptime render: fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void, ?*anyopaque, c_uint, c_uint) c_int,
    smith: *std.testing.Smith,
) !void {
    @disableInstrumentation();
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    if (!accept(input)) return;
    _ = render(@ptrCast(input.ptr), @intCast(input.len), sink, null, c.MD_DIALECT_ALL, 0);
}

test "md_parse" {
    // Parser-only harness: no-op SAX callbacks isolate parser bugs from renderer
    // noise and run fastest. Every renderer harness below also drives md_parse,
    // but this one maximizes parser coverage per iteration.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            @disableInstrumentation();
            var buf: [max_input]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            if (!accept(input)) return;
            var p: c.Parser = .{};
            p.flags = c.MD_DIALECT_ALL;
            const nop = struct {
                fn block(_: *const c.BlockDetail, _: ?*anyopaque) c.CallbackResult {
                    return 0;
                }
                fn span(_: *const c.SpanDetail, _: ?*anyopaque) c.CallbackResult {
                    return 0;
                }
                fn text(_: c.TextType, _: []const c.MD_CHAR, _: ?*anyopaque) c.CallbackResult {
                    return 0;
                }
            };
            p.enter_block = nop.block;
            p.leave_block = nop.block;
            p.enter_span = nop.span;
            p.leave_span = nop.span;
            p.text = nop.text;
            _ = lib.md_parse(@ptrCast(input.ptr), @intCast(input.len), &p, null);
        }
    }.one, .{});
}

test "md_html" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            try fuzzRenderer(lib.md_html, smith);
        }
    }.one, .{});
}

test "md_ast" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            try fuzzRenderer(lib.md_ast, smith);
        }
    }.one, .{});
}

test "md_ansi" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            try fuzzRenderer(lib.md_ansi, smith);
        }
    }.one, .{});
}

test "md_text" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            try fuzzRenderer(lib.md_text, smith);
        }
    }.one, .{});
}

test "md_meta" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            try fuzzRenderer(lib.md_meta, smith);
        }
    }.one, .{});
}

test "md_markdown" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            try fuzzRenderer(lib.md_markdown, smith);
        }
    }.one, .{});
}

test "md_heal" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            @disableInstrumentation();
            var buf: [max_input]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            if (!accept(input)) return;
            _ = lib.md_heal(@ptrCast(input.ptr), @intCast(input.len), healSink, null);
        }
    }.one, .{});
}
