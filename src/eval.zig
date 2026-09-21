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
    LimitExceeded,
    Unsupported, // placeholder for plan items not landed yet
    OutOfMemory,
};

/// Session resource limits (semantics §5). Set by the host at session
/// creation; there are deliberately no defaults here.
pub const Limits = struct {
    /// Evaluation steps (one per eval loop iteration, including tail
    /// iterations). The counter is `fuel_used`; the host may reset it
    /// between feeds (e.g. a REPL giving each line a fresh budget).
    fuel: u64,
    /// Nested (non-tail) evaluation depth. Guards the Zig stack: counts eval
    /// recursion, which covers §5's non-tail call frames plus expression
    /// nesting (a stricter measure than the doc's minimum — the latter is
    /// already bounded by reader depth). Tail calls don't consume depth.
    call_depth: usize,
};

/// Maps a runtime error to its §3 kind symbol. OutOfMemory maps to
/// limit-exceeded: hosts run guests behind a byte-budgeted allocator
/// (limits.LimitedAllocator), so allocation failure *is* the heap_bytes
/// limit. A genuine host OOM lands on the same kind, which is acceptable —
/// the guest can't tell the difference and shouldn't.
pub fn kindOf(err: Error) []const u8 {
    return switch (err) {
        Error.BadSyntax => "bad-syntax",
        Error.UnboundVariable => "unbound-variable",
        Error.NotAProcedure => "not-a-procedure",
        Error.ArityMismatch => "arity-mismatch",
        Error.TypeError => "type-error",
        Error.DivideByZero => "divide-by-zero",
        Error.IntegerOverflow => "integer-overflow",
        Error.LimitExceeded => "limit-exceeded",
        Error.Unsupported => "bad-syntax", // unimplemented forms read as syntax for now
        Error.OutOfMemory => "limit-exceeded",
    };
}

/// Context for the most recent error (semantics §3: kind + message +
/// irritants). Zig errors carry no payload, so the evaluator records the
/// human-facing part here; valid until the next eval call.
pub const Diagnostic = struct {
    context: []const u8, // e.g. the unbound name or the primitive involved
};

