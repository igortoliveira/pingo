//! SRFI-115 SRE matcher (tier 15A; design in docs/regex.md). Patterns are
//! s-expressions (`Value`s), matched against immutable strings by a bounded
//! backtracking interpreter. Pure: same pattern + string → same result. Shared
//! by both engines through the `regexp-*` primitives.
//!
//! 15A.2 scope: char/string/`any`/`bos`/`eos`, `seq`/`or`/`*`/`+`/`?`,
//! `submatch`/`$`, named classes (`alpha`/`num`/`alnum`/`space`). Char ranges
//! `(/ ...)`, complement `(~ ...)` and `regexp-replace` land in 15A.3.

const std = @import("std");
const value_mod = @import("value.zig");

const Value = value_mod.Value;
const Pair = Value.Pair;

pub const Error = error{ BadPattern, LimitExceeded, OutOfMemory };

pub const Span = struct { start: usize, end: usize };

pub const Match = struct { whole: Span, subs: []const ?Span };

/// A continuation frame: a run of SRE nodes to match, a "close submatch"
/// marker that records a group's span when reached, or a greedy "repeat"
/// marker that re-enters a repetition.
const Cont = struct {
    tag: union(enum) {
        items: []const Value,
        close: struct { idx: usize, start: usize },
        repeat: struct { items: []const Value, from: usize },
    },
    next: ?*const Cont,
};

const Matcher = struct {
    arena: std.mem.Allocator,
    s: []const u8,
    subs: []?Span,
    index: std.AutoHashMapUnmanaged(*Pair, usize) = .empty,
    steps: usize = 0,

    const step_cap: usize = 50_000_000; // regex runs inside one fuel step

    fn charge(m: *Matcher) Error!void {
        m.steps += 1;
        if (m.steps > step_cap) return error.LimitExceeded;
    }

    fn snapshot(m: *Matcher) Error![]?Span {
        return m.arena.dupe(?Span, m.subs);
    }
    fn restore(m: *Matcher, saved: []?Span) void {
        @memcpy(m.subs, saved);
    }

    fn cont(m: *Matcher, k: ?*const Cont, pos: usize) Error!?usize {
        var cur = k;
        while (cur) |c| {
            switch (c.tag) {
                .items => |it| {
                    if (it.len == 0) {
                        cur = c.next;
                        continue;
                    }
                    const rest = Cont{ .tag = .{ .items = it[1..] }, .next = c.next };
                    return m.node(it[0], pos, &rest);
                },
                .close => |cl| {
                    m.subs[cl.idx] = .{ .start = cl.start, .end = pos };
                    cur = c.next;
                },
                .repeat => |rp| {
                    if (pos == rp.from) {
                        cur = c.next; // no progress this occurrence — stop repeating
                        continue;
                    }
                    // greedily try another occurrence, else continue past.
                    const saved = try m.snapshot();
                    const rc = Cont{ .tag = .{ .repeat = .{ .items = rp.items, .from = pos } }, .next = c.next };
                    const frame = Cont{ .tag = .{ .items = rp.items }, .next = &rc };
                    if (try m.cont(&frame, pos)) |end| return end;
                    m.restore(saved);
                    cur = c.next;
                },
            }
        }
        return pos; // nothing left to match
    }

    fn node(m: *Matcher, re: Value, pos: usize, k: ?*const Cont) Error!?usize {
        try m.charge();
        switch (re) {
            .char => |ch| return if (pos < m.s.len and m.s[pos] == ch) m.cont(k, pos + 1) else null,
            .string => |str| {
                if (pos + str.len > m.s.len or !std.mem.eql(u8, m.s[pos .. pos + str.len], str)) return null;
                return m.cont(k, pos + str.len);
            },
            .symbol => |name| return m.atomSymbol(name, pos, k),
            .pair => return m.compound(re, pos, k),
            else => return error.BadPattern,
        }
    }

    fn atomSymbol(m: *Matcher, name: []const u8, pos: usize, k: ?*const Cont) Error!?usize {
        if (std.mem.eql(u8, name, "bos")) return if (pos == 0) m.cont(k, pos) else null;
        if (std.mem.eql(u8, name, "eos")) return if (pos == m.s.len) m.cont(k, pos) else null;
        if (pos >= m.s.len) return null;
        const c = m.s[pos];
        const ok = if (std.mem.eql(u8, name, "any"))
            true
        else if (std.mem.eql(u8, name, "alpha"))
            std.ascii.isAlphabetic(c)
        else if (std.mem.eql(u8, name, "num"))
            std.ascii.isDigit(c)
        else if (std.mem.eql(u8, name, "alnum"))
            std.ascii.isAlphanumeric(c)
        else if (std.mem.eql(u8, name, "space"))
            std.ascii.isWhitespace(c)
        else
            return error.BadPattern;
        return if (ok) m.cont(k, pos + 1) else null;
    }

    fn compound(m: *Matcher, re: Value, pos: usize, k: ?*const Cont) Error!?usize {
        const p = re.pair;
        if (p.car != .symbol) return error.BadPattern;
        const op = p.car.symbol;
        const items = try listItems(m.arena, p.cdr);

        if (std.mem.eql(u8, op, "seq")) {
            const frame = Cont{ .tag = .{ .items = items }, .next = k };
            return m.cont(&frame, pos);
        }
        if (std.mem.eql(u8, op, "or")) {
            var it = p.cdr;
            while (it == .pair) : (it = it.pair.cdr) {
                const saved = try m.snapshot();
                if (try m.node(it.pair.car, pos, k)) |end| return end;
                m.restore(saved);
            }
            return null;
        }
        if (std.mem.eql(u8, op, "?")) {
            const saved = try m.snapshot();
            const frame = Cont{ .tag = .{ .items = items }, .next = k };
            if (try m.cont(&frame, pos)) |end| return end;
            m.restore(saved);
            return m.cont(k, pos);
        }
        if (std.mem.eql(u8, op, "*")) {
            const saved = try m.snapshot();
            const rc = Cont{ .tag = .{ .repeat = .{ .items = items, .from = pos } }, .next = k };
            const frame = Cont{ .tag = .{ .items = items }, .next = &rc };
            if (try m.cont(&frame, pos)) |end| return end;
            m.restore(saved);
            return m.cont(k, pos); // zero occurrences
        }
        if (std.mem.eql(u8, op, "+")) {
            const rc = Cont{ .tag = .{ .repeat = .{ .items = items, .from = pos } }, .next = k };
            const frame = Cont{ .tag = .{ .items = items }, .next = &rc };
            return m.cont(&frame, pos); // one mandatory, then repeat
        }
        if (std.mem.eql(u8, op, "submatch") or std.mem.eql(u8, op, "$")) {
            const idx = m.index.get(p) orelse return error.BadPattern;
            const close = Cont{ .tag = .{ .close = .{ .idx = idx, .start = pos } }, .next = k };
            const frame = Cont{ .tag = .{ .items = items }, .next = &close };
            return m.cont(&frame, pos);
        }
        return error.BadPattern;
    }
};

