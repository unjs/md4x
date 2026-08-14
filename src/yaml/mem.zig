//! Containers for the libyaml port: the growable byte string, the fixed input
//! buffer, and the stack/queue that back `Parser`'s token queue, indent stack,
//! simple-key stack and state stack.
//!
//! These replace libyaml's `yaml_string_t` / `yaml_buffer_t` and the
//! `STRING_*` / `STACK_*` / `QUEUE_*` macro families in `src/yaml_private.h`.
//! The growth policy is ported exactly (`yaml_string_extend`,
//! `yaml_stack_extend`, `yaml_queue_extend` in `src/api.c`) because scanner
//! behaviour depends on it: `STRING_EXTEND` keeps at least five spare zero
//! bytes past the write cursor, which is the ONLY reason libyaml's scalar
//! values are NUL-terminated.
//!
//! The C originals are raw `start`/`pointer`/`end` pointer triples. Here they
//! are a slice plus indices, so every access is bounds-checked in Debug and
//! ReleaseSafe (see .agents/conventions.md — "a cursor a loop can step past the
//! front of an array must be a signed index, never a pointer"). The index
//! arithmetic is otherwise 1:1 with the macros:
//!
//!   C                                Zig
//!   ------------------------------   ------------------------------
//!   string.pointer - string.start    string.len
//!   *(string.pointer++) = c          string.putAssumeCapacity(c)
//!   string.start                     string.slice().ptr  (see toOwned)
//!   STRING_EXTEND(parser, string)    try string.extend(alloc)
//!   CLEAR(parser, string)            string.clear()
//!   JOIN(parser, a, b)               try a.join(alloc, &b)
//!   stack.top[-1]                    stack.top().*
//!   stack.top - stack.start          stack.len
//!   queue.head[i]                    queue.at(i).*
//!   queue.tail[-1]                   queue.last().*

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The size of the input raw buffer (`yaml_private.h`).
pub const INPUT_RAW_BUFFER_SIZE: usize = 16384;

/// The size of the input buffer. It must be possible to decode the whole raw
/// buffer into it.
pub const INPUT_BUFFER_SIZE: usize = INPUT_RAW_BUFFER_SIZE * 3;

pub const INITIAL_STACK_SIZE: usize = 16;
pub const INITIAL_QUEUE_SIZE: usize = 16;
pub const INITIAL_STRING_SIZE: usize = 16;

/// libyaml's `MAX_FILE_SIZE`: the largest input `parser.offset` can address.
pub const MAX_FILE_SIZE: usize = std.math.maxInt(usize) / 2;

// ---- String (yaml_string_t) ----

