//! Evaluator: the sequential reference interpreter (semantics §6). Being the
//! reference, clarity beats speed here — any valid output of this evaluator
//! defines what future schedulers are allowed to produce.

const std = @import("std");
const datum_mod = @import("datum.zig");
const value_mod = @import("value.zig");

const Datum = datum_mod.Datum;
const Value = value_mod.Value;

pub const Error = error{
    BadSyntax,
    Unsupported, // placeholder for plan items not landed yet
    OutOfMemory,
};

pub const Evaluator = struct {
    /// Session arena: values allocated here outlive individual reads.
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) Evaluator {
        return .{ .arena = arena };
    }

    pub fn eval(e: *Evaluator, d: Datum) Error!Value {
        switch (d) {
            // Self-evaluating literals (semantics §2).
            .integer => |n| return .{ .integer = n },
            .boolean => |b| return .{ .boolean = b },
            .string => |s| return .{ .string = try e.arena.dupe(u8, s) },
            // () is not a valid expression, only a value produced by quote.
            .empty_list => return Error.BadSyntax,
            .symbol => return Error.Unsupported, // variables land with 3.3/3.4
            .pair => |p| {
                if (p.car == .symbol and std.mem.eql(u8, p.car.symbol, "quote")) {
                    if (p.cdr != .pair or p.cdr.pair.cdr != .empty_list) return Error.BadSyntax;
                    return try value_mod.fromDatum(e.arena, p.cdr.pair.car);
                }
                return Error.Unsupported; // other forms and applications come later
            },
        }
    }
};

// -- tests --------------------------------------------------------------

const reader_mod = @import("reader.zig");

pub const TestSession = struct {
    arena_state: std.heap.ArenaAllocator,
    evaluator: Evaluator,

    pub fn init() TestSession {
        var s = TestSession{
            .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator),
            .evaluator = undefined,
        };
        s.evaluator = Evaluator.init(s.arena_state.allocator());
        return s;
    }

    pub fn deinit(s: *TestSession) void {
        s.arena_state.deinit();
    }

    /// Reads and evaluates every datum in `src`, returning the last result.
    pub fn run(s: *TestSession, src: []const u8) !Value {
        // The evaluator was initialized against a moved struct in init();
        // re-point it at the final arena location.
        s.evaluator.arena = s.arena_state.allocator();
        var r = reader_mod.Reader.init(s.arena_state.allocator(), src, 32);
        var last: Value = .unspecified;
        while (try r.read()) |d| last = try s.evaluator.eval(d);
        return last;
    }
};

test "self-evaluating literals" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectEqual(@as(i64, 42), (try s.run("42")).integer);
    try std.testing.expectEqual(false, (try s.run("#f")).boolean);
    try std.testing.expectEqualStrings("hi", (try s.run("\"hi\"")).string);
}

test "quote returns the datum as a value" {
    var s = TestSession.init();
    defer s.deinit();

    const v = try s.run("'(1 x)");
    try std.testing.expectEqual(@as(i64, 1), v.pair.car.integer);
    try std.testing.expectEqualStrings("x", v.pair.cdr.pair.car.symbol);
    try std.testing.expectEqual(Value.empty_list, v.pair.cdr.pair.cdr);

    try std.testing.expectEqual(Value.empty_list, try s.run("'()"));
    try std.testing.expectEqualStrings("quote", (try s.run("''a")).pair.car.symbol);
}

test "quote arity and bare () are syntax errors" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectError(error.BadSyntax, s.run("(quote)"));
    try std.testing.expectError(error.BadSyntax, s.run("(quote 1 2)"));
    try std.testing.expectError(error.BadSyntax, s.run("()"));
}
