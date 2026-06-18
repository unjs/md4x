/*
 * MD4X: Markdown parser for C
 * (http://github.com/unjs/md4x)
 *
 * Copyright (c) 2026 Pooya Parsa <pooya@pi0.io>
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
#include <string.h>

#include "md4x-ansi.h"
#include "md4x-props.h"
#include "md4x-heal-wrap.h"
#include "entity.h"


#if !defined(__STDC_VERSION__) || __STDC_VERSION__ < 199409L
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


/* ANSI escape sequences */
#define ANSI_RESET          "\033[0m"
#define ANSI_BOLD           "\033[1m"
#define ANSI_BOLD_OFF       "\033[22m"
#define ANSI_DIM            "\033[2m"
#define ANSI_DIM_OFF        "\033[22m"
#define ANSI_ITALIC         "\033[3m"
#define ANSI_ITALIC_OFF     "\033[23m"
#define ANSI_UNDERLINE      "\033[4m"
#define ANSI_UNDERLINE_OFF  "\033[24m"
#define ANSI_STRIKETHROUGH  "\033[9m"
#define ANSI_STRIKE_OFF     "\033[29m"

#define ANSI_COLOR_BLUE     "\033[34m"
#define ANSI_COLOR_CYAN     "\033[36m"
#define ANSI_COLOR_MAGENTA  "\033[35m"
#define ANSI_COLOR_YELLOW   "\033[33m"
#define ANSI_COLOR_GREEN    "\033[32m"
#define ANSI_COLOR_RED      "\033[31m"
#define ANSI_COLOR_DEFAULT  "\033[39m"

/* Compound styles */
#define ANSI_HEADING        "\033[1;35m"
#define ANSI_LINK           "\033[4;34m"
#define ANSI_LINK_URL       "\033[2;34m"

/* OSC 8 hyperlinks: \033]8;;URL\033\\ to open, \033]8;;\033\\ to close */
#define ANSI_HYPERLINK_OPEN "\033]8;;"
#define ANSI_HYPERLINK_SEP  "\033\\"
#define ANSI_HYPERLINK_CLOSE "\033]8;;\033\\"

/* Box-drawing characters (UTF-8) */
#define HORIZONTAL_RULE     "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" \
                            "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" \
                            "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" \
                            "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" \
                            "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"

/* Blockquote bar (UTF-8: vertical bar U+2502) */
#define QUOTE_BAR           "\xe2\x94\x82"

/* Alert bar (UTF-8: left half block U+258C ▌) */
#define ALERT_BAR           "\xe2\x96\x8c"


/* Code block metadata entry (heap-allocated when MD_ANSI_FLAG_CODE_META is set) */
typedef struct MD_ANSI_CODE_META {
    MD_SIZE start;          /* Byte offset: start of code block (before ANSI_DIM) */
    MD_SIZE end;            /* Byte offset: end of code block (after ANSI_DIM_OFF) */
    char lang[64];
    MD_SIZE lang_size;
    char filename[256];
    MD_SIZE filename_size;
    unsigned* highlights;
    unsigned highlight_count;
    char prefix[256];       /* Line indent prefix (captured from render_indent + "  ") */
    MD_SIZE prefix_size;
} MD_ANSI_CODE_META;

/* Math span metadata entry (heap-allocated when MD_ANSI_FLAG_CODE_META is set) */
typedef struct MD_ANSI_MATH_META {
    MD_SIZE start;              /* Byte offset of math content start (after DIM) */
    MD_SIZE end;                /* Byte offset of math content end (before DIM_OFF) */
    int display;                /* 1 if display math, 0 if inline math */
} MD_ANSI_MATH_META;

typedef struct MD_ANSI_tag MD_ANSI;
struct MD_ANSI_tag {
    void (*process_output)(const MD_CHAR*, MD_SIZE, void*);
    void* userdata;
    unsigned flags;
    int image_nesting_level;
    int quote_depth;
    int list_depth;
    int ol_counter;
    int in_code_block;
    int need_newline;       /* pending newline before next block */
    int need_indent;        /* emit indent prefix on next code text */
    int li_opened;          /* just opened a list item (bullet already printed) */
    int in_alert;           /* inside an alert block */
    const char* alert_color; /* ANSI color escape for current alert bar */
    int component_nesting;  /* block component nesting depth */
    int in_comp_frontmatter; /* inside component frontmatter (suppress output) */