/// A growable, always-zero-filled byte buffer.
///
/// Every byte from `len` to the end of the allocation is zero, which is what
/// makes `toOwned` able to hand out a `[:0]u8` and what makes libyaml's scalar
/// values NUL-terminated. `putAssumeCapacity` and the `read*` helpers rely on
/// `extend` having been called first, exactly like `STRING_EXTEND` + `COPY`.
pub const String = struct {
    /// The whole allocation. `buf[len..]` is guaranteed zero.
    buf: []u8 = &.{},
    /// Write cursor — `string.pointer - string.start` in the C.
    len: usize = 0,
    /// High-water mark: the largest `len` reached since the last `clear`.
    ///
    /// `clear` has to re-zero every byte that was ever written, not just the
    /// live ones, because `join` rewinds its source WITHOUT zeroing and the
    /// scanners then read byte 0 of the logically-empty result. The C gets this
    /// for free by memsetting the whole allocation; doing that here would make
    /// a pooled scratch buffer pay its own worst case on every later token.
    hi: usize = 0,

    pub const empty: String = .{};

    pub fn init(alloc: Allocator, size: usize) Allocator.Error!String {
        const buf = try alloc.alloc(u8, size);
        @memset(buf, 0);
        return .{ .buf = buf, .len = 0 };
    }

    pub fn deinit(self: *String, alloc: Allocator) void {
        if (self.buf.len != 0) alloc.free(self.buf);
        self.* = .{};
    }

    /// `yaml_string_extend`: double the allocation, zeroing the new half.
    ///
    /// Unconditional, exactly like the C function. `join` loops on THIS, not on
    /// `extend` — looping on the guarded form spins forever once the guard is
    /// satisfied but the requested room still is not.
    ///
    /// `noinline` so the guarded `extend` above stays small enough to inline at
    /// its call sites — the same hot-check / cold-body split as
    /// `Parser.cache` / `reader.updateBuffer`.
    pub noinline fn grow(self: *String, alloc: Allocator) Allocator.Error!void {
        const old_len = self.buf.len;
        const new_len = if (old_len == 0) INITIAL_STRING_SIZE else old_len * 2;
        self.buf = try alloc.realloc(self.buf, new_len);
        @memset(self.buf[old_len..], 0);
    }

    /// `STRING_EXTEND(context, string)`: grow only when fewer than five bytes
    /// are spare.
    ///
    /// The `pointer + 5 < end` guard is kept verbatim — the widest single
    /// `COPY` / `READ_LINE` writes 4 bytes, and the spare fifth byte is the NUL
    /// terminator every consumer of a scalar value reads.
    ///
    /// `inline` because the C is a macro and the guard is two loads and a
    /// compare; see `grow` below for the other half.
    pub inline fn extend(self: *String, alloc: Allocator) Allocator.Error!void {
        if (self.len + 5 < self.buf.len) return;
        return self.grow(alloc);
    }

    /// `CLEAR`: rewind the cursor and re-zero everything ever written.
    ///
    /// The C memsets the whole allocation. Zeroing `[0..max(len, hi)]` covers
    /// the same bytes: nothing above the high-water mark was ever written, so
    /// it is still zero from `init` or from `grow`'s tail memset.
    pub fn clear(self: *String) void {
        const dirty = @max(self.len, self.hi);
        @memset(self.buf[0..dirty], 0);
        self.len = 0;
        self.hi = 0;
    }

    /// The bytes written so far — `string.start .. string.pointer`.
    pub fn slice(self: *const String) []u8 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const String) bool {
        return self.len == 0;
    }

    /// `*(string.pointer++) = c`. The caller must have called `extend` first.
    pub fn putAssumeCapacity(self: *String, c: u8) void {
        self.buf[self.len] = c;
        self.len += 1;
    }

    /// `JOIN(context, self, other)`: append `other`'s bytes and rewind `other`.
    pub fn join(self: *String, alloc: Allocator, other: *String) Allocator.Error!void {
        if (other.len == 0) return;
        // `grow`, not `extend`: the C loops on the unconditional
        // `yaml_string_extend`, and looping on the guarded form spins forever
        // as soon as the five-spare-bytes guard is satisfied but the room this
        // loop wants still is not.
        while (self.buf.len -| self.len <= other.len) try self.grow(alloc);
        @memcpy(self.buf[self.len..][0..other.len], other.slice());
        self.len += other.len;
        // The rewind leaves other.buf[0..len] stale on purpose (see `hi`).
        other.hi = @max(other.hi, other.len);
        other.len = 0;
    }

    /// Hand the written bytes to a token or event, shrunk to exactly what was
    /// written plus the NUL.
    ///
    /// libyaml transfers `string.start` and frees it later with `yaml_free`,
    /// which does not need a length. A Zig allocator does, and the caller only
    /// records the value's length — so the allocation is shrunk to `len + 1`
    /// here, making `free(value)` (which adds 1 for the sentinel) exact. See
    /// .agents/conventions.md, "shrink-to-fit where the length field is the
    /// only record of the allocation".
    pub fn toOwned(self: *String, alloc: Allocator) Allocator.Error![:0]u8 {
        if (self.buf.len == 0) {
            const buf = try alloc.allocSentinel(u8, 0, 0);
            self.* = .{};
            return buf;
        }
        const len = self.len;
        const buf = try alloc.realloc(self.buf, len + 1);
        buf[len] = 0;
        self.* = .{};
        return buf[0..len :0];
    }

    /// Free a value handed out by `toOwned`.
    pub fn freeOwned(alloc: Allocator, value: [:0]u8) void {
        alloc.free(value);
    }
};

// ---- Buffer (the parser's decoded input window) ----

