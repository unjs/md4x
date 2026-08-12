// SPDX-License-Identifier: MIT
//
// Shared JSON writer + YAML-to-JSON helpers for the md4x renderers.
//
// This is the Zig counterpart of the (orphaned) header-only md4x-json.h. The C
// header's helpers are `static`, so @cImport translates them as unresolved
// external references (which the WASM linker cannot satisfy). The streaming JSON
// writer and the libyaml-backed YAML-to-JSON conversion are therefore ported to
// Zig here and shared by the AST and meta renderers. Behavior is kept
// byte-for-byte identical to the C source, including YAML 1.1 type coercion.
//
// Imported (not @cImport'd into a clashing symbol) by each renderer lib: Zig
// compiles its own internal copy per importing artifact, so there is no
// exported-symbol collision and no build.zig change is required.

const std = @import("std");

// MD_* types now come from the Zig-native abi module (replacing md4x.h);
// genuinely external C headers (if any) stay in a @cImport bound as `sys`.
const c = @import("abi");
const sys = @cImport({
    @cInclude("stdio.h");
    @cInclude("yaml.h");
});

pub const ProcessOutputFn = ?*const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void;

// Streaming JSON writer (mirrors the C JSON_WRITER struct).
pub const JsonWriter = struct {
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
};

pub fn json_write(w: *JsonWriter, data: [*]const u8, size: c.MD_SIZE) void {
    w.process_output.?(@ptrCast(data), size, w.userdata);
}

// Write a sentinel-terminated string slice (length known at the type level).
pub fn json_write_str(w: *JsonWriter, str: [:0]const u8) void {
    json_write(w, str.ptr, @intCast(str.len));
}

// Write a NUL-terminated string pointer (length computed via strlen).
pub fn json_write_strz(w: *JsonWriter, str: [*:0]const u8) void {
    json_write(w, str, @intCast(std.mem.len(str)));
}

pub fn json_write_escaped(w: *JsonWriter, str: [*]const u8, size: c.MD_SIZE) void {
    var i: c.MD_OFFSET = 0;
    var beg: c.MD_OFFSET = 0;
    var esc: [8]u8 = undefined;

    while (i < size) : (i += 1) {
        const ch: u8 = str[i];
        var replacement: ?[*]const u8 = null;
        var esc_len: c_int = 0;

        switch (ch) {
            '"' => replacement = "\\\"",
            '\\' => replacement = "\\\\",
            0x08 => replacement = "\\b",
            0x0C => replacement = "\\f",
            '\n' => replacement = "\\n",
            '\r' => replacement = "\\r",
            '\t' => replacement = "\\t",
            else => {
                if (ch < 0x20) {
                    _ = sys.snprintf(&esc, esc.len, "\\u%04x", @as(c_uint, ch));
                    replacement = &esc;
                    esc_len = 6;
                }
            },
        }

        if (replacement) |rep| {
            if (i > beg)
                json_write(w, str + beg, i - beg);
            if (esc_len == 0)
                esc_len = @intCast(std.mem.len(@as([*:0]const u8, @ptrCast(rep))));
            json_write(w, rep, @intCast(esc_len));
            beg = i + 1;
        }
    }

    if (i > beg)
        json_write(w, str + beg, i - beg);
}

pub fn json_write_string(w: *JsonWriter, str: [*]const u8, size: c.MD_SIZE) void {
    json_write(w, "\"", 1);
    json_write_escaped(w, str, size);
    json_write(w, "\"", 1);
}

// ---- YAML-to-JSON (md4x-json.h: json_write_yaml_*) ----

// Helper: check if a string matches a literal (case-insensitive, known length).
fn yaml_streq_ci(s: [*]const u8, len: c.MD_SIZE, lit: []const u8) bool {
    if (len != lit.len)
        return false;
    var i: c.MD_SIZE = 0;
    while (i < len) : (i += 1) {
        var ch = s[i];
        if (ch >= 'A' and ch <= 'Z')
            ch += 32;
        if (ch != lit[i])
            return false;
    }
    return true;
}

