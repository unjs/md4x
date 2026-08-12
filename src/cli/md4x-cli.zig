// MD4X command-line driver.
//
// Zig port of the former src/cli/md4x-cli.c + src/cli/cmdline.c. Behaviorally
// identical: same options, same stdout bytes, same diagnostics. File I/O uses a
// thin libc binding (a direct mirror of the C driver); argument vectors come
// from the Zig runtime (std.process.Init).
//
// Copyright (c) 2016-2024 Martin Mitáš
// Copyright (c) 2026 Pooya Parsa <pooya@pi0.io>
// MIT License (see repository LICENSE).

const std = @import("std");
const abi = @import("abi");
const lib = @import("md4x");
const build_options = @import("build_options");

const MD_CHAR = abi.MD_CHAR;
const MD_SIZE = abi.MD_SIZE;
const gpa = std.heap.c_allocator;

// ---------------------------------------------------------------------------
// Minimal libc binding (stdio + exit). Linux/glibc symbols; the CLI is built
// and tested on the host only.
// ---------------------------------------------------------------------------
const libc = struct {
    const FILE = opaque {};
    extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern fn fclose(stream: *FILE) c_int;
    extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
    extern fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;
    extern fn fputs(s: [*:0]const u8, stream: *FILE) c_int;
    extern fn exit(code: c_int) noreturn;
    extern fn clock() c_long;
    const CLOCKS_PER_SEC: c_long = 1000000;
    extern var stdin: *FILE;
    extern var stdout: *FILE;
    extern var stderr: *FILE;
};

// Formatted write to stderr (diagnostics; not part of compared output).
fn eprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    _ = libc.fputs(s, libc.stderr);
}

// ---------------------------------------------------------------------------
// Renderer entry points. They live in this artifact's module graph (Phase 4a),
// so these are direct Zig calls, not link-time C-ABI symbol resolution.
// ---------------------------------------------------------------------------
const ProcessOutput = abi.ProcessOutput;
const MD_HTML_OPTS = lib.MD_HTML_OPTS;

// ---------------------------------------------------------------------------
// Renderer flag values (mirror the former md4x-*.h headers).
// ---------------------------------------------------------------------------
const MD_HTML_FLAG_DEBUG: c_uint = 0x0001;
const MD_HTML_FLAG_SKIP_UTF8_BOM: c_uint = 0x0004;
const MD_HTML_FLAG_FULL_HTML: c_uint = 0x0008;
const MD_HTML_FLAG_HEAL: c_uint = 0x0100;

const MD_AST_FLAG_DEBUG: c_uint = 0x0001;
const MD_AST_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_AST_FLAG_HEAL: c_uint = 0x0100;

const MD_ANSI_FLAG_DEBUG: c_uint = 0x0001;
const MD_ANSI_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_ANSI_FLAG_HEAL: c_uint = 0x0100;

const MD_TEXT_FLAG_DEBUG: c_uint = 0x0001;
const MD_TEXT_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_TEXT_FLAG_HEAL: c_uint = 0x0100;

const MD_MARKDOWN_FLAG_DEBUG: c_uint = 0x0001;
const MD_MARKDOWN_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_MARKDOWN_FLAG_HEAL: c_uint = 0x0100;

const OutputFormat = enum { html, text, json, ansi, markdown, heal };

// ---------------------------------------------------------------------------
// Global options (mirror the C file's `static` globals).
// ---------------------------------------------------------------------------
var output_format: OutputFormat = .html;
var parser_flags: c_uint = abi.MD_DIALECT_ALL;
var renderer_flags: c_uint = MD_HTML_FLAG_DEBUG | MD_HTML_FLAG_SKIP_UTF8_BOM;
var want_fullhtml = false;
var want_heal = false;
var want_stat = false;
var want_replay_fuzz = false;
var html_title: ?[:0]const u8 = null;
var css_path: ?[:0]const u8 = null;
var input_path: ?[:0]const u8 = null;
var output_path: ?[:0]const u8 = null;

// ---------------------------------------------------------------------------
// Output buffer + SAX output sink.
// ---------------------------------------------------------------------------
const MemBuffer = std.ArrayListUnmanaged(u8);

