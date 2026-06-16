#!/bin/sh
# Build all fuzzer harnesses with clang + LibFuzzer + sanitizers.
#
# Usage:
#   ./test/fuzzers/build.sh                  # build all fuzzers
#   ./test/fuzzers/build.sh fuzz-mdhtml      # build a single fuzzer
#
# Requirements:
#   - clang with LibFuzzer support
#   - zig (the library is Zig since the C->Zig migration)
#   - libyaml (vendored as a Zig package dep; for html/ast/meta fuzzers)
#
# Run a fuzzer:
#   ./fuzz-mdhtml  test/fuzzers/seed-corpus/
#   ./fuzz-mdast   test/fuzzers/seed-corpus/
#   ./fuzz-mdheal  test/fuzzers/seed-corpus/
#
# ---------------------------------------------------------------------------
# How this works (post C->Zig migration)
# ---------------------------------------------------------------------------
# The whole library is now Zig (src/md4x.zig parser, src/entity.zig,
# src/renderers/md4x-*.zig). The fuzz harnesses are still clang/libFuzzer C
# files that call the public C-ABI entry points (md_html, md_ast, ... md_heal)
# declared in the unchanged .h headers. So the harnesses just need to LINK
# against the Zig implementations instead of the deleted .c sources.
#
# For each fuzzer we:
#   1. Compile each needed Zig unit to a native object via `zig build-obj`
#      (parser src/md4x.zig, entity src/entity.zig, and the renderer
#      src/renderers/md4x-<name>.zig). Renderers @import the shared
#      md4x-props.zig / md4x-json.zig modules, so those are pulled in
#      automatically. Every renderer also @cImports md4x-heal.h and calls
#      md_heal (heal-before-render), so md4x-heal.zig is always linked too.
#   2. Compile libyaml (api/reader/scanner/parser.c from the vendored Zig
#      package) with clang + the -DYAML_* flags from build.zig. Only the
#      html/ast/meta renderers pull in libyaml (via yaml.h / md4x-json.zig).
#   3. Link with clang -fsanitize=fuzzer,address,undefined.
#
# CAVEAT: the Zig objects are NOT SanitizerCoverage-instrumented (zig build-obj
# does not emit libFuzzer's coverage tables), so libFuzzer's `cov:` counter
# stays low — it only sees coverage of the C harness + libyaml. This is
# expected and acceptable: ASan/UBSan still instrument the Zig objects and
# catch memory errors / UB. (To get full coverage one would need a Zig
# fuzz-instrumented build; out of scope here.)
#
# A tiny C stub provides __zig_probe_stack, which Zig emits on large stack
# frames but whose real impl lives in Zig's compiler-rt (not linked here).
# A no-op is benign — it only touches guard pages to grow the stack, which
# clang/glibc already handle.
# ---------------------------------------------------------------------------

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FUZZ_DIR="$ROOT/test/fuzzers"
OUT_DIR="${FUZZ_OUT_DIR:-$ROOT/fuzz-out}"
SANITIZERS="${SANITIZERS:-fuzzer,address,undefined}"
SRC="$ROOT/src"
RENDERERS="$SRC/renderers"

# Resolve a clang with LibFuzzer support.
# Apple's system clang does not ship LibFuzzer — use Homebrew LLVM on macOS.
if [ -z "$CC" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        LLVM_PREFIX="$(brew --prefix llvm 2>/dev/null || true)"
        if [ -x "$LLVM_PREFIX/bin/clang" ]; then
            CC="$LLVM_PREFIX/bin/clang"
        else
            echo "Error: LibFuzzer requires LLVM clang on macOS (Apple clang does not include it)." >&2
            echo "Install it with:  brew install llvm" >&2
            exit 1
        fi
    else
        CC="clang"
    fi
fi

ZIG="${ZIG:-zig}"

# Resolve the vendored libyaml package directory. Its name is the content hash
# from build.zig.zon; the package is extracted to $ROOT/zig-pkg/<hash>/.
YAML_HASH="$(sed -n 's/.*\.hash = "\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon" | head -n1)"
YAML_PKG="$ROOT/zig-pkg/$YAML_HASH"
if [ ! -d "$YAML_PKG" ]; then
    # Fall back to globbing if the layout changes.
    YAML_PKG="$(ls -d "$ROOT"/zig-pkg/N-V-* 2>/dev/null | head -n1)"
fi
YAML_INC="$YAML_PKG/include"

# Where intermediate Zig/libyaml objects are cached (per build invocation).
OBJ_DIR="$OUT_DIR/obj"

mkdir -p "$OUT_DIR" "$OBJ_DIR"

# Compiler flags.
ZIG_FLAGS="-lc -fPIC -OReleaseSafe -I $SRC -I $RENDERERS -I $YAML_INC"
CLANG_CFLAGS="-fsanitize=$SANITIZERS -I$SRC -I$RENDERERS -I$FUZZ_DIR -DMD4X_USE_UTF8 -g -O1"
# libyaml's own C sources are compiled with ASan/UBSan (no fuzzer/coverage —
# that flag is only for the linked fuzz binary). The -DYAML_* flags mirror
# build.zig's libyaml_c_flags; YAML_VERSION_STRING must be a quoted C string.
YAML_SANITIZERS="$(echo "$SANITIZERS" | sed 's/fuzzer,\{0,1\}//; s/,\{0,1\}fuzzer//')"

# ---- Build helpers (each compiles its unit once, then caches the .o) --------

# build_zig_obj <relpath-from-ROOT-without-ext> <objname>
build_zig_obj() {
    src="$ROOT/$1.zig"
    obj="$OBJ_DIR/$2.o"
    if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ]; then
        # shellcheck disable=SC2086
        ( cd "$OBJ_DIR" && "$ZIG" build-obj "$src" $ZIG_FLAGS --name "$2" )
    fi
    echo "$obj"
}

