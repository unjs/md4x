const std = @import("std");
const zon = @import("build.zig.zon");

const version = std.SemanticVersion.parse(zon.version) catch unreachable;

// --- Source files ---

// Parser is now src/md4x.zig (ported from src/md4x.c), linked as its own static
// lib (addParserLib) into every artifact, exporting the md4x.h C ABI (md_parse).
// Entity table is now src/entity.zig (linked as its own static lib). No C
// sources remain shared across all artifacts, so this base is empty.
const renderer_sources = [_][]const u8{};
const cli_sources = renderer_sources ++ .{ "src/cli/md4x-cli.c", "src/cli/cmdline.c" };
// WASM/NAPI glue are now Zig (src/md4x-wasm.zig, src/md4x-napi.zig). They are the
// root source of their respective artifacts; no C glue sources remain.

// Renderers/utilities ported from C to Zig. Each is compiled as a static lib
// from src/renderers/<name>.zig (via addZigRenderer) and linked into every
// artifact (CLI exe, WASM, NAPI). Add a name here as each unit is migrated.
const zig_renderers = [_][]const u8{ "md4x-heal", "md4x-text", "md4x-markdown", "md4x-ansi", "md4x-meta", "md4x-ast", "md4x-html" };

// --- Compiler flags ---

const c_flags: []const []const u8 = &.{
    std.fmt.comptimePrint("-DMD_VERSION_MAJOR={d}", .{version.major}),
    std.fmt.comptimePrint("-DMD_VERSION_MINOR={d}", .{version.minor}),
    std.fmt.comptimePrint("-DMD_VERSION_RELEASE={d}", .{version.patch}),
    "-Wall",
    "-Wextra",
    "-Wshadow",
    "-Wdeclaration-after-statement",
    "-O2",
};

const libyaml_c_flags: []const []const u8 = &.{
    "-DYAML_DECLARE_STATIC",
    "-DYAML_VERSION_MAJOR=0",
    "-DYAML_VERSION_MINOR=2",
    "-DYAML_VERSION_PATCH=5",
    "-DYAML_VERSION_STRING=\"0.2.5\"",
};

// --- Build options passed to WASM/NAPI targets ---

const PkgBuildOptions = struct {
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    libyaml_src: std.Build.Module.AddCSourceFilesOptions,
    include_paths: []const std.Build.LazyPath,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;

    const strip = optimize != .Debug;

    // --- libyaml (YAML parser for frontmatter) ---

    const libyaml = b.dependency("libyaml", .{});
    const libyaml_src: std.Build.Module.AddCSourceFilesOptions = .{
        .root = libyaml.path(""),
        .files = &.{ "src/api.c", "src/reader.c", "src/scanner.c", "src/parser.c" },
        .flags = libyaml_c_flags,
    };

    const include_paths: []const std.Build.LazyPath = &.{ b.path("src"), b.path("src/renderers"), libyaml.path("include") };

    // --- CLI executable ---

    const exe = b.addExecutable(.{
        .name = "md4x",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/md4x-cli.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
            .single_threaded = true,
        }),
    });
    exe.root_module.addImport("abi", b.createModule(.{ .root_source_file = b.path("src/abi.zig") }));
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "version", zon.version);
    exe.root_module.addOptions("build_options", cli_options);
    // libyaml is still compiled into the exe: the html/ast/meta renderer libs
    // reference its symbols at final link.
    exe.root_module.addCSourceFiles(libyaml_src);
    for (include_paths) |p| exe.root_module.addIncludePath(p);
    exe.root_module.linkLibrary(addParserLib(b, target, optimize, strip, include_paths));
    exe.root_module.linkLibrary(addEntityLib(b, target, optimize, strip, include_paths));
    for (zig_renderers) |name| exe.root_module.linkLibrary(addZigRenderer(b, name, target, optimize, strip, include_paths));
    b.installArtifact(exe);

    // --- Unit tests (`zig build test`) ---
    // Compile src/md4x.zig as a test artifact. It @cImports md4x.h/entity.h
    // (resolved via include_paths) and references entity_lookup (provided by the
    // entity static lib), so we link the entity lib in.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/md4x.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .single_threaded = true,
        }),
    });
    for (include_paths) |p| unit_tests.root_module.addIncludePath(p);
    unit_tests.root_module.addImport("abi", b.createModule(.{ .root_source_file = b.path("src/abi.zig") }));
    unit_tests.root_module.linkLibrary(addEntityLib(b, target, optimize, strip, include_paths));
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run parser unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // --- Fuzzer targets ---

    addFuzzers(b);
    addZigFuzzer(b, target, include_paths, libyaml_src);

    // --- WASM & NAPI targets ---

    const pkg_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const pkg_opts: PkgBuildOptions = .{
        .optimize = pkg_optimize,
        .strip = pkg_optimize != .Debug,
        .libyaml_src = libyaml_src,
        .include_paths = include_paths,
    };
    _ = addWasm(b, pkg_opts);
    _ = addNapi(b, pkg_opts);
}

