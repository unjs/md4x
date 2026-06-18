/*
 * MD4X: Markdown parser for C
 * (http://github.com/unjs/md4x)
 *
 * Copyright (c) 2016-2024 Martin Mitáš
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <yaml.h>

#include "md4x-html.h"
#include "md4x-props.h"
#include "md4x-heal-wrap.h"
#include "entity.h"


#if !defined(__STDC_VERSION__) || __STDC_VERSION__ < 199409L
    /* C89/90 or old compilers in general may not understand "inline". */
    #if defined __GNUC__
        #define inline __inline__
    #elif defined _MSC_VER
        #define inline __inline
    #else
        #define inline
    #endif
#endif

#ifdef _WIN32
    #define snprintf _snprintf
#endif



/* Code block metadata entry (heap-allocated when MD_HTML_FLAG_CODE_META is set) */
typedef struct MD_HTML_CODE_META {
    MD_SIZE start;              /* Byte offset of code content start (after <code...>) */
    MD_SIZE end;                /* Byte offset of code content end (before </code>) */
    char lang[64];              /* Language string (copied) */
    MD_SIZE lang_size;
    char filename[256];         /* Filename string (copied) */
    MD_SIZE filename_size;
    unsigned* highlights;       /* Heap-allocated copy of highlight line numbers, or NULL */
    unsigned highlight_count;
} MD_HTML_CODE_META;

/* Math span metadata entry (heap-allocated when MD_HTML_FLAG_CODE_META is set) */
typedef struct MD_HTML_MATH_META {
    MD_SIZE start;              /* Byte offset of math content start (after <x-equation...>) */
    MD_SIZE end;                /* Byte offset of math content end (before </x-equation>) */
    int display;                /* 1 if display math, 0 if inline math */
} MD_HTML_MATH_META;


typedef struct MD_HTML_tag MD_HTML;
struct MD_HTML_tag {
    void (*process_output)(const MD_CHAR*, MD_SIZE, void*);
    void* userdata;
    unsigned flags;
    int image_nesting_level;
    char escape_map[256];

    /* Frontmatter suppression state. */
    int in_frontmatter;
    int component_nesting;  /* Track block component nesting depth. */

    /* Component frontmatter: deferred open tag.
     * When entering a block component, we buffer the open tag prefix so that
     * if a frontmatter block immediately follows, its YAML keys can be emitted
     * as HTML attributes before closing the tag. */
    int comp_fm_pending;        /* 1 = waiting to see if frontmatter follows. */
    int comp_fm_capturing;      /* 1 = inside component frontmatter, capturing text. */
    char* comp_fm_tag;          /* Buffered open tag: "<tag-name ...props" (before ">"). */
    MD_SIZE comp_fm_tag_size;
    MD_SIZE comp_fm_tag_cap;
    char* comp_fm_text;         /* Captured YAML text from component frontmatter. */
    MD_SIZE comp_fm_text_size;
    MD_SIZE comp_fm_text_cap;

    /* Full-HTML mode state. */
    const MD_HTML_OPTS* opts;
    int head_emitted;

    /* Frontmatter YAML capture buffer (allocated only when FULL_HTML). */
    char* fm_text;
    MD_SIZE fm_size;
    MD_SIZE fm_cap;

    /* Code block metadata tracking (only active when MD_HTML_FLAG_CODE_META is set) */
    MD_SIZE output_offset;
    int in_code_block;
    MD_HTML_CODE_META* code_blocks;
    int n_code_blocks;
    int code_blocks_cap;

    /* Math metadata tracking (only active when MD_HTML_FLAG_CODE_META is set) */
    int in_math_span;
    MD_HTML_MATH_META* math_blocks;
    int n_math_blocks;
    int math_blocks_cap;
};

#define NEED_HTML_ESC_FLAG   0x1
#define NEED_URL_ESC_FLAG    0x2


/*****************************************
 ***  HTML rendering helper functions  ***
 *****************************************/

#define ISDIGIT(ch)     ('0' <= (ch) && (ch) <= '9')
#define ISLOWER(ch)     ('a' <= (ch) && (ch) <= 'z')
#define ISUPPER(ch)     ('A' <= (ch) && (ch) <= 'Z')
#define ISALNUM(ch)     (ISLOWER(ch) || ISUPPER(ch) || ISDIGIT(ch))


static inline void
render_verbatim(MD_HTML* r, const MD_CHAR* text, MD_SIZE size)
{
    r->process_output(text, size, r->userdata);
    if(r->flags & MD_HTML_FLAG_CODE_META)
        r->output_offset += size;
}

/* Keep this as a macro. Most compiler should then be smart enough to replace
 * the strlen() call with a compile-time constant if the string is a C literal. */
#define RENDER_VERBATIM(r, verbatim)                                    \
        render_verbatim((r), (verbatim), (MD_SIZE) (strlen(verbatim)))


static void
render_html_escaped(MD_HTML* r, const MD_CHAR* data, MD_SIZE size)
{
    MD_OFFSET beg = 0;
    MD_OFFSET off = 0;

    /* Some characters need to be escaped in normal HTML text. */
    #define NEED_HTML_ESC(ch)   (r->escape_map[(unsigned char)(ch)] & NEED_HTML_ESC_FLAG)

    while(1) {
        /* Optimization: Use some loop unrolling. */
        while(off + 3 < size  &&  !NEED_HTML_ESC(data[off+0])  &&  !NEED_HTML_ESC(data[off+1])
                              &&  !NEED_HTML_ESC(data[off+2])  &&  !NEED_HTML_ESC(data[off+3]))
            off += 4;
        while(off < size  &&  !NEED_HTML_ESC(data[off]))
            off++;

        if(off > beg)
            render_verbatim(r, data + beg, off - beg);

        if(off < size) {
            switch(data[off]) {
                case '&':   RENDER_VERBATIM(r, "&amp;"); break;
                case '<':   RENDER_VERBATIM(r, "&lt;"); break;
                case '>':   RENDER_VERBATIM(r, "&gt;"); break;
                case '"':   RENDER_VERBATIM(r, "&quot;"); break;
            }
            off++;
        } else {
            break;
        }
        beg = off;
    }
}

static void
render_url_escaped(MD_HTML* r, const MD_CHAR* data, MD_SIZE size)
{
    static const MD_CHAR hex_chars[] = "0123456789ABCDEF";
    MD_OFFSET beg = 0;
    MD_OFFSET off = 0;

    /* Some characters need to be escaped in URL attributes. */
    #define NEED_URL_ESC(ch)    (r->escape_map[(unsigned char)(ch)] & NEED_URL_ESC_FLAG)

    while(1) {
        while(off < size  &&  !NEED_URL_ESC(data[off]))
            off++;
        if(off > beg)
            render_verbatim(r, data + beg, off - beg);

        if(off < size) {
            char hex[3];

            switch(data[off]) {
                case '&':   RENDER_VERBATIM(r, "&amp;"); break;
                default:
                    hex[0] = '%';
                    hex[1] = hex_chars[((unsigned)data[off] >> 4) & 0xf];
                    hex[2] = hex_chars[((unsigned)data[off] >> 0) & 0xf];
                    render_verbatim(r, hex, 3);
                    break;
            }
            off++;
        } else {
            break;
        }

        beg = off;
    }
}

