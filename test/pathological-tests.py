#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import re
import argparse
import sys
import platform
from prog import Prog
from subprocess import TimeoutExpired
from timeit import default_timer as timer

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Run Markdown tests.')
    parser.add_argument('-p', '--program', dest='program', nargs='?', default=None,
            help='program to test')
    args = parser.parse_args(sys.argv[1:])

# list of pairs consisting of input and a regex that must match the output.
pathological = {
    # note - some pythons have limit of 65535 for {num-matches} in re.
    "U+0000":
            ("abc\u0000de\u0000",
            re.compile("abc\ufffd?de\ufffd?")),
    "U+0000 in code span across lines":
            ("`\u0000\n`",
            re.compile(r"<p><code>.? </code></p>")),
    "U+FEFF (Unicode BOM)":
            ("\ufefffoo",
            re.compile("<p>foo</p>")),
    "nested strong emph":
            (("*a **a " * 65000) + "b" + (" a** a*" * 65000),
            re.compile("(<em>a <strong>a ){65000}b( a</strong> a</em>){65000}")),
    "many emph closers with no openers":
            (("a_ " * 65000),
            re.compile("(a[_] ){64999}a_")),
    "many emph openers with no closers":
            (("_a " * 65000),
            re.compile("(_a ){64999}_a")),
    "many 3-emph openers with no closers":
            (("a***" * 65000),
            re.compile("(a<em><strong>a</strong></em>){32500}")),
    "many link closers with no openers":
            (("a]" * 65000),
            re.compile(r"(a\]){65000}")),
    "many link openers with no closers":
            (("[a" * 65000),
            re.compile(r"(\[a){65000}")),
    "mismatched openers and closers":
            (("*a_ " * 50000),
            re.compile("([*]a[_] ){49999}[*]a_")),
    "openers and closers multiple of 3":
            (("a**b" + ("c* " * 50000)),
            re.compile("a[*][*]b(c[*] ){49999}c[*]")),
    "link openers and emph closers":
            (("[ a_" * 50000),
            re.compile(r"(\[ a_){50000}")),
    "hard link/emph case":
            ("**x [a*b**c*](d)",
            re.compile("\\*\\*x <a href=\"d\">a<em>b\\*\\*c</em></a>")),
    "nested brackets":
            (("[" * 50000) + "a" + ("]" * 50000),
            re.compile(r"\[{49998}<x-wikilink data-target=\"a\">a</x-wikilink>\]{49998}")),
    "nested block quotes":
            ((("> " * 50000) + "a"),
            re.compile("(<blockquote>\r?\n){50000}")),
    "backticks":
            ("".join(map(lambda x: ("e" + "`" * x), range(1,1000))),
            re.compile("^<p>[e`]*</p>\r?\n$")),
    "many links":
            ("[t](/u) " * 50000,
            re.compile("(<a href=\"/u\">t</a> ?){50000}")),
    "many references":
            ("".join(map(lambda x: ("[" + str(x) + "]: u\n"), range(1,20000 * 16))) + "[0] " * 20000,
            re.compile(r"(\[0\] ){19999}")),
    "deeply nested lists":
            ("".join(map(lambda x: ("  " * x + "* a\n"), range(0,1000))),
            re.compile("<ul>\r?\n(<li>a<ul>\r?\n){999}<li>a</li>\r?\n</ul>\r?\n(</li>\r?\n</ul>\r?\n){999}")),
    # --format=json cases. The AST renderer is the only one that materializes a
    # tree, so it is the only one with a nesting limit (JSON_MAX_DEPTH in
    # src/renderers/md4x-ast.zig -- its serializer recurses once per level).
    # Every case above proves the PARSER has no such limit, and the streaming
    # renderers happily emit "> " * 300000, so the AST renderer used to be the
    # one that fell over: past the limit it set ctx->err, md_ast() returned -1
    # and emitted ZERO bytes -- one deep blockquote or list anywhere in a
    # document killed the whole render (a thrown Error through the JS
    # bindings). It now stops nesting instead, keeping the content and saying
    # so in the tree's `meta` bag. Both cases therefore assert three things: a
    # zero exit code, the exact depth the tree stops at, and the flag.
    "deeply nested block quotes (json)":
            ((("> " * 50000) + "a"),
            re.compile(r'^\{"nodes":\[(\["blockquote",\{\},){1023}"a"\]{1023}\],'
                       r'"frontmatter":\{\},"meta":\{"headings":\[\],"maxDepthExceeded":true\}\}'),
            ["--format=json"]),
    "deeply nested lists (json)":
            ("".join(map(lambda x: ("  " * x + "* a\n"), range(0,1000))),
            re.compile(r'^\{"nodes":\[(\["ul",\{\},\["li",\{\},"a",){511}\["ul",\{\},"a{489}"[\]]+,'
                       r'"frontmatter":\{\},"meta":\{"headings":\[\],"maxDepthExceeded":true\}\}'),
            ["--format=json"]),
    "many html openers and closers":
            (("<>" * 50000),
            re.compile("(&lt;&gt;){50000}")),
    "many html proc. inst. openers":
            (("x" + "<?" * 50000),
            re.compile("x(&lt;\\?){50000}")),
    "many html CDATA openers":
            (("x" + "<![CDATA[" * 50000),
            re.compile("x(&lt;!\\[CDATA\\[){50000}")),
    "many backticks and escapes":
            (("\\``" * 50000),
            re.compile("(``){50000}")),
    "many broken link titles":
            (("[ (](" * 50000),
            re.compile(r"(\[ \(\]\(){50000}")),
    "broken thematic break":
            (("* " * 50000 + "a"),
            re.compile("<ul>\r?\n(<li><ul>\r?\n){49999}<li>a</li>\r?\n</ul>\r?\n(</li>\r?\n</ul>\r?\n){49999}")),
    "nested invalid link references":
            (("[" * 50000 + "]" * 50000 + "\n\n[a]: /b"),
            re.compile(r"\[{49997}<x-wikilink.*?</x-wikilink>\]{49997}")),
    "many broken permissive autolinks":
            (("www._" * 50000 + "x"),
            re.compile("<p>(www._){50000}x</p>")),
    "huge table":
            (("th|" * 10000 + "\n" + "-|" * 10000 + "\n" + "td\n" * 10000),
            re.compile("")),
    "many broken links":
            (("]([\n" * 50000),
            re.compile(r"<p>(\]\(\[\r?\n){49999}\]\(\[</p>")),
    "many link ref. def. instantiations":
            (("[x]: " + "x" * 50000 + "\n[x]" * 50000),
            re.compile("")),
    "many unclosed inline attributes":
            (("*a*{" * 50000),
            re.compile("(<em>a</em>[{]){50000}")),
    "many unclosed span attributes":
            (("[t]{" * 50000),
            re.compile(r"(\[t\]\{){50000}")),

    # --format=json case. The AST renderer is the one renderer that BUILDS a
    # tree instead of streaming, and its consecutive-text-node merge used to
    # copy the incoming bytes into the arena before appending them -- which
    # pushed the node's own buffer off the arena's growable tail, so every
    # merge reallocated and copied the whole accumulated text and abandoned the
    # previous buffer. Every soft-wrapped line of a paragraph is one merge, so
    # the cost was quadratic in the PARAGRAPH length; the streaming renderers
    # never touch this path, which is why none of the cases above caught it.
    #
    # This trigger is deliberately memory-decisive rather than time-decisive:
    # the quadratic is in the arena as much as in the copying, so the buggy
    # build is OOM-killed (~20 GB, exit 137) rather than merely slow, and the
    # case fails on the exit code on any machine. A correct build renders it in
    # ~10 ms. Newline-free content per line, and no blank line anywhere, so the
    # whole document is ONE paragraph -- a blank line every so often would cap
    # the merge chain at the paragraph and hide the bug.
    "one huge soft-wrapped paragraph (json)":
            (("a\n" * 100000),
            re.compile(r'\["p",\{\},"a(\\na)+"\]'),
            ["--format=json"]),

    # --format=json case. The YAML scanners' leading_break / trailing_breaks /
    # whitespaces scratch is pooled on the Parser (src/yaml/types.zig) rather
    # than malloced per token the way the C does it, which is what removes 3 of
    # every 4 allocations a scalar makes. The catch is that CLEAR then costs
    # the buffer's high-water mark instead of the current token's: a long run
    # of line breaks early in a document would be re-zeroed once per later
    # scalar, i.e. quadratic in (longest break run x scalar count). Frontmatter
    # is attacker-supplied on any site that renders user markdown, so this is a
    # DoS shape, not a benchmark curiosity -- the input below takes 629 ms
    # against 9 ms (68x) without the bound, and worsens quadratically.
    #
    # mem.String.hi bounds the memset to what was actually written. The
    # decisive guard is the canary test in mem.zig, because reverting to the
    # C's whole-allocation memset stays CORRECT and so shows up in no output;
    # this case covers the same trap end to end, where the printed time makes a
    # regression visible even though this section enforces no budget.
    "frontmatter with a long break run then many keys (json)":
            ("---\nfirst: value\n" + "\n" * 60000
             + "".join("k%d: v%d\n" % (k, k) for k in range(20000))
             + "---\n\n# doc\n",
            re.compile(r'"k19999":"v19999"\}'),
            ["--format=json"]),

    # --format=heal cases. md_heal() does not use the parser, so none of the
    # limits above cover it; its helpers used to rescan the document once per
    # candidate marker, which made these inputs quadratic (50 000 asterisks took
    # ~1 s, 160 000 took ~17 s, and the underscore form ~14 s). Both shapes are
    # newline-free on purpose: the link/HTML-context helpers stopped at the
    # previous newline, so a document with none made them walk to offset 0.
    # Odd repeat counts, so the marker really is unbalanced and heal appends a
    # closer -- an even count is already balanced and exercises less.
    "many unclosed asterisks (heal)":
            (("*a " * 49999),
            re.compile(r"(\*a ){49998}\*a\*"),
            ["--format=heal"]),
    "many unclosed underscores (heal)":
            (("_a " * 49999),
            re.compile(r"(_a ){49998}_a_"),
            ["--format=heal"]),
    "many math spans and emphasis (heal)":
            (("$x$ *a* _b_ " * 25000),
            re.compile(r"(\$x\$ \*a\* _b_ ){24999}\$x\$ \*a\* _b_"),
            ["--format=heal"]),
}