/// Compile a Zig-ported renderer/utility (src/renderers/<name>.zig) as a static
/// library. Returns the compile step so callers can `linkLibrary` it into their
/// artifact. The project include paths (src, src/renderers, libyaml/include) are
/// added so any `@cImport` of md4x.h / entity.h / yaml.h resolves. Mirrors the
/// per-artifact target/optimize/strip so ABI/codegen match.
fn addZigRenderer(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool, include_paths: []const std.Build.LazyPath) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/renderers/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
            .single_threaded = true,
        }),
    });
    for (include_paths) |p| lib.root_module.addIncludePath(p);
    lib.root_module.addImport("abi", b.createModule(.{ .root_source_file = b.path("src/abi.zig") }));
    return lib;
}

/// Compile the parser (src/md4x.zig, ported from src/md4x.c) as a static library
/// exporting the md4x.h C ABI (md_parse). Linked into every artifact (CLI exe,
/// WASM, NAPI). The project include paths (src, src/renderers, libyaml/include)
/// are added so its `@cImport` of md4x.h / entity.h resolves. Mirrors the
/// per-artifact target/optimize/strip so ABI/codegen match.
fn addParserLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool, include_paths: []const std.Build.LazyPath) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "md4x",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/md4x.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
            .single_threaded = true,
        }),
    });
    for (include_paths) |p| lib.root_module.addIncludePath(p);
    lib.root_module.addImport("abi", b.createModule(.{ .root_source_file = b.path("src/abi.zig") }));
    return lib;
}

/// Compile the HTML entity table (src/entity.zig, ported from src/entity.c) as a
/// static library exporting the entity.h C ABI (entity_lookup). Linked into every
/// artifact so both the C parser (md4x.c) and the Zig renderers (@cImport entity.h)
/// resolve their entity references. Mirrors target/optimize/strip for ABI match.
fn addEntityLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool, include_paths: []const std.Build.LazyPath) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "entity",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entity.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
            .single_threaded = true,
        }),
    });
    for (include_paths) |p| lib.root_module.addIncludePath(p);
    return lib;
}

fn addWasm(b: *std.Build, opts: PkgBuildOptions) *std.Build.Step {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const md4x_wasm = b.addExecutable(.{
        .name = "md4x",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/md4x-wasm.zig"),
            .target = wasm_target,
            .optimize = opts.optimize,
            .link_libc = true,
            .strip = opts.strip,
            .single_threaded = true,
        }),
    });
    md4x_wasm.rdynamic = true;
    md4x_wasm.root_module.addCSourceFiles(opts.libyaml_src);
    for (opts.include_paths) |p| md4x_wasm.root_module.addIncludePath(p);
    md4x_wasm.root_module.linkLibrary(addParserLib(b, wasm_target, opts.optimize, opts.strip, opts.include_paths));
    md4x_wasm.root_module.linkLibrary(addEntityLib(b, wasm_target, opts.optimize, opts.strip, opts.include_paths));
    for (zig_renderers) |name| md4x_wasm.root_module.linkLibrary(addZigRenderer(b, name, wasm_target, opts.optimize, opts.strip, opts.include_paths));
    md4x_wasm.root_module.export_symbol_names = &.{
        "md4x_alloc",
        "md4x_free",
        "md4x_to_html",
        "md4x_to_html_meta",
        "md4x_to_ast",
        "md4x_to_ansi",
        "md4x_to_meta",
        "md4x_to_text",
        "md4x_to_markdown",
        "md4x_heal",
        "md4x_result_ptr",
        "md4x_result_size",
    };

    const wasm_install = b.addInstallArtifact(md4x_wasm, .{
        .dest_dir = .{ .override = .{ .custom = "../packages/md4x/build" } },
    });
    const wasm_step = b.step("wasm", "Build WASM library");
    wasm_step.dependOn(&wasm_install.step);
    return wasm_step;
}