static unsigned
hex_val(char ch)
{
    if('0' <= ch && ch <= '9')
        return ch - '0';
    if('a' <= ch && ch <= 'f')
        return ch - 'a' + 10;
    if('A' <= ch && ch <= 'F')
        return ch - 'A' + 10;
    return 0;
}

static void
render_utf8_codepoint(MD_HTML* r, unsigned codepoint,
                      void (*fn_append)(MD_HTML*, const MD_CHAR*, MD_SIZE))
{
    static const MD_CHAR utf8_replacement_char[] = { (char)0xef, (char)0xbf, (char)0xbd };

    unsigned char utf8[4];
    size_t n;

    if(codepoint <= 0x7f) {
        n = 1;
        utf8[0] = codepoint;
    } else if(codepoint <= 0x7ff) {
        n = 2;
        utf8[0] = 0xc0 | ((codepoint >>  6) & 0x1f);
        utf8[1] = 0x80 + ((codepoint >>  0) & 0x3f);
    } else if(codepoint <= 0xffff) {
        n = 3;
        utf8[0] = 0xe0 | ((codepoint >> 12) & 0xf);
        utf8[1] = 0x80 + ((codepoint >>  6) & 0x3f);
        utf8[2] = 0x80 + ((codepoint >>  0) & 0x3f);
    } else {
        n = 4;
        utf8[0] = 0xf0 | ((codepoint >> 18) & 0x7);
        utf8[1] = 0x80 + ((codepoint >> 12) & 0x3f);
        utf8[2] = 0x80 + ((codepoint >>  6) & 0x3f);
        utf8[3] = 0x80 + ((codepoint >>  0) & 0x3f);
    }

    if(0 < codepoint  &&  codepoint <= 0x10ffff)
        fn_append(r, (char*)utf8, (MD_SIZE)n);
    else
        fn_append(r, utf8_replacement_char, 3);
}

/* Translate entity to its UTF-8 equivalent, or output the verbatim one
 * if such entity is unknown (or if the translation is disabled). */
static void
render_entity(MD_HTML* r, const MD_CHAR* text, MD_SIZE size,
              void (*fn_append)(MD_HTML*, const MD_CHAR*, MD_SIZE))
{
    if(r->flags & MD_HTML_FLAG_VERBATIM_ENTITIES) {
        render_verbatim(r, text, size);
        return;
    }

    /* We assume UTF-8 output is what is desired. */
    if(size > 3 && text[1] == '#') {
        unsigned codepoint = 0;

        if(text[2] == 'x' || text[2] == 'X') {
            /* Hexadecimal entity (e.g. "&#x1234abcd;")). */
            MD_SIZE i;
            for(i = 3; i < size-1; i++)
                codepoint = 16 * codepoint + hex_val(text[i]);
        } else {
            /* Decimal entity (e.g. "&1234;") */
            MD_SIZE i;
            for(i = 2; i < size-1; i++)
                codepoint = 10 * codepoint + (text[i] - '0');
        }

        render_utf8_codepoint(r, codepoint, fn_append);
        return;
    } else {
        /* Named entity (e.g. "&nbsp;"). */
        const ENTITY* ent;

        ent = entity_lookup(text, size);
        if(ent != NULL) {
            render_utf8_codepoint(r, ent->codepoints[0], fn_append);
            if(ent->codepoints[1])
                render_utf8_codepoint(r, ent->codepoints[1], fn_append);
            return;
        }
    }

    fn_append(r, text, size);
}

static void
render_attribute(MD_HTML* r, const MD_ATTRIBUTE* attr,
                 void (*fn_append)(MD_HTML*, const MD_CHAR*, MD_SIZE))
{
    int i;

    for(i = 0; attr->substr_offsets[i] < attr->size; i++) {
        MD_TEXTTYPE type = attr->substr_types[i];
        MD_OFFSET off = attr->substr_offsets[i];
        MD_SIZE size = attr->substr_offsets[i+1] - off;
        const MD_CHAR* text = attr->text + off;

        switch(type) {
            case MD_TEXT_NULLCHAR:  render_utf8_codepoint(r, 0x0000, render_verbatim); break;
            case MD_TEXT_ENTITY:    render_entity(r, text, size, fn_append); break;
            default:                fn_append(r, text, size); break;
        }
    }
}


static void
render_open_ol_block(MD_HTML* r, const MD_BLOCK_OL_DETAIL* det)
{
    char buf[64];

    if(det->start == 1) {
        RENDER_VERBATIM(r, "<ol>\n");
        return;
    }

    snprintf(buf, sizeof(buf), "<ol start=\"%u\">\n", det->start);
    RENDER_VERBATIM(r, buf);
}

static void
render_open_li_block(MD_HTML* r, const MD_BLOCK_LI_DETAIL* det)
{
    if(det->is_task) {
        RENDER_VERBATIM(r, "<li class=\"task-list-item\">"
                          "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled");
        if(det->task_mark == 'x' || det->task_mark == 'X')
            RENDER_VERBATIM(r, " checked");
        RENDER_VERBATIM(r, ">");
    } else {
        RENDER_VERBATIM(r, "<li>");
    }
}

static void
render_open_code_block(MD_HTML* r, const MD_BLOCK_CODE_DETAIL* det)
{
    RENDER_VERBATIM(r, "<pre><code");

    /* If known, output the HTML 5 attribute class="language-LANGNAME". */
    if(det->lang.text != NULL) {
        RENDER_VERBATIM(r, " class=\"language-");
        render_attribute(r, &det->lang, render_html_escaped);
        RENDER_VERBATIM(r, "\"");
    }

    RENDER_VERBATIM(r, ">");
}

static void
render_open_td_block(MD_HTML* r, const MD_CHAR* cell_type, const MD_BLOCK_TD_DETAIL* det)
{
    RENDER_VERBATIM(r, "<");
    RENDER_VERBATIM(r, cell_type);

    switch(det->align) {
        case MD_ALIGN_LEFT:     RENDER_VERBATIM(r, " align=\"left\">"); break;
        case MD_ALIGN_CENTER:   RENDER_VERBATIM(r, " align=\"center\">"); break;
        case MD_ALIGN_RIGHT:    RENDER_VERBATIM(r, " align=\"right\">"); break;
        default:                RENDER_VERBATIM(r, ">"); break;
    }
}

/* Forward declaration. */
static void render_html_component_props(MD_HTML* r, const MD_CHAR* raw, MD_SIZE size);

static void
render_open_a_span(MD_HTML* r, const MD_SPAN_A_DETAIL* det)
{
    RENDER_VERBATIM(r, "<a href=\"");
    render_attribute(r, &det->href, render_url_escaped);

    if(det->title.text != NULL) {
        RENDER_VERBATIM(r, "\" title=\"");
        render_attribute(r, &det->title, render_html_escaped);
    }

    RENDER_VERBATIM(r, "\"");
    if(det->raw_attrs != NULL && det->raw_attrs_size > 0)
        render_html_component_props(r, det->raw_attrs, det->raw_attrs_size);
    RENDER_VERBATIM(r, ">");
}

