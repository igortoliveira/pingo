//! Evaluator: the sequential reference interpreter (semantics §6). Being the
//! reference, clarity beats speed here — any valid output of this evaluator
//! defines what future schedulers are allowed to produce.

const std = @import("std");
const datum_mod = @import("datum.zig");
const value_mod = @import("value.zig");
const env_mod = @import("env.zig");
const primitives = @import("primitives.zig");

const Datum = datum_mod.Datum;
const Value = value_mod.Value;
const Env = env_mod.Env;

pub const Error = error{
    BadSyntax,
    UnboundVariable,
    NotAProcedure,
    ArityMismatch,
    TypeError,
    DivideByZero,
    IntegerOverflow,
    Unsupported, // placeholder for plan items not landed yet
    OutOfMemory,
};

pub const Evaluator = struct {
    /// Session arena: values allocated here outlive individual reads.
    arena: std.mem.Allocator,
    global: *Env,

    pub fn init(arena: std.mem.Allocator) std.mem.Allocator.Error!Evaluator {
        const global = try Env.init(arena, null);
        try primitives.install(global);
        return .{ .arena = arena, .global = global };
    }

    /// Entry point for programs/REPL lines: only here `define` is legal (§2).
    pub fn evalToplevel(e: *Evaluator, d: Datum) Error!Value {
        if (d == .pair and isForm(d.pair, "define")) {
            const args = d.pair.cdr;
            if (args != .pair or args.pair.car != .symbol) return Error.BadSyntax;
            if (args.pair.cdr != .pair or args.pair.cdr.pair.cdr != .empty_list)
                return Error.BadSyntax;
            const v = try e.eval(args.pair.cdr.pair.car, e.global);
            try e.global.define(args.pair.car.symbol, v);
            return .unspecified;
        }
        return e.eval(d, e.global);
    }

    pub fn eval(e: *Evaluator, d: Datum, scope: *Env) Error!Value {
        switch (d) {
            // Self-evaluating literals (semantics §2).
            .integer => |n| return .{ .integer = n },
            .boolean => |b| return .{ .boolean = b },
            .string => |s| return .{ .string = try e.arena.dupe(u8, s) },
            // () is not a valid expression, only a value produced by quote.
            .empty_list => return Error.BadSyntax,
            .symbol => |name| return scope.lookup(name) orelse Error.UnboundVariable,
            .pair => |p| {
                if (isForm(p, "quote")) {
                    if (p.cdr != .pair or p.cdr.pair.cdr != .empty_list) return Error.BadSyntax;
                    return try value_mod.fromDatum(e.arena, p.cdr.pair.car);
                }
                if (isForm(p, "define")) return Error.BadSyntax; // top level only (§2)
                if (isForm(p, "if")) {
                    // (if c t) or (if c t e); c evaluates first, then exactly
                    // one branch (§2).
                    const c = p.cdr;
                    if (c != .pair or c.pair.cdr != .pair) return Error.BadSyntax;
                    const t = c.pair.cdr.pair;
                    var alt: ?Datum = null;
                    switch (t.cdr) {
                        .empty_list => {},
                        .pair => |a| {
                            if (a.cdr != .empty_list) return Error.BadSyntax;
                            alt = a.car;
                        },
                        else => return Error.BadSyntax,
                    }
                    const cond = try e.eval(c.pair.car, scope);
                    if (isTruthy(cond)) return e.eval(t.car, scope);
                    if (alt) |a| return e.eval(a, scope);
                    return .unspecified;
                }
                if (isForm(p, "lambda")) return e.makeClosure(p.cdr, scope);

                // Application. The reference evaluator picks left-to-right,
                // one of the sequential orders §2 allows.
                const op = try e.eval(p.car, scope);
                var args: std.ArrayList(Value) = .empty;
                defer args.deinit(e.arena);
                var rest = p.cdr;
                while (rest == .pair) : (rest = rest.pair.cdr)
                    try args.append(e.arena, try e.eval(rest.pair.car, scope));
                if (rest != .empty_list) return Error.BadSyntax;
                return e.apply(op, args.items);
            },
        }
    }

    fn makeClosure(e: *Evaluator, form: Datum, scope: *Env) Error!Value {
        // (lambda (p ...) body1 ... bodyn), n >= 1, params distinct symbols.
        if (form != .pair) return Error.BadSyntax;
        var params: std.ArrayList([]const u8) = .empty;
        defer params.deinit(e.arena);
        var rest = form.pair.car;
        while (rest == .pair) : (rest = rest.pair.cdr) {
            if (rest.pair.car != .symbol) return Error.BadSyntax;
            const name = rest.pair.car.symbol;
            for (params.items) |seen|
                if (std.mem.eql(u8, seen, name)) return Error.BadSyntax;
            try params.append(e.arena, name);
        }
        if (rest != .empty_list) return Error.BadSyntax;

        var body: std.ArrayList(Datum) = .empty;
        defer body.deinit(e.arena);
        var b = form.pair.cdr;
        while (b == .pair) : (b = b.pair.cdr) try body.append(e.arena, b.pair.car);
        if (b != .empty_list or body.items.len == 0) return Error.BadSyntax;

        const c = try e.arena.create(Value.Closure);
        c.* = .{
            .params = try e.arena.dupe([]const u8, params.items),
            .body = try e.arena.dupe(Datum, body.items),
            .env = scope,
        };
        return .{ .closure = c };
    }

    pub fn apply(e: *Evaluator, op: Value, args: []const Value) Error!Value {
        switch (op) {
            .closure => |c| {
                if (args.len != c.params.len) return Error.ArityMismatch;
                const child = try Env.init(e.arena, c.env);
                for (c.params, args) |name, v| try child.define(name, v);
                var result: Value = .unspecified;
                for (c.body) |bd| result = try e.eval(bd, child);
                return result;
            },
            .primitive => |p| return p.func(e.arena, args),
            else => return Error.NotAProcedure,
        }
    }
};