pub const Evaluator = struct {
    /// Session arena: values allocated here outlive individual reads.
    arena: std.mem.Allocator,
    global: *Env,
    limits: Limits,
    fuel_used: u64 = 0,
    depth: usize = 0,
    /// Set alongside the returned error when there is useful context.
    diagnostic: ?Diagnostic = null,

    pub fn init(arena: std.mem.Allocator, limits: Limits) std.mem.Allocator.Error!Evaluator {
        const global = try Env.init(arena, null);
        try primitives.install(global);
        return .{ .arena = arena, .global = global, .limits = limits };
    }

    fn chargeFuel(e: *Evaluator) Error!void {
        if (e.fuel_used >= e.limits.fuel) {
            e.diagnostic = .{ .context = "fuel" };
            return Error.LimitExceeded;
        }
        e.fuel_used += 1;
    }

    /// Entry point for programs/REPL lines: only here `define` is legal (§2).
    pub fn evalToplevel(e: *Evaluator, d: Datum) Error!Value {
        e.diagnostic = null;
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

    /// Iterative evaluator: tail positions (last body expression, chosen `if`
    /// branch, last `begin` expression) loop instead of recursing, so tail
    /// calls consume no Zig stack (semantics §5: proper tail calls are
    /// guaranteed). Non-tail subexpressions still recurse.
    pub fn eval(e: *Evaluator, d0: Datum, scope0: *Env) Error!Value {
        if (e.depth >= e.limits.call_depth) {
            e.diagnostic = .{ .context = "call-depth" };
            return Error.LimitExceeded;
        }
        e.depth += 1;
        defer e.depth -= 1;

        var d = d0;
        var scope = scope0;
        while (true) {
            try e.chargeFuel();
            switch (d) {
                // Self-evaluating literals (semantics §2).
                .integer => |n| return .{ .integer = n },
                .boolean => |b| return .{ .boolean = b },
                .string => |s| return .{ .string = try e.arena.dupe(u8, s) },
                // () is not a valid expression, only a value produced by quote.
                .empty_list => return Error.BadSyntax,
                .symbol => |name| return scope.lookup(name) orelse {
                    e.diagnostic = .{ .context = name };
                    return Error.UnboundVariable;
                },
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
                        if (isTruthy(cond)) {
                            d = t.car; // tail position
                            continue;
                        }
                        if (alt) |a| {
                            d = a; // tail position
                            continue;
                        }
                        return .unspecified;
                    }
                    if (isForm(p, "lambda")) return e.makeClosure(p.cdr, scope);
                    if (isForm(p, "begin")) {
                        // (begin e1 ... en), n >= 1: sequential by definition (§2).
                        var rest = p.cdr;
                        if (rest != .pair) return Error.BadSyntax;
                        // Validate the shape first so (begin 1 . 2) can't run e1.
                        var check = rest;
                        while (check == .pair) : (check = check.pair.cdr) {}
                        if (check != .empty_list) return Error.BadSyntax;
                        while (rest.pair.cdr == .pair) : (rest = rest.pair.cdr)
                            _ = try e.eval(rest.pair.car, scope);
                        d = rest.pair.car; // tail position
                        continue;
                    }

                    // Application. The reference evaluator picks left-to-right,
                    // one of the sequential orders §2 allows.
                    const op = try e.eval(p.car, scope);
                    var args: std.ArrayList(Value) = .empty;
                    defer args.deinit(e.arena);
                    var rest = p.cdr;
                    while (rest == .pair) : (rest = rest.pair.cdr)
                        try args.append(e.arena, try e.eval(rest.pair.car, scope));
                    if (rest != .empty_list) return Error.BadSyntax;

                    switch (op) {
                        .closure => |c| {
                            // Inline the closure call so its last body expression
                            // is a tail position of this loop.
                            if (args.items.len != c.params.len) return Error.ArityMismatch;
                            const child = try Env.init(e.arena, c.env);
                            for (c.params, args.items) |name, v| try child.define(name, v);
                            for (c.body[0 .. c.body.len - 1]) |bd| _ = try e.eval(bd, child);
                            d = c.body[c.body.len - 1];
                            scope = child;
                            continue;
                        },
                        else => return e.apply(op, args.items),
                    }
                },
            }
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
            .primitive => |p| return p.func(e.arena, args) catch |err| {
                e.diagnostic = .{ .context = p.name };
                return err;
            },
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

    /// Generous defaults so ordinary tests never trip limits; limit tests
    /// construct their own evaluator or shrink these.
    pub const test_limits: Limits = .{ .fuel = 100_000_000, .call_depth = 1_000 };

    /// Reads and evaluates every datum in `src`, returning the last result.
    /// The global environment persists across `run` calls within a session.
    pub fn run(s: *TestSession, src: []const u8) !Value {
        const arena = s.arena_state.allocator();
        if (s.evaluator == null) s.evaluator = try Evaluator.init(arena, test_limits);
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

test "list primitives" {
    var s = TestSession.init();
    defer s.deinit();
    const v = try s.run("(cons 1 '(2))");
    try std.testing.expectEqual(@as(i64, 1), v.pair.car.integer);
    try std.testing.expectEqual(@as(i64, 2), v.pair.cdr.pair.car.integer);

    try std.testing.expectEqual(@as(i64, 1), (try s.run("(car '(1 2))")).integer);
    try std.testing.expectEqual(@as(i64, 2), (try s.run("(car (cdr '(1 2)))")).integer);
    try std.testing.expectEqual(true, (try s.run("(null? '())")).boolean);
    try std.testing.expectEqual(false, (try s.run("(null? '(1))")).boolean);
    try std.testing.expectEqual(true, (try s.run("(pair? '(1))")).boolean);
    try std.testing.expectEqual(false, (try s.run("(pair? '())")).boolean);
    // improper pair via cons
    try std.testing.expectEqual(@as(i64, 2), (try s.run("(cdr (cons 1 2))")).integer);
}

test "list primitive errors" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectError(error.TypeError, s.run("(car '())"));
    try std.testing.expectError(error.TypeError, s.run("(cdr 5)"));
    try std.testing.expectError(error.ArityMismatch, s.run("(cons 1)"));
    try std.testing.expectError(error.ArityMismatch, s.run("(null?)"));
}

test "begin sequences and returns the last value" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectEqual(@as(i64, 3), (try s.run("(begin 1 2 3)")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try s.run("(begin 1)")).integer);
    try std.testing.expectError(error.BadSyntax, s.run("(begin)"));
    // earlier expressions do run (their errors fire)
    try std.testing.expectError(error.DivideByZero, s.run("(begin (/ 1 0) 2)"));
}

test "eq? identity semantics" {
    var s = TestSession.init();
    defer s.deinit();
    try std.testing.expectEqual(true, (try s.run("(eq? 1 1)")).boolean);
    try std.testing.expectEqual(false, (try s.run("(eq? 1 2)")).boolean);
    try std.testing.expectEqual(true, (try s.run("(eq? 'a 'a)")).boolean);
    try std.testing.expectEqual(true, (try s.run("(eq? '() '())")).boolean);
    try std.testing.expectEqual(false, (try s.run("(eq? 1 'a)")).boolean);
    // pairs by identity, not structure
    try std.testing.expectEqual(false, (try s.run("(eq? (cons 1 2) (cons 1 2))")).boolean);
    _ = try s.run("(define p (cons 1 2))");
    try std.testing.expectEqual(true, (try s.run("(eq? p p)")).boolean);
    // closures/primitives by identity
    try std.testing.expectEqual(true, (try s.run("(eq? + +)")).boolean);
    _ = try s.run("(define f (lambda (x) x))");
    try std.testing.expectEqual(true, (try s.run("(eq? f f)")).boolean);
    try std.testing.expectEqual(false, (try s.run("(eq? f (lambda (x) x))")).boolean);
}

test "errors carry §3 kind and context, never panic" {
    var s = TestSession.init();
    defer s.deinit();

    try std.testing.expectError(error.UnboundVariable, s.run("mystery"));
    try std.testing.expectEqualStrings("mystery", s.evaluator.?.diagnostic.?.context);
    try std.testing.expectEqualStrings("unbound-variable", kindOf(error.UnboundVariable));

    try std.testing.expectError(error.DivideByZero, s.run("(/ 1 0)"));
    try std.testing.expectEqualStrings("/", s.evaluator.?.diagnostic.?.context);

    // diagnostic clears on the next successful toplevel eval
    _ = try s.run("1");
    try std.testing.expectEqual(@as(?Diagnostic, null), s.evaluator.?.diagnostic);

    // the session stays usable after any error (§3)
    try std.testing.expectEqual(@as(i64, 2), (try s.run("(+ 1 1)")).integer);
}

test "fuel exhaustion is limit-exceeded and uncatchable by the guest" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("(define loop (lambda (n) (if (eq? n 0) 'done (loop (- n 1)))))");

    s.evaluator.?.limits.fuel = s.evaluator.?.fuel_used + 1_000;
    try std.testing.expectError(error.LimitExceeded, s.run("(loop 1000000)"));
    try std.testing.expectEqualStrings("fuel", s.evaluator.?.diagnostic.?.context);
    try std.testing.expectEqualStrings("limit-exceeded", kindOf(error.LimitExceeded));

    // The host can refill fuel and keep the session (host's contract, §5).
    s.evaluator.?.limits.fuel = TestSession.test_limits.fuel;
    try std.testing.expectEqualStrings("done", (try s.run("(loop 10)")).symbol);
}