static void
render_open_img_span(MD_HTML* r, const MD_SPAN_IMG_DETAIL* det)
{
    RENDER_VERBATIM(r, "<img src=\"");
    render_attribute(r, &det->src, render_url_escaped);

    RENDER_VERBATIM(r, "\" alt=\"");
}

static void
render_close_img_span(MD_HTML* r, const MD_SPAN_IMG_DETAIL* det)
{
    if(det->title.text != NULL) {
        RENDER_VERBATIM(r, "\" title=\"");
        render_attribute(r, &det->title, render_html_escaped);
    }

    RENDER_VERBATIM(r, "\"");
    if(det->raw_attrs != NULL && det->raw_attrs_size > 0)
        render_html_component_props(r, det->raw_attrs, det->raw_attrs_size);
    RENDER_VERBATIM(r, ">");
}

static void
render_open_wikilink_span(MD_HTML* r, const MD_SPAN_WIKILINK_DETAIL* det)
{
    RENDER_VERBATIM(r, "<x-wikilink data-target=\"");
    render_attribute(r, &det->target, render_html_escaped);

    RENDER_VERBATIM(r, "\">");
}

/* Render parsed component props as HTML attributes.
 * Uses the shared md_parse_props() parser from md4x-props.h. */
static void
render_html_component_props(MD_HTML* r, const MD_CHAR* raw, MD_SIZE size)
{
    MD_PARSED_PROPS parsed;
    int i;

    md_parse_props(raw, size, &parsed);

    /* Write #id. */
    if(parsed.id != NULL && parsed.id_size > 0) {
        RENDER_VERBATIM(r, " id=\"");
        render_html_escaped(r, parsed.id, parsed.id_size);
        RENDER_VERBATIM(r, "\"");
    }

    /* Write regular props. */
    for(i = 0; i < parsed.n_props; i++) {
        const MD_PROP* p = &parsed.props[i];

        RENDER_VERBATIM(r, " ");
        render_html_escaped(r, p->key, p->key_size);

        switch(p->type) {
            case MD_PROP_STRING:
            case MD_PROP_BIND:
                RENDER_VERBATIM(r, "=\"");
                render_html_escaped(r, p->value, p->value_size);
                RENDER_VERBATIM(r, "\"");
                break;

            case MD_PROP_BOOLEAN:
                /* Bare attribute (no value). */
                break;
        }
    }

    /* Write merged class. */
    if(parsed.class_len > 0) {
        RENDER_VERBATIM(r, " class=\"");
        render_html_escaped(r, parsed.class_buf, parsed.class_len);
        RENDER_VERBATIM(r, "\"");
    }
}

/* Render opening tag for a simple span with optional trailing attrs. */
static void
render_open_tag_with_attrs(MD_HTML* r, const char* tag, const MD_SPAN_ATTRS_DETAIL* det)
{
    RENDER_VERBATIM(r, "<");
    RENDER_VERBATIM(r, tag);
    if(det != NULL && det->raw_attrs != NULL && det->raw_attrs_size > 0)
        render_html_component_props(r, det->raw_attrs, det->raw_attrs_size);
    RENDER_VERBATIM(r, ">");
}

/* Render opening tag for [text]{attrs} span. */
static void
render_open_span_span(MD_HTML* r, const MD_SPAN_SPAN_DETAIL* det)
{
    RENDER_VERBATIM(r, "<span");
    if(det != NULL && det->raw_attrs != NULL && det->raw_attrs_size > 0)
        render_html_component_props(r, det->raw_attrs, det->raw_attrs_size);
    RENDER_VERBATIM(r, ">");
}

static void
render_open_component_span(MD_HTML* r, const MD_SPAN_COMPONENT_DETAIL* det)
{
    RENDER_VERBATIM(r, "<");
    render_attribute(r, &det->tag_name, render_html_escaped);
    if(det->raw_props != NULL && det->raw_props_size > 0)
        render_html_component_props(r, det->raw_props, det->raw_props_size);
    RENDER_VERBATIM(r, ">");
}

static void
render_close_component_span(MD_HTML* r, const MD_SPAN_COMPONENT_DETAIL* det)
{
    RENDER_VERBATIM(r, "</");
    render_attribute(r, &det->tag_name, render_html_escaped);
    RENDER_VERBATIM(r, ">");
}

/* Append to the component frontmatter tag buffer. */
static int
comp_fm_tag_append(MD_HTML* r, const char* text, MD_SIZE size)
{
    if(r->comp_fm_tag_size + size > r->comp_fm_tag_cap) {
        MD_SIZE new_cap = r->comp_fm_tag_cap + r->comp_fm_tag_cap / 2 + size + 64;
        char* p = (char*) realloc(r->comp_fm_tag, new_cap);
        if(p == NULL) return -1;
        r->comp_fm_tag = p;
        r->comp_fm_tag_cap = new_cap;
    }
    memcpy(r->comp_fm_tag + r->comp_fm_tag_size, text, size);
    r->comp_fm_tag_size += size;
    return 0;
}

/* Append to the component frontmatter text buffer. */
static int
comp_fm_text_append(MD_HTML* r, const char* text, MD_SIZE size)
{
    if(r->comp_fm_text_size + size > r->comp_fm_text_cap) {
        MD_SIZE new_cap = r->comp_fm_text_cap + r->comp_fm_text_cap / 2 + size + 64;
        char* p = (char*) realloc(r->comp_fm_text, new_cap);
        if(p == NULL) return -1;
        r->comp_fm_text = p;
        r->comp_fm_text_cap = new_cap;
    }
    memcpy(r->comp_fm_text + r->comp_fm_text_size, text, size);
    r->comp_fm_text_size += size;
    return 0;
}

/* process_output callback wrapper for capturing into comp_fm_tag buffer. */
static void
comp_fm_tag_capture(const MD_CHAR* text, MD_SIZE size, void* userdata)
{
    comp_fm_tag_append((MD_HTML*) userdata, text, size);
}

/* Flush the buffered component open tag. If YAML text was captured,
 * parse it and emit as HTML attributes before closing ">". */
