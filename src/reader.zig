//! Reader: tokens → Datum trees. Depth-limited from day one: reader input is
//! adversarial and deep nesting must fail cleanly before evaluation exists
//! (semantics §5, `reader_depth`).

const std = @import("std");
const lexer_mod = @import("lexer.zig");
const datum_mod = @import("datum.zig");

const Lexer = lexer_mod.Lexer;
const Token = lexer_mod.Token;
const Datum = datum_mod.Datum;

pub const Error = error{
    UnexpectedRightParen,
    UnexpectedEndOfInput,
    InvalidToken,
    IntegerOverflow,
    DepthLimitExceeded,
    OutOfMemory,
};

pub const Reader = struct {
    lexer: Lexer,
    arena: std.mem.Allocator,
    max_depth: usize,

    pub fn init(arena: std.mem.Allocator, src: []const u8, max_depth: usize) Reader {
        return .{ .lexer = Lexer.init(src), .arena = arena, .max_depth = max_depth };
    }

    /// Reads the next datum, or null at end of input.
    pub fn read(r: *Reader) Error!?Datum {
        const tok = r.lexer.next();
        if (tok.tag == .eof) return null;
        return try r.datum(tok, 0);
    }

    fn datum(r: *Reader, tok: Token, depth: usize) Error!Datum {
        switch (tok.tag) {
            .integer => {
                const text = r.lexer.src[tok.start..tok.end];
                const n = std.fmt.parseInt(i64, text, 10) catch |e| switch (e) {
                    error.Overflow => return error.IntegerOverflow,
                    error.InvalidCharacter => unreachable, // lexer only emits digit runs
                };
                return .{ .integer = n };
            },
            .boolean => return .{ .boolean = r.lexer.src[tok.start + 1] == 't' },
            .symbol => {
                const text = r.lexer.src[tok.start..tok.end];
                // A lone dot is only meaningful inside a list (handled there).
                if (std.mem.eql(u8, text, ".")) return error.InvalidToken;
                return try datum_mod.symbol(r.arena, text);
            },
            .string => return .{ .string = try r.decodeString(tok) },
            .quote => {
                // 'd reads as (quote d); the quoted datum sits one level deeper.
                if (depth + 1 > r.max_depth) return error.DepthLimitExceeded;
                const next = r.lexer.next();
                if (next.tag == .eof) return error.UnexpectedEndOfInput;
                const quoted = try r.datum(next, depth + 1);
                const tail = try datum_mod.cons(r.arena, quoted, .empty_list);
                return try datum_mod.cons(r.arena, try datum_mod.symbol(r.arena, "quote"), tail);
            },
            .lparen => return try r.list(depth + 1),
            .rparen => return error.UnexpectedRightParen,
            .invalid => return error.InvalidToken,
            .eof => return error.UnexpectedEndOfInput,
        }
    }

    fn list(r: *Reader, depth: usize) Error!Datum {
        if (depth > r.max_depth) return error.DepthLimitExceeded;
        var items: std.ArrayList(Datum) = .empty;
        defer items.deinit(r.arena);
        var tail: Datum = .empty_list;
        while (true) {
            const tok = r.lexer.next();
            switch (tok.tag) {
                .rparen => break,
                .eof => return error.UnexpectedEndOfInput,
                .symbol => {
                    // `(a ... . d)`: exactly one datum after the dot, then `)`.
                    if (std.mem.eql(u8, r.lexer.src[tok.start..tok.end], ".")) {
                        if (items.items.len == 0) return error.InvalidToken; // (. d)
                        const after = r.lexer.next();
                        if (after.tag == .eof) return error.UnexpectedEndOfInput;
                        if (after.tag == .rparen) return error.InvalidToken; // (a .)
                        tail = try r.datum(after, depth);
                        const close = r.lexer.next();
                        if (close.tag == .eof) return error.UnexpectedEndOfInput;
                        if (close.tag != .rparen) return error.InvalidToken; // (a . b c)
                        break;
                    }
                    try items.append(r.arena, try r.datum(tok, depth));
                },
                else => try items.append(r.arena, try r.datum(tok, depth)),
            }
        }
        var result = tail;
        var i = items.items.len;
        while (i > 0) {
            i -= 1;
            result = try datum_mod.cons(r.arena, items.items[i], result);
        }
        return result;
    }

    fn decodeString(r: *Reader, tok: Token) Error![]const u8 {
        const raw = r.lexer.src[tok.start + 1 .. tok.end - 1]; // strip quotes
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(r.arena);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\') {
                i += 1; // lexer guarantees a valid escape follows
                try out.append(r.arena, switch (raw[i]) {
                    '"' => '"',
                    '\\' => '\\',
                    'n' => '\n',
                    else => unreachable,
                });
            } else {
                try out.append(r.arena, raw[i]);
            }
        }
        return try out.toOwnedSlice(r.arena);
    }
};

// -- tests --------------------------------------------------------------

const TestReader = struct {
    arena_state: std.heap.ArenaAllocator,
    reader: Reader,

    fn init() TestReader {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator),
            .reader = undefined, // set in start(), which needs the arena
        };
    }

    fn start(t: *TestReader, src: []const u8, max_depth: usize) *Reader {
        t.reader = Reader.init(t.arena_state.allocator(), src, max_depth);
        return &t.reader;
    }

    fn deinit(t: *TestReader) void {
        t.arena_state.deinit();
    }
};