# ---------------------------------------------------------------------------
# Timed heal cases.
#
# The cases above only assert on OUTPUT, and a quadratic healer still produces
# exactly the right bytes -- just eventually. md_heal() also does not use the
# parser, so none of the parser's linear-time limits (docs/parser-api.md) cover
# it, and the corpus in scripts/diff-corpus.sh is far too short for a quadratic
# path to show up there. Three separate O(n^2) DoS bugs shipped in md_heal()
# through exactly that gap (the heal_links_and_images bracket walk, the
# heal_comparison_operators fence rescan + per-insertion splice, and
# heal_strikethrough's monotone has_meaningful_content test), on top of an
# earlier round covering '*'*n / 'a_'*n / '~'*n. heal() is an exported JS API
# and --heal is reachable on every renderer, so all of them were reachable from
# untrusted input. Each trigger below is therefore *timed*, and a case that
# blows its budget FAILS the suite rather than just printing a large number.
#
# Threshold strategy: every trigger heals the SAME number of bytes as a prose
# document, and must finish within HEAL_BUDGET_FACTOR x the prose time (with a
# floor, below). Two alternatives were rejected:
#
#   * An absolute wall-clock limit has to be tuned for the slowest CI runner,
#     and is then far too loose on a fast one.
#   * A scaling ratio across two sizes (~4x per doubling = quadratic, ~2x =
#     linear) needs the sizes to be big enough that the ~4 ms process start
#     stops dominating; at sizes small enough to keep this suite fast, that
#     constant compresses every ratio towards 1 and the test measures nothing.
#
# Calibrating against the prose baseline keeps the yardstick machine-relative
# (both sides scale with the CPU) while staying valid at a size where the whole
# section costs well under a second. The constant process start is included on
# both sides, which compresses the observed ratios towards 1 -- that only makes
# the check more conservative, and the margin absorbs it: at 256 KB every
# healed pathological input below measures within 1.3x of prose, whereas a
# build from before the fixes measures 10.8 s (brackets), 4.2 s (comparison
# operators), 13.6 s (strikethrough) and 18.8 s (tildes) for the same bytes,
# i.e. 800x-3800x the prose baseline.
#
# HEAL_BUDGET_FLOOR keeps a very fast machine from turning the budget into
# noise: below ~62 ms of baseline the floor wins, above it the relative term
# does. Timing is best-of-HEAL_ATTEMPTS with an early exit on the first passing
# run, so a healthy suite pays one run per case and only a suspected failure
# pays the retries that rule out a transient stall -- and only while the
# overrun is small enough to plausibly BE one, since a real quadratic overruns
# by three orders of magnitude and re-timing it just makes the suite slow.
HEAL_SIZE = 256 * 1024
HEAL_BUDGET_FACTOR = 8.0
HEAL_BUDGET_FLOOR = 0.5
HEAL_ATTEMPTS = 3
HEAL_RETRY_MARGIN = 4.0