static void
comp_fm_flush_tag(MD_HTML* r)
{
    if(r->comp_fm_tag == NULL || r->comp_fm_tag_size == 0)
        return;

    /* Emit the buffered tag prefix (e.g. "<card ...props"). */
    r->process_output(r->comp_fm_tag, r->comp_fm_tag_size, r->userdata);

    /* If we captured YAML, parse and emit as attributes. */
    if(r->comp_fm_text != NULL && r->comp_fm_text_size > 0) {
        yaml_parser_t yp;
        yaml_event_t event;

        if(yaml_parser_initialize(&yp)) {
            yaml_parser_set_input_string(&yp, (const unsigned char*) r->comp_fm_text,
                                         r->comp_fm_text_size);

            /* STREAM_START */
            if(yaml_parser_parse(&yp, &event) && event.type == YAML_STREAM_START_EVENT) {
                yaml_event_delete(&event);
                /* DOCUMENT_START */
                if(yaml_parser_parse(&yp, &event) && event.type == YAML_DOCUMENT_START_EVENT) {
                    yaml_event_delete(&event);
                    /* MAPPING_START */
                    if(yaml_parser_parse(&yp, &event) && event.type == YAML_MAPPING_START_EVENT) {
                        yaml_event_delete(&event);
                        /* Iterate key-value pairs. */
                        while(yaml_parser_parse(&yp, &event)) {
                            char key_buf[256];
                            size_t key_len;
                            if(event.type == YAML_MAPPING_END_EVENT) {
                                yaml_event_delete(&event);
                                break;
                            }
                            if(event.type != YAML_SCALAR_EVENT) {
                                yaml_event_delete(&event);
                                break;
                            }
                            key_len = event.data.scalar.length;
                            if(key_len >= sizeof(key_buf)) key_len = sizeof(key_buf) - 1;
                            memcpy(key_buf, event.data.scalar.value, key_len);
                            key_buf[key_len] = '\0';
                            yaml_event_delete(&event);

                            /* Read value. */
                            if(!yaml_parser_parse(&yp, &event)) break;
                            if(event.type == YAML_SCALAR_EVENT) {
                                RENDER_VERBATIM(r, " ");
                                render_html_escaped(r, key_buf, (MD_SIZE) key_len);
                                RENDER_VERBATIM(r, "=\"");
                                render_html_escaped(r, (const char*) event.data.scalar.value,
                                                    (MD_SIZE) event.data.scalar.length);
                                RENDER_VERBATIM(r, "\"");
                            } else if(event.type == YAML_MAPPING_START_EVENT
                                      || event.type == YAML_SEQUENCE_START_EVENT) {
                                /* Skip nested structures. */
                                int depth = 1;
                                yaml_event_delete(&event);
                                while(depth > 0 && yaml_parser_parse(&yp, &event)) {
                                    if(event.type == YAML_MAPPING_START_EVENT
                                       || event.type == YAML_SEQUENCE_START_EVENT)
                                        depth++;
                                    else if(event.type == YAML_MAPPING_END_EVENT
                                            || event.type == YAML_SEQUENCE_END_EVENT)
                                        depth--;
                                    yaml_event_delete(&event);
                                }
                                continue;
                            }
                            yaml_event_delete(&event);
                        }
                    } else {
                        yaml_event_delete(&event);
                    }
                } else {
                    yaml_event_delete(&event);
                }
            } else {
                yaml_event_delete(&event);
            }
            yaml_parser_delete(&yp);
        }
    }

    RENDER_VERBATIM(r, ">\n");

    /* Reset buffers. */
    r->comp_fm_tag_size = 0;
    r->comp_fm_text_size = 0;
    r->comp_fm_pending = 0;
    r->comp_fm_capturing = 0;
}

static void
render_open_block_component(MD_HTML* r, const MD_BLOCK_COMPONENT_DETAIL* det)
{
    /* Buffer the open tag (without closing ">") so we can append
     * frontmatter YAML attributes if a frontmatter block follows. */
    r->comp_fm_tag_size = 0;
    r->comp_fm_text_size = 0;
    comp_fm_tag_append(r, "<", 1);

    /* Append tag name. */
    {
        const MD_ATTRIBUTE* attr = &det->tag_name;
        int i;
        for(i = 0; attr->substr_offsets != NULL && attr->substr_offsets[i] < attr->size; i++) {
            MD_TEXTTYPE type = attr->substr_types[i];
            MD_SIZE off = attr->substr_offsets[i];
            MD_SIZE next = attr->substr_offsets[i+1] < attr->size ? attr->substr_offsets[i+1] : attr->size;
            MD_SIZE len = next - off;
            (void) type;
            comp_fm_tag_append(r, attr->text + off, len);
        }
    }

    /* Append title as attribute if present. */
    if(det->title != NULL && det->title_size > 0) {
        comp_fm_tag_append(r, " title=\"", 8);
        {
            void (*saved_output)(const MD_CHAR*, MD_SIZE, void*) = r->process_output;
            void* saved_ud = r->userdata;
            r->process_output = comp_fm_tag_capture;
            r->userdata = r;
            render_html_escaped(r, det->title, det->title_size);
            r->process_output = saved_output;
            r->userdata = saved_ud;
        }
        comp_fm_tag_append(r, "\"", 1);
    }

    /* Append {props} if present. */
    if(det->raw_props != NULL && det->raw_props_size > 0) {
        /* Render props to a temp buffer by capturing output. */
        void (*saved_output)(const MD_CHAR*, MD_SIZE, void*) = r->process_output;
        void* saved_ud = r->userdata;
        r->process_output = comp_fm_tag_capture;
        r->userdata = r;
        render_html_component_props(r, det->raw_props, det->raw_props_size);
        r->process_output = saved_output;
        r->userdata = saved_ud;
    }

    r->comp_fm_pending = 1;
}

static void
render_close_block_component(MD_HTML* r, const MD_BLOCK_COMPONENT_DETAIL* det)
{
    /* Flush pending open tag if it was never flushed (empty component). */
    if(r->comp_fm_pending)
        comp_fm_flush_tag(r);
    RENDER_VERBATIM(r, "</");
    render_attribute(r, &det->tag_name, render_html_escaped);
    RENDER_VERBATIM(r, ">\n");
}


/*****************************************
 ***  Code block metadata tracking     ***
 *****************************************/

static MD_HTML_CODE_META*
code_meta_push(MD_HTML* r)
{
    if(r->code_blocks == NULL) {
        r->code_blocks = (MD_HTML_CODE_META*) malloc(8 * sizeof(MD_HTML_CODE_META));
        if(r->code_blocks == NULL) return NULL;
        r->code_blocks_cap = 8;
    } else if(r->n_code_blocks >= r->code_blocks_cap) {
        int new_cap = r->code_blocks_cap * 2;
        MD_HTML_CODE_META* p = (MD_HTML_CODE_META*) realloc(r->code_blocks, new_cap * sizeof(MD_HTML_CODE_META));
        if(p == NULL) return NULL;
        r->code_blocks = p;
        r->code_blocks_cap = new_cap;
    }
    memset(&r->code_blocks[r->n_code_blocks], 0, sizeof(MD_HTML_CODE_META));
    return &r->code_blocks[r->n_code_blocks];
}

static void
code_meta_cleanup(MD_HTML* r)
{
    if(r->code_blocks != NULL) {
        int i;
        /* Free committed entries + the in-progress entry if parse was aborted. */
        int count = r->n_code_blocks + (r->in_code_block ? 1 : 0);
        for(i = 0; i < count; i++)
            free(r->code_blocks[i].highlights);
        free(r->code_blocks);
    }
    if(r->math_blocks != NULL) {
        free(r->math_blocks);
    }
}