fn process_output(text: [*c]const MD_CHAR, size: MD_SIZE, userdata: ?*anyopaque) void {
    const buf: *MemBuffer = @ptrCast(@alignCast(userdata.?));
    buf.appendSlice(gpa, text[0..size]) catch {
        eprint("membuf_append: out of memory.\n", .{});
        libc.exit(1);
    };
}

// Read an entire libc stream into an owned buffer.
fn read_stream(stream: *libc.FILE) []u8 {
    var buf: MemBuffer = .empty;
    var chunk: [32 * 1024]u8 = undefined;
    while (true) {
        const n = libc.fread(&chunk, 1, chunk.len, stream);
        if (n == 0) break;
        buf.appendSlice(gpa, chunk[0..n]) catch {
            eprint("read_stream: out of memory.\n", .{});
            libc.exit(1);
        };
    }
    return buf.toOwnedSlice(gpa) catch {
        eprint("read_stream: out of memory.\n", .{});
        libc.exit(1);
    };
}

fn process_file(in: *libc.FILE, out: *libc.FILE) c_int {
    var p_flags = parser_flags;
    var r_flags = renderer_flags;

    const input = read_stream(in);
    defer gpa.free(input);
    var in_size: usize = input.len;

    var out_buf: MemBuffer = .empty;
    defer out_buf.deinit(gpa);

    // Undocumented mode: replay a fuzz test case (flags prefixed to the input).
    if (want_replay_fuzz) {
        if (in_size < 2 * @sizeOf(c_uint)) {
            eprint("File isn't valid fuzz test case.\n", .{});
            return -1;
        }
        @memcpy(std.mem.asBytes(&p_flags), input[0..@sizeOf(c_uint)]);
        @memcpy(std.mem.asBytes(&r_flags), input[@sizeOf(c_uint) .. 2 * @sizeOf(c_uint)]);
        const skip = 2 * @sizeOf(c_uint);
        std.mem.copyForwards(u8, input[0 .. in_size - skip], input[skip..in_size]);
        in_size -= skip;
        @memset(input[in_size .. in_size + skip], 0);
    }

    if (want_heal)
        r_flags |= MD_HTML_FLAG_HEAL;

    const input_ptr: [*c]const MD_CHAR = input.ptr;
    const in_sz: MD_SIZE = @intCast(in_size);
    var ret: c_int = -1;

    const t0 = libc.clock();
    switch (output_format) {
        .html => {
            var html_flags = r_flags;
            var html_opts: MD_HTML_OPTS = .{};
            var opts_ptr: ?*const MD_HTML_OPTS = null;
            if (want_fullhtml) {
                html_flags |= MD_HTML_FLAG_FULL_HTML;
                html_opts.title = if (html_title) |t| t.ptr else null;
                html_opts.css_url = if (css_path) |u| u.ptr else null;
                opts_ptr = &html_opts;
            }
            ret = lib.md_html_ex(input_ptr, in_sz, process_output, &out_buf, p_flags, html_flags, opts_ptr);
        },
        .json => {
            var j_flags = MD_AST_FLAG_DEBUG | MD_AST_FLAG_SKIP_UTF8_BOM;
            if (want_heal) j_flags |= MD_AST_FLAG_HEAL;
            ret = lib.md_ast(input_ptr, in_sz, process_output, &out_buf, p_flags, j_flags);
        },
        .ansi => {
            var a_flags = MD_ANSI_FLAG_DEBUG | MD_ANSI_FLAG_SKIP_UTF8_BOM;
            if (want_heal) a_flags |= MD_ANSI_FLAG_HEAL;
            ret = lib.md_ansi(input_ptr, in_sz, process_output, &out_buf, p_flags, a_flags);
        },
        .text => {
            var t_flags = MD_TEXT_FLAG_DEBUG | MD_TEXT_FLAG_SKIP_UTF8_BOM;
            if (want_heal) t_flags |= MD_TEXT_FLAG_HEAL;
            ret = lib.md_text(input_ptr, in_sz, process_output, &out_buf, p_flags, t_flags);
        },
        .markdown => {
            var pm_flags = MD_MARKDOWN_FLAG_DEBUG | MD_MARKDOWN_FLAG_SKIP_UTF8_BOM;
            if (want_heal) pm_flags |= MD_MARKDOWN_FLAG_HEAL;
            ret = lib.md_markdown(input_ptr, in_sz, process_output, &out_buf, p_flags, pm_flags);
        },
        .heal => {
            ret = lib.md_heal(input.ptr, in_sz, process_output, &out_buf);
        },
    }

    const t1 = libc.clock();
    if (ret != 0) {
        eprint("Parsing failed.\n", .{});
        return ret;
    }

    if (out_buf.items.len > 0)
        _ = libc.fwrite(out_buf.items.ptr, 1, out_buf.items.len, out);

    if (want_stat and t0 != -1 and t1 != -1) {
        const elapsed = @as(f64, @floatFromInt(t1 - t0)) / @as(f64, @floatFromInt(libc.CLOCKS_PER_SEC));
        if (elapsed < 1)
            eprint("Time spent on parsing: {d:7.2} ms.\n", .{elapsed * 1e3})
        else
            eprint("Time spent on parsing: {d:6.3} s.\n", .{elapsed});
    }

    return 0;
}