fn isForm(p: *const Datum.Pair, name: []const u8) bool {
    return p.car == .symbol and std.mem.eql(u8, p.car.symbol, name);
}

/// Semantics §2: only #f is false.
fn isTruthy(v: Value) bool {
    return !(v == .boolean and !v.boolean);
}

// -- tests --------------------------------------------------------------

const reader_mod = @import("reader.zig");

pub const TestSession = struct {
    arena_state: std.heap.ArenaAllocator,
    evaluator: ?Evaluator = null, // created lazily, after the struct stops moving

    pub fn init() TestSession {
        return .{ .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }

    pub fn deinit(s: *TestSession) void {
        s.arena_state.deinit();
    }

    /// Reads and evaluates every datum in `src`, returning the last result.
    /// The global environment persists across `run` calls within a session.
    pub fn run(s: *TestSession, src: []const u8) !Value {
        const arena = s.arena_state.allocator();
        if (s.evaluator == null) s.evaluator = try Evaluator.init(arena);
        s.evaluator.?.arena = arena;
        var r = reader_mod.Reader.init(arena, src, 32);
        var last: Value = .unspecified;
        while (try r.read()) |d| last = try s.evaluator.?.evalToplevel(d);
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

test "if evaluates exactly one branch" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectEqual(@as(i64, 1), (try s.run("(if #t 1 2)")).integer);
    try std.testing.expectEqual(@as(i64, 2), (try s.run("(if #f 1 2)")).integer);
    // The untaken branch is not evaluated: `boom` is unbound but must not fire.
    try std.testing.expectEqual(@as(i64, 1), (try s.run("(if #t 1 boom)")).integer);
    try std.testing.expectEqual(@as(i64, 2), (try s.run("(if #f boom 2)")).integer);
}

test "only #f is false" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectEqual(@as(i64, 1), (try s.run("(if 0 1 2)")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try s.run("(if \"\" 1 2)")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try s.run("(if '() 1 2)")).integer);
}

test "if without alternative returns unspecified on false" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectEqual(Value.unspecified, try s.run("(if #f 1)"));
    try std.testing.expectEqual(@as(i64, 1), (try s.run("(if #t 1)")).integer);
}

test "if arity is checked" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectError(error.BadSyntax, s.run("(if)"));
    try std.testing.expectError(error.BadSyntax, s.run("(if #t)"));
    try std.testing.expectError(error.BadSyntax, s.run("(if #t 1 2 3)"));
}