fn addNapi(b: *std.Build, opts: PkgBuildOptions) *std.Build.Step {
    const napi_include = b.option([]const u8, "napi-include", "Path to node-api-headers include directory") orelse "node_modules/node-api-headers/include";
    const napi_def = b.option([]const u8, "napi-def", "Path to node_api.def file (for Windows targets)") orelse "node_modules/node-api-headers/def/node_api.def";

    // Ensure node_modules are installed (provides node-api-headers)
    // const bun_install = b.addSystemCommand(&.{ "bun", "install", "--frozen-lockfile" });

    const NapiTarget = struct {
        name: []const u8,
        cpu_arch: std.Target.Cpu.Arch,
        os_tag: std.Target.Os.Tag,
        abi: std.Target.Abi,
        output_name: []const u8,
        dlltool_machine: ?[]const u8,
    };

    const napi_targets = [_]NapiTarget{
        .{ .name = "linux-x64", .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .output_name = "md4x.linux-x64.node", .dlltool_machine = null },
        .{ .name = "linux-x64-musl", .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl, .output_name = "md4x.linux-x64-musl.node", .dlltool_machine = null },
        .{ .name = "linux-arm64", .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu, .output_name = "md4x.linux-arm64.node", .dlltool_machine = null },
        .{ .name = "linux-arm64-musl", .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl, .output_name = "md4x.linux-arm64-musl.node", .dlltool_machine = null },
        .{ .name = "linux-arm", .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabihf, .output_name = "md4x.linux-arm.node", .dlltool_machine = null },
        .{ .name = "darwin-x64", .cpu_arch = .x86_64, .os_tag = .macos, .abi = .none, .output_name = "md4x.darwin-x64.node", .dlltool_machine = null },
        .{ .name = "darwin-arm64", .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none, .output_name = "md4x.darwin-arm64.node", .dlltool_machine = null },
        .{ .name = "win32-x64", .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu, .output_name = "md4x.win32-x64.node", .dlltool_machine = "i386:x86-64" },
        .{ .name = "win32-arm64", .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu, .output_name = "md4x.win32-arm64.node", .dlltool_machine = "arm64" },
    };

    const napi_all_step = b.step("napi-all", "Build NAPI addon for all platforms");

    inline for (napi_targets) |nt| {
        const cross_target = b.resolveTargetQuery(.{
            .cpu_arch = nt.cpu_arch,
            .os_tag = nt.os_tag,
            .abi = nt.abi,
        });

        const napi_lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "md4x",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/md4x-napi.zig"),
                .target = cross_target,
                .optimize = opts.optimize,
                .link_libc = true,
                .strip = opts.strip,
                .single_threaded = true,
            }),
        });
        napi_lib.root_module.addCSourceFiles(opts.libyaml_src);
        for (opts.include_paths) |p| napi_lib.root_module.addIncludePath(p);
        // node_api.h lives outside the project tree (node_modules). Resolve to an
        // absolute path so the root Zig module's @cImport translate-c step finds
        // it regardless of the sub-process working directory.
        const napi_include_abs = if (std.fs.path.isAbsolute(napi_include))
            napi_include
        else
            b.pathFromRoot(napi_include);
        napi_lib.root_module.addIncludePath(.{ .cwd_relative = napi_include_abs });
        napi_lib.root_module.linkLibrary(addParserLib(b, cross_target, opts.optimize, opts.strip, opts.include_paths));
        napi_lib.root_module.linkLibrary(addEntityLib(b, cross_target, opts.optimize, opts.strip, opts.include_paths));
        for (zig_renderers) |name| napi_lib.root_module.linkLibrary(addZigRenderer(b, name, cross_target, opts.optimize, opts.strip, opts.include_paths));

        if (nt.dlltool_machine) |machine| {
            const dlltool = b.addSystemCommand(&.{
                "zig", "dlltool",
                "-d",  napi_def,
                "-m",  machine,
                "-D",  "node.exe",
                "-l",
            });
            const implib = dlltool.addOutputFileArg("node_api.lib");
            napi_lib.root_module.addObjectFile(implib);
        } else {
            napi_lib.linker_allow_shlib_undefined = true;
        }

        const cross_install = b.addInstallArtifact(napi_lib, .{
            .dest_dir = .{ .override = .{ .custom = "../packages/md4x/build" } },
            .dest_sub_path = nt.output_name,
        });

        const cross_step = b.step("napi-" ++ nt.name, "Build NAPI addon for " ++ nt.name);
        cross_step.dependOn(&cross_install.step);
        napi_all_step.dependOn(&cross_install.step);
    }

    return napi_all_step;
}

fn addFuzzers(b: *std.Build) void {
    const fuzz_build = b.addSystemCommand(&.{ "sh", "test/fuzzers/build.sh" });
    const fuzz_step = b.step("fuzz", "Build all C/libFuzzer harnesses (requires clang)");
    fuzz_step.dependOn(&fuzz_build.step);
}

/// Zig-native, coverage-instrumented fuzz harness (`src/fuzz.zig`), complementing
/// the C/libFuzzer harnesses. It @imports the parser + renderer sources directly,
/// so Zig's own fuzzer (`zig build fuzz-zig --fuzz`) instruments the library and
/// gets real coverage feedback — which the C harnesses cannot (see build.sh).
///
/// Built ReleaseSafe regardless of -Doptimize so runtime safety checks (OOB,
/// overflow, unreachable, bad casts) are always armed during fuzzing; without
/// them a miscompiled UB would pass silently. libyaml (C) is linked for the
/// html/ast/meta paths but, like in the C harnesses, is not instrumented.
fn addZigFuzzer(b: *std.Build, target: std.Build.ResolvedTarget, include_paths: []const std.Build.LazyPath, libyaml_src: std.Build.Module.AddCSourceFilesOptions) void {
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .single_threaded = true,
        }),
    });
    for (include_paths) |p| fuzz_tests.root_module.addIncludePath(p);
    fuzz_tests.root_module.addCSourceFiles(libyaml_src);
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_zig_step = b.step("fuzz-zig", "Run the Zig-native fuzz harness (add --fuzz for coverage-guided fuzzing)");
    fuzz_zig_step.dependOn(&run_fuzz_tests.step);
}