static MD_HTML_MATH_META*
math_meta_push(MD_HTML* r)
{
    if(r->math_blocks == NULL) {
        r->math_blocks = (MD_HTML_MATH_META*) malloc(8 * sizeof(MD_HTML_MATH_META));
        if(r->math_blocks == NULL) return NULL;
        r->math_blocks_cap = 8;
    } else if(r->n_math_blocks >= r->math_blocks_cap) {
        int new_cap = r->math_blocks_cap * 2;
        MD_HTML_MATH_META* p = (MD_HTML_MATH_META*) realloc(r->math_blocks, new_cap * sizeof(MD_HTML_MATH_META));
        if(p == NULL) return NULL;
        r->math_blocks = p;
        r->math_blocks_cap = new_cap;
    }
    memset(&r->math_blocks[r->n_math_blocks], 0, sizeof(MD_HTML_MATH_META));
    return &r->math_blocks[r->n_math_blocks];
}

static void
emit_json_str(void (*out)(const MD_CHAR*, MD_SIZE, void*), void* ud,
              const char* str, MD_SIZE size)
{
    MD_SIZE i, beg = 0;
    out("\"", 1, ud);
    for(i = 0; i < size; i++) {
        unsigned char ch = (unsigned char) str[i];
        if(ch == '"' || ch == '\\' || ch < 0x20) {
            if(i > beg)
                out(str + beg, i - beg, ud);
            if(ch == '"' || ch == '\\') {
                out("\\", 1, ud);
                out(str + i, 1, ud);
            } else if(ch == '\n') {
                out("\\n", 2, ud);
            } else if(ch == '\r') {
                out("\\r", 2, ud);
            } else if(ch == '\t') {
                out("\\t", 2, ud);
            } else {
                /* Other control chars: \u00XX */
                static const char hex[] = "0123456789abcdef";
                char esc[6] = { '\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 0xf] };
                out(esc, 6, ud);
            }
            beg = i + 1;
        }
    }
    if(i > beg)
        out(str + beg, i - beg, ud);
    out("\"", 1, ud);
}

static void
render_code_meta_json(MD_HTML* r)
{
    void (*out)(const MD_CHAR*, MD_SIZE, void*) = r->process_output;
    void* ud = r->userdata;
    char buf[64];
    int i, n;

    out("\0", 1, ud);
    out("{\"c\":[", 6, ud);
    for(i = 0; i < r->n_code_blocks; i++) {
        MD_HTML_CODE_META* m = &r->code_blocks[i];
        if(i > 0) out(",", 1, ud);

        n = snprintf(buf, sizeof(buf), "{\"s\":%u,\"e\":%u",
                     (unsigned)m->start, (unsigned)m->end);
        out(buf, (MD_SIZE)n, ud);

        if(m->lang_size > 0) {
            out(",\"l\":", 5, ud);
            emit_json_str(out, ud, m->lang, m->lang_size);
        }
        if(m->filename_size > 0) {
            out(",\"f\":", 5, ud);
            emit_json_str(out, ud, m->filename, m->filename_size);
        }
        if(m->highlight_count > 0) {
            unsigned j;
            out(",\"h\":[", 6, ud);
            for(j = 0; j < m->highlight_count; j++) {
                if(j > 0) out(",", 1, ud);
                n = snprintf(buf, sizeof(buf), "%u", m->highlights[j]);
                out(buf, (MD_SIZE)n, ud);
            }
            out("]", 1, ud);
        }
        out("}", 1, ud);
    }
    out("],\"m\":[", 7, ud);
    for(i = 0; i < r->n_math_blocks; i++) {
        MD_HTML_MATH_META* m = &r->math_blocks[i];
        if(i > 0) out(",", 1, ud);

        n = snprintf(buf, sizeof(buf), "{\"s\":%u,\"e\":%u",
                     (unsigned)m->start, (unsigned)m->end);
        out(buf, (MD_SIZE)n, ud);
        
        if(m->display) {
            out(",\"d\":1", 6, ud);
        }
        out("}", 1, ud);
    }
    out("]}", 2, ud);
}


static void
render_open_alert_block(MD_HTML* r, const MD_BLOCK_ALERT_DETAIL* det)
{
    MD_SIZE i;

    RENDER_VERBATIM(r, "<blockquote class=\"alert alert-");
    /* Lowercase the type name for the CSS class. */
    if(det->type_name.text != NULL) {
        for(i = 0; i < det->type_name.size; i++) {
            char ch = det->type_name.text[i];
            if(ch >= 'A' && ch <= 'Z')
                ch += 32;
            render_verbatim(r, &ch, 1);
        }
    }
    RENDER_VERBATIM(r, "\">\n");
}


/*********************************************
 ***  Full-HTML frontmatter YAML helpers  ***
 *********************************************/

static int
fm_append(MD_HTML* r, const char* text, MD_SIZE size)
{
    if(r->fm_size + size > r->fm_cap) {
        MD_SIZE new_cap = r->fm_cap + r->fm_cap / 2 + size + 64;
        char* p = (char*) realloc(r->fm_text, new_cap);
        if(p == NULL) return -1;
        r->fm_text = p;
        r->fm_cap = new_cap;
    }
    memcpy(r->fm_text + r->fm_size, text, size);
    r->fm_size += size;
    return 0;
}

/* Parse YAML frontmatter and extract title/description.
 * Caller must free *out_title and *out_description if non-NULL. */
static void
parse_frontmatter_meta(const char* text, MD_SIZE size,
                       char** out_title, char** out_description)
{
    yaml_parser_t yp;
    yaml_event_t event;

    *out_title = NULL;
    *out_description = NULL;

    if(!yaml_parser_initialize(&yp))
        return;

    yaml_parser_set_input_string(&yp, (const unsigned char*) text, size);

    /* Consume STREAM_START. */
    if(!yaml_parser_parse(&yp, &event)) goto done;
    if(event.type != YAML_STREAM_START_EVENT) { yaml_event_delete(&event); goto done; }
    yaml_event_delete(&event);

    /* Consume DOCUMENT_START. */
    if(!yaml_parser_parse(&yp, &event)) goto done;
    if(event.type != YAML_DOCUMENT_START_EVENT) { yaml_event_delete(&event); goto done; }
    yaml_event_delete(&event);

    /* Expect top-level MAPPING_START. */
    if(!yaml_parser_parse(&yp, &event)) goto done;
    if(event.type != YAML_MAPPING_START_EVENT) { yaml_event_delete(&event); goto done; }
    yaml_event_delete(&event);

    /* Iterate top-level key-value pairs. */
    while(1) {
        char** target = NULL;

        if(!yaml_parser_parse(&yp, &event)) goto done;
        if(event.type == YAML_MAPPING_END_EVENT) { yaml_event_delete(&event); break; }
        if(event.type != YAML_SCALAR_EVENT) { yaml_event_delete(&event); goto done; }

        /* Check if key is "title" or "description". */
        if(event.data.scalar.length == 5
           && memcmp(event.data.scalar.value, "title", 5) == 0) {
            target = out_title;
        } else if(event.data.scalar.length == 11
                  && memcmp(event.data.scalar.value, "description", 11) == 0) {
            target = out_description;
        }
        yaml_event_delete(&event);

        /* Read the value. */
        if(!yaml_parser_parse(&yp, &event)) goto done;

        if(target != NULL && event.type == YAML_SCALAR_EVENT
           && event.data.scalar.length > 0) {
            size_t len = event.data.scalar.length;
            char* s = (char*) malloc(len + 1);
            if(s != NULL) {
                memcpy(s, event.data.scalar.value, len);
                s[len] = '\0';
                free(*target);
                *target = s;
            }
        } else if(event.type == YAML_MAPPING_START_EVENT
                  || event.type == YAML_SEQUENCE_START_EVENT) {
            /* Skip nested structures. */
            int depth = 1;
            yaml_event_delete(&event);
            while(depth > 0) {
                if(!yaml_parser_parse(&yp, &event)) goto done;
                if(event.type == YAML_MAPPING_START_EVENT
                   || event.type == YAML_SEQUENCE_START_EVENT)
                    depth++;
                else if(event.type == YAML_MAPPING_END_EVENT
                        || event.type == YAML_SEQUENCE_END_EVENT)
                    depth--;
                yaml_event_delete(&event);
            }
            continue;
        }
        yaml_event_delete(&event);
    }

done:
    yaml_parser_delete(&yp);
}

/* Emit the <!DOCTYPE html><html><head>...<body> preamble.
 * Called lazily before the first body content in full-HTML mode. */
static void
ensure_head_emitted(MD_HTML* r)
{
    char* yaml_title = NULL;
    char* yaml_desc = NULL;
    const char* title;

    if(r->head_emitted)
        return;
    r->head_emitted = 1;

    /* Parse YAML frontmatter for title/description. */
    if(r->fm_text != NULL && r->fm_size > 0)
        parse_frontmatter_meta(r->fm_text, r->fm_size, &yaml_title, &yaml_desc);

    /* Explicit opts->title overrides YAML title. */
    title = (r->opts != NULL && r->opts->title != NULL) ? r->opts->title
            : yaml_title;

    RENDER_VERBATIM(r, "<!DOCTYPE html>\n<html>\n<head>\n");

    RENDER_VERBATIM(r, "<title>");
    if(title != NULL)
        render_html_escaped(r, title, (MD_SIZE) strlen(title));
    RENDER_VERBATIM(r, "</title>\n");

    RENDER_VERBATIM(r, "<meta name=\"generator\" content=\"md4x\">\n");

#if !defined MD4X_USE_ASCII && !defined MD4X_USE_UTF16
    RENDER_VERBATIM(r, "<meta charset=\"UTF-8\">\n");
#endif

    if(yaml_desc != NULL) {
        RENDER_VERBATIM(r, "<meta name=\"description\" content=\"");
        render_html_escaped(r, yaml_desc, (MD_SIZE) strlen(yaml_desc));
        RENDER_VERBATIM(r, "\">\n");
    }

    if(r->opts != NULL && r->opts->css_url != NULL) {
        RENDER_VERBATIM(r, "<link rel=\"stylesheet\" href=\"");
        render_html_escaped(r, r->opts->css_url, (MD_SIZE) strlen(r->opts->css_url));
        RENDER_VERBATIM(r, "\">\n");
    }

    RENDER_VERBATIM(r, "</head>\n<body>\n");

    free(yaml_title);
    free(yaml_desc);
}


/**************************************
 ***  HTML renderer implementation  ***
 **************************************/

static int
enter_block_callback(MD_BLOCKTYPE type, void* detail, void* userdata)
{
    static const MD_CHAR* head[6] = { "<h1>", "<h2>", "<h3>", "<h4>", "<h5>", "<h6>" };
    MD_HTML* r = (MD_HTML*) userdata;

    /* Frontmatter: always suppress, capture text for full-HTML or component props. */
    if(type == MD_BLOCK_FRONTMATTER) {
        r->in_frontmatter = 1;
        if(r->comp_fm_pending) {
            r->comp_fm_capturing = 1;
        }
        return 0;
    }

    /* If a component tag is pending and the next block is not frontmatter,
     * flush the buffered tag immediately. */
    if(r->comp_fm_pending && type != MD_BLOCK_FRONTMATTER) {
        comp_fm_flush_tag(r);
    }

    /* In full-HTML mode, emit <head> before first body content. */
    if((r->flags & MD_HTML_FLAG_FULL_HTML) && type != MD_BLOCK_DOC)
        ensure_head_emitted(r);

    switch(type) {
        case MD_BLOCK_DOC:      /* noop */ break;
        case MD_BLOCK_QUOTE:    RENDER_VERBATIM(r, "<blockquote>\n"); break;
        case MD_BLOCK_UL:       RENDER_VERBATIM(r, "<ul>\n"); break;
        case MD_BLOCK_OL:       render_open_ol_block(r, (const MD_BLOCK_OL_DETAIL*)detail); break;
        case MD_BLOCK_LI:       render_open_li_block(r, (const MD_BLOCK_LI_DETAIL*)detail); break;
        case MD_BLOCK_HR:       RENDER_VERBATIM(r, "<hr>\n"); break;
        case MD_BLOCK_H:        RENDER_VERBATIM(r, head[((MD_BLOCK_H_DETAIL*)detail)->level - 1]); break;
        case MD_BLOCK_CODE:
            render_open_code_block(r, (const MD_BLOCK_CODE_DETAIL*) detail);
            if(r->flags & MD_HTML_FLAG_CODE_META) {
                const MD_BLOCK_CODE_DETAIL* det = (const MD_BLOCK_CODE_DETAIL*) detail;
                MD_HTML_CODE_META* meta = code_meta_push(r);
                if(meta != NULL) {
                    meta->start = r->output_offset;
                    if(det->lang.text != NULL && det->lang.size > 0) {
                        MD_SIZE sz = det->lang.size < sizeof(meta->lang) ? det->lang.size : sizeof(meta->lang) - 1;
                        memcpy(meta->lang, det->lang.text, sz);
                        meta->lang_size = sz;
                    }
                    if(det->filename.text != NULL && det->filename.size > 0) {
                        MD_SIZE sz = det->filename.size < sizeof(meta->filename) ? det->filename.size : sizeof(meta->filename) - 1;
                        memcpy(meta->filename, det->filename.text, sz);
                        meta->filename_size = sz;
                    }
                    if(det->highlights != NULL && det->highlight_count > 0) {
                        meta->highlights = (unsigned*) malloc(det->highlight_count * sizeof(unsigned));
                        if(meta->highlights != NULL) {
                            memcpy(meta->highlights, det->highlights, det->highlight_count * sizeof(unsigned));
                            meta->highlight_count = det->highlight_count;
                        }
                    }
                    r->in_code_block = 1;
                }
            }
            break;
        case MD_BLOCK_HTML:     /* noop */ break;
        case MD_BLOCK_P:        RENDER_VERBATIM(r, "<p>"); break;
        case MD_BLOCK_TABLE:    RENDER_VERBATIM(r, "<table>\n"); break;
        case MD_BLOCK_THEAD:    RENDER_VERBATIM(r, "<thead>\n"); break;
        case MD_BLOCK_TBODY:    RENDER_VERBATIM(r, "<tbody>\n"); break;
        case MD_BLOCK_TR:       RENDER_VERBATIM(r, "<tr>\n"); break;
        case MD_BLOCK_TH:       render_open_td_block(r, "th", (MD_BLOCK_TD_DETAIL*)detail); break;
        case MD_BLOCK_TD:       render_open_td_block(r, "td", (MD_BLOCK_TD_DETAIL*)detail); break;
        case MD_BLOCK_FRONTMATTER:  break;  /* handled above */
        case MD_BLOCK_COMPONENT:    r->component_nesting++; render_open_block_component(r, (const MD_BLOCK_COMPONENT_DETAIL*) detail); break;
        case MD_BLOCK_ALERT:        render_open_alert_block(r, (const MD_BLOCK_ALERT_DETAIL*) detail); break;
        case MD_BLOCK_TEMPLATE: {
            const MD_BLOCK_TEMPLATE_DETAIL* det = (const MD_BLOCK_TEMPLATE_DETAIL*) detail;
            RENDER_VERBATIM(r, "<template name=\"");
            render_attribute(r, &det->name, render_html_escaped);
            RENDER_VERBATIM(r, "\">\n");
            break;
        }
    }

    return 0;
}

static int
leave_block_callback(MD_BLOCKTYPE type, void* detail, void* userdata)
{
    static const MD_CHAR* head[6] = { "</h1>\n", "</h2>\n", "</h3>\n", "</h4>\n", "</h5>\n", "</h6>\n" };
    MD_HTML* r = (MD_HTML*) userdata;

    /* Frontmatter: always suppress. */
    if(type == MD_BLOCK_FRONTMATTER) {
        r->in_frontmatter = 0;
        if(r->comp_fm_capturing) {
            /* Component frontmatter done — flush the buffered tag with YAML attrs. */
            comp_fm_flush_tag(r);
        }
        return 0;
    }

    switch(type) {
        case MD_BLOCK_DOC:
            if(r->flags & MD_HTML_FLAG_FULL_HTML) {
                ensure_head_emitted(r);
                RENDER_VERBATIM(r, "</body>\n</html>\n");
            }
            break;
        case MD_BLOCK_QUOTE:    RENDER_VERBATIM(r, "</blockquote>\n"); break;
        case MD_BLOCK_UL:       RENDER_VERBATIM(r, "</ul>\n"); break;
        case MD_BLOCK_OL:       RENDER_VERBATIM(r, "</ol>\n"); break;
        case MD_BLOCK_LI:       RENDER_VERBATIM(r, "</li>\n"); break;
        case MD_BLOCK_HR:       /*noop*/ break;
        case MD_BLOCK_H:        RENDER_VERBATIM(r, head[((MD_BLOCK_H_DETAIL*)detail)->level - 1]); break;
        case MD_BLOCK_CODE:
            if((r->flags & MD_HTML_FLAG_CODE_META) && r->in_code_block) {
                r->code_blocks[r->n_code_blocks].end = r->output_offset;
                r->n_code_blocks++;
                r->in_code_block = 0;
            }
            RENDER_VERBATIM(r, "</code></pre>\n");
            break;
        case MD_BLOCK_HTML:     /* noop */ break;
        case MD_BLOCK_P:        RENDER_VERBATIM(r, "</p>\n"); break;
        case MD_BLOCK_TABLE:    RENDER_VERBATIM(r, "</table>\n"); break;
        case MD_BLOCK_THEAD:    RENDER_VERBATIM(r, "</thead>\n"); break;
        case MD_BLOCK_TBODY:    RENDER_VERBATIM(r, "</tbody>\n"); break;
        case MD_BLOCK_TR:       RENDER_VERBATIM(r, "</tr>\n"); break;
        case MD_BLOCK_TH:       RENDER_VERBATIM(r, "</th>\n"); break;
        case MD_BLOCK_TD:       RENDER_VERBATIM(r, "</td>\n"); break;
        case MD_BLOCK_FRONTMATTER:  break;  /* handled above */
        case MD_BLOCK_COMPONENT:    r->component_nesting--; render_close_block_component(r, (const MD_BLOCK_COMPONENT_DETAIL*) detail); break;
        case MD_BLOCK_ALERT:        RENDER_VERBATIM(r, "</blockquote>\n"); break;
        case MD_BLOCK_TEMPLATE:     RENDER_VERBATIM(r, "</template>\n"); break;
    }

    return 0;
}

static int
enter_span_callback(MD_SPANTYPE type, void* detail, void* userdata)
{
    MD_HTML* r = (MD_HTML*) userdata;
    int inside_img = (r->image_nesting_level > 0);

    /* We are inside a Markdown image label. Markdown allows to use any emphasis
     * and other rich contents in that context similarly as in any link label.
     *
     * However, unlike in the case of links (where that contents becomescontents
     * of the <a>...</a> tag), in the case of images the contents is supposed to
     * fall into the attribute alt: <img alt="...">.
     *
     * In that context we naturally cannot output nested HTML tags. So lets
     * suppress them and only output the plain text (i.e. what falls into text()
     * callback).
     *
     * CommonMark specification declares this a recommended practice for HTML
     * output.
     */
    if(type == MD_SPAN_IMG)
        r->image_nesting_level++;
    if(inside_img)
        return 0;

    switch(type) {
        case MD_SPAN_EM:
            if(detail != NULL)
                render_open_tag_with_attrs(r, "em", (MD_SPAN_ATTRS_DETAIL*) detail);
            else
                RENDER_VERBATIM(r, "<em>");
            break;
        case MD_SPAN_STRONG:
            if(detail != NULL)
                render_open_tag_with_attrs(r, "strong", (MD_SPAN_ATTRS_DETAIL*) detail);
            else
                RENDER_VERBATIM(r, "<strong>");
            break;
        case MD_SPAN_U:
            if(detail != NULL)
                render_open_tag_with_attrs(r, "u", (MD_SPAN_ATTRS_DETAIL*) detail);
            else
                RENDER_VERBATIM(r, "<u>");
            break;
        case MD_SPAN_A:                 render_open_a_span(r, (MD_SPAN_A_DETAIL*) detail); break;
        case MD_SPAN_IMG:               render_open_img_span(r, (MD_SPAN_IMG_DETAIL*) detail); break;
        case MD_SPAN_CODE:
            if(detail != NULL)
                render_open_tag_with_attrs(r, "code", (MD_SPAN_ATTRS_DETAIL*) detail);
            else
                RENDER_VERBATIM(r, "<code>");
            break;
        case MD_SPAN_DEL:
            if(detail != NULL)
                render_open_tag_with_attrs(r, "del", (MD_SPAN_ATTRS_DETAIL*) detail);
            else
                RENDER_VERBATIM(r, "<del>");
            break;
        case MD_SPAN_LATEXMATH:
            RENDER_VERBATIM(r, "<x-equation>");
            if(r->flags & MD_HTML_FLAG_CODE_META) {
                MD_HTML_MATH_META* meta = math_meta_push(r);
                if(meta != NULL) {
                    meta->start = r->output_offset;
                    meta->display = 0;
                    r->in_math_span = 1;
                }
            }
            break;
        case MD_SPAN_LATEXMATH_DISPLAY:
            RENDER_VERBATIM(r, "<x-equation type=\"display\">");
            if(r->flags & MD_HTML_FLAG_CODE_META) {
                MD_HTML_MATH_META* meta = math_meta_push(r);
                if(meta != NULL) {
                    meta->start = r->output_offset;
                    meta->display = 1;
                    r->in_math_span = 1;
                }
            }
            break;
        case MD_SPAN_WIKILINK:          render_open_wikilink_span(r, (MD_SPAN_WIKILINK_DETAIL*) detail); break;
        case MD_SPAN_COMPONENT:         render_open_component_span(r, (MD_SPAN_COMPONENT_DETAIL*) detail); break;
        case MD_SPAN_SPAN:              render_open_span_span(r, (MD_SPAN_SPAN_DETAIL*) detail); break;
    }

    return 0;
}

static int
leave_span_callback(MD_SPANTYPE type, void* detail, void* userdata)
{
    MD_HTML* r = (MD_HTML*) userdata;

    if(type == MD_SPAN_IMG)
        r->image_nesting_level--;
    if(r->image_nesting_level > 0)
        return 0;

    switch(type) {
        case MD_SPAN_EM:                RENDER_VERBATIM(r, "</em>"); break;
        case MD_SPAN_STRONG:            RENDER_VERBATIM(r, "</strong>"); break;
        case MD_SPAN_U:                 RENDER_VERBATIM(r, "</u>"); break;
        case MD_SPAN_A:                 RENDER_VERBATIM(r, "</a>"); break;
        case MD_SPAN_IMG:               render_close_img_span(r, (MD_SPAN_IMG_DETAIL*) detail); break;
        case MD_SPAN_CODE:              RENDER_VERBATIM(r, "</code>"); break;
        case MD_SPAN_DEL:               RENDER_VERBATIM(r, "</del>"); break;
        case MD_SPAN_LATEXMATH:         /*fall through*/
        case MD_SPAN_LATEXMATH_DISPLAY:
            if((r->flags & MD_HTML_FLAG_CODE_META) && r->in_math_span) {
                r->math_blocks[r->n_math_blocks].end = r->output_offset;
                r->n_math_blocks++;
                r->in_math_span = 0;
            }
            RENDER_VERBATIM(r, "</x-equation>");
            break;
        case MD_SPAN_WIKILINK:          RENDER_VERBATIM(r, "</x-wikilink>"); break;
        case MD_SPAN_COMPONENT:         render_close_component_span(r, (MD_SPAN_COMPONENT_DETAIL*) detail); break;
        case MD_SPAN_SPAN:              RENDER_VERBATIM(r, "</span>"); break;
    }

    return 0;
}

static int
text_callback(MD_TEXTTYPE type, const MD_CHAR* text, MD_SIZE size, void* userdata)
{
    MD_HTML* r = (MD_HTML*) userdata;

    /* Frontmatter text: capture for full-HTML or component frontmatter, always suppress output. */
    if(r->in_frontmatter) {
        if(r->comp_fm_capturing)
            comp_fm_text_append(r, text, size);
        else if((r->flags & MD_HTML_FLAG_FULL_HTML) && r->component_nesting == 0)
            fm_append(r, text, size);
        return 0;
    }

    switch(type) {
        case MD_TEXT_NULLCHAR:  render_utf8_codepoint(r, 0x0000, render_verbatim); break;
        case MD_TEXT_BR:        RENDER_VERBATIM(r, (r->image_nesting_level == 0 ? "<br>\n" : " "));
                                break;
        case MD_TEXT_SOFTBR:    RENDER_VERBATIM(r, (r->image_nesting_level == 0 ? "\n" : " ")); break;
        case MD_TEXT_HTML:      render_verbatim(r, text, size); break;
        case MD_TEXT_ENTITY:    render_entity(r, text, size, render_html_escaped); break;
        default:                render_html_escaped(r, text, size); break;
    }

    return 0;
}

static void
debug_log_callback(const char* msg, void* userdata)
{
    MD_HTML* r = (MD_HTML*) userdata;
    if(r->flags & MD_HTML_FLAG_DEBUG)
        fprintf(stderr, "MD4X: %s\n", msg);
}

int
md_html_ex(const MD_CHAR* input, MD_SIZE input_size,
           void (*process_output)(const MD_CHAR*, MD_SIZE, void*),
           void* userdata, unsigned parser_flags, unsigned renderer_flags,
           const MD_HTML_OPTS* opts)
{
    MD_HTML render;
    MD_PARSER parser;
    int i;
    int ret;

    /* Heal-before-render: run md_heal first, then render the healed output. */
    if(renderer_flags & MD_HTML_FLAG_HEAL) {
        MD4X_HEAL_BUF hbuf;
        if(md4x_heal_input(input, input_size, &hbuf) != 0) {
            free(hbuf.data);
            return -1;
        }
        ret = md_html_ex(hbuf.data, hbuf.size, process_output, userdata,
                         parser_flags, renderer_flags & ~MD_HTML_FLAG_HEAL, opts);
        free(hbuf.data);
        return ret;
    }

    memset(&render, 0, sizeof(render));
    render.process_output = process_output;
    render.userdata = userdata;
    render.flags = renderer_flags;
    render.opts = opts;

    memset(&parser, 0, sizeof(parser));
    parser.flags = parser_flags;
    parser.enter_block = enter_block_callback;
    parser.leave_block = leave_block_callback;
    parser.enter_span = enter_span_callback;
    parser.leave_span = leave_span_callback;
    parser.text = text_callback;
    parser.debug_log = debug_log_callback;

    /* Build map of characters which need escaping. */
    for(i = 0; i < 256; i++) {
        unsigned char ch = (unsigned char) i;

        if(strchr("\"&<>", ch) != NULL)
            render.escape_map[i] |= NEED_HTML_ESC_FLAG;

        if(!ISALNUM(ch)  &&  strchr("~-_.+!*(),%#@?=;:/,+$", ch) == NULL)
            render.escape_map[i] |= NEED_URL_ESC_FLAG;
    }

    /* Consider skipping UTF-8 byte order mark (BOM). */
    if(renderer_flags & MD_HTML_FLAG_SKIP_UTF8_BOM  &&  sizeof(MD_CHAR) == 1) {
        static const MD_CHAR bom[3] = { (char)0xef, (char)0xbb, (char)0xbf };
        if(input_size >= sizeof(bom)  &&  memcmp(input, bom, sizeof(bom)) == 0) {
            input += sizeof(bom);
            input_size -= sizeof(bom);
        }
    }

    ret = md_parse(input, input_size, &parser, (void*) &render);

    if(renderer_flags & MD_HTML_FLAG_CODE_META) {
        if(ret == 0)
            render_code_meta_json(&render);
        code_meta_cleanup(&render);
    }

    free(render.fm_text);
    free(render.comp_fm_tag);
    free(render.comp_fm_text);

    return ret;
}

int
md_html(const MD_CHAR* input, MD_SIZE input_size,
        void (*process_output)(const MD_CHAR*, MD_SIZE, void*),
        void* userdata, unsigned parser_flags, unsigned renderer_flags)
{
    return md_html_ex(input, input_size, process_output, userdata,
                      parser_flags, renderer_flags, NULL);
}