test "fuel counts work, not wall time" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("1"); // force evaluator creation
    const before = s.evaluator.?.fuel_used;
    _ = try s.run("(+ 1 (+ 2 3))");
    const spent = s.evaluator.?.fuel_used - before;
    // (+ 1 (+ 2 3)): 7 evals — outer form, +, 1, inner form, +, 2, 3.
    try std.testing.expectEqual(@as(u64, 7), spent);
}

test "deep non-tail recursion hits the depth limit instead of the Zig stack" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("(define fact (lambda (n) (if (eq? n 0) 1 (* n (fact (- n 1))))))");
    try std.testing.expectError(error.LimitExceeded, s.run("(fact 1000000)"));
    try std.testing.expectEqualStrings("call-depth", s.evaluator.?.diagnostic.?.context);
    // depth unwinds correctly: the session still evaluates
    try std.testing.expectEqual(@as(i64, 120), (try s.run("(fact 5)")).integer);
}

test "tail calls do not consume depth" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("(define loop (lambda (n) (if (eq? n 0) 'done (loop (- n 1)))))");
    s.evaluator.?.limits.call_depth = 16; // tiny; 100k tail iterations must still fit
    try std.testing.expectEqualStrings("done", (try s.run("(loop 100000)")).symbol);
}

test "heap budget stops a heap bomb as limit-exceeded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var heap = limits_mod.LimitedAllocator.init(arena_state.allocator(), 64 * 1024);
    const arena = heap.allocator();

    var evaluator = try Evaluator.init(arena, TestSession.test_limits);
    var r = reader_mod.Reader.init(arena,
        \\(define grow (lambda (n acc) (if (eq? n 0) acc (grow (- n 1) (cons n acc)))))
        \\(grow 1000000 '())
    , 32);
    _ = try evaluator.evalToplevel((try r.read()).?);
    const err = evaluator.evalToplevel((try r.read()).?);
    try std.testing.expectError(error.OutOfMemory, err);
    try std.testing.expectEqualStrings("limit-exceeded", kindOf(error.OutOfMemory));
}

const limits_mod = @import("limits.zig");

test "tail calls do not grow the stack" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("(define loop (lambda (n) (if (eq? n 0) 'done (loop (- n 1)))))");
    try std.testing.expectEqualStrings("done", (try s.run("(loop 1000000)")).symbol);
}

test "mutual tail recursion" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("(define even? (lambda (n) (if (eq? n 0) #t (odd? (- n 1)))))");
    _ = try s.run("(define odd? (lambda (n) (if (eq? n 0) #f (even? (- n 1)))))");
    try std.testing.expectEqual(false, (try s.run("(even? 100001)")).boolean);
}

test "tail position through begin" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("(define f (lambda (n) (if (eq? n 0) 'ok (begin 1 (f (- n 1))))))");
    try std.testing.expectEqualStrings("ok", (try s.run("(f 200000)")).symbol);
}

test "non-tail recursion still works" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("(define fact (lambda (n) (if (eq? n 0) 1 (* n (fact (- n 1))))))");
    try std.testing.expectEqual(@as(i64, 3628800), (try s.run("(fact 10)")).integer);
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
