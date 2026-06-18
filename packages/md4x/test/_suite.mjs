import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const nitroIndex = readFileSync(
  join(__dirname, "fixtures/nitro-index.md"),
  "utf-8",
);

export function defineSuite({
  renderToHtml,
  renderToAST,
  renderToAnsi,
  parseAST,
  renderToMeta,
  parseMeta,
  renderToText,
  heal,
}) {
  describe("renderToHtml", () => {
    it("renders a heading", async () => {
      expect(await renderToHtml("# Hello")).toBe("<h1>Hello</h1>\n");
    });

    it("renders a paragraph", async () => {
      expect(await renderToHtml("Hello world")).toBe("<p>Hello world</p>\n");
    });

    it("renders inline formatting", async () => {
      expect(await renderToHtml("**bold** and *italic*")).toBe(
        "<p><strong>bold</strong> and <em>italic</em></p>\n",
      );
    });

    it("renders a link", async () => {
      expect(await renderToHtml("[click](https://example.com)")).toBe(
        '<p><a href="https://example.com">click</a></p>\n',
      );
    });

    it("renders a code block", async () => {
      expect(await renderToHtml("```js\nconsole.log(1)\n```")).toBe(
        '<pre><code class="language-js">console.log(1)\n</code></pre>\n',
      );
    });

    it("renders empty input", async () => {
      expect(await renderToHtml("")).toBe("");
    });

    it("renders multiline content", async () => {
      const html = await renderToHtml("# Title\n\nParagraph\n\n- item");
      expect(html).toContain("<h1>Title</h1>");
      expect(html).toContain("<p>Paragraph</p>");
      expect(html).toContain("<li>item</li>");
    });

    it("supports tables", async () => {
      const html = await renderToHtml("| a | b |\n|---|---|\n| 1 | 2 |");
      expect(html).toContain("<table>");
      expect(html).toContain("<td>1</td>");
    });

    it("supports strikethrough", async () => {
      expect(await renderToHtml("~~strike~~")).toContain("<del>strike</del>");
    });

    it("supports task lists", async () => {
      expect(await renderToHtml("- [x] done\n- [ ] todo")).toContain(
        'type="checkbox"',
      );
    });

    it("supports latex math", async () => {
      expect(await renderToHtml("$E=mc^2$")).toContain("E=mc^2");
    });

    it("renders inline component", async () => {
      expect(await renderToHtml(":icon-star")).toContain("<icon-star>");
    });

    it("renders inline component with content", async () => {
      const html = await renderToHtml(":badge[New]");
      expect(html).toContain("<badge>New</badge>");
    });

    it("renders inline component with props", async () => {
      const html = await renderToHtml(':badge[New]{color="blue"}');
      expect(html).toContain('color="blue"');
      expect(html).toContain("<badge");
      expect(html).toContain("New</badge>");
    });

    it("renders bold and italic combined", async () => {
      const html = await renderToHtml("***Bold and italic***");
      expect(html).toContain("<strong>");
      expect(html).toContain("<em>");
      expect(html).toContain("Bold and italic");
    });

    it("renders a basic image", async () => {
      const html = await renderToHtml("![Alt text](image.png)");
      expect(html).toContain('<img src="image.png" alt="Alt text"');
    });

    it("renders image with title", async () => {
      const html = await renderToHtml('![Alt](image.png "Image title")');
      expect(html).toContain('title="Image title"');
      expect(html).toContain('src="image.png"');
    });

    it("renders link with title", async () => {
      const html = await renderToHtml(
        '[Link](https://example.com "Link title")',
      );
      expect(html).toContain('title="Link title"');
      expect(html).toContain('href="https://example.com"');
    });

    it("renders a blockquote", async () => {
      const html = await renderToHtml("> This is a blockquote");
      expect(html).toContain("<blockquote>");
      expect(html).toContain("This is a blockquote");
    });

    it("renders horizontal rule", async () => {
      expect(await renderToHtml("***")).toContain("<hr");
    });

    it("renders ordered list", async () => {
      const html = await renderToHtml("1. First\n2. Second\n3. Third");
      expect(html).toContain("<ol>");
      expect(html).toContain("<li>First</li>");
    });

    it("renders unordered list with nesting", async () => {
      const html = await renderToHtml("- Item 1\n  - Nested\n- Item 2");
      expect(html).toContain("<ul>");
      expect(html).toContain("Nested");
    });

    it("renders frontmatter", async () => {
      const html = await renderToHtml("---\ntitle: Test\n---\n\n# Content");
      expect(html).not.toContain("<x-frontmatter>");
      expect(html).not.toContain("title: Test");
      expect(html).toContain("<h1>Content</h1>");
    });

    it("renders full HTML document with { full: true }", async () => {
      const html = await renderToHtml("# Hello", { full: true });
      expect(html).toContain("<!DOCTYPE html>");
      expect(html).toContain("<html");
      expect(html).toContain("<head>");
      expect(html).toContain("<body>");
      expect(html).toContain("<h1>Hello</h1>");
      expect(html).toContain("</body>");
      expect(html).toContain("</html>");
    });

    it("uses frontmatter title in full HTML mode", async () => {
      const html = await renderToHtml(
        "---\ntitle: My Page\ndescription: A test page\n---\n\n# Content",
        { full: true },
      );
      expect(html).toContain("<!DOCTYPE html>");
      expect(html).toContain("<title>My Page</title>");
      expect(html).toContain('name="description"');
      expect(html).toContain("A test page");
      expect(html).toContain("<h1>Content</h1>");
    });

    it("renders body-only HTML without full option", async () => {
      const html = await renderToHtml("# Hello");
      expect(html).not.toContain("<!DOCTYPE html>");
      expect(html).toBe("<h1>Hello</h1>\n");
    });

    it("renders aligned table", async () => {
      const html = await renderToHtml(
        "| Left | Right |\n|:-----|------:|\n| a    | b     |",
      );
      expect(html).toContain("<table>");
      expect(html).toContain("align");
    });

    it("renders inline markdown in table cells", async () => {
      const html = await renderToHtml("| a |\n|---|\n| **bold** |");
      expect(html).toContain("<strong>bold</strong>");
      expect(html).toContain("<td>");
    });

    it("renders deep nested block components", async () => {
      const html = await renderToHtml(
        "::::outer\n\n:::middle\n\n::inner\nContent\n::\n\n:::\n\n::::",
      );
      expect(html).toContain("<outer>");
      expect(html).toContain("<middle>");
      expect(html).toContain("<inner>");
      expect(html).toContain("Content");
    });
  });

  describe("renderToAST", () => {
    it("returns a string", async () => {
      const json = await renderToAST("# Hello");
      expect(typeof json).toBe("string");
    });

    it("returns valid JSON", async () => {
      const json = await renderToAST("# Hello");
      const parsed = JSON.parse(json);
      expect(parsed.nodes).toBeInstanceOf(Array);
    });

    it("returns empty string for empty input", async () => {
      const json = await renderToAST("");
      const parsed = JSON.parse(json);
      expect(parsed.nodes).toHaveLength(0);
    });
  });

  describe("parseAST", () => {
    it("returns comark tree", async () => {
      const ast = await parseAST("# Hello");
      expect(ast.nodes).toBeInstanceOf(Array);
      expect(ast.frontmatter).toEqual({});
      expect(ast.meta).toEqual({});
    });

    it("parses heading as h1 tuple", async () => {
      const ast = await parseAST("# Hello");
      const h1 = ast.nodes[0];
      expect(h1[0]).toBe("h1");
      expect(h1[1]).toEqual({});
      expect(h1[2]).toBe("Hello");
    });

    it("parses paragraph with inline formatting", async () => {
      const ast = await parseAST("**bold**");
      const p = ast.nodes[0];
      expect(p[0]).toBe("p");
      const strong = p[2];
      expect(strong[0]).toBe("strong");
      expect(strong[2]).toBe("bold");
    });

    it("parses code block as pre > code", async () => {
      const ast = await parseAST("```js\ncode\n```");
      const pre = ast.nodes[0];
      expect(pre[0]).toBe("pre");
      expect(pre[1].language).toBe("js");
      const code = pre[2];
      expect(code[0]).toBe("code");
      expect(code[1].class).toBe("language-js");
      expect(code[2]).toContain("code");
    });

    it("parses empty input", async () => {
      const ast = await parseAST("");
      expect(ast.nodes).toHaveLength(0);
      expect(ast.frontmatter).toEqual({});
    });

    it("parses link as anchor tuple", async () => {
      const ast = await parseAST("[text](https://example.com)");
      const p = ast.nodes[0];
      const a = p[2];
      expect(a[0]).toBe("a");
      expect(a[1].href).toBe("https://example.com");
      expect(a[2]).toBe("text");
    });

    it("parses inline elements", async () => {
      const ast = await parseAST("hello **world**");
      const p = ast.nodes[0];
      expect(p[0]).toBe("p");
      expect(p[2]).toBe("hello ");
      expect(p[3][0]).toBe("strong");
      expect(p[3][2]).toBe("world");
    });

    it("text nodes are plain strings", async () => {
      const ast = await parseAST("hello");
      const p = ast.nodes[0];
      expect(typeof p[2]).toBe("string");
      expect(p[2]).toBe("hello");
    });

    it("parses code block filename", async () => {
      const ast = await parseAST("```js [app.js]\nconsole.log(1)\n```");
      const pre = ast.nodes[0];
      expect(pre[0]).toBe("pre");
      expect(pre[1].language).toBe("js");
      expect(pre[1].filename).toBe("app.js");
    });

    it("parses code block highlights", async () => {
      const ast = await parseAST("```js {1-3,5}\na\nb\nc\nd\ne\n```");
      const pre = ast.nodes[0];
      expect(pre[1].highlights).toEqual([1, 2, 3, 5]);
    });

    it("parses code block with filename, highlights and meta", async () => {
      const ast = await parseAST(
        "```ts {1-2} [utils.ts] meta=value\ncode\n```",
      );
      const pre = ast.nodes[0];
      expect(pre[1].language).toBe("ts");
      expect(pre[1].filename).toBe("utils.ts");
      expect(pre[1].highlights).toEqual([1, 2]);
      expect(pre[1].meta).toBe("meta=value");
    });

    it("parses code block with escaped filename", async () => {
      const ast = await parseAST("```ts [@[...slug\\].ts]\ncode\n```");
      const pre = ast.nodes[0];
      expect(pre[1].filename).toBe("@[...slug].ts");
    });

    it("code block without metadata has no extra props", async () => {
      const ast = await parseAST("```js\ncode\n```");
      const pre = ast.nodes[0];
      expect(pre[1].filename).toBeUndefined();
      expect(pre[1].highlights).toBeUndefined();
      expect(pre[1].meta).toBeUndefined();
    });

    it("parses standalone inline component", async () => {
      const ast = await parseAST(":icon-star");
      const p = ast.nodes[0];
      expect(p[0]).toBe("p");
      const comp = p[2];
      expect(comp[0]).toBe("icon-star");
      expect(comp[1]).toEqual({});
    });

    it("parses inline component with content", async () => {
      const ast = await parseAST(":badge[New]");
      const p = ast.nodes[0];
      const comp = p[2];
      expect(comp[0]).toBe("badge");
      expect(comp[2]).toBe("New");
    });

    it("parses inline component with content and props", async () => {
      const ast = await parseAST(':badge[New]{color="blue"}');
      const p = ast.nodes[0];
      const comp = p[2];
      expect(comp[0]).toBe("badge");
      expect(comp[1].color).toBe("blue");
      expect(comp[2]).toBe("New");
    });

    it("parses inline component with props only", async () => {
      const ast = await parseAST(':tooltip{text="Hover"}');
      const p = ast.nodes[0];
      const comp = p[2];
      expect(comp[0]).toBe("tooltip");
      expect(comp[1].text).toBe("Hover");
    });

    it("parses inline component with id and class props", async () => {
      const ast = await parseAST(":badge[Text]{#my-id .highlight}");
      const p = ast.nodes[0];
      const comp = p[2];
      expect(comp[0]).toBe("badge");
      expect(comp[1].id).toBe("my-id");
      expect(comp[1].class).toBe("highlight");
      expect(comp[2]).toBe("Text");
    });

    it("parses inline component with boolean prop", async () => {
      const ast = await parseAST(":alert{dismissible}");
      const p = ast.nodes[0];
      const comp = p[2];
      expect(comp[0]).toBe("alert");
      expect(comp[1][":dismissible"]).toBe("true");
    });

    it("inline component with markdown content", async () => {
      const ast = await parseAST(":badge[**bold** text]");
      const p = ast.nodes[0];
      const comp = p[2];
      expect(comp[0]).toBe("badge");
      // First child is strong element
      expect(comp[2][0]).toBe("strong");
      expect(comp[2][2]).toBe("bold");
      // Second child is text
      expect(comp[3]).toBe(" text");
    });

    it("parses basic image AST", async () => {
      const ast = await parseAST("![Alt text](image.png)");
      const p = ast.nodes[0];
      const img = p[2];
      expect(img[0]).toBe("img");
      expect(img[1].src).toBe("image.png");
      expect(img[1].alt).toBe("Alt text");
    });

    it("parses link with title AST", async () => {
      const ast = await parseAST('[Link](https://example.com "title")');
      const p = ast.nodes[0];
      const a = p[2];
      expect(a[0]).toBe("a");
      expect(a[1].href).toBe("https://example.com");
      expect(a[1].title).toBe("title");
    });

    it("parses blockquote AST", async () => {
      const ast = await parseAST("> Quote text");
      const bq = ast.nodes[0];
      expect(bq[0]).toBe("blockquote");
    });

    it("parses horizontal rule AST", async () => {
      const ast = await parseAST("***");
      const hr = ast.nodes[0];
      expect(hr[0]).toBe("hr");
    });

    it("parses ordered list AST", async () => {
      const ast = await parseAST("1. First\n2. Second");
      const ol = ast.nodes[0];
      expect(ol[0]).toBe("ol");
    });

    it("parses unordered list AST", async () => {
      const ast = await parseAST("- Item 1\n- Item 2");
      const ul = ast.nodes[0];
      expect(ul[0]).toBe("ul");
    });

    it("parses frontmatter AST with YAML props", async () => {
      const ast = await parseAST(
        "---\ntitle: Hello\ncount: 42\ndraft: true\n---\n\n# Content",
      );
      expect(ast.frontmatter).toEqual({
        title: "Hello",
        count: 42,
        draft: true,
      });
      expect(ast.nodes[0][0]).toBe("h1");
    });

    it("parses frontmatter YAML type coercion", async () => {
      const ast = await parseAST(
        '---\nstr: hello\nquoted: "world"\nnum: 3.14\nneg: -1\nbool_yes: yes\nbool_no: no\nnull_val: null\ntilde: ~\nempty:\n---',
      );
      const props = ast.frontmatter;
      expect(props.str).toBe("hello");
      expect(props.quoted).toBe("world");
      expect(props.num).toBe(3.14);
      expect(props.neg).toBe(-1);
      expect(props.bool_yes).toBe(true);
      expect(props.bool_no).toBe(false);
      expect(props.null_val).toBe(null);
      expect(props.tilde).toBe(null);
      expect(props.empty).toBe(null);
    });

    it("parses frontmatter with indented fences", async () => {
      const ast = await parseAST("   ---\ntitle: Hello\n   ---\n\n# Content");
      expect(ast.frontmatter).toEqual({ title: "Hello" });
      expect(ast.nodes[0][0]).toBe("h1");
    });

    it("parses frontmatter with nested objects", async () => {
      const ast = await parseAST(
        "---\nauthor:\n  name: John\n  email: john@example.com\n---",
      );
      expect(ast.frontmatter.author).toEqual({
        name: "John",
        email: "john@example.com",
      });
    });

    it("parses frontmatter with arrays", async () => {
      const ast = await parseAST(
        "---\ntags:\n  - javascript\n  - typescript\n---",
      );
      expect(ast.frontmatter.tags).toEqual(["javascript", "typescript"]);
    });

    it("parses frontmatter with inline flow sequence", async () => {
      const ast = await parseAST("---\ntags: [javascript, typescript]\n---");
      expect(ast.frontmatter.tags).toEqual(["javascript", "typescript"]);
    });

    it("parses frontmatter with mixed types in array", async () => {
      const ast = await parseAST(
        "---\ndata:\n  - hello\n  - 42\n  - true\n---",
      );
      expect(ast.frontmatter.data).toEqual(["hello", 42, true]);
    });

    it("parses frontmatter with deeply nested structure", async () => {
      const ast = await parseAST(
        "---\nmeta:\n  author:\n    name: John\n  date: 2024\n---",
      );
      expect(ast.frontmatter.meta).toEqual({
        author: { name: "John" },
        date: 2024,
      });
    });

    it("parses frontmatter with multi-line literal block", async () => {
      const ast = await parseAST(
        "---\ndescription: |\n  Line 1\n  Line 2\n---",
      );
      expect(ast.frontmatter.description).toContain("Line 1");
      expect(ast.frontmatter.description).toContain("Line 2");
    });

    it.skip("parses excerpt with <!-- more --> separator", async () => {
      const ast = await parseAST(
        "# Title\n\nIntro paragraph\n\n<!-- more -->\n\nFull content",
      );
      expect(ast.excerpt).toBeDefined();
    });
  });

  describe("block components", () => {
    it("renders block component HTML", async () => {
      const html = await renderToHtml("::alert\nHello world\n::");
      expect(html).toContain("<alert>");
      expect(html).toContain("<p>Hello world</p>");
      expect(html).toContain("</alert>");
    });

    it("renders block component with props HTML", async () => {
      const html = await renderToHtml('::alert{type="info"}\nMessage\n::');
      expect(html).toContain('<alert type="info">');
      expect(html).toContain("</alert>");
    });

    it("parses block component AST", async () => {
      const ast = await parseAST("::alert\nHello\n::");
      const comp = ast.nodes[0];
      expect(comp[0]).toBe("alert");
      expect(comp[1]).toEqual({});
      // Child is a paragraph
      const p = comp[2];
      expect(p[0]).toBe("p");
      expect(p[2]).toBe("Hello");
    });

    it("parses block component with props AST", async () => {
      const ast = await parseAST('::alert{type="info"}\nMessage\n::');
      const comp = ast.nodes[0];
      expect(comp[0]).toBe("alert");
      expect(comp[1].type).toBe("info");
    });

    it("parses nested block components AST", async () => {
      const ast = await parseAST(
        ":::outer\nOuter\n\n::inner\nInner\n::\n\n:::",
      );
      const outer = ast.nodes[0];
      expect(outer[0]).toBe("outer");
      // First child: paragraph "Outer"
      expect(outer[2][0]).toBe("p");
      expect(outer[2][2]).toBe("Outer");
      // Second child: inner component
      const inner = outer[3];
      expect(inner[0]).toBe("inner");
      expect(inner[2][0]).toBe("p");
      expect(inner[2][2]).toBe("Inner");
    });

    it("parses empty block component AST", async () => {
      const ast = await parseAST("::divider\n::");
      const comp = ast.nodes[0];
      expect(comp[0]).toBe("divider");
      expect(comp.length).toBe(2); // [tag, props] with no children
    });

    it("block component with markdown content AST", async () => {
      const ast = await parseAST("::card\n# Title\n\nParagraph\n::");
      const card = ast.nodes[0];
      expect(card[0]).toBe("card");
      expect(card[2][0]).toBe("h1");
      expect(card[2][2]).toBe("Title");
      expect(card[3][0]).toBe("p");
      expect(card[3][2]).toBe("Paragraph");
    });

    it("parses block component with id and class AST", async () => {
      const ast = await parseAST("::alert{#my-id .highlight}\nText\n::");
      const comp = ast.nodes[0];
      expect(comp[0]).toBe("alert");
      expect(comp[1].id).toBe("my-id");
      expect(comp[1].class).toBe("highlight");
    });

    it("parses block component with boolean prop AST", async () => {
      const ast = await parseAST("::alert{dismissible}\nText\n::");
      const comp = ast.nodes[0];
      expect(comp[0]).toBe("alert");
      expect(comp[1][":dismissible"]).toBe("true");
    });

    it("parses deep nested block components AST", async () => {
      const ast = await parseAST(
        "::::l1\n\n:::l2\n\n::l3\nDeep\n::\n\n:::\n\n::::",
      );
      const l1 = ast.nodes[0];
      expect(l1[0]).toBe("l1");
      const l2 = l1[2];
      expect(l2[0]).toBe("l2");
      const l3 = l2[2];
      expect(l3[0]).toBe("l3");
    });

    it("parses block component with named slots AST", async () => {
      const ast = await parseAST(
        "::card\n#header\n## Card Title\n\n#content\nMain content\n\n#footer\nFooter text\n::",
      );
      const card = ast.nodes[0];
      expect(card[0]).toBe("card");
      const header = card[2];
      expect(header[0]).toBe("template");
      expect(header[1].name).toBe("header");
      const content = card[3];
      expect(content[0]).toBe("template");
      expect(content[1].name).toBe("content");
      const footer = card[4];
      expect(footer[0]).toBe("template");
      expect(footer[1].name).toBe("footer");
    });

    it("renders single slot HTML", async () => {
      const html = await renderToHtml("::card\n#title\nCard Title\n::");
      expect(html).toContain('<template name="title">');
      expect(html).toContain("</template>");
      expect(html).toContain("<p>Card Title</p>");
    });

    it("parses default content before named slot AST", async () => {
      const ast = await parseAST(
        "::card\nDefault content\n\n#title\nCard Title\n::",
      );
      const card = ast.nodes[0];
      expect(card[0]).toBe("card");
      // Default content is a direct child (paragraph)
      expect(card[2][0]).toBe("p");
      expect(card[2][2]).toBe("Default content");
      // Named slot follows
      const tmpl = card[3];
      expect(tmpl[0]).toBe("template");
      expect(tmpl[1].name).toBe("title");
    });

    it("parses empty slot AST", async () => {
      const ast = await parseAST("::card\n#empty\n#content\nText here\n::");
      const card = ast.nodes[0];
      const empty = card[2];
      expect(empty[0]).toBe("template");
      expect(empty[1].name).toBe("empty");
      expect(empty.length).toBe(2); // no children
      const content = card[3];
      expect(content[0]).toBe("template");
      expect(content[1].name).toBe("content");
    });
  });

  describe("block component title (VitePress-style)", () => {
    it("renders block component with title HTML", async () => {
      const html = await renderToHtml(":::danger STOP\nDanger zone\n:::");
      expect(html).toContain('<danger title="STOP">');
      expect(html).toContain("<p>Danger zone</p>");
      expect(html).toContain("</danger>");
    });

    it("parses block component with title AST", async () => {
      const ast = await parseAST(":::danger STOP\nDanger zone\n:::");
      const comp = ast.nodes[0];
      expect(comp[0]).toBe("danger");
      expect(comp[1].title).toBe("STOP");
      expect(comp[2][2]).toBe("Danger zone");
    });

    it("parses block component with multi-word title AST", async () => {
      const ast = await parseAST(":::details Click me to toggle\nContent\n:::");
      const comp = ast.nodes[0];
      expect(comp[0]).toBe("details");
      expect(comp[1].title).toBe("Click me to toggle");
    });

    it("parses block component with title and props AST", async () => {
      const ast = await parseAST(":::warning Be careful {open}\nContent\n:::");
      const comp = ast.nodes[0];
      expect(comp[0]).toBe("warning");
      expect(comp[1].title).toBe("Be careful");
      expect(comp[1][":open"]).toBe("true");
    });

    it("block component without title has no title prop", async () => {
      const ast = await parseAST("::alert\nContent\n::");
      const comp = ast.nodes[0];
      expect(comp[1].title).toBeUndefined();
    });

    it("supports space between colons and name", async () => {
      const ast = await parseAST("::: info\nContent\n:::");
      const comp = ast.nodes[0];
      expect(comp[0]).toBe("info");
    });

    it("supports space between colons and name with title", async () => {
      const ast = await parseAST("::: danger STOP\nContent\n:::");
      const comp = ast.nodes[0];
      expect(comp[0]).toBe("danger");
      expect(comp[1].title).toBe("STOP");
    });
  });

  describe("component frontmatter", () => {
    it("parses YAML frontmatter as component props in AST", async () => {
      const ast = await parseAST(
        "::card\n\n---\nicon: star\ntitle: Hello\n---\n\nContent\n::",
      );
      const card = ast.nodes[0];
      expect(card[0]).toBe("card");
      expect(card[1].icon).toBe("star");
      expect(card[1].title).toBe("Hello");
      // Content child, no frontmatter child
      expect(card[2][0]).toBe("p");
      expect(card[2][2]).toBe("Content");
    });

    it("merges frontmatter with inline props in AST", async () => {
      const ast = await parseAST(
        '::card{type="info"}\n\n---\nicon: star\n---\n\nContent\n::',
      );
      const card = ast.nodes[0];
      expect(card[1].type).toBe("info");
      expect(card[1].icon).toBe("star");
    });

    it("renders frontmatter as HTML attributes", async () => {
      const html = await renderToHtml(
        "::card\n\n---\nicon: star\ntitle: Hello\n---\n\nContent\n::",
      );
      expect(html).toContain('<card icon="star" title="Hello">');
      expect(html).toContain("<p>Content</p>");
    });

    it("does not treat --- as frontmatter after content", async () => {
      const ast = await parseAST("::card\nSome text\n\n---\n\nMore text\n::");
      const card = ast.nodes[0];
      // First non-blank line is text, so --- is an HR
      expect(card[1]).toEqual({});
      const tags = card.slice(2).map((c) => c[0]);
      expect(tags).toContain("hr");
    });

    it("frontmatter YAML type coercion in component", async () => {
      const ast = await parseAST(
        "::card\n\n---\ncount: 42\nenabled: true\n---\n\n::",
      );
      const card = ast.nodes[0];
      expect(card[1].count).toBe(42);
      expect(card[1].enabled).toBe(true);
    });

    it("nested component frontmatter in AST", async () => {
      const ast = await parseAST(
        ":::outer\n::inner\n\n---\nkey: value\n---\n\nContent\n::\n:::",
      );
      const outer = ast.nodes[0];
      expect(outer[0]).toBe("outer");
      const inner = outer[2];
      expect(inner[0]).toBe("inner");
      expect(inner[1].key).toBe("value");
      expect(inner[2][0]).toBe("p");
    });

    it("suppresses frontmatter from ANSI output", async () => {
      const ansi = await renderToAnsi(
        "::card\n\n---\nicon: star\n---\n\nContent\n::",
      );
      expect(ansi).not.toContain("icon");
      expect(ansi).not.toContain("star");
      expect(ansi).toContain("Content");
    });

    it("suppresses frontmatter from text output", async () => {
      const text = await renderToText(
        "::card\n\n---\nicon: star\n---\n\nContent\n::",
      );
      expect(text).not.toContain("icon");
      expect(text).toContain("Content");
    });
  });

  describe("component property parsing", () => {
    it("merges multiple classes", async () => {
      const ast = await parseAST(":badge[Text]{.foo .bar .baz}");
      const comp = ast.nodes[0][2];
      expect(comp[0]).toBe("badge");
      expect(comp[1].class).toBe("foo bar baz");
    });

    it("merges multiple classes on block component", async () => {
      const ast = await parseAST("::alert{.warning .large}\nMsg\n::");
      const comp = ast.nodes[0];
      expect(comp[0]).toBe("alert");
      expect(comp[1].class).toBe("warning large");
    });

    it("handles single-quoted string values", async () => {
      const ast = await parseAST(":badge[Text]{color='blue'}");
      const comp = ast.nodes[0][2];
      expect(comp[1].color).toBe("blue");
    });

    it("handles mixed props with id, classes, key-value, and boolean", async () => {
      const ast = await parseAST(':badge[T]{#myid .cls1 .cls2 key="val" flag}');
      const comp = ast.nodes[0][2];
      expect(comp[1].id).toBe("myid");
      expect(comp[1].class).toBe("cls1 cls2");
      expect(comp[1].key).toBe("val");
      expect(comp[1][":flag"]).toBe("true");
    });

    it("handles empty props object", async () => {
      const ast = await parseAST(":badge[Text]{}");
      const comp = ast.nodes[0][2];
      expect(comp[0]).toBe("badge");
      expect(comp[1]).toEqual({});
    });

    it("handles bind syntax in props", async () => {
      const ast = await parseAST(":widget{:data='{\"x\":1}'}");
      const comp = ast.nodes[0][2];
      expect(comp[0]).toBe("widget");
      expect(comp[1][":data"]).toEqual({ x: 1 });
    });

    it("renders merged classes in HTML", async () => {
      const html = await renderToHtml(":badge[Text]{.foo .bar .baz}");
      expect(html).toContain('class="foo bar baz"');
    });

    it("renders mixed props in HTML", async () => {
      const html = await renderToHtml(
        ':badge[T]{#myid .cls1 .cls2 key="val" flag}',
      );
      expect(html).toContain('id="myid"');
      expect(html).toContain('class="cls1 cls2"');
      expect(html).toContain('key="val"');
      expect(html).toContain("flag");
    });

    it("handles array/JSON prop value", async () => {
      const ast = await parseAST(':widget{:items=\'["a","b"]\'}');
      const comp = ast.nodes[0][2];
      expect(comp[0]).toBe("widget");
      expect(comp[1][":items"]).toEqual(["a", "b"]);
    });
  });

  describe("inline attributes", () => {
    it("renders strong with class HTML", async () => {
      const html = await renderToHtml("**bold**{.highlight}");
      expect(html).toContain('<strong class="highlight">bold</strong>');
    });

    it("renders emphasis with id HTML", async () => {
      const html = await renderToHtml("*italic*{#myid}");
      expect(html).toContain('<em id="myid">italic</em>');
    });

    it("renders code span with class HTML", async () => {
      const html = await renderToHtml("`code`{.lang}");
      expect(html).toContain('<code class="lang">code</code>');
    });

    it("renders link with target HTML", async () => {
      const html = await renderToHtml(
        '[Link](https://example.com){target="_blank"}',
      );
      expect(html).toContain('target="_blank"');
      expect(html).toContain('<a href="https://example.com"');
    });

    it("renders image with class HTML", async () => {
      const html = await renderToHtml("![alt](img.png){.responsive}");
      expect(html).toContain(
        '<img src="img.png" alt="alt" class="responsive">',
      );
    });

    it("renders span syntax HTML", async () => {
      const html = await renderToHtml("[text]{.class}");
      expect(html).toContain('<span class="class">text</span>');
    });

    it("renders span with mixed attrs HTML", async () => {
      const html = await renderToHtml('[text]{#myid .cls key="val"}');
      expect(html).toContain('id="myid"');
      expect(html).toContain('class="cls"');
      expect(html).toContain('key="val"');
      expect(html).toContain("<span");
    });

    it("parses strong with attrs AST", async () => {
      const ast = await parseAST("**bold**{.highlight}");
      const p = ast.nodes[0];
      const strong = p[2];
      expect(strong[0]).toBe("strong");
      expect(strong[1].class).toBe("highlight");
      expect(strong[2]).toBe("bold");
    });

    it("parses emphasis with attrs AST", async () => {
      const ast = await parseAST("*italic*{#myid}");
      const p = ast.nodes[0];
      const em = p[2];
      expect(em[0]).toBe("em");
      expect(em[1].id).toBe("myid");
      expect(em[2]).toBe("italic");
    });

    it("parses code span with attrs AST", async () => {
      const ast = await parseAST("`code`{.lang}");
      const p = ast.nodes[0];
      const code = p[2];
      expect(code[0]).toBe("code");
      expect(code[1].class).toBe("lang");
      expect(code[2]).toBe("code");
    });

    it("parses link with attrs AST", async () => {
      const ast = await parseAST(
        '[Link](https://example.com){target="_blank"}',
      );
      const p = ast.nodes[0];
      const a = p[2];
      expect(a[0]).toBe("a");
      expect(a[1].href).toBe("https://example.com");
      expect(a[1].target).toBe("_blank");
      expect(a[2]).toBe("Link");
    });

    it("parses image with attrs AST", async () => {
      const ast = await parseAST("![alt](img.png){.responsive}");
      const p = ast.nodes[0];
      const img = p[2];
      expect(img[0]).toBe("img");
      expect(img[1].src).toBe("img.png");
      expect(img[1].class).toBe("responsive");
    });

    it("parses span syntax AST", async () => {
      const ast = await parseAST("[text]{.class}");
      const p = ast.nodes[0];
      const span = p[2];
      expect(span[0]).toBe("span");
      expect(span[1].class).toBe("class");
      expect(span[2]).toBe("text");
    });

    it("parses span with multiple classes AST", async () => {
      const ast = await parseAST("[text]{.foo .bar .baz}");
      const p = ast.nodes[0];
      const span = p[2];
      expect(span[0]).toBe("span");
      expect(span[1].class).toBe("foo bar baz");
    });

    it("span with inline markdown AST", async () => {
      const ast = await parseAST("[**bold** text]{.styled}");
      const p = ast.nodes[0];
      const span = p[2];
      expect(span[0]).toBe("span");
      expect(span[1].class).toBe("styled");
      expect(span[2][0]).toBe("strong");
      expect(span[2][2]).toBe("bold");
      expect(span[3]).toBe(" text");
    });

    it("element without attrs has no extra props", async () => {
      const ast = await parseAST("**bold**");
      const p = ast.nodes[0];
      const strong = p[2];
      expect(strong[0]).toBe("strong");
      expect(strong[1]).toEqual({});
    });

    it("empty attrs have no effect AST", async () => {
      const ast = await parseAST("**bold**{}");
      const p = ast.nodes[0];
      const strong = p[2];
      expect(strong[0]).toBe("strong");
      expect(strong[1]).toEqual({});
    });

    it("plain text followed by braces is not attrs", async () => {
      const html = await renderToHtml("hello{.class}");
      expect(html).toContain("hello{.class}");
      expect(html).not.toContain("<span");
    });

    it("renders strikethrough with attrs HTML", async () => {
      const html = await renderToHtml("~~del~~{.red}");
      expect(html).toContain('<del class="red">del</del>');
    });

    it("renders strong with boolean attr HTML", async () => {
      const html = await renderToHtml("**bold**{flag}");
      expect(html).toContain("<strong");
      expect(html).toContain("flag");
      expect(html).toContain(">bold</strong>");
    });

    it("renders strong with data attr HTML", async () => {
      const html = await renderToHtml('**bold**{data-value="custom"}');
      expect(html).toContain('data-value="custom"');
      expect(html).toContain(">bold</strong>");
    });

    it("parses strikethrough with attrs AST", async () => {
      const ast = await parseAST("~~del~~{.red}");
      const p = ast.nodes[0];
      const del = p[2];
      expect(del[0]).toBe("del");
      expect(del[1].class).toBe("red");
    });

    it("parses strong with boolean attr AST", async () => {
      const ast = await parseAST("**bold**{flag}");
      const p = ast.nodes[0];
      const strong = p[2];
      expect(strong[0]).toBe("strong");
      expect(strong[1][":flag"]).toBe("true");
    });

    it("parses strong with data attr AST", async () => {
      const ast = await parseAST('**bold**{data-value="custom"}');
      const p = ast.nodes[0];
      const strong = p[2];
      expect(strong[0]).toBe("strong");
      expect(strong[1]["data-value"]).toBe("custom");
    });

    it.skip("renders heading with auto-id", async () => {
      const html = await renderToHtml("# Hello World");
      expect(html).toContain('id="hello-world"');
    });

    it.skip("renders emoji", async () => {
      const html = await renderToHtml("Hello :wave:");
      expect(html).toContain("\u{1F44B}");
    });
  });

  describe("HTML comments", () => {
    it("parses block comment as null-tag element", async () => {
      const ast = await parseAST("<!-- This is a comment -->");
      const comment = ast.nodes[0];
      expect(comment[0]).toBeNull();
      expect(comment[1]).toEqual({});
      expect(comment[2]).toBe(" This is a comment ");
    });

    it("parses inline comment", async () => {
      const ast = await parseAST("Text before <!-- comment --> text after");
      const p = ast.nodes[0];
      expect(p[0]).toBe("p");
      expect(p[2]).toBe("Text before ");
      expect(p[3][0]).toBeNull();
      expect(p[3][2]).toBe(" comment ");
      expect(p[4]).toBe(" text after");
    });

    it("parses multi-line block comment", async () => {
      const ast = await parseAST("<!--\nMulti-line\ncomment\n-->");
      const comment = ast.nodes[0];
      expect(comment[0]).toBeNull();
      expect(comment[2]).toBe("\nMulti-line\ncomment\n");
    });

    it("keeps non-comment HTML blocks as html_block", async () => {
      const ast = await parseAST("<div>hello</div>");
      const block = ast.nodes[0];
      expect(block[0]).toBe("html_block");
    });
  });

  describe("real-world: nitro docs", () => {
    // Helper to recursively collect all element tag names from AST
    function collectTags(nodes, tags = []) {
      if (!Array.isArray(nodes)) return tags;
      for (const n of nodes) {
        if (Array.isArray(n)) {
          tags.push(n[0]);
          for (let i = 2; i < n.length; i++) {
            if (Array.isArray(n[i])) collectTags([n[i]], tags);
          }
        }
      }
      return tags;
    }

    // Helper to find elements by tag name (recursive)
    function findAll(nodes, tag) {
      const result = [];
      if (!Array.isArray(nodes)) return result;
      for (const n of nodes) {
        if (Array.isArray(n)) {
          if (n[0] === tag) result.push(n);
          for (let i = 2; i < n.length; i++) {
            if (Array.isArray(n[i])) result.push(...findAll([n[i]], tag));
          }
        }
      }
      return result;
    }

    it("parses without error", async () => {
      const ast = await parseAST(nitroIndex);
      expect(ast.nodes.length).toBeGreaterThan(0);
      expect(ast.frontmatter).toBeDefined();
    });

    it("parses frontmatter with nested seo object", async () => {
      const ast = await parseAST(nitroIndex);
      expect(ast.frontmatter.seo).toEqual({
        title: "Ship Full-Stack Vite Apps",
        description:
          "Nitro extends your Vite application with a production-ready server, compatible with any runtime. Add server routes to your application and deploy many hosting platform with a zero-config experience.",
      });
    });

    it("detects top-level block components", async () => {
      const ast = await parseAST(nitroIndex);
      const topTags = ast.nodes.map((n) => (Array.isArray(n) ? n[0] : null));
      expect(topTags).toContain("u-page-hero");
      expect(topTags).toContain("div");
      expect(topTags).toContain("u-page-section");
    });

    it("detects nested block components", async () => {
      const ast = await parseAST(nitroIndex);
      const allTags = collectTags(ast.nodes);
      expect(allTags).toContain("code-group");
      expect(allTags).toContain("prose-pre");
      expect(allTags).toContain("u-button");
      expect(allTags).toContain("u-container");
      expect(allTags).toContain("tabs");
      // Deeply indented components (previously missed due to code block detection)
      expect(allTags).toContain("u-page-grid");
      expect(allTags).toContain("u-page-feature");
      expect(allTags).toContain("tabs-item");
      expect(allTags).toContain("code-tree");
    });

    it("detects inline components", async () => {
      const ast = await parseAST(nitroIndex);
      const allTags = collectTags(ast.nodes);
      expect(allTags).toContain("hero-background");
      expect(allTags).toContain("page-sponsors");
      expect(allTags).toContain("page-contributors");
    });

    it("detects named slots (templates)", async () => {
      const ast = await parseAST(nitroIndex);
      const templates = findAll(ast.nodes, "template");
      const slotNames = templates.map((t) => t[1].name);
      expect(slotNames).toContain("title");
      expect(slotNames).toContain("description");
      expect(slotNames).toContain("links");
      expect(slotNames).toContain("default");
    });

    it("detects component props", async () => {
      const ast = await parseAST(nitroIndex);
      const divs = findAll(ast.nodes, "div");
      const withClass = divs.find((d) => d[1].class?.includes("bg-neutral-50"));
      expect(withClass).toBeDefined();
    });

    it("detects u-button components inside slots", async () => {
      const ast = await parseAST(nitroIndex);
      const buttons = findAll(ast.nodes, "u-button");
      expect(buttons.length).toBe(2);
    });

    it("detects deeply nested tabs-item with props", async () => {
      const ast = await parseAST(nitroIndex);
      const tabsItems = findAll(ast.nodes, "tabs-item");
      expect(tabsItems.length).toBe(5);
      expect(tabsItems[0][1].label).toBe("FS Routing");
      expect(tabsItems[0][1].icon).toBe("i-lucide-folder");
    });

    it("detects u-page-feature components with slots", async () => {
      const ast = await parseAST(nitroIndex);
      const features = findAll(ast.nodes, "u-page-feature");
      expect(features.length).toBe(3);
      // Each feature has title and description slots
      for (const feature of features) {
        const slots = feature
          .slice(2)
          .filter((c) => Array.isArray(c) && c[0] === "template");
        expect(slots.length).toBe(2);
      }
    });

    it("renders HTML without error", async () => {
      const html = await renderToHtml(nitroIndex);
      expect(html).toContain('<u-page-hero orientation="horizontal">');
      expect(html).toContain('<u-page-section orientation="horizontal">');
      expect(html).toContain("</u-page-hero>");
    });

    it("renders ANSI without error", async () => {
      const ansi = await renderToAnsi(nitroIndex);
      expect(ansi.length).toBeGreaterThan(0);
    });
  });

  describe("renderToHtml with highlighter", () => {
    function collectBlocks(md) {
      const blocks = [];
      const html = renderToHtml(md, {
        highlighter: (code, block) => {
          blocks.push({ code, ...block });
          return undefined; // keep default rendering
        },
      });
      return { html, blocks };
    }

    it("no code blocks calls highlighter zero times", async () => {
      const { html, blocks } = await collectBlocks("# Hello");
      expect(html).toBe("<h1>Hello</h1>\n");
      expect(blocks).toEqual([]);
    });

    it("receives code block metadata with correct content", async () => {
      const { blocks } = await collectBlocks("```js\nconsole.log(1)\n```");
      expect(blocks).toHaveLength(1);
      expect(blocks[0].lang).toBe("js");
      expect(blocks[0].code).toBe("console.log(1)\n");
    });

    it("receives filename and highlights", async () => {
      const { blocks } = await collectBlocks(
        "```ts [app.ts] {1,3}\na\nb\nc\n```",
      );
      expect(blocks[0].lang).toBe("ts");
      expect(blocks[0].filename).toBe("app.ts");
      expect(blocks[0].highlights).toEqual([1, 3]);
    });

    it("tracks multiple code blocks in order", async () => {
      const md = "# Title\n\n```js\nfoo\n```\n\nText\n\n```py\nbar\n```";
      const { blocks } = await collectBlocks(md);
      expect(blocks).toHaveLength(2);
      expect(blocks[0].lang).toBe("js");
      expect(blocks[0].code).toBe("foo\n");
      expect(blocks[1].lang).toBe("py");
      expect(blocks[1].code).toBe("bar\n");
    });

    it("unescapes HTML entities in code", async () => {
      const { blocks } = await collectBlocks("```html\n<div>&</div>\n```");
      expect(blocks).toHaveLength(1);
      expect(blocks[0].code).toContain("<div>");
      expect(blocks[0].code).toContain("&");
    });

    it("handles empty code block", async () => {
      const { blocks } = await collectBlocks("```js\n```");
      expect(blocks).toHaveLength(1);
      expect(blocks[0].lang).toBe("js");
      expect(blocks[0].code).toBe("");
    });

    it("handles code block without language", async () => {
      const { blocks } = await collectBlocks("```\nhello\n```");
      expect(blocks).toHaveLength(1);
      expect(blocks[0].lang).toBe("");
      expect(blocks[0].code).toBe("hello\n");
    });

    it("replaces code when highlighter returns string", async () => {
      const html = await renderToHtml("```js\nfoo\n```", {
        highlighter: () => '<pre class="custom">highlighted</pre>',
      });
      expect(html).toContain('<pre class="custom">highlighted</pre>');
      expect(html).not.toContain('<code class="language-js">');
    });

    it("highlight ranges metadata is preserved", async () => {
      const { blocks } = await collectBlocks(
        "```js {1-3,5,7-9}\na\nb\nc\nd\ne\nf\ng\nh\ni\n```",
      );
      expect(blocks).toHaveLength(1);
      expect(blocks[0].highlights).toEqual([1, 2, 3, 5, 7, 8, 9]);
    });

    it("multiple code blocks with highlights all cleaned up", async () => {
      const md = [
        "```js {1}\na\n```",
        "",
        "```py {2,3}\nb\nc\n```",
        "",
        "```rs {1-2}\nd\ne\n```",
      ].join("\n");
      const { blocks } = await collectBlocks(md);
      expect(blocks).toHaveLength(3);
      expect(blocks[0].highlights).toEqual([1]);
      expect(blocks[1].highlights).toEqual([2, 3]);
      expect(blocks[2].highlights).toEqual([1, 2]);
    });

    it("escapes control characters in filename JSON", async () => {
      // Tab in filename: ```js [file\tname.js]
      const { blocks } = await collectBlocks(
        "```js [file\tname.js]\ncode\n```",
      );
      expect(blocks).toHaveLength(1);
      // The filename should round-trip through JSON without corruption
      expect(blocks[0].filename).toBe("file\tname.js");
    });

    it("escapes quotes and backslashes in filename JSON", async () => {
      const { blocks } = await collectBlocks(
        '```js [file\\"name.js]\ncode\n```',
      );
      expect(blocks).toHaveLength(1);
      // Filename with backslash and quote should survive JSON parsing
      expect(typeof blocks[0].filename).toBe("string");
    });
  });

  describe("renderToHtml with math", () => {
    it("renders inline math with math callback", async () => {
      const html = await renderToHtml("This is $E=mc^2$", {
        math: (code, display) => {
          return display ? `<div class="math-display">${code}</div>` : `<span class="math-inline">${code}</span>`;
        }
      });
      expect(html).toContain('<span class="math-inline">E=mc^2</span>');
    });

    it("renders display math with math callback", async () => {
      const html = await renderToHtml("$$\n\\sum_{i=1}^n i\n$$", {
        math: (code, display) => {
          return display ? `<div class="math-display">${code}</div>` : `<span class="math-inline">${code}</span>`;
        }
      });
      expect(html).toContain('<div class="math-display"> \\sum_{i=1}^n i </div>');
    });

    it("falls back to default rendering when math callback returns undefined", async () => {
      const html = await renderToHtml("$x$", {
        math: () => undefined
      });
      expect(html).toContain("<x-equation>x</x-equation>");
    });

    it("tracks multiple math blocks in order", async () => {
      const html = await renderToHtml("$a$ and $b$", {
        math: (code) => `[math:${code}]`
      });
      expect(html).toContain("[math:a] and [math:b]");
    });

    it("interleaves math blocks and code blocks", async () => {
      const md = "$math1$\n```js\ncode\n```\n$math2$";
      const html = await renderToHtml(md, {
        math: (code) => `[m:${code.trim()}]`,
        highlighter: (code) => `<pre><code>[c:${code.trim()}]</code></pre>\n`
      });
      expect(html).toContain("[m:math1]");
      expect(html).toContain("[c:code]");
      expect(html).toContain("[m:math2]");
    });
  });

  describe("renderToAnsi", () => {
    it("renders heading with ansi codes", async () => {
      expect(await renderToAnsi("# Hello")).toContain("Hello");
    });

    it("renders empty input", async () => {
      expect(await renderToAnsi("")).toBe("");
    });
  });

  describe("renderToAnsi with math", () => {
    it("renders inline math with math callback", async () => {
      const ansi = await renderToAnsi("This is $E=mc^2$", {
        math: (code, display) => display ? `[MATH:${code}]` : `[math:${code}]`
      });
      expect(ansi).toContain('This is [math:E=mc^2]');
    });

    it("renders display math with math callback", async () => {
      const ansi = await renderToAnsi("$$\n\\sum_{i=1}^n i\n$$", {
        math: (code, display) => display ? `[MATH:${code}]` : `[math:${code}]`
      });
      expect(ansi).toContain('[MATH: \\sum_{i=1}^n i ]');
    });
  });

  describe("renderToMeta", () => {
    it("returns a string", async () => {
      const json = await renderToMeta("# Hello");
      expect(typeof json).toBe("string");
    });

    it("returns valid JSON", async () => {
      const json = await renderToMeta("# Hello");
      const parsed = JSON.parse(json);
      expect(parsed.headings).toBeInstanceOf(Array);
    });

    it("returns empty headings for empty input", async () => {
      const json = await renderToMeta("");
      const parsed = JSON.parse(json);
      expect(parsed.headings).toHaveLength(0);
    });
  });

  describe("parseMeta", () => {
    it("extracts title from frontmatter", async () => {
      const meta = await parseMeta(
        "---\ntitle: Hello\ntags: [a, b]\n---\n\n# My Doc\n\n## Section 1",
      );
      expect(meta.title).toBe("Hello");
      expect(meta.tags).toEqual(["a", "b"]);
      expect(meta.headings).toEqual([
        { level: 1, text: "My Doc" },
        { level: 2, text: "Section 1" },
      ]);
    });

    it("falls back to first heading as title", async () => {
      const meta = await parseMeta("# My Doc\n\n## Section 1");
      expect(meta.title).toBe("My Doc");
      expect(meta.headings).toEqual([
        { level: 1, text: "My Doc" },
        { level: 2, text: "Section 1" },
      ]);
    });

    it("returns empty headings for empty input", async () => {
      const meta = await parseMeta("");
      expect(meta.headings).toHaveLength(0);
      expect(meta.title).toBeUndefined();
    });

    it("extracts multiple headings at different levels", async () => {
      const meta = await parseMeta("# H1\n\n## H2\n\n### H3\n\n#### H4");
      expect(meta.headings).toEqual([
        { level: 1, text: "H1" },
        { level: 2, text: "H2" },
        { level: 3, text: "H3" },
        { level: 4, text: "H4" },
      ]);
    });

    it("strips inline formatting from heading text", async () => {
      const meta = await parseMeta("# **Bold** and *italic* heading");
      expect(meta.headings[0].text).toBe("Bold and italic heading");
    });

    it("handles frontmatter with complex YAML", async () => {
      const meta = await parseMeta(
        "---\ntitle: Hello\nauthor:\n  name: John\ntags:\n  - js\n  - ts\ncount: 42\ndraft: true\n---",
      );
      expect(meta.title).toBe("Hello");
      expect(meta.author).toEqual({ name: "John" });
      expect(meta.tags).toEqual(["js", "ts"]);
      expect(meta.count).toBe(42);
      expect(meta.draft).toBe(true);
    });

    it("handles frontmatter without title and heading", async () => {
      const meta = await parseMeta("---\ndraft: true\n---\n\nJust a paragraph");
      expect(meta.draft).toBe(true);
      expect(meta.title).toBeUndefined();
      expect(meta.headings).toHaveLength(0);
    });

    it("handles heading with entity", async () => {
      const meta = await parseMeta("# Hello &amp; World");
      expect(meta.headings[0].text).toBe("Hello & World");
    });

    it("handles heading with inline code", async () => {
      const meta = await parseMeta("# Using `parseMeta` API");
      expect(meta.headings[0].text).toBe("Using parseMeta API");
    });

    it("ignores component frontmatter", async () => {
      const meta = await parseMeta(
        "---\ntitle: Installation\ndescription: How to install.\n---\n\n" +
          "## Try it online\n\n" +
          "::card\n---\ntitle: Stackblitz\nicon: simple-icons:stackblitz\n---\nContent.\n::\n",
      );
      expect(meta.title).toBe("Installation");
      expect(meta.description).toBe("How to install.");
      expect(meta.icon).toBeUndefined();
      expect(meta.headings).toHaveLength(1);
      expect(meta.headings[0].text).toBe("Try it online");
    });
  });

  describe("renderToText", () => {
    it("renders a heading", async () => {
      expect(await renderToText("# Hello")).toBe("Hello\n");
    });

    it("renders a paragraph", async () => {
      expect(await renderToText("Hello world")).toBe("Hello world\n");
    });

    it("strips inline formatting", async () => {
      expect(await renderToText("**bold** and *italic*")).toBe(
        "bold and italic\n",
      );
    });

    it("renders empty input", async () => {
      expect(await renderToText("")).toBe("");
    });

    it("renders a link as text only", async () => {
      expect(await renderToText("[click](https://example.com)")).toBe(
        "click\n",
      );
    });

    it("renders a code block with indent", async () => {
      const text = await renderToText("```\ncode\n```");
      expect(text).toContain("  code");
    });

    it("renders unordered list", async () => {
      const text = await renderToText("- one\n- two");
      expect(text).toContain("- one");
      expect(text).toContain("- two");
    });

    it("renders ordered list", async () => {
      const text = await renderToText("1. first\n2. second");
      expect(text).toContain("1. first");
      expect(text).toContain("2. second");
    });

    it("renders blockquote with prefix", async () => {
      const text = await renderToText("> quoted");
      expect(text).toContain("> quoted");
    });

    it("renders horizontal rule", async () => {
      const text = await renderToText("text\n\n***");
      expect(text).toContain("---");
    });

    it("strips frontmatter", async () => {
      const text = await renderToText("---\ntitle: Test\n---\n\n# Content");
      expect(text).not.toContain("title: Test");
      expect(text).toContain("Content");
    });

    it("renders task list", async () => {
      const text = await renderToText("- [x] done\n- [ ] todo");
      expect(text).toContain("[x] done");
      expect(text).toContain("[ ] todo");
    });

    it("resolves entities", async () => {
      expect(await renderToText("&amp;")).toBe("&\n");
    });

    it("renders multiline content", async () => {
      const text = await renderToText("# Title\n\nParagraph\n\n- item");
      expect(text).toContain("Title");
      expect(text).toContain("Paragraph");
      expect(text).toContain("- item");
    });

    it("renders real-world content without error", async () => {
      const text = await renderToText(nitroIndex);
      expect(text.length).toBeGreaterThan(0);
    });
  });

  describe("heal", () => {
    it("completes incomplete bold", async () => {
      expect(await heal("**hello")).toBe("**hello**");
    });

    it("completes incomplete italic (*)", async () => {
      expect(await heal("*hello")).toBe("*hello*");
    });

    it("completes incomplete italic (_)", async () => {
      expect(await heal("_hello")).toBe("_hello_");
    });

    it("completes incomplete italic (__)", async () => {
      expect(await heal("__hello")).toBe("__hello__");
    });

    it("completes incomplete bold-italic (***)", async () => {
      expect(await heal("***hello")).toBe("***hello***");
    });

    it("completes incomplete strikethrough", async () => {
      expect(await heal("~~hello")).toBe("~~hello~~");
    });

    it("completes incomplete inline code", async () => {
      expect(await heal("`hello")).toBe("`hello`");
    });

    it("closes unclosed code block", async () => {
      expect(await heal("```\ncode\n")).toBe("```\ncode\n```");
    });

    it("completes incomplete katex", async () => {
      expect(await heal("$$x+y")).toBe("$$x+y$$");
    });

    it("completes incomplete link url", async () => {
      expect(await heal("[text](url")).toBe("[text]()");
    });

    it("removes incomplete link text bracket", async () => {
      expect(await heal("[text")).toBe("text");
    });

    it("removes incomplete image", async () => {
      expect(await heal("text ![alt](url")).toBe("text");
    });

    it("handles half-complete bold", async () => {
      expect(await heal("**bold*")).toBe("**bold**");
    });

    it("handles half-complete strikethrough", async () => {
      expect(await heal("~~strike~")).toBe("~~strike~~");
    });

    it("handles half-complete italic (__)", async () => {
      expect(await heal("__italic_")).toBe("__italic__");
    });

    it("preserves already complete formatting", async () => {
      expect(await heal("**bold** and *italic*")).toBe("**bold** and *italic*");
    });

    it("preserves plain text", async () => {
      expect(await heal("hello world")).toBe("hello world");
    });

    it("strips trailing single space", async () => {
      expect(await heal("hello ")).toBe("hello");
    });

    it("preserves trailing double space (line break)", async () => {
      expect(await heal("hello  ")).toBe("hello  ");
    });

    it("strips incomplete HTML tag", async () => {
      expect(await heal("text <div")).toBe("text");
    });

    it("prevents setext heading with dash", async () => {
      const result = await heal("heading\n-");
      expect(result).toContain("\u200B");
    });

    it("does not modify triple dash (thematic break)", async () => {
      expect(await heal("heading\n---")).toBe("heading\n---");
    });

    it("handles empty input", async () => {
      expect(await heal("")).toBe("");
    });

    it("escapes comparison operators in lists", async () => {
      expect(await heal("- > 5")).toBe("- \\> 5");
    });

    it("does not modify blockquotes", async () => {
      expect(await heal("> quote")).toBe("> quote");
    });

    it("handles block katex with newlines", async () => {
      expect(await heal("$$\nx + y")).toBe("$$\nx + y\n$$");
    });

    it("does not heal inside code blocks", async () => {
      expect(await heal("```\n**bold\n```")).toBe("```\n**bold\n```");
    });
  });

  describe("heal option on renderers", () => {
    const incomplete = "# Hello **world";

    it("renderToHtml with heal", async () => {
      const html = await renderToHtml(incomplete, { heal: true });
      expect(html).toBe("<h1>Hello <strong>world</strong></h1>\n");
    });

    it("renderToHtml without heal", async () => {
      const html = await renderToHtml(incomplete);
      expect(html).toContain("**world");
    });

    it("renderToAST with heal", async () => {
      const ast = await renderToAST(incomplete, { heal: true });
      expect(ast).toContain('"strong"');
    });

    it("parseAST with heal", async () => {
      const tree = await parseAST(incomplete, { heal: true });
      const h1 = tree.nodes[0];
      expect(h1[0]).toBe("h1");
      const strong = h1.find((n) => Array.isArray(n) && n[0] === "strong");
      expect(strong).toBeTruthy();
    });

    it("renderToAnsi with heal", async () => {
      const ansi = await renderToAnsi(incomplete, { heal: true });
      expect(ansi).toContain("world");
      expect(ansi).not.toContain("**world");
    });

    it("renderToText with heal", async () => {
      const text = await renderToText(incomplete, { heal: true });
      expect(text.trim()).toBe("Hello world");
    });

    it("renderToMeta with heal", async () => {
      const meta = await renderToMeta(incomplete, { heal: true });
      const parsed = JSON.parse(meta);
      expect(parsed.headings[0].text).toBe("Hello world");
    });

    it("parseMeta with heal", async () => {
      const meta = await parseMeta(incomplete, { heal: true });
      expect(meta.headings[0].text).toBe("Hello world");
    });

    it("heal option combines with other options", async () => {
      const html = await renderToHtml(incomplete, {
        heal: true,
        full: true,
      });
      expect(html).toContain("<!DOCTYPE html>");
      expect(html).toContain("<strong>world</strong>");
    });
  });

  describe("memory safety regressions", () => {
    // Regression: dynamic component named "pre" or "code" must NOT flatten
    // children into literal text. The AST renderer must check tag_is_dynamic
    // before strcmp dispatch in json_text.
    it("::code component children are parsed as markdown, not flattened", async () => {
      const tree = await parseAST("::code\n\n**bold** text\n\n::");
      const comp = tree.nodes[0];
      expect(comp[0]).toBe("code");
      // Children should include a paragraph with strong, not raw text
      const p = comp.find((n) => Array.isArray(n) && n[0] === "p");
      expect(p).toBeTruthy();
      const strong = p.find((n) => Array.isArray(n) && n[0] === "strong");
      expect(strong).toBeTruthy();
    });

    it("::pre component children are parsed as markdown, not flattened", async () => {
      const tree = await parseAST("::pre\n\nHello **world**\n\n::");
      const comp = tree.nodes[0];
      expect(comp[0]).toBe("pre");
      const p = comp.find((n) => Array.isArray(n) && n[0] === "p");
      expect(p).toBeTruthy();
    });

    it("::frontmatter component children are parsed as markdown", async () => {
      const tree = await parseAST("::frontmatter\n\nSome text\n\n::");
      const comp = tree.nodes[0];
      expect(comp[0]).toBe("frontmatter");
      const p = comp.find((n) => Array.isArray(n) && n[0] === "p");
      expect(p).toBeTruthy();
    });

    // Regression: heal_comparison_operators used a stale `text` pointer after
    // buf_append_ch could realloc. Test with many list items with comparison
    // operators to stress-trigger buffer growth.
    it("heal handles many comparison operators without corruption", async () => {
      const lines = [];
      for (let i = 0; i < 200; i++) {
        lines.push(`- > ${i}`);
      }
      const input = lines.join("\n");
      const result = await heal(input);
      // Every > should be escaped as \>
      const escaped = result.split("\\>").length - 1;
      expect(escaped).toBe(200);
      // Should not contain any corruption / null bytes
      expect(result).not.toContain("\0");
    });
  });

  describe("input validation", () => {
    const renderers = [
      ["renderToHtml", renderToHtml],
      ["renderToAST", renderToAST],
      ["renderToAnsi", renderToAnsi],
      ["renderToMeta", renderToMeta],
      ["renderToText", renderToText],
      ["heal", heal],
    ];

    for (const [name, fn] of renderers) {
      describe(name, () => {
        it("treats null as empty string", async () => {
          expect(() => fn(null)).not.toThrow();
        });

        it("treats undefined as empty string", async () => {
          expect(() => fn(undefined)).not.toThrow();
        });

        it("treats no arguments as empty string", async () => {
          expect(() => fn()).not.toThrow();
        });

        it("throws TypeError on number input", async () => {
          expect(() => fn(42)).toThrow(TypeError);
          expect(() => fn(42)).toThrow("md4x: input must be a string");
        });

        it("throws TypeError on object input", async () => {
          expect(() => fn({})).toThrow(TypeError);
          expect(() => fn({})).toThrow("md4x: input must be a string");
        });

        it("throws TypeError on array input", async () => {
          expect(() => fn([])).toThrow(TypeError);
        });

        it("throws TypeError on boolean input", async () => {
          expect(() => fn(true)).toThrow(TypeError);
        });
      });
    }

    it("renderToHtml(null) returns empty string", async () => {
      expect(await renderToHtml(null)).toBe("");
    });

    it("renderToHtml(undefined) returns empty string", async () => {
      expect(await renderToHtml(undefined)).toBe("");
    });

    it("renderToHtml() with no args returns empty string", async () => {
      expect(await renderToHtml()).toBe("");
    });

    it("renderToAST(null) returns empty nodes", async () => {
      const result = JSON.parse(await renderToAST(null));
      expect(result.nodes).toEqual([]);
    });

    it("renderToMeta(null) returns empty headings", async () => {
      const result = JSON.parse(await renderToMeta(null));
      expect(result.headings).toEqual([]);
    });

    it("parseAST(null) returns empty tree", async () => {
      const tree = await parseAST(null);
      expect(tree.nodes).toEqual([]);
      expect(tree.frontmatter).toEqual({});
    });

    it("parseAST throws TypeError on number input", async () => {
      expect(() => parseAST(42)).toThrow(TypeError);
    });

    it("parseMeta(null) returns empty meta", async () => {
      const meta = await parseMeta(null);
      expect(meta.headings).toEqual([]);
    });

    it("parseMeta throws TypeError on number input", async () => {
      expect(() => parseMeta(42)).toThrow(TypeError);
    });

    it("heal(null) returns empty string", async () => {
      expect(await heal(null)).toBe("");
    });

    it("heal(undefined) returns empty string", async () => {
      expect(await heal(undefined)).toBe("");
    });
  });

  describe("supplementary unicode plane (emoji, math symbols)", () => {
    it("preserves emoji in HTML heading", async () => {
      expect(await renderToHtml("# Hello 🚀 World")).toBe(
        "<h1>Hello 🚀 World</h1>\n",
      );
    });

    it("preserves emoji in emphasis", async () => {
      expect(await renderToHtml("*🚀*")).toBe("<p><em>🚀</em></p>\n");
    });

    it("preserves supplementary math symbol (U+1D573) in strong", async () => {
      expect(await renderToHtml("**bold 𝕳 text**")).toBe(
        "<p><strong>bold 𝕳 text</strong></p>\n",
      );
    });

    it("handles emphasis flanking with emoji boundary", async () => {
      expect(await renderToHtml("🚀*foo*🚀")).toBe("<p>🚀<em>foo</em>🚀</p>\n");
    });

    it("preserves emoji in inline code", async () => {
      expect(await renderToHtml("`code 🔥`")).toBe(
        "<p><code>code 🔥</code></p>\n",
      );
    });

    it("preserves emoji in link text", async () => {
      expect(await renderToHtml("[link 🌍](http://example.com)")).toBe(
        '<p><a href="http://example.com">link 🌍</a></p>\n',
      );
    });

    it("preserves multiple supplementary chars in a row", async () => {
      expect(await renderToHtml("🚀🎉🔥🌍")).toBe("<p>🚀🎉🔥🌍</p>\n");
    });

    it("preserves CJK supplementary (U+20000)", async () => {
      expect(await renderToHtml("𠀀")).toBe("<p>𠀀</p>\n");
    });

    it("preserves emoji in AST", async () => {
      const ast = await parseAST("# Hello 🚀");
      expect(ast.nodes[0][2]).toBe("Hello 🚀");
    });

    it("preserves emoji in frontmatter via AST", async () => {
      const ast = await parseAST("---\ntitle: Hello 🚀\n---\n# Heading");
      expect(ast.frontmatter.title).toBe("Hello 🚀");
    });

    it("preserves supplementary chars in meta", async () => {
      const meta = await parseMeta("# Heading 𝕳 🚀");
      expect(meta.headings[0].text).toBe("Heading 𝕳 🚀");
    });

    it("preserves emoji in text renderer", async () => {
      expect(await renderToText("**bold 🚀** and *italic 𝕳*")).toBe(
        "bold 🚀 and italic 𝕳\n",
      );
    });

    it("preserves emoji in ANSI renderer", async () => {
      const result = await renderToAnsi("# Hello 🚀");
      expect(result).toContain("Hello 🚀");
    });

    it("preserves emoji through heal", async () => {
      expect(await heal("**bold 🚀")).toContain("🚀");
    });
  });

  describe("error handling", () => {
    describe("edge-case inputs", () => {
      it("handles only whitespace input", async () => {
        expect(await renderToHtml("   \n\n  \t  \n")).toBe("");
      });

      it("handles extremely long line without crashing", async () => {
        const longLine = "a".repeat(100_000);
        const result = await renderToHtml(longLine);
        expect(result).toContain(longLine);
      });

      it("handles deeply nested blockquotes", async () => {
        const input = "> ".repeat(100) + "deep";
        const result = await renderToHtml(input);
        expect(result).toContain("deep");
      });

      it("handles deeply nested lists", async () => {
        const lines = [];
        for (let i = 0; i < 50; i++) {
          lines.push("  ".repeat(i) + "- item " + i);
        }
        const result = await renderToHtml(lines.join("\n"));
        expect(result).toContain("item 0");
      });

      it("handles unclosed code fence", async () => {
        const result = await renderToHtml("```js\nsome code\nmore code");
        expect(result).toContain("some code");
      });

      it("handles unclosed frontmatter", async () => {
        const result = await renderToHtml("---\ntitle: hello\nno closing");
        expect(typeof result).toBe("string");
      });

      it("handles null bytes in input", async () => {
        const result = await renderToHtml("hello\0world");
        expect(result).toContain("hello");
      });

      it("handles many unclosed emphasis markers", async () => {
        const input = "**".repeat(500);
        const result = await renderToHtml(input);
        expect(typeof result).toBe("string");
      });

      it("handles many unclosed brackets", async () => {
        const input = "[".repeat(500);
        const result = await renderToHtml(input);
        expect(typeof result).toBe("string");
      });

      it("parseAST handles malformed components gracefully", async () => {
        const tree = await parseAST("::broken{invalid\ncontent\n::");
        expect(tree).toHaveProperty("nodes");
      });

      it("parseAST handles deeply nested components", async () => {
        let input = "";
        for (let i = 0; i < 20; i++) {
          input += ":".repeat(i + 3) + "comp" + i + "\n";
        }
        for (let i = 19; i >= 0; i--) {
          input += ":".repeat(i + 3) + "\n";
        }
        const tree = await parseAST(input);
        expect(tree).toHaveProperty("nodes");
      });

      it("heal handles input that is already valid", async () => {
        const input = "# Hello\n\nA **bold** paragraph.";
        expect(await heal(input)).toBe(input);
      });

      it("heal handles all unclosed markers at once", async () => {
        const input = "**bold *italic `code ~~strike";
        const result = await heal(input);
        expect(typeof result).toBe("string");
        expect(result.length).toBeGreaterThanOrEqual(input.length);
      });
    });
  });
}