    /* Code block metadata tracking (only active when MD_ANSI_FLAG_CODE_META is set) */
    MD_SIZE output_offset;
    MD_ANSI_CODE_META* code_blocks;
    int n_code_blocks;
    int code_blocks_cap;

    /* Math metadata tracking (only active when MD_ANSI_FLAG_CODE_META is set) */
    int in_math_span;
    MD_ANSI_MATH_META* math_blocks;
    int n_math_blocks;
    int math_blocks_cap;
};


/*********************************************
 ***  ANSI rendering helper functions  ***
 *********************************************/

static inline void
render_verbatim(MD_ANSI* r, const MD_CHAR* text, MD_SIZE size)
{
    r->process_output(text, size, r->userdata);
    if(r->flags & MD_ANSI_FLAG_CODE_META)
        r->output_offset += size;
}

#define RENDER_VERBATIM(r, verbatim)                                    \
        render_verbatim((r), (verbatim), (MD_SIZE) (strlen(verbatim)))

static inline void
render_ansi(MD_ANSI* r, const char* code)
{
    if(!(r->flags & MD_ANSI_FLAG_NO_COLOR))
        RENDER_VERBATIM(r, code);
}

static void
render_indent(MD_ANSI* r)
{
    int i;
    for(i = 0; i < r->quote_depth; i++) {
        render_ansi(r, ANSI_DIM);
        RENDER_VERBATIM(r, "  " QUOTE_BAR " ");
        render_ansi(r, ANSI_DIM_OFF);
    }
    if(r->in_alert && r->alert_color) {
        render_ansi(r, r->alert_color);
        RENDER_VERBATIM(r, ALERT_BAR " ");
        render_ansi(r, ANSI_COLOR_DEFAULT);
    }
    for(i = 0; i < r->list_depth; i++) {
        RENDER_VERBATIM(r, "  ");
    }
}

static void
render_newline(MD_ANSI* r)
{
    RENDER_VERBATIM(r, "\n");
}