/// Pre-order-numbers every `submatch`/`$` node so the matcher can index its
/// captures, and returns the count.
fn indexSubmatches(m: *Matcher, re: Value, next: *usize) Error!void {
    if (re != .pair) return;
    const p = re.pair;
    if (p.car == .symbol and (std.mem.eql(u8, p.car.symbol, "submatch") or std.mem.eql(u8, p.car.symbol, "$"))) {
        try m.index.put(m.arena, p, next.*);
        next.* += 1;
    }
    var it: Value = re;
    while (it == .pair) : (it = it.pair.cdr) try indexSubmatches(m, it.pair.car, next);
}

fn listItems(arena: std.mem.Allocator, list: Value) Error![]const Value {
    var out: std.ArrayList(Value) = .empty;
    var it = list;
    while (it == .pair) : (it = it.pair.cdr) try out.append(arena, it.pair.car);
    if (it != .empty_list) return error.BadPattern;
    return out.toOwnedSlice(arena);
}

fn setup(arena: std.mem.Allocator, sre: Value, s: []const u8) Error!Matcher {
    var m = Matcher{ .arena = arena, .s = s, .subs = &.{} };
    var count: usize = 0;
    try indexSubmatches(&m, sre, &count);
    m.subs = try arena.alloc(?Span, count);
    @memset(m.subs, null);
    return m;
}

/// Leftmost match of `sre` anywhere in `s`; null if none.
pub fn search(arena: std.mem.Allocator, sre: Value, s: []const u8) Error!?Match {
    var m = try setup(arena, sre, s);
    var start: usize = 0;
    while (start <= s.len) : (start += 1) {
        @memset(m.subs, null);
        const frame = Cont{ .tag = .{ .items = (&sre)[0..1] }, .next = null };
        if (try m.cont(&frame, start)) |end| {
            return .{ .whole = .{ .start = start, .end = end }, .subs = m.subs };
        }
    }
    return null;
}

/// True iff `sre` matches the whole string `s`.
pub fn matchesWhole(arena: std.mem.Allocator, sre: Value, s: []const u8) Error!bool {
    var m = try setup(arena, sre, s);
    const eos = Value{ .symbol = "eos" };
    const items = [_]Value{ sre, eos };
    const frame = Cont{ .tag = .{ .items = &items }, .next = null };
    return (try m.cont(&frame, 0)) != null;
}
