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
                // Lone dot is dotted-pair syntax, which v0 does not support.
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
        while (true) {
            const tok = r.lexer.next();
            switch (tok.tag) {
                .rparen => break,
                .eof => return error.UnexpectedEndOfInput,
                else => try items.append(r.arena, try r.datum(tok, depth)),
            }
        }
        var result: Datum = .empty_list;
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
        .{ .src = "(a . b)", .err = error.InvalidToken },
        .{ .src = "99999999999999999999", .err = error.IntegerOverflow },
    };
    for (cases) |case| {
        var t = TestReader.init();
        defer t.deinit();
        try std.testing.expectError(case.err, t.start(case.src, 8).read());
    }
}