/* Render a blank separator line with alert bar prefix when inside an alert. */
static void
render_separator(MD_ANSI* r)
{
    render_newline(r);
    if(r->in_alert && r->alert_color) {
        render_ansi(r, r->alert_color);
        RENDER_VERBATIM(r, ALERT_BAR);
        render_ansi(r, ANSI_COLOR_DEFAULT);
        render_newline(r);
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
render_utf8_codepoint(MD_ANSI* r, unsigned codepoint,
                      void (*fn_append)(MD_ANSI*, const MD_CHAR*, MD_SIZE))
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

static void
render_entity(MD_ANSI* r, const MD_CHAR* text, MD_SIZE size,
              void (*fn_append)(MD_ANSI*, const MD_CHAR*, MD_SIZE))
{
    if(size > 3 && text[1] == '#') {
        unsigned codepoint = 0;

        if(text[2] == 'x' || text[2] == 'X') {
            MD_SIZE i;
            for(i = 3; i < size-1; i++)
                codepoint = 16 * codepoint + hex_val(text[i]);
        } else {
            MD_SIZE i;
            for(i = 2; i < size-1; i++)
                codepoint = 10 * codepoint + (text[i] - '0');
        }

        render_utf8_codepoint(r, codepoint, fn_append);
        return;
    } else {
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
render_attribute(MD_ANSI* r, const MD_ATTRIBUTE* attr,
                 void (*fn_append)(MD_ANSI*, const MD_CHAR*, MD_SIZE))
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


/* Case-insensitive compare for short ASCII strings. */
static int
ci_eq(const MD_CHAR* a, MD_SIZE a_size, const char* b)
{
    MD_SIZE i;
    for(i = 0; i < a_size && b[i] != '\0'; i++) {
        char ca = a[i];
        char cb = b[i];
        if(ca >= 'A' && ca <= 'Z') ca += 32;
        if(cb >= 'A' && cb <= 'Z') cb += 32;
        if(ca != cb) return 0;
    }
    return (i == a_size && b[i] == '\0');
}

/* Map alert/component type name to ANSI color, or NULL if not an alert name. */
static const char*
alert_type_color(const MD_CHAR* name, MD_SIZE size)
{
    if(size == 0 || name == NULL)
        return NULL;

    if(ci_eq(name, size, "note"))       return ANSI_COLOR_BLUE;
    if(ci_eq(name, size, "info"))       return ANSI_COLOR_BLUE;
    if(ci_eq(name, size, "tip"))        return ANSI_COLOR_GREEN;
    if(ci_eq(name, size, "success"))    return ANSI_COLOR_GREEN;
    if(ci_eq(name, size, "important"))  return ANSI_COLOR_MAGENTA;
    if(ci_eq(name, size, "warning"))    return ANSI_COLOR_YELLOW;
    if(ci_eq(name, size, "caution"))    return ANSI_COLOR_RED;
    if(ci_eq(name, size, "danger"))     return ANSI_COLOR_RED;

    return NULL;
}


/*****************************************
 ***  Code block metadata tracking     ***
 *****************************************/

static MD_ANSI_CODE_META*
ansi_code_meta_push(MD_ANSI* r)
{
    if(r->code_blocks == NULL) {
        r->code_blocks = (MD_ANSI_CODE_META*) malloc(8 * sizeof(MD_ANSI_CODE_META));
        if(r->code_blocks == NULL) return NULL;
        r->code_blocks_cap = 8;
    } else if(r->n_code_blocks >= r->code_blocks_cap) {
        int new_cap = r->code_blocks_cap * 2;
        MD_ANSI_CODE_META* p = (MD_ANSI_CODE_META*) realloc(r->code_blocks, new_cap * sizeof(MD_ANSI_CODE_META));
        if(p == NULL) return NULL;
        r->code_blocks = p;
        r->code_blocks_cap = new_cap;
    }
    memset(&r->code_blocks[r->n_code_blocks], 0, sizeof(MD_ANSI_CODE_META));
    return &r->code_blocks[r->n_code_blocks];
}

static void
ansi_code_meta_cleanup(MD_ANSI* r)
{
    if(r->code_blocks != NULL) {
        int i;
        int count = r->n_code_blocks + (r->in_code_block ? 1 : 0);
        for(i = 0; i < count; i++)
            free(r->code_blocks[i].highlights);
        free(r->code_blocks);
    }
    if(r->math_blocks != NULL) {
        free(r->math_blocks);
    }
}

static MD_ANSI_MATH_META*
ansi_math_meta_push(MD_ANSI* r)
{
    if(r->math_blocks == NULL) {
        r->math_blocks = (MD_ANSI_MATH_META*) malloc(8 * sizeof(MD_ANSI_MATH_META));
        if(r->math_blocks == NULL) return NULL;
        r->math_blocks_cap = 8;
    } else if(r->n_math_blocks >= r->math_blocks_cap) {
        int new_cap = r->math_blocks_cap * 2;
        MD_ANSI_MATH_META* p = (MD_ANSI_MATH_META*) realloc(r->math_blocks, new_cap * sizeof(MD_ANSI_MATH_META));
        if(p == NULL) return NULL;
        r->math_blocks = p;
        r->math_blocks_cap = new_cap;
    }
    memset(&r->math_blocks[r->n_math_blocks], 0, sizeof(MD_ANSI_MATH_META));
    return &r->math_blocks[r->n_math_blocks];
}

/* Capture buffer for redirecting output to capture the indent prefix. */
typedef struct {
    char* buf;
    MD_SIZE size;
    MD_SIZE cap;
} ANSI_CAPTURE_BUF;

static void
ansi_capture_append(const MD_CHAR* text, MD_SIZE size, void* userdata)
{
    ANSI_CAPTURE_BUF* cap = (ANSI_CAPTURE_BUF*) userdata;
    MD_SIZE n = (cap->size + size <= cap->cap) ? size : (cap->cap - cap->size);
    if(n > 0) {
        memcpy(cap->buf + cap->size, text, n);
        cap->size += n;
    }
}

static void
ansi_emit_json_str(void (*out)(const MD_CHAR*, MD_SIZE, void*), void* ud,
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
            } else if(ch == 0x1b) {
                out("\\u001b", 6, ud);
            } else {
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
render_ansi_code_meta_json(MD_ANSI* r)
{
    void (*out)(const MD_CHAR*, MD_SIZE, void*) = r->process_output;
    void* ud = r->userdata;
    char buf[64];
    int i, n;

    out("\0", 1, ud);
    out("{\"c\":[", 6, ud);
    for(i = 0; i < r->n_code_blocks; i++) {
        MD_ANSI_CODE_META* m = &r->code_blocks[i];
        if(i > 0) out(",", 1, ud);

        n = snprintf(buf, sizeof(buf), "{\"s\":%u,\"e\":%u",
                     (unsigned)m->start, (unsigned)m->end);
        out(buf, (MD_SIZE)n, ud);

        if(m->lang_size > 0) {
            out(",\"l\":", 5, ud);
            ansi_emit_json_str(out, ud, m->lang, m->lang_size);
        }
        if(m->filename_size > 0) {
            out(",\"f\":", 5, ud);
            ansi_emit_json_str(out, ud, m->filename, m->filename_size);
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
        if(m->prefix_size > 0) {
            out(",\"i\":", 5, ud);
            ansi_emit_json_str(out, ud, m->prefix, m->prefix_size);
        }
        out("}", 1, ud);
    }
    out("],\"m\":[", 7, ud);
    for(i = 0; i < r->n_math_blocks; i++) {
        MD_ANSI_MATH_META* m = &r->math_blocks[i];
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


/**************************************
 ***  ANSI renderer implementation  ***
 **************************************/

static int
enter_block_callback(MD_BLOCKTYPE type, void* detail, void* userdata)
{
    MD_ANSI* r = (MD_ANSI*) userdata;

    switch(type) {
        case MD_BLOCK_DOC:
            break;

        case MD_BLOCK_QUOTE:
            if(r->need_newline) {
                render_separator(r);
                r->need_newline = 0;
            }
            r->quote_depth++;
            break;

        case MD_BLOCK_UL:
            if(r->need_newline && r->list_depth == 0) {
                render_separator(r);
                r->need_newline = 0;
            }
            break;

        case MD_BLOCK_OL:
            if(r->need_newline && r->list_depth == 0) {
                render_separator(r);
                r->need_newline = 0;
            }
            r->ol_counter = ((MD_BLOCK_OL_DETAIL*)detail)->start;
            break;

        case MD_BLOCK_LI: {
            const MD_BLOCK_LI_DETAIL* li = (const MD_BLOCK_LI_DETAIL*)detail;
            render_indent(r);
            if(li->is_task) {
                if(li->task_mark == 'x' || li->task_mark == 'X') {
                    render_ansi(r, ANSI_COLOR_GREEN);
                    RENDER_VERBATIM(r, "[x] ");
                    render_ansi(r, ANSI_COLOR_DEFAULT);
                } else {
                    RENDER_VERBATIM(r, "[ ] ");
                }
            } else {
                /* Check parent: is this inside OL or UL? We track via ol_counter. */
                if(r->ol_counter > 0) {
                    char buf[16];
                    snprintf(buf, sizeof(buf), "%d. ", r->ol_counter);
                    render_ansi(r, ANSI_DIM);
                    RENDER_VERBATIM(r, buf);
                    render_ansi(r, ANSI_DIM_OFF);
                    r->ol_counter++;
                } else {
                    render_ansi(r, ANSI_DIM);
                    RENDER_VERBATIM(r, "* ");
                    render_ansi(r, ANSI_DIM_OFF);
                }
            }
            r->list_depth++;
            r->li_opened = 1;
            break;
        }

        case MD_BLOCK_HR:
            if(r->need_newline) {
                render_separator(r);
                r->need_newline = 0;
            }
            render_indent(r);
            render_ansi(r, ANSI_DIM);
            RENDER_VERBATIM(r, HORIZONTAL_RULE);
            render_ansi(r, ANSI_DIM_OFF);
            render_newline(r);
            r->need_newline = 1;
            break;

        case MD_BLOCK_H:
            if(r->need_newline) {
                render_separator(r);
                r->need_newline = 0;
            }
            render_indent(r);
            render_ansi(r, ANSI_HEADING);
            break;

        case MD_BLOCK_CODE:
            if(r->need_newline) {
                render_separator(r);
                r->need_newline = 0;
            }
            r->in_code_block = 1;
            r->need_indent = 1;
            if(r->flags & MD_ANSI_FLAG_CODE_META) {
                MD_ANSI_CODE_META* meta = ansi_code_meta_push(r);
                if(meta != NULL) {
                    const MD_BLOCK_CODE_DETAIL* det = (const MD_BLOCK_CODE_DETAIL*) detail;
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
                    /* Capture the indent prefix by temporarily redirecting output. */
                    {
                        char pfx_buf[256];
                        ANSI_CAPTURE_BUF cap = { pfx_buf, 0, sizeof(pfx_buf) };
                        void (*saved_out)(const MD_CHAR*, MD_SIZE, void*) = r->process_output;
                        void* saved_ud = r->userdata;
                        r->process_output = ansi_capture_append;
                        r->userdata = &cap;
                        render_indent(r);
                        RENDER_VERBATIM(r, "  ");
                        r->process_output = saved_out;
                        r->userdata = saved_ud;
                        if(cap.size <= sizeof(meta->prefix)) {
                            memcpy(meta->prefix, pfx_buf, cap.size);
                            meta->prefix_size = cap.size;
                        }
                    }
                }
            }
            render_ansi(r, ANSI_DIM);
            break;

        case MD_BLOCK_HTML:
            break;

        case MD_BLOCK_P:
            if(r->need_newline && !r->li_opened) {
                render_separator(r);
                r->need_newline = 0;
            }
            if(!r->li_opened)
                render_indent(r);
            r->li_opened = 0;
            break;

        case MD_BLOCK_TABLE:
            if(r->need_newline) {
                render_separator(r);
                r->need_newline = 0;
            }
            break;

        case MD_BLOCK_THEAD:
            break;

        case MD_BLOCK_TBODY:
            break;

        case MD_BLOCK_TR:
            render_indent(r);
            break;

        case MD_BLOCK_TH:
            render_ansi(r, ANSI_BOLD);
            break;

        case MD_BLOCK_TD:
            break;

        case MD_BLOCK_FRONTMATTER:
            if(r->component_nesting > 0) {
                r->in_comp_frontmatter = 1;
            } else if(r->flags & MD_ANSI_FLAG_SHOW_FRONTMATTER) {
                render_ansi(r, ANSI_DIM);
            } else {
                r->in_comp_frontmatter = 1;
            }
            break;

        case MD_BLOCK_COMPONENT: {
            const MD_BLOCK_COMPONENT_DETAIL* comp = (const MD_BLOCK_COMPONENT_DETAIL*) detail;
            const char* color = alert_type_color(comp->tag_name.text, comp->tag_name.size);
            const MD_CHAR* title = comp->tag_name.text;
            MD_SIZE title_size = comp->tag_name.size;

            /* Use explicit title if provided (e.g. :::danger STOP). */
            if(comp->title != NULL && comp->title_size > 0) {
                title = comp->title;
                title_size = comp->title_size;
            }

            /* For ::alert{type="..."}, resolve color from the type prop. */
            if(color == NULL && ci_eq(comp->tag_name.text, comp->tag_name.size, "alert")) {
                MD_PARSED_PROPS parsed;
                int pi;
                md_parse_props(comp->raw_props, comp->raw_props_size, &parsed);
                for(pi = 0; pi < parsed.n_props; pi++) {
                    if(parsed.props[pi].type == MD_PROP_STRING
                        && ci_eq(parsed.props[pi].key, parsed.props[pi].key_size, "type"))
                    {
                        color = alert_type_color(parsed.props[pi].value, parsed.props[pi].value_size);
                        if(comp->title == NULL || comp->title_size == 0) {
                            title = parsed.props[pi].value;
                            title_size = parsed.props[pi].value_size;
                        }
                        break;
                    }
                }
                if(color == NULL) color = ANSI_COLOR_YELLOW;
            }

            if(r->need_newline) {
                render_separator(r);
                r->need_newline = 0;
            }
            r->component_nesting++;
            if(color != NULL) {
                /* Render as alert-style box */
                r->alert_color = color;
                render_indent(r);
                render_ansi(r, color);
                RENDER_VERBATIM(r, ALERT_BAR " ");
                render_ansi(r, ANSI_BOLD);
                render_verbatim(r, title, title_size);
                render_ansi(r, ANSI_BOLD_OFF);
                render_ansi(r, ANSI_COLOR_DEFAULT);
                render_newline(r);
                r->in_alert = 1;
            } else {
                render_ansi(r, ANSI_COLOR_CYAN);
            }
            break;
        }

        case MD_BLOCK_ALERT: {
            const MD_BLOCK_ALERT_DETAIL* det = (const MD_BLOCK_ALERT_DETAIL*) detail;
            const char* color = alert_type_color(det->type_name.text, det->type_name.size);
            if(color == NULL) color = ANSI_COLOR_YELLOW;
            if(r->need_newline) {
                render_separator(r);
                r->need_newline = 0;
            }
            r->alert_color = color;
            /* Render title line: ▌ TYPE */
            render_indent(r);
            render_ansi(r, color);
            RENDER_VERBATIM(r, ALERT_BAR " ");
            render_ansi(r, ANSI_BOLD);
            if(det->type_name.text != NULL && det->type_name.size > 0)
                render_verbatim(r, det->type_name.text, det->type_name.size);
            render_ansi(r, ANSI_BOLD_OFF);
            render_ansi(r, ANSI_COLOR_DEFAULT);
            render_newline(r);
            /* Set in_alert after title so render_indent doesn't double-bar */
            r->in_alert = 1;
            break;
        }

        case MD_BLOCK_TEMPLATE:
            /* Transparent — content renders normally within parent component. */
            break;
    }

    return 0;
}

static int
leave_block_callback(MD_BLOCKTYPE type, void* detail, void* userdata)
{
    MD_ANSI* r = (MD_ANSI*) userdata;

    (void) detail;

    switch(type) {
        case MD_BLOCK_DOC:
            break;

        case MD_BLOCK_QUOTE:
            r->quote_depth--;
            break;

        case MD_BLOCK_UL:
            r->ol_counter = 0;
            r->li_opened = 0;
            r->need_newline = 1;
            break;

        case MD_BLOCK_OL:
            r->ol_counter = 0;
            r->li_opened = 0;
            r->need_newline = 1;
            break;

        case MD_BLOCK_LI:
            r->list_depth--;
            render_newline(r);
            break;

        case MD_BLOCK_HR:
            break;

        case MD_BLOCK_H:
            render_ansi(r, ANSI_RESET);
            render_newline(r);
            r->need_newline = 1;
            break;

        case MD_BLOCK_CODE:
            render_ansi(r, ANSI_DIM_OFF);
            if((r->flags & MD_ANSI_FLAG_CODE_META) && r->n_code_blocks < r->code_blocks_cap) {
                r->code_blocks[r->n_code_blocks].end = r->output_offset;
                r->n_code_blocks++;
            }
            r->in_code_block = 0;
            r->need_newline = 1;
            break;

        case MD_BLOCK_HTML:
            break;

        case MD_BLOCK_P:
            render_newline(r);
            r->need_newline = 1;
            break;

        case MD_BLOCK_TABLE:
            r->need_newline = 1;
            break;

        case MD_BLOCK_THEAD:
            render_indent(r);
            render_ansi(r, ANSI_DIM);
            RENDER_VERBATIM(r, HORIZONTAL_RULE);
            render_ansi(r, ANSI_DIM_OFF);
            render_newline(r);
            break;

        case MD_BLOCK_TBODY:
            break;

        case MD_BLOCK_TR:
            render_newline(r);
            break;

        case MD_BLOCK_TH:
            render_ansi(r, ANSI_BOLD_OFF);
            RENDER_VERBATIM(r, "\t");
            break;

        case MD_BLOCK_TD:
            RENDER_VERBATIM(r, "\t");
            break;

        case MD_BLOCK_FRONTMATTER:
            if(r->in_comp_frontmatter) {
                r->in_comp_frontmatter = 0;
            } else {
                render_ansi(r, ANSI_DIM_OFF);
                r->need_newline = 1;
            }
            break;

        case MD_BLOCK_COMPONENT:
            r->component_nesting--;
            if(r->in_alert) {
                r->in_alert = 0;
                r->alert_color = NULL;
            } else {
                render_ansi(r, ANSI_COLOR_DEFAULT);
            }
            r->need_newline = 1;
            break;

        case MD_BLOCK_ALERT:
            r->in_alert = 0;
            r->alert_color = NULL;
            r->need_newline = 1;
            break;

        case MD_BLOCK_TEMPLATE:
            /* Transparent — no output needed. */
            break;
    }

    return 0;
}

static int
enter_span_callback(MD_SPANTYPE type, void* detail, void* userdata)
{
    MD_ANSI* r = (MD_ANSI*) userdata;

    if(type == MD_SPAN_IMG)
        r->image_nesting_level++;

    if(r->image_nesting_level > 0 && type != MD_SPAN_IMG)
        return 0;

    switch(type) {
        case MD_SPAN_EM:                render_ansi(r, ANSI_ITALIC); break;
        case MD_SPAN_STRONG:            render_ansi(r, ANSI_BOLD); break;
        case MD_SPAN_U:                 render_ansi(r, ANSI_UNDERLINE); break;
        case MD_SPAN_A: {
            const MD_SPAN_A_DETAIL* a = (const MD_SPAN_A_DETAIL*) detail;
            /* OSC 8 hyperlink: makes text clickable in supported terminals */
            if(!(r->flags & MD_ANSI_FLAG_NO_COLOR) && a->href.size > 0) {
                RENDER_VERBATIM(r, ANSI_HYPERLINK_OPEN);
                render_attribute(r, &a->href, render_verbatim);
                RENDER_VERBATIM(r, ANSI_HYPERLINK_SEP);
            }
            render_ansi(r, ANSI_LINK);
            break;
        }
        case MD_SPAN_IMG:
        //   render_ansi(r, ANSI_DIM);
        //     RENDER_VERBATIM(r, "[image: ");
        /* Images are suppressed — alt text is silently skipped via image_nesting_level */
            break;
        case MD_SPAN_CODE:              render_ansi(r, ANSI_COLOR_CYAN); break;
        case MD_SPAN_DEL:               render_ansi(r, ANSI_STRIKETHROUGH); break;
        case MD_SPAN_LATEXMATH:
            render_ansi(r, ANSI_COLOR_YELLOW);
            if(r->flags & MD_ANSI_FLAG_CODE_META) {
                MD_ANSI_MATH_META* meta = ansi_math_meta_push(r);
                if(meta != NULL) {
                    meta->start = r->output_offset;
                    meta->display = 0;
                    r->in_math_span = 1;
                }
            }
            break;
        case MD_SPAN_LATEXMATH_DISPLAY:
            render_ansi(r, ANSI_COLOR_YELLOW);
            if(r->flags & MD_ANSI_FLAG_CODE_META) {
                MD_ANSI_MATH_META* meta = ansi_math_meta_push(r);
                if(meta != NULL) {
                    meta->start = r->output_offset;
                    meta->display = 1;
                    r->in_math_span = 1;
                }
            }
            break;
        case MD_SPAN_WIKILINK:          render_ansi(r, ANSI_LINK); break;
        case MD_SPAN_COMPONENT:         render_ansi(r, ANSI_COLOR_CYAN); break;
        case MD_SPAN_SPAN:              break;  /* Transparent: no special styling */
    }

    return 0;
}

static int
leave_span_callback(MD_SPANTYPE type, void* detail, void* userdata)
{
    MD_ANSI* r = (MD_ANSI*) userdata;

    if(type == MD_SPAN_IMG)
        r->image_nesting_level--;

    if(r->image_nesting_level > 0)
        return 0;

    switch(type) {
        case MD_SPAN_EM:                render_ansi(r, ANSI_ITALIC_OFF); break;
        case MD_SPAN_STRONG:            render_ansi(r, ANSI_BOLD_OFF); break;
        case MD_SPAN_U:                 render_ansi(r, ANSI_UNDERLINE_OFF); break;
        case MD_SPAN_A: {
            const MD_SPAN_A_DETAIL* a = (const MD_SPAN_A_DETAIL*) detail;
            render_ansi(r, ANSI_RESET);
            /* Close OSC 8 hyperlink */
            if(!(r->flags & MD_ANSI_FLAG_NO_COLOR) && a->href.size > 0)
                RENDER_VERBATIM(r, ANSI_HYPERLINK_CLOSE);
            /* Show URL as dim fallback for terminals without OSC 8 */
            if((r->flags & MD_ANSI_FLAG_SHOW_URLS) && a->href.size > 0 && !a->is_autolink) {
                render_ansi(r, ANSI_LINK_URL);
                RENDER_VERBATIM(r, " (");
                render_attribute(r, &a->href, render_verbatim);
                RENDER_VERBATIM(r, ")");
                render_ansi(r, ANSI_RESET);
            }
            break;
        }
        case MD_SPAN_IMG:
            break;
        case MD_SPAN_CODE:              render_ansi(r, ANSI_COLOR_DEFAULT); break;
        case MD_SPAN_DEL:               render_ansi(r, ANSI_STRIKE_OFF); break;
        case MD_SPAN_LATEXMATH:         /*fall through*/
        case MD_SPAN_LATEXMATH_DISPLAY:
            if((r->flags & MD_ANSI_FLAG_CODE_META) && r->in_math_span) {
                r->math_blocks[r->n_math_blocks].end = r->output_offset;
                r->n_math_blocks++;
                r->in_math_span = 0;
            }
            render_ansi(r, ANSI_COLOR_DEFAULT);
            break;
        case MD_SPAN_WIKILINK:          render_ansi(r, ANSI_RESET); break;
        case MD_SPAN_COMPONENT:         render_ansi(r, ANSI_COLOR_DEFAULT); break;
        case MD_SPAN_SPAN:              break;  /* Transparent: no special styling */
    }

    return 0;
}

static int
text_callback(MD_TEXTTYPE type, const MD_CHAR* text, MD_SIZE size, void* userdata)
{
    MD_ANSI* r = (MD_ANSI*) userdata;

    /* Suppress component frontmatter text. */
    if(r->in_comp_frontmatter)
        return 0;

    switch(type) {
        case MD_TEXT_NULLCHAR:
            render_utf8_codepoint(r, 0x0000, render_verbatim);
            break;

        case MD_TEXT_BR:
            render_newline(r);
            render_indent(r);
            break;

        case MD_TEXT_SOFTBR:
            if(r->image_nesting_level == 0) {
                render_newline(r);
                render_indent(r);
            } else {
                RENDER_VERBATIM(r, " ");
            }
            break;

        case MD_TEXT_HTML:
            /* Raw HTML: suppress in terminal output */
            break;

        case MD_TEXT_ENTITY:
            render_entity(r, text, size, render_verbatim);
            break;

        case MD_TEXT_CODE:
            if(r->in_code_block) {
                /* Inside code block: the parser sends each line and its \n
                 * as separate callbacks. We use need_indent to track when
                 * we need to emit the indent prefix at line start. */
                if(size == 1 && text[0] == '\n') {
                    render_newline(r);
                    r->need_indent = 1;
                } else {
                    if(r->need_indent) {
                        render_indent(r);
                        RENDER_VERBATIM(r, "  ");
                        r->need_indent = 0;
                    }
                    render_verbatim(r, text, size);
                }
            } else {
                /* Inline code span */
                render_verbatim(r, text, size);
            }
            break;

        default:
            render_verbatim(r, text, size);
            break;
    }

    return 0;
}

static void
debug_log_callback(const char* msg, void* userdata)
{
    MD_ANSI* r = (MD_ANSI*) userdata;
    if(r->flags & MD_ANSI_FLAG_DEBUG)
        fprintf(stderr, "MD4X: %s\n", msg);
}

int
md_ansi(const MD_CHAR* input, MD_SIZE input_size,
        void (*process_output)(const MD_CHAR*, MD_SIZE, void*),
        void* userdata, unsigned parser_flags, unsigned renderer_flags)
{
    MD_ANSI render;
    MD_PARSER parser;

    /* Heal-before-render: run md_heal first, then render the healed output. */
    if(renderer_flags & MD_ANSI_FLAG_HEAL) {
        MD4X_HEAL_BUF hbuf;
        int ret;
        if(md4x_heal_input(input, input_size, &hbuf) != 0) {
            free(hbuf.data);
            return -1;
        }
        ret = md_ansi(hbuf.data, hbuf.size, process_output, userdata,
                      parser_flags, renderer_flags & ~MD_ANSI_FLAG_HEAL);
        free(hbuf.data);
        return ret;
    }

    memset(&parser, 0, sizeof(parser));
    parser.flags = parser_flags;
    parser.enter_block = enter_block_callback;
    parser.leave_block = leave_block_callback;
    parser.enter_span = enter_span_callback;
    parser.leave_span = leave_span_callback;
    parser.text = text_callback;
    parser.debug_log = debug_log_callback;

    memset(&render, 0, sizeof(render));
    render.process_output = process_output;
    render.userdata = userdata;
    render.flags = renderer_flags;

    /* Consider skipping UTF-8 byte order mark (BOM). */
    if(renderer_flags & MD_ANSI_FLAG_SKIP_UTF8_BOM  &&  sizeof(MD_CHAR) == 1) {
        static const MD_CHAR bom[3] = { (char)0xef, (char)0xbb, (char)0xbf };
        if(input_size >= sizeof(bom)  &&  memcmp(input, bom, sizeof(bom)) == 0) {
            input += sizeof(bom);
            input_size -= sizeof(bom);
        }
    }

    {
        int ret = md_parse(input, input_size, &parser, (void*) &render);

        if(renderer_flags & MD_ANSI_FLAG_CODE_META) {
            if(ret == 0)
                render_ansi_code_meta_json(&render);
            ansi_code_meta_cleanup(&render);
        }

        return ret;
    }
}
