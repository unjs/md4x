const std = @import("std");
const zon = @import("build.zig.zon");

// --- Source files ---

// The entire library is Zig: parser (src/md4x.zig + src/parser/), renderers
// (src/renderers/<name>.zig), entity table (src/entity.zig), CLI driver
// (src/cli/md4x-cli.zig), and the WASM/NAPI glue. The only C compiled into any
// artifact is the vendored libyaml dependency. The shared ABI types live in
// src/abi.zig (added as the "abi" module to every Zig compile step).
//
// Phase 4a: the parser, entity table, and renderers are no longer built as
// separate static libraries that find each other through link-time C-ABI
// symbols. Each artifact's root source `@import`s src/lib.zig, which pulls all
// of them into that artifact's module graph, so they call each other by direct
// Zig call. Adding a renderer means adding it to src/lib.zig, not here.

// --- Compiler flags ---

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
    /// Shared "abi" module. It must be ONE module instance per artifact:
    /// creating it twice puts src/abi.zig in two modules, which Zig rejects
    /// ("file exists in modules 'abi' and 'abi0'").
    abi: *std.Build.Module,
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

    // Shared ABI types module — created once and reused by every artifact (a
    // second instance would put src/abi.zig in two modules, which Zig rejects).
    const abi_mod = b.createModule(.{ .root_source_file = b.path("src/abi.zig") });

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
    exe.root_module.addImport("abi", abi_mod);
    // The CLI root lives in src/cli/, so it cannot `@import("../lib.zig")` (a
    // module may not reach outside its own directory). The other artifacts'
    // roots are in src/ and import it relatively. Same module graph either way.
    exe.root_module.addImport("md4x", md4xLibModule(b, target, optimize, strip, include_paths, abi_mod));
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "version", zon.version);
    exe.root_module.addOptions("build_options", cli_options);
    // libyaml is compiled into the exe: the html/ast/meta renderers call into it.
    exe.root_module.addCSourceFiles(libyaml_src);
    for (include_paths) |p| exe.root_module.addIncludePath(p);
    b.installArtifact(exe);

    // --- Unit tests (`zig build test`) ---
    // Compile src/md4x.zig as a test artifact. It imports src/entity.zig
    // directly, so nothing needs linking in.
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
    unit_tests.root_module.addImport("abi", abi_mod);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run parser unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // --- Fuzzer target (Zig-native, coverage-instrumented) ---

    addZigFuzzer(b, target, include_paths, libyaml_src, abi_mod);

    // --- WASM & NAPI targets ---

    const pkg_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const pkg_opts: PkgBuildOptions = .{
        .optimize = pkg_optimize,
        .strip = pkg_optimize != .Debug,
        .libyaml_src = libyaml_src,
        .include_paths = include_paths,
        .abi = abi_mod,
    };
    _ = addWasm(b, pkg_opts);
    _ = addNapi(b, pkg_opts);
}

/// The library root (src/lib.zig) as a named module: parser + entity table +
/// every renderer, in one module graph, calling each other by direct Zig call.
/// Only the CLI needs this form; see the comment at its call site.
fn md4xLibModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool, include_paths: []const std.Build.LazyPath, abi: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .single_threaded = true,
    });
    mod.addImport("abi", abi);
    for (include_paths) |p| mod.addIncludePath(p);
    return mod;
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
    md4x_wasm.root_module.addImport("abi", opts.abi);
    md4x_wasm.root_module.addCSourceFiles(opts.libyaml_src);
    for (opts.include_paths) |p| md4x_wasm.root_module.addIncludePath(p);
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
        napi_lib.root_module.addImport("abi", opts.abi);
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

/// Zig-native, coverage-instrumented fuzz harness (`src/fuzz.zig`). It imports
/// src/lib.zig, so the parser + renderer sources are compiled into the test
/// binary and Zig's own fuzzer (`zig build fuzz-zig --fuzz`) instruments them,
/// steering inputs by real coverage of the library internals.
///
/// Built ReleaseSafe regardless of -Doptimize so runtime safety checks (OOB,
/// overflow, unreachable, bad casts) are always armed during fuzzing; without
/// them a miscompiled UB would pass silently. libyaml (C) is linked for the
/// html/ast/meta paths but is not instrumented.
fn addZigFuzzer(b: *std.Build, target: std.Build.ResolvedTarget, include_paths: []const std.Build.LazyPath, libyaml_src: std.Build.Module.AddCSourceFilesOptions, abi: *std.Build.Module) void {
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
    fuzz_tests.root_module.addImport("abi", abi);
    fuzz_tests.root_module.addCSourceFiles(libyaml_src);
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_zig_step = b.step("fuzz-zig", "Run the Zig-native fuzz harness (add --fuzz for coverage-guided fuzzing)");
    fuzz_zig_step.dependOn(&run_fuzz_tests.step);
}