# Stub for __zig_probe_stack (see header comment).
build_zig_stub() {
    stub="$OBJ_DIR/zig-stubs.c"
    if [ ! -f "$stub" ]; then
        printf 'void __zig_probe_stack(void) {}\n' > "$stub"
    fi
    echo "$stub"
}

# build_yaml -> echoes the list of libyaml object paths.
build_yaml() {
    objs=""
    for f in api reader scanner parser; do
        obj="$OBJ_DIR/yaml-$f.o"
        if [ ! -f "$obj" ] || [ "$YAML_PKG/src/$f.c" -nt "$obj" ]; then
            "$CC" -fsanitize="$YAML_SANITIZERS" -fPIC -g -O1 -I"$YAML_INC" \
                -DYAML_DECLARE_STATIC -DYAML_VERSION_MAJOR=0 -DYAML_VERSION_MINOR=2 \
                -DYAML_VERSION_PATCH=5 -DYAML_VERSION_STRING='"0.2.5"' \
                -c "$YAML_PKG/src/$f.c" -o "$obj"
        fi
        objs="$objs $obj"
    done
    echo "$objs"
}

PARSER_OBJ=""
ENTITY_OBJ=""
HEAL_OBJ=""
STUB=""
ensure_core() {
    [ -n "$PARSER_OBJ" ] || PARSER_OBJ="$(build_zig_obj src/md4x md4x)"
    [ -n "$ENTITY_OBJ" ] || ENTITY_OBJ="$(build_zig_obj src/entity entity)"
    [ -n "$HEAL_OBJ" ]   || HEAL_OBJ="$(build_zig_obj src/renderers/md4x-heal md4x-heal)"
    [ -n "$STUB" ]       || STUB="$(build_zig_stub)"
}

# link_fuzzer <name> <harness.c> <renderer-objs...> [+yaml]
# Builds core (parser/entity/heal), the named renderer object, optionally
# libyaml, then links the fuzz binary.
build_renderer_fuzzer() {
    name="$1"; renderer="$2"; want_yaml="$3"
    echo "Building fuzz-md$name..."
    ensure_core
    rend_obj="$(build_zig_obj "src/renderers/md4x-$renderer" "md4x-$renderer")"
    yaml_objs=""
    if [ "$want_yaml" = "yaml" ]; then
        yaml_objs="$(build_yaml)"
    fi
    # shellcheck disable=SC2086
    $CC $CLANG_CFLAGS \
        "$FUZZ_DIR/fuzz-md$name.c" \
        "$PARSER_OBJ" "$ENTITY_OBJ" "$rend_obj" "$HEAL_OBJ" \
        $yaml_objs "$STUB" \
        -o "$OUT_DIR/fuzz-md$name"
}

build_html()     { build_renderer_fuzzer html     html     yaml; }
build_ast()      { build_renderer_fuzzer ast      ast      yaml; }
build_meta()     { build_renderer_fuzzer meta     meta     yaml; }
build_ansi()     { build_renderer_fuzzer ansi     ansi     ""; }
build_text()     { build_renderer_fuzzer text     text     ""; }
build_markdown() { build_renderer_fuzzer markdown markdown ""; }

# heal is standalone: no parser/entity/yaml, only md4x-heal.zig.
build_heal() {
    echo "Building fuzz-mdheal..."
    [ -n "$HEAL_OBJ" ] || HEAL_OBJ="$(build_zig_obj src/renderers/md4x-heal md4x-heal)"
    [ -n "$STUB" ]     || STUB="$(build_zig_stub)"
    # shellcheck disable=SC2086
    $CC $CLANG_CFLAGS \
        "$FUZZ_DIR/fuzz-mdheal.c" \
        "$HEAL_OBJ" "$STUB" \
        -o "$OUT_DIR/fuzz-mdheal"
}

if [ $# -eq 0 ]; then
    build_html
    build_ast
    build_ansi
    build_text
    build_meta
    build_markdown
    build_heal
    echo "All fuzzers built in $OUT_DIR/"
else
    for target in "$@"; do
        case "$target" in
            fuzz-mdhtml|html)  build_html ;;
            fuzz-mdast|ast)    build_ast ;;
            fuzz-mdansi|ansi)  build_ansi ;;
            fuzz-mdtext|text)  build_text ;;
            fuzz-mdmeta|meta)  build_meta ;;
            fuzz-mdmarkdown|markdown)  build_markdown ;;
            fuzz-mdheal|heal)  build_heal ;;
            *) echo "Unknown target: $target" >&2; exit 1 ;;
        esac
    done
fi
