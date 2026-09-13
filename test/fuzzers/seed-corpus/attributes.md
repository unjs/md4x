**bold**{.highlight}

_italic_{#myid}

`code`{.lang}

~~del~~{.red}

_underline_{.accent}

[Link](https://example.com){target="\_blank" rel="noopener"}

![image](pic.png){.responsive width="100"}

[styled text]{.class-one .class-two}

[**bold** and *italic*]{#special .styled}

**nested _emph_{.inner}**{.outer}

**bind**{:k='hello'}

[Link](https://example.com){:data='{"x":1}'}

**bold**{ }

[t]{=}

[Link](https://example.com "Title"){ }

![image](pic.png "Title"){.}

`code`{#}

Interpolation {{ site.name }}

# Heading {{ title }}

*em*{{ x }} [span]{{ y }} `code`{{ z }}

Template ${amount}

Hello {{ site.name }} {.greeting}

Malformed {"} {=b} {a=} {.a {b}} {a="b} {1x} {a/b=c} {a=b"c}

**b**{"} [t]{=} [t]{=foo} `c`{.} ![a](p){#} [l](u){a=b<c}

*a*{x
y}

Mixed {.ok "}

Valid {#i .a.b data-x aria-label="y" k='v w' u=v :b="e" _p}