// ---------------------------------------------------------------------------
// Help / version.
// ---------------------------------------------------------------------------
fn usage() void {
    _ = libc.fputs(
        "Usage: md4x [OPTION]... [FILE]\n" ++
            "Convert input FILE (or standard input) in Markdown format.\n" ++
            "\n" ++
            "General options:\n" ++
            "  -o  --output=FILE    Output file (default is standard output)\n" ++
            "  -t, --format=FORMAT  Output format: html (default), text, json, ansi, markdown, heal\n" ++
            "      --heal           Heal incomplete markdown before rendering\n" ++
            "  -s, --stat           Measure time of input parsing\n" ++
            "  -h, --help           Display this help and exit\n" ++
            "  -v, --version        Display version and exit\n" ++
            "\n" ++
            "HTML output options:\n" ++
            "  -f, --full-html      Generate full HTML document, including header\n" ++
            "      --html-title=TITLE Sets the title of the document\n" ++
            "      --html-css=URL   In full HTML mode add a css link\n" ++
            "\n",
        libc.stdout,
    );
}

fn version() void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "{s}\n", .{build_options.version}) catch return;
    _ = libc.fputs(s, libc.stdout);
}

// ---------------------------------------------------------------------------
// Argument parsing (port of cmdline.c for this program's option set).
// ---------------------------------------------------------------------------
const Opt = struct {
    short: u8, // 0 for none
    long: ?[]const u8,
    id: u8,
    required_arg: bool,
};

const options = [_]Opt{
    .{ .short = 'o', .long = "output", .id = 'o', .required_arg = true },
    .{ .short = 'f', .long = "full-html", .id = 'f', .required_arg = false },
    .{ .short = 0, .long = "heal", .id = '4', .required_arg = false },
    .{ .short = 's', .long = "stat", .id = 's', .required_arg = false },
    .{ .short = 'h', .long = "help", .id = 'h', .required_arg = false },
    .{ .short = 'v', .long = "version", .id = 'v', .required_arg = false },
    .{ .short = 't', .long = "format", .id = '3', .required_arg = true },
    .{ .short = 0, .long = "html-title", .id = '1', .required_arg = true },
    .{ .short = 0, .long = "html-css", .id = '2', .required_arg = true },
    .{ .short = 0, .long = "replay-fuzz", .id = 'r', .required_arg = false },
};

fn fail_usage() noreturn {
    usage();
    libc.exit(1);
}

// Apply one resolved option (id + optional value). Exits on fatal user error,
// matching the C callback's exit() calls.
fn handle_opt(id: u8, value: ?[:0]const u8) void {
    switch (id) {
        'o' => output_path = value,
        'f' => want_fullhtml = true,
        '4' => want_heal = true,
        's' => want_stat = true,
        'r' => want_replay_fuzz = true,
        'h' => {
            usage();
            libc.exit(0);
        },
        'v' => {
            version();
            libc.exit(0);
        },
        '3' => {
            const v = value.?;
            if (std.mem.eql(u8, v, "html")) {
                output_format = .html;
            } else if (std.mem.eql(u8, v, "text")) {
                output_format = .text;
            } else if (std.mem.eql(u8, v, "json")) {
                output_format = .json;
            } else if (std.mem.eql(u8, v, "ansi")) {
                output_format = .ansi;
            } else if (std.mem.eql(u8, v, "markdown")) {
                output_format = .markdown;
            } else if (std.mem.eql(u8, v, "heal")) {
                output_format = .heal;
            } else {
                eprint("Unknown format: {s}\n", .{v});
                eprint("Supported formats: html, text, json, ansi, markdown, heal\n", .{});
                libc.exit(1);
            }
        },
        '1' => html_title = value,
        '2' => css_path = value,
        else => unreachable,
    }
}