# Real markdown prose, balanced so that no healer has anything to fix: the
# baseline must measure throughput, not healing work.
HEAL_PROSE = (
    "## Section heading\n"
    "\n"
    "The quick brown fox jumps over the *lazy* dog, and then writes it all\n"
    "up in `code`, linking to [the docs](https://example.com/docs) as it goes.\n"
    "\n"
    "- one item\n"
    "- two **items**\n"
    "- three items\n"
    "\n"
)


def heal_repeat(unit, odd=True):
    """Repeat count that fills HEAL_SIZE bytes with `unit`.

    Odd by default so a repeated marker really is unbalanced and heal takes its
    append path -- an even count is already balanced and exercises less. That
    is not a nicety: on a pre-fix build '~' * 262143 heals in 19.1 s and
    '~' * 262144 in 0.005 s, because only the odd run leaves the trailing '~'
    that arms heal_strikethrough. An even count here would test nothing.
    """
    n = max(1, HEAL_SIZE // len(unit))
    if odd and n % 2 == 0:
        n -= 1
    return n


heal_baseline = HEAL_PROSE * heal_repeat(HEAL_PROSE, odd=False)

heal_timed = {
    # heal_links_and_images' backward bracket walk (fixed: a single pass that
    # keeps a stack of open brackets). The trailing ']' is what makes the walk
    # run; without it there is no closer to match.
    "unclosed brackets (heal)":
            ("[" * (heal_repeat("[") - 1)) + "]",
    # heal_comparison_operators: one in_fenced_code_block() rescan per '- > 5'
    # line, plus a whole-tail memmove per inserted backslash (fixed: a
    # resumable FenceScanner and an append-only second buffer).
    "many comparison operators (heal)":
            "- > 5\n" * heal_repeat("- > 5\n"),
    # heal_strikethrough's two descending loops re-asking has_meaningful_content
    # over a range that grows as the index falls (fixed: one hoisted backward
    # scan per loop). The TRAILING '~' is load-bearing -- it is what arms the
    # `size >= 4 && text[size-1] == '~'` guard on the first loop. Ending the
    # input in any other byte drops straight through it and times nothing.
    "unclosed strikethrough (heal)":
            ("~~ " * heal_repeat("~~ ")) + "~",
    # The same heal_strikethrough loops off the plainest possible trigger. An
    # ODD run of tildes ends in the '~' that arms them, so this one is
    # quadratic on a pre-fix build too (19.1 s here, 4.8 s at half the size)
    # -- do not "simplify" the repeat count to an even one.
    "many tildes (heal)":
            "~" * heal_repeat("~"),
    # Paths fixed in the earlier round (in_math_block restarting at offset 0,
    # in_link_url / in_html_tag walking back to the previous newline -- which
    # is the whole document when it has none). Kept as regression guards.
    "many asterisks (heal)":
            "*" * heal_repeat("*"),
    "many emph closers (heal)":
            "a_" * heal_repeat("a_"),
    "many asterisk closers (heal)":
            "a*" * heal_repeat("a*"),
    "many math delimiters (heal)":
            "$" * heal_repeat("$"),
    "many backticks (heal)":
            "`" * heal_repeat("`"),
    "many backtick runs (heal)":
            "a` " * heal_repeat("a` "),
    "many escapes (heal)":
            "\\" * heal_repeat("\\"),
    # Fence-dense input, to drive the FenceScanner cursor rather than the
    # comparison-operator caller that queries it.
    "many code fences (heal)":
            "```\n" * heal_repeat("```\n"),
    # Every marker family interleaved and nested, with an unbalanced tail so
    # the emphasis healers all engage.
    "nested mixed markers (heal)":
            ("***a **b _c_ ~~d~~ `e` $f$ [g](h) "
             * heal_repeat("***a **b _c_ ~~d~~ `e` $f$ [g](h) ")) + "***",
}


def time_heal(program, inp, budget=None):
    """Best-of-HEAL_ATTEMPTS wall time of a `--format=heal` run over `inp`.

    Returns (seconds, rc, output, err); seconds is None if the run was killed
    for exceeding the hard cap. Stops after the first run that fits `budget`
    (None = always run every attempt, used for the baseline itself).
    """
    prog = Prog(cmdline=program, default_options=["--format=heal"])
    # Hard cap so a reintroduced quadratic fails the suite in seconds rather
    # than hanging CI: the bugs above ran for minutes at 1 MB.
    cap = max(30.0, (budget or 0.0) * 30.0)
    best = None
    for _ in range(HEAL_ATTEMPTS):
        start = timer()
        try:
            [rc, actual, err] = prog.to_html(inp, timeout=cap)
        except TimeoutExpired:
            return (None, 0, '', b'')
        end = timer()
        if best is None or end - start < best:
            best = end - start
        if rc != 0:
            return (best, rc, actual, err)
        if budget is None:
            continue
        if best <= budget:
            break                       # already known good, no need to retry
        if best > budget * HEAL_RETRY_MARGIN:
            break                       # far too slow to be a transient stall
    return (best, 0, actual, err)


whitespace_re = re.compile('/s+/')
passed = 0
errored = 0
failed = 0

#print("Testing pathological cases:")
for description in pathological:
    if len(pathological[description]) == 2:
        (inp, regex) = pathological[description]
        prog = Prog(cmdline=args.program)
    else:
        (inp, regex, default_options) = pathological[description]
        prog = Prog(cmdline=args.program, default_options=default_options)

    start = timer()
    [rc, actual, err] = prog.to_html(inp)
    end = timer()
    if rc != 0:
        errored += 1
        print('{:35} [ERRORED (exit code {})]'.format(description, rc))
        print(err)
    elif regex.search(actual):
        print('{:35} [PASSED] {:.3f} secs'.format(description, end-start))
        passed += 1
    else:
        print('{:35} [FAILED]'.format(description))
        print(repr(actual))
        failed += 1

(base_secs, base_rc, base_out, base_err) = time_heal(args.program, heal_baseline)
if base_rc != 0 or base_secs is None:
    errored += 1
    print('{:35} [ERRORED (exit code {})]'.format('heal prose baseline', base_rc))
    print(base_err)
    budget = HEAL_BUDGET_FLOOR
else:
    print('{:35} [PASSED] {:.3f} secs ({} bytes)'.format(
            'heal prose baseline', base_secs, len(heal_baseline)))
    passed += 1
    budget = max(HEAL_BUDGET_FACTOR * base_secs, HEAL_BUDGET_FLOOR)

for description in heal_timed:
    inp = heal_timed[description]
    (secs, rc, actual, err) = time_heal(args.program, inp, budget)
    if secs is None:
        failed += 1
        print('{:35} [FAILED] killed after the {:.3f} sec cap (budget {:.3f} secs)'.format(
                description, max(30.0, budget * 30.0), budget))
    elif rc != 0:
        errored += 1
        print('{:35} [ERRORED (exit code {})]'.format(description, rc))
        print(err)
    elif len(actual) == 0:
        failed += 1
        print('{:35} [FAILED] empty output for {} bytes of input'.format(
                description, len(inp)))
    elif secs > budget:
        failed += 1
        print('{:35} [FAILED] {:.3f} secs > {:.3f} sec budget ({:.1f}x the prose '
              'baseline for the same {} bytes -- likely a quadratic path)'.format(
                description, secs, budget,
                secs / base_secs if base_secs else float('inf'), len(inp)))
    else:
        print('{:35} [PASSED] {:.3f} secs (budget {:.3f})'.format(
                description, secs, budget))
        passed += 1

print("%d passed, %d failed, %d errored" % (passed, failed, errored))
if (failed == 0 and errored == 0):
    exit(0)
else:
    exit(1)