test "lambda and application" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectEqual(@as(i64, 4), (try s.run("((lambda (x) x) 4)")).integer);
    try std.testing.expectEqual(@as(i64, 2), (try s.run("((lambda (a b) b) 1 2)")).integer);
    try std.testing.expectEqual(@as(i64, 9), (try s.run("((lambda () 9))")).integer);
    // define + call, and lexical capture
    _ = try s.run("(define id (lambda (x) x))");
    try std.testing.expectEqual(@as(i64, 5), (try s.run("(id 5)")).integer);
    _ = try s.run("(define k (lambda (x) (lambda () x)))");
    try std.testing.expectEqual(@as(i64, 3), (try s.run("((k 3))")).integer);
}

test "closures see definition-site scope, not call-site" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("(define x 1) (define get-x (lambda () x))");
    _ = try s.run("(define shadow (lambda (x) (get-x)))");
    try std.testing.expectEqual(@as(i64, 1), (try s.run("(shadow 99)")).integer);
}

test "application errors" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectError(error.NotAProcedure, s.run("(1 2)"));
    try std.testing.expectError(error.ArityMismatch, s.run("((lambda (x) x))"));
    try std.testing.expectError(error.ArityMismatch, s.run("((lambda (x) x) 1 2)"));
}

test "lambda syntax errors" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectError(error.BadSyntax, s.run("(lambda)"));
    try std.testing.expectError(error.BadSyntax, s.run("(lambda (x))")); // empty body
    try std.testing.expectError(error.BadSyntax, s.run("(lambda (1) x)"));
    try std.testing.expectError(error.BadSyntax, s.run("(lambda (x x) x)")); // dup param
}

test "arithmetic" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectEqual(@as(i64, 6), (try s.run("(+ 1 2 3)")).integer);
    try std.testing.expectEqual(@as(i64, 0), (try s.run("(+)")).integer);
    try std.testing.expectEqual(@as(i64, -1), (try s.run("(- 2 3)")).integer);
    try std.testing.expectEqual(@as(i64, -5), (try s.run("(- 5)")).integer);
    try std.testing.expectEqual(@as(i64, 24), (try s.run("(* 2 3 4)")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try s.run("(*)")).integer);
    try std.testing.expectEqual(@as(i64, 3), (try s.run("(/ 7 2)")).integer);
    try std.testing.expectEqual(@as(i64, -3), (try s.run("(/ -7 2)")).integer); // truncating
    try std.testing.expectEqual(@as(i64, 7), (try s.run("((lambda (x) (+ x 3)) 4)")).integer);
}

test "arithmetic errors follow §3" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectError(error.DivideByZero, s.run("(/ 1 0)"));
    try std.testing.expectError(error.TypeError, s.run("(+ 1 #t)"));
    try std.testing.expectError(error.ArityMismatch, s.run("(-)"));
    try std.testing.expectError(error.ArityMismatch, s.run("(/ 1)"));
    try std.testing.expectError(error.IntegerOverflow, s.run("(+ 9223372036854775807 1)"));
    try std.testing.expectError(error.IntegerOverflow, s.run("(- -9223372036854775808)"));
    try std.testing.expectError(error.IntegerOverflow, s.run("(/ -9223372036854775808 -1)"));
}

test "primitives are first-class values" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("(define apply2 (lambda (f a b) (f a b)))");
    try std.testing.expectEqual(@as(i64, 5), (try s.run("(apply2 + 2 3)")).integer);
}

test "define binds, returns unspecified, and persists" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectEqual(Value.unspecified, try s.run("(define x 42)"));
    try std.testing.expectEqual(@as(i64, 42), (try s.run("x")).integer);
    _ = try s.run("(define x 7)"); // redefinition replaces (§2)
    try std.testing.expectEqual(@as(i64, 7), (try s.run("x")).integer);
}

test "unbound variable" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectError(error.UnboundVariable, s.run("nope"));
}

test "define is top level only and takes (define name expr)" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectError(error.BadSyntax, s.run("(define y (define z 1))"));
    try std.testing.expectError(error.BadSyntax, s.run("(define)"));
    try std.testing.expectError(error.BadSyntax, s.run("(define 3 1)"));
    try std.testing.expectError(error.BadSyntax, s.run("(define x 1 2)"));
    // quoted define is data, not a binding
    _ = try s.run("'(define q 1)");
    try std.testing.expectError(error.UnboundVariable, s.run("q"));
}