fn handle_positional(value: [:0]const u8) void {
    if (input_path != null) {
        eprint("Too many arguments. Only one input file can be specified.\n", .{});
        eprint("Use --help for more info.\n", .{});
        libc.exit(1);
    }
    input_path = value;
}

fn find_short(ch: u8) ?*const Opt {
    for (&options) |*o| {
        if (o.short != 0 and o.short == ch) return o;
    }
    return null;
}

fn parse_args(argv: []const [:0]const u8) void {
    var after_doubledash = false;
    var i: usize = 1; // skip argv[0]
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (after_doubledash or std.mem.eql(u8, arg, "-")) {
            handle_positional(arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_doubledash = true;
            continue;
        }
        if (arg.len == 0 or arg[0] != '-') {
            handle_positional(arg);
            continue;
        }

        // Long option ("--name" / "--name=value").
        if (arg.len >= 2 and arg[1] == '-') {
            const body = arg[2..]; // after "--"
            var matched = false;
            for (&options) |*o| {
                const long = o.long orelse continue;
                if (!std.mem.startsWith(u8, body, long)) continue;
                const rest = body[long.len..];
                if (rest.len == 0) {
                    if (o.required_arg) {
                        if (i + 1 < argv.len) {
                            i += 1;
                            handle_opt(o.id, argv[i]);
                        } else {
                            eprint("The option {s} requires an argument.\n", .{arg});
                            fail_usage();
                        }
                    } else {
                        handle_opt(o.id, null);
                    }
                    matched = true;
                    break;
                } else if (rest[0] == '=') {
                    if (o.required_arg) {
                        handle_opt(o.id, rest[1..]);
                    } else {
                        eprint("The option --{s} does not expect an argument.\n", .{long});
                        fail_usage();
                    }
                    matched = true;
                    break;
                }
                // else: prefix-only match, keep scanning for a longer name.
            }
            if (!matched) {
                eprint("Unknown option: {s}\n", .{arg});
                fail_usage();
            }
            continue;
        }

        // Short option(s): "-o value", "-ovalue", or a group like "-sf".
        const first = find_short(arg[1]) orelse {
            eprint("Unknown option: {s}\n", .{arg});
            fail_usage();
        };
        if (first.required_arg) {
            if (arg.len > 2) {
                handle_opt(first.id, arg[2..]);
            } else if (i + 1 < argv.len) {
                i += 1;
                handle_opt(first.id, argv[i]);
            } else {
                eprint("The option -{c} requires an argument.\n", .{arg[1]});
                fail_usage();
            }
        } else {
            handle_opt(first.id, null);
            // Remaining chars in the group are argument-less short options.
            var k: usize = 2;
            while (k < arg.len) : (k += 1) {
                const o = find_short(arg[k]);
                if (o != null and !o.?.required_arg) {
                    handle_opt(o.?.id, null);
                } else {
                    eprint("Unknown option: -{c}\n", .{arg[k]});
                    fail_usage();
                }
            }
        }
    }
}

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch {
        eprint("Failed to read command line.\n", .{});
        return 1;
    };

    parse_args(argv);

    var in: *libc.FILE = libc.stdin;
    var out: *libc.FILE = libc.stdout;

    if (input_path) |p| {
        if (!std.mem.eql(u8, p, "-")) {
            in = libc.fopen(p.ptr, "rb") orelse {
                eprint("Cannot open {s}.\n", .{p});
                return 1;
            };
        }
    }
    if (output_path) |p| {
        if (!std.mem.eql(u8, p, "-")) {
            out = libc.fopen(p.ptr, "wt") orelse {
                eprint("Cannot open {s}.\n", .{p});
                return 1;
            };
        }
    }

    const ret = process_file(in, out);

    if (in != libc.stdin) _ = libc.fclose(in);
    if (out != libc.stdout) _ = libc.fclose(out);

    return if (ret == 0) 0 else 1;
}