// Helper: check if a value string looks like a JSON number.
fn yaml_is_number(s: [*]const u8, len: c.MD_SIZE) bool {
    var i: c.MD_SIZE = 0;
    var has_digit = false;
    var has_dot = false;

    if (len == 0)
        return false;

    // Optional leading sign.
    if (s[0] == '-' or s[0] == '+') {
        i += 1;
        if (i >= len)
            return false;
    }

    while (i < len) : (i += 1) {
        if (s[i] >= '0' and s[i] <= '9') {
            has_digit = true;
        } else if (s[i] == '.' and !has_dot) {
            has_dot = true;
        } else {
            return false;
        }
    }
    return has_digit;
}

// Write a YAML scalar as a typed JSON value (YAML 1.1 resolution for plain scalars).
fn json_write_yaml_scalar(w: *JsonWriter, event: *const sys.yaml_event_t) void {
    const val: [*]const u8 = @ptrCast(event.data.scalar.value);
    const len: c.MD_SIZE = @intCast(event.data.scalar.length);
    const style = event.data.scalar.style;

    // Quoted scalars are always strings.
    if (style == sys.YAML_SINGLE_QUOTED_SCALAR_STYLE or style == sys.YAML_DOUBLE_QUOTED_SCALAR_STYLE) {
        json_write_string(w, val, len);
        return;
    }

    // Plain scalars: apply type coercion.
    if (len == 0) {
        json_write_str(w, "null");
        return;
    }
    if (yaml_streq_ci(val, len, "null") or (len == 1 and val[0] == '~')) {
        json_write_str(w, "null");
        return;
    }
    if (yaml_streq_ci(val, len, "true") or yaml_streq_ci(val, len, "yes") or yaml_streq_ci(val, len, "on")) {
        json_write_str(w, "true");
        return;
    }
    if (yaml_streq_ci(val, len, "false") or yaml_streq_ci(val, len, "no") or yaml_streq_ci(val, len, "off")) {
        json_write_str(w, "false");
        return;
    }
    if (yaml_is_number(val, len)) {
        json_write(w, val, len);
        return;
    }

    // Default: string (also covers literal/folded block scalars).
    json_write_string(w, val, len);
}

// Write a YAML mapping as JSON object key-value pairs (without outer braces).
// Assumes MAPPING_START consumed. Returns number of pairs, or -1 on error.
fn json_write_yaml_mapping(w: *JsonWriter, yp: *sys.yaml_parser_t) c_int {
    var event: sys.yaml_event_t = undefined;
    var n: c_int = 0;

    while (true) {
        if (sys.yaml_parser_parse(yp, &event) == 0)
            return -1;

        if (event.type == sys.YAML_MAPPING_END_EVENT) {
            sys.yaml_event_delete(&event);
            break;
        }

        if (event.type != sys.YAML_SCALAR_EVENT) {
            sys.yaml_event_delete(&event);
            return -1;
        }

        if (n > 0)
            json_write(w, ",", 1);

        // Write key.
        json_write(w, "\"", 1);
        json_write_escaped(w, @ptrCast(event.data.scalar.value), @intCast(event.data.scalar.length));
        json_write_str(w, "\":");
        sys.yaml_event_delete(&event);

        // Write value (recursive).
        if (json_write_yaml_value(w, yp) < 0)
            return -1;

        n += 1;
    }
    return n;
}