/// The parser's fixed-size decoded-input window (`parser.buffer`) and its raw
/// counterpart (`parser.raw_buffer`).
///
/// `cap` is the C `end - start`; the allocation is `cap + guard` bytes so that
/// the multi-byte lookahead in `IS_BREAK_AT` / `IS_PRINTABLE_AT` (which reads
/// up to two bytes past the character it is testing) can never index out of
/// the slice. Those trailing bytes stay zero, which is what the C reads too:
/// the reader NUL-terminates at `last`, and every multi-byte predicate only
/// looks past a lead byte it has already matched.
pub const Buffer = struct {
    /// The allocation: `cap + guard` bytes.
    mem: []u8 = &.{},
    /// `end - start` — the usable capacity, excluding the guard.
    cap: usize = 0,
    /// `pointer - start` — the read cursor.
    pos: usize = 0,
    /// `last - start` — the end of the valid decoded bytes.
    last: usize = 0,

    pub const guard: usize = 8;

    /// Only the guard tail is zeroed, matching the C.
    ///
    /// `BUFFER_INIT` mallocs and does NOT memset: the reader NUL-terminates at
    /// `last`, and no predicate can read past that NUL (each looks ahead only
    /// after matching a lead byte the reader already decoded). Zeroing the
    /// whole window instead costs 64 KB of stores per parser — which, for
    /// frontmatter, is once per document, and measured 1.6x slower than the C
    /// on a 296-byte input before this was fixed.
    pub fn init(alloc: Allocator, cap: usize) Allocator.Error!Buffer {
        const mem = try alloc.alloc(u8, cap + guard);
        @memset(mem[cap..], 0);
        return .{ .mem = mem, .cap = cap, .pos = 0, .last = 0 };
    }

    pub fn deinit(self: *Buffer, alloc: Allocator) void {
        if (self.mem.len != 0) alloc.free(self.mem);
        self.* = .{};
    }

    /// `buffer.pointer[offset]`.
    pub fn at(self: *const Buffer, offset: usize) u8 {
        return self.mem[self.pos + offset];
    }

    /// The undecoded remainder — `pointer .. last`.
    pub fn pending(self: *const Buffer) []u8 {
        return self.mem[self.pos..self.last];
    }

    /// Advance the read cursor by `n` bytes.
    pub fn skip(self: *Buffer, n: usize) void {
        self.pos += n;
    }
};

// ---- Stack / Queue ----

/// `yaml_stack_t`: `start` / `top` / `end`, grown by doubling.
pub fn Stack(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The allocation — capacity, not length.
        buf: []T = &.{},
        /// `top - start`.
        len: usize = 0,

        pub const empty: Self = .{};

        pub fn init(alloc: Allocator, capacity: usize) Allocator.Error!Self {
            return .{ .buf = try alloc.alloc(T, capacity), .len = 0 };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            if (self.buf.len != 0) alloc.free(self.buf);
            self.* = .{};
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        /// `STACK_LIMIT(context, stack, size)`: true while the stack is still
        /// under `size` entries. The C spelling records a memory error on
        /// failure; callers here raise it themselves so the error type stays
        /// visible at the call site.
        pub fn underLimit(self: *const Self, size: usize) bool {
            return self.len < size;
        }

        pub fn push(self: *Self, alloc: Allocator, value: T) Allocator.Error!void {
            if (self.len == self.buf.len) {
                const new_len = if (self.buf.len == 0) INITIAL_STACK_SIZE else self.buf.len * 2;
                self.buf = try alloc.realloc(self.buf, new_len);
            }
            self.buf[self.len] = value;
            self.len += 1;
        }

        pub fn pop(self: *Self) T {
            self.len -= 1;
            return self.buf[self.len];
        }

        /// `stack.top[-1]`.
        pub fn top(self: *const Self) *T {
            return &self.buf[self.len - 1];
        }

        /// `stack.start[i]`.
        pub fn at(self: *const Self, i: usize) *T {
            return &self.buf[i];
        }

        pub fn slice(self: *const Self) []T {
            return self.buf[0..self.len];
        }
    };
}

