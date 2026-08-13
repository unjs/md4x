#!/usr/bin/env bash
# fetch-yaml-corpus.sh — populate test/fuzzers/yaml-corpus/ with the official
# yaml-test-suite inputs, for the Zig-port differential harness.
#
#   bash scripts/fetch-yaml-corpus.sh
#   zig build yaml-parity
#
# The corpus is gitignored: it is ~350 upstream-owned files that would triple
# the repo's tracked test data for no benefit, and it is reproducible from the
# pinned commit below. The tracked seeds in test/fuzzers/yaml-seed/ are the ones
# that must always be checked, corpus present or not.
#
# Pinned to the head of yaml-test-suite's `data` branch (2022-01-17), the layout
# where each case is a directory holding a raw `in.yaml`. The `main` branch
# stores cases as composite YAML documents instead, which would need parsing by
# the very thing under test.
set -euo pipefail

REPO_SHA="6ad3d2c62885d82fc349026c136ef560838fdf3d"
URL="https://github.com/yaml/yaml-test-suite/archive/${REPO_SHA}.tar.gz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/fuzzers/yaml-corpus"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetching yaml-test-suite @ ${REPO_SHA:0:12} ..."
curl -sSfL "$URL" | tar -xz -C "$TMP"

SRC="$TMP/yaml-test-suite-$REPO_SHA"
[ -d "$SRC" ] || { echo "error: unexpected tarball layout" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST"

# Every case is <case-id>/in.yaml, sometimes with numbered sub-cases
# (<case-id>/<nn>/in.yaml). Flatten to <case-id>[-<nn>].yaml so the harness can
# name the failing input without walking back up the tree.
count=0
while IFS= read -r f; do
  rel="${f#"$SRC"/}"
  name="$(dirname "$rel" | tr '/' '-')"
  cp "$f" "$DEST/$name.yaml"
  count=$((count + 1))
done < <(find "$SRC" -name in.yaml -type f | sort)

echo "wrote $count cases to test/fuzzers/yaml-corpus/"