// Write a YAML sequence as a JSON array.
// Assumes SEQUENCE_START consumed. Returns 0 on success, -1 on error.
fn json_write_yaml_sequence(w: *JsonWriter, yp: *sys.yaml_parser_t) c_int {
    var event: sys.yaml_event_t = undefined;
    var n: c_int = 0;

    json_write(w, "[", 1);

    while (true) {
        if (sys.yaml_parser_parse(yp, &event) == 0)
            return -1;

        if (event.type == sys.YAML_SEQUENCE_END_EVENT) {
            sys.yaml_event_delete(&event);
            break;
        }

        if (n > 0)
            json_write(w, ",", 1);

        if (event.type == sys.YAML_SCALAR_EVENT) {
            json_write_yaml_scalar(w, &event);
            sys.yaml_event_delete(&event);
        } else if (event.type == sys.YAML_MAPPING_START_EVENT) {
            sys.yaml_event_delete(&event);
            json_write(w, "{", 1);
            if (json_write_yaml_mapping(w, yp) < 0)
                return -1;
            json_write(w, "}", 1);
        } else if (event.type == sys.YAML_SEQUENCE_START_EVENT) {
            sys.yaml_event_delete(&event);
            if (json_write_yaml_sequence(w, yp) < 0)
                return -1;
        } else {
            sys.yaml_event_delete(&event);
            return -1;
        }

        n += 1;
    }

    json_write(w, "]", 1);
    return 0;
}

// Write the next YAML value (scalar, mapping, or sequence) as JSON.
// Returns 0 on success, -1 on error.
fn json_write_yaml_value(w: *JsonWriter, yp: *sys.yaml_parser_t) c_int {
    var event: sys.yaml_event_t = undefined;

    if (sys.yaml_parser_parse(yp, &event) == 0)
        return -1;

    if (event.type == sys.YAML_SCALAR_EVENT) {
        json_write_yaml_scalar(w, &event);
        sys.yaml_event_delete(&event);
        return 0;
    }
    if (event.type == sys.YAML_MAPPING_START_EVENT) {
        sys.yaml_event_delete(&event);
        json_write(w, "{", 1);
        if (json_write_yaml_mapping(w, yp) < 0)
            return -1;
        json_write(w, "}", 1);
        return 0;
    }
    if (event.type == sys.YAML_SEQUENCE_START_EVENT) {
        sys.yaml_event_delete(&event);
        return json_write_yaml_sequence(w, yp);
    }
    if (event.type == sys.YAML_ALIAS_EVENT) {
        sys.yaml_event_delete(&event);
        json_write_str(w, "null");
        return 0;
    }

    sys.yaml_event_delete(&event);
    return -1;
}

// Write parsed YAML frontmatter as JSON props using libyaml.
// Returns number of top-level props written.
pub fn json_write_yaml_props(w: *JsonWriter, text: [*]const u8, size: c.MD_SIZE) c_int {
    var yp: sys.yaml_parser_t = undefined;
    var event: sys.yaml_event_t = undefined;
    var n_written: c_int = 0;

    if (sys.yaml_parser_initialize(&yp) == 0)
        return 0;

    sys.yaml_parser_set_input_string(&yp, @ptrCast(text), size);

    // Consume STREAM_START.
    if (sys.yaml_parser_parse(&yp, &event) == 0) {
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    if (event.type != sys.YAML_STREAM_START_EVENT) {
        sys.yaml_event_delete(&event);
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    sys.yaml_event_delete(&event);

    // Consume DOCUMENT_START.
    if (sys.yaml_parser_parse(&yp, &event) == 0) {
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    if (event.type != sys.YAML_DOCUMENT_START_EVENT) {
        sys.yaml_event_delete(&event);
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    sys.yaml_event_delete(&event);

    // Expect top-level MAPPING_START.
    if (sys.yaml_parser_parse(&yp, &event) == 0) {
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    if (event.type != sys.YAML_MAPPING_START_EVENT) {
        sys.yaml_event_delete(&event);
        sys.yaml_parser_delete(&yp);
        return n_written;
    }
    sys.yaml_event_delete(&event);

    n_written = json_write_yaml_mapping(w, &yp);
    if (n_written < 0)
        n_written = 0;

    sys.yaml_parser_delete(&yp);
    return n_written;
}