/// `yaml_queue_t`: `start` / `head` / `tail` / `end`.
///
/// `grow` ports `yaml_queue_extend` exactly, including its two-step behaviour:
/// the allocation only doubles when the queue is both full and anchored at the
/// start; otherwise the live range is shifted down to the front. Token indices
/// handed to `insert` are relative to `head`, as in `QUEUE_INSERT`.
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T = &.{},
        head: usize = 0,
        tail: usize = 0,

        pub const empty: Self = .{};

        pub fn init(alloc: Allocator, capacity: usize) Allocator.Error!Self {
            return .{ .buf = try alloc.alloc(T, capacity), .head = 0, .tail = 0 };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            if (self.buf.len != 0) alloc.free(self.buf);
            self.* = .{};
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head == self.tail;
        }

        /// `queue.tail - queue.head`.
        pub fn count(self: *const Self) usize {
            return self.tail - self.head;
        }

        fn grow(self: *Self, alloc: Allocator) Allocator.Error!void {
            if (self.head == 0 and self.tail == self.buf.len) {
                const new_len = if (self.buf.len == 0) INITIAL_QUEUE_SIZE else self.buf.len * 2;
                self.buf = try alloc.realloc(self.buf, new_len);
            }
            if (self.tail == self.buf.len) {
                if (self.head != self.tail) {
                    std.mem.copyForwards(T, self.buf[0..self.count()], self.buf[self.head..self.tail]);
                }
                self.tail -= self.head;
                self.head = 0;
            }
        }

        pub fn enqueue(self: *Self, alloc: Allocator, value: T) Allocator.Error!void {
            if (self.tail == self.buf.len) try self.grow(alloc);
            self.buf[self.tail] = value;
            self.tail += 1;
        }

        pub fn dequeue(self: *Self) T {
            const value = self.buf[self.head];
            self.head += 1;
            return value;
        }

        /// `QUEUE_INSERT(context, queue, index, value)` — `index` counts from
        /// `head`.
        pub fn insert(self: *Self, alloc: Allocator, index: usize, value: T) Allocator.Error!void {
            if (self.tail == self.buf.len) try self.grow(alloc);
            const from = self.head + index;
            std.mem.copyBackwards(T, self.buf[from + 1 .. self.tail + 1], self.buf[from..self.tail]);
            self.buf[from] = value;
            self.tail += 1;
        }

        /// `queue.head[i]`.
        pub fn at(self: *const Self, i: usize) *T {
            return &self.buf[self.head + i];
        }

        /// `queue.tail[-1]`.
        pub fn last(self: *const Self) *T {
            return &self.buf[self.tail - 1];
        }

        pub fn slice(self: *const Self) []T {
            return self.buf[self.head..self.tail];
        }
    };
}

// ---- Tests ----

const testing = std.testing;

test "String extend keeps five spare zero bytes and NUL-terminates" {
    const alloc = testing.allocator;
    var s = try String.init(alloc, INITIAL_STRING_SIZE);
    defer s.deinit(alloc);

    for ("hello world, this is longer than sixteen bytes") |c| {
        try s.extend(alloc);
        s.putAssumeCapacity(c);
    }
    try testing.expectEqualStrings("hello world, this is longer than sixteen bytes", s.slice());
    try testing.expect(s.len + 5 < s.buf.len);
    try testing.expectEqual(@as(u8, 0), s.buf[s.len]);
}

