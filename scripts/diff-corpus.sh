#!/usr/bin/env bash
# diff-corpus.sh — capture a reproducible output-hash set across every renderer
# over a broad corpus, so any phase of the Zig idiomatization can prove
# byte-for-byte parity against the baseline.
#
# Usage:
#   bash scripts/diff-corpus.sh > /tmp/md4x-baseline.sha     # capture baseline
#   bash scripts/diff-corpus.sh > /tmp/md4x-now.sha          # after a change
#   diff /tmp/md4x-baseline.sha /tmp/md4x-now.sha            # MUST be empty
#
# The CLI binary defaults to zig-out/bin/md4x; override with $MD4X.
set -u

MD4X="${MD4X:-zig-out/bin/md4x}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

if [ ! -x "$MD4X" ]; then
  echo "error: $MD4X not found; run 'zig build' first" >&2
  exit 1
fi

# Corpus: spec/extension/regression suites + fuzzer seed corpus.
# Only git-TRACKED files are hashed: a fuzzing run drops many gitignored inputs
# into test/fuzzers/seed-corpus/, and globbing those would make the hash set
# non-reproducible. `git ls-files` excludes them by construction.
corpus=()
while IFS= read -r f; do
  [ -f "$f" ] && corpus+=("$f")
done < <(git ls-files 'test/*.txt' 'test/fuzzers/seed-corpus/*.md')

for fmt in html text json ansi markdown heal; do
  for f in "${corpus[@]}"; do
    h="$("$MD4X" --format="$fmt" "$f" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    printf '%s  %s:%s\n' "$h" "$fmt" "$f"
  done
done | sort