test "atoms" {
    var t = TestReader.init();
    defer t.deinit();
    const r = t.start("42 -7 #t #f foo \"a\\nb\"", 8);

    try std.testing.expectEqual(@as(i64, 42), (try r.read()).?.integer);
    try std.testing.expectEqual(@as(i64, -7), (try r.read()).?.integer);
    try std.testing.expectEqual(true, (try r.read()).?.boolean);
    try std.testing.expectEqual(false, (try r.read()).?.boolean);
    try std.testing.expectEqualStrings("foo", (try r.read()).?.symbol);
    try std.testing.expectEqualStrings("a\nb", (try r.read()).?.string);
    try std.testing.expectEqual(@as(?Datum, null), try r.read());
}

test "nested lists" {
    var t = TestReader.init();
    defer t.deinit();
    const r = t.start("(1 (2 3) ())", 8);

    const d = (try r.read()).?;
    try std.testing.expectEqual(@as(i64, 1), d.pair.car.integer);
    const inner = d.pair.cdr.pair.car;
    try std.testing.expectEqual(@as(i64, 2), inner.pair.car.integer);
    try std.testing.expectEqual(@as(i64, 3), inner.pair.cdr.pair.car.integer);
    try std.testing.expectEqual(Datum.empty_list, d.pair.cdr.pair.cdr.pair.car);
    try std.testing.expectEqual(Datum.empty_list, d.pair.cdr.pair.cdr.pair.cdr);
}

test "depth limit" {
    var t = TestReader.init();
    defer t.deinit();
    try std.testing.expectError(error.DepthLimitExceeded, t.start("(((1)))", 2).read());

    var t2 = TestReader.init();
    defer t2.deinit();
    _ = (try t2.start("(((1)))", 3).read()).?; // exactly at the limit is fine
}

test "dotted pairs" {
    var t = TestReader.init();
    defer t.deinit();
    const r = t.start("(1 . 2) (1 2 . 3) '(a . b)", 8);

    const d = (try r.read()).?;
    try std.testing.expectEqual(@as(i64, 1), d.pair.car.integer);
    try std.testing.expectEqual(@as(i64, 2), d.pair.cdr.integer);

    const d2 = (try r.read()).?;
    try std.testing.expectEqual(@as(i64, 2), d2.pair.cdr.pair.car.integer);
    try std.testing.expectEqual(@as(i64, 3), d2.pair.cdr.pair.cdr.integer);

    const d3 = (try r.read()).?; // (quote (a . b))
    try std.testing.expectEqualStrings("a", d3.pair.cdr.pair.car.pair.car.symbol);
    try std.testing.expectEqualStrings("b", d3.pair.cdr.pair.car.pair.cdr.symbol);
}

test "quote expands to (quote d)" {
    var t = TestReader.init();
    defer t.deinit();
    const r = t.start("'x ''y", 8);

    const d = (try r.read()).?;
    try std.testing.expectEqualStrings("quote", d.pair.car.symbol);
    try std.testing.expectEqualStrings("x", d.pair.cdr.pair.car.symbol);
    try std.testing.expectEqual(Datum.empty_list, d.pair.cdr.pair.cdr);

    // ''y == (quote (quote y))
    const dd = (try r.read()).?;
    try std.testing.expectEqualStrings("quote", dd.pair.car.symbol);
    try std.testing.expectEqualStrings("quote", dd.pair.cdr.pair.car.pair.car.symbol);
}

test "quote respects the depth limit and eof" {
    var t = TestReader.init();
    defer t.deinit();
    try std.testing.expectError(error.DepthLimitExceeded, t.start("''''x", 3).read());

    var t2 = TestReader.init();
    defer t2.deinit();
    try std.testing.expectError(error.UnexpectedEndOfInput, t2.start("'", 8).read());
}

test "syntax errors" {
    const cases = [_]struct { src: []const u8, err: Error }{
        .{ .src = ")", .err = error.UnexpectedRightParen },
        .{ .src = "(1 2", .err = error.UnexpectedEndOfInput },
        .{ .src = "#true", .err = error.InvalidToken },
        .{ .src = "(. b)", .err = error.InvalidToken },
        .{ .src = "(a .)", .err = error.InvalidToken },
        .{ .src = "(a . b c)", .err = error.InvalidToken },
        .{ .src = ".", .err = error.InvalidToken },
        .{ .src = "99999999999999999999", .err = error.IntegerOverflow },
    };
    for (cases) |case| {
        var t = TestReader.init();
        defer t.deinit();
        try std.testing.expectError(case.err, t.start(case.src, 8).read());
    }
}

fn readAllIgnoringErrors(src: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var r = Reader.init(arena_state.allocator(), src, 16);
    // Any outcome is fine (value, error, or eof) — the property under test is
    // "no crash, no hang, no leak" on arbitrary input.
    while (r.read() catch null) |_| {}
}

test "malformed corpus never crashes" {
    const corpus = [_][]const u8{
        "", "'", "''", "'(", "((((((((((((((((((((((((1",
        ")))))", "\"", "\"\\", "\"\\q", "#", "#t#f", ". . .",
        "\x00\xff\x80 1", "(\x00)", ";\x00", "-", "+", "9223372036854775808",
        "(1 . 2 . 3)", "'\"", "(()()()(()())",
    };
    for (corpus) |src| readAllIgnoringErrors(src);
}

fn fuzzReader(_: void, smith: *std.testing.Smith) !void {
    var buf: [256]u8 = undefined;
    const len: usize = smith.value(u8);
    const src = buf[0..@min(len, buf.len)];
    smith.bytes(src);
    readAllIgnoringErrors(src);
}

test "fuzz: reader survives arbitrary bytes" {
    try std.testing.fuzz({}, fuzzReader, .{});
}