test "String toOwned shrinks to len + 1 and stays NUL-terminated" {
    const alloc = testing.allocator;
    var s = try String.init(alloc, INITIAL_STRING_SIZE);
    for ("abc") |c| {
        try s.extend(alloc);
        s.putAssumeCapacity(c);
    }
    const owned = try s.toOwned(alloc);
    defer alloc.free(owned);
    try testing.expectEqualStrings("abc", owned);
    try testing.expectEqual(@as(u8, 0), owned.ptr[3]);
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "clear re-zeroes bytes a join rewound but did not zero" {
    // The load-bearing case: the scanners read byte 0 of a logically-empty
    // fold buffer, and `join` rewinds its source WITHOUT zeroing, so only
    // `clear` can put the zero back. `clear` must therefore cover the
    // high-water mark, not just the live length -- if it tracked `len` alone
    // it would zero nothing here and byte 0 would stay stale.
    const alloc = testing.allocator;
    var dst = try String.init(alloc, INITIAL_STRING_SIZE);
    defer dst.deinit(alloc);
    var src = try String.init(alloc, INITIAL_STRING_SIZE);
    defer src.deinit(alloc);

    for ("\n\n\n") |c| {
        try src.extend(alloc);
        src.putAssumeCapacity(c);
    }
    try dst.join(alloc, &src);

    // Exactly the C's state after JOIN: rewound, but still readable and stale.
    try testing.expectEqual(@as(usize, 0), src.len);
    try testing.expectEqual(@as(u8, '\n'), src.buf[0]);

    src.clear();
    try testing.expectEqual(@as(u8, 0), src.buf[0]);
    for (src.buf) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "clear does not walk past the high-water mark" {
    // Deliberately white-box, and the ONLY deterministic guard on this: going
    // back to the C's `memset(whole allocation)` stays correct, so no output
    // test can see it -- it just makes every pooled scratch buffer re-zero its
    // own worst case on every later token. Measured 68x on a 330 KB document
    // (9 ms -> 629 ms) and it is quadratic, so a timing test would be the
    // alternative and a flaky one.
    //
    // A canary above the mark is not a state the type can reach on its own
    // (everything above it is zero by construction); it is planted precisely
    // so that a `clear` which overwrites it fails here.
    const alloc = testing.allocator;
    var s = try String.init(alloc, INITIAL_STRING_SIZE);
    defer s.deinit(alloc);

    for (0..4096) |_| {
        try s.extend(alloc);
        s.putAssumeCapacity('x');
    }
    s.clear();
    try testing.expect(s.buf.len >= 4096); // capacity is retained...
    try testing.expectEqual(@as(usize, 0), s.hi);

    // ...but after a short write, clear must touch only the short prefix.
    try s.extend(alloc);
    s.putAssumeCapacity('y');
    const canary = s.buf.len - 1;
    s.buf[canary] = 0xAA;
    s.clear();
    try testing.expectEqual(@as(u8, 0), s.buf[0]);
    try testing.expectEqual(@as(u8, 0xAA), s.buf[canary]);
}

test "String join appends and rewinds the source" {
    const alloc = testing.allocator;
    var a = try String.init(alloc, INITIAL_STRING_SIZE);
    defer a.deinit(alloc);
    var b = try String.init(alloc, INITIAL_STRING_SIZE);
    defer b.deinit(alloc);

    for ("head-") |c| {
        try a.extend(alloc);
        a.putAssumeCapacity(c);
    }
    for ("tail-and-then-some-more") |c| {
        try b.extend(alloc);
        b.putAssumeCapacity(c);
    }
    try a.join(alloc, &b);
    try testing.expectEqualStrings("head-tail-and-then-some-more", a.slice());
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "Stack push/pop/top/limit" {
    const alloc = testing.allocator;
    var s = try Stack(i32).init(alloc, INITIAL_STACK_SIZE);
    defer s.deinit(alloc);

    try testing.expect(s.isEmpty());
    for (0..100) |i| try s.push(alloc, @intCast(i));
    try testing.expectEqual(@as(usize, 100), s.len);
    try testing.expectEqual(@as(i32, 99), s.top().*);
    try testing.expectEqual(@as(i32, 0), s.at(0).*);
    try testing.expect(s.underLimit(101));
    try testing.expect(!s.underLimit(100));
    try testing.expectEqual(@as(i32, 99), s.pop());
}

test "Queue enqueue/dequeue/insert survives the shift-down path" {
    const alloc = testing.allocator;
    var q = try Queue(i32).init(alloc, INITIAL_QUEUE_SIZE);
    defer q.deinit(alloc);

    for (0..8) |i| try q.enqueue(alloc, @intCast(i));
    for (0..4) |i| try testing.expectEqual(@as(i32, @intCast(i)), q.dequeue());
    for (100..140) |i| try q.enqueue(alloc, @intCast(i));
    try testing.expectEqual(@as(i32, 4), q.at(0).*);
    try testing.expectEqual(@as(i32, 139), q.last().*);

    try q.insert(alloc, 1, -1);
    try testing.expectEqual(@as(i32, 4), q.at(0).*);
    try testing.expectEqual(@as(i32, -1), q.at(1).*);
    try testing.expectEqual(@as(i32, 5), q.at(2).*);
    try testing.expectEqual(@as(i32, 139), q.last().*);
}
