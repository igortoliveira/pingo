//! Evaluator: the sequential reference interpreter (semantics §6). Being the
//! reference, clarity beats speed here — any valid output of this evaluator
//! defines what future schedulers are allowed to produce.

const std = @import("std");
const datum_mod = @import("datum.zig");
const value_mod = @import("value.zig");
const env_mod = @import("env.zig");
const primitives = @import("primitives.zig");
const expand = @import("expand.zig");

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
    HostError,
    LimitExceeded,
    Unsupported, // placeholder for plan items not landed yet
    /// The reference oracle does not implement `call/cc` (design decision,
    /// docs/callcc.md): first-class continuations need the machine's explicit
    /// frame stack. The machine handles it; the oracle reports this.
    Unimplemented,
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
        Error.HostError => "host-error",
        Error.LimitExceeded => "limit-exceeded",
        Error.Unsupported => "bad-syntax", // unimplemented forms read as syntax for now
        Error.Unimplemented => "unimplemented",
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
        var e = Evaluator{ .arena = arena, .global = global, .limits = limits };
        try e.loadPrelude();
        return e;
    }

    /// Evaluates the embedded prelude (§7) under an internal budget; trusted
    /// runtime source, so failures besides OOM are build bugs.
    fn loadPrelude(e: *Evaluator) std.mem.Allocator.Error!void {
        const saved = e.limits;
        e.limits = .{ .fuel = 10_000_000, .call_depth = 500 };
        defer {
            e.limits = saved;
            e.fuel_used = 0;
        }
        var r = reader_mod.Reader.init(e.arena, @embedFile("prelude.scm"), 64);
        while (r.read() catch unreachable) |d| {
            _ = e.evalToplevel(d) catch |err| switch (err) {
                Error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
        }
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
            const parts = try expand.defineParts(e.arena, d.pair.cdr);
            const v = try e.eval(parts.expr, e.global);
            try e.global.define(parts.name, v);
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
                .real => |x| return .{ .real = x },
                .char => |c| return .{ .char = c },
                // #(...) literals evaluate like quoted data: a fresh copy (§1)
                .vector => return try value_mod.fromDatum(e.arena, d),
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
                    if (isForm(p, "quasiquote")) {
                        d = try expand.expandQuasiquote(e.arena, p.cdr);
                        continue;
                    }
                    if (isForm(p, "unquote") or isForm(p, "unquote-splicing"))
                        return Error.BadSyntax; // only meaningful inside quasiquote
                    if (isForm(p, "set!")) {
                        const a = p.cdr;
                        if (a != .pair or a.pair.car != .symbol) return Error.BadSyntax;
                        if (a.pair.cdr != .pair or a.pair.cdr.pair.cdr != .empty_list)
                            return Error.BadSyntax;
                        const v = try e.eval(a.pair.cdr.pair.car, scope);
                        if (!scope.set(a.pair.car.symbol, v)) {
                            e.diagnostic = .{ .context = a.pair.car.symbol };
                            return Error.UnboundVariable;
                        }
                        return .unspecified;
                    }
                    if (isForm(p, "lambda")) return e.makeClosure(p.cdr, scope);
                    if (isForm(p, "let")) {
                        d = try expand.expandLet(e.arena, p.cdr);
                        continue;
                    }
                    if (isForm(p, "let*")) {
                        d = try expand.expandLetStar(e.arena, p.cdr);
                        continue;
                    }
                    if (isForm(p, "case")) {
                        d = try expand.expandCase(e.arena, p.cdr);
                        continue;
                    }
                    if (isForm(p, "do")) {
                        d = try expand.expandDo(e.arena, p.cdr);
                        continue;
                    }
                    if (isForm(p, "delay")) {
                        d = try expand.expandDelay(e.arena, p.cdr);
                        continue;
                    }
                    if (isForm(p, "letrec")) {
                        if (p.cdr != .pair) return Error.BadSyntax;
                        var body = p.cdr.pair.cdr;
                        var check = body;
                        while (check == .pair) : (check = check.pair.cdr) {}
                        if (body != .pair or check != .empty_list) return Error.BadSyntax;
                        body = try expand.rewriteBody(e.arena, body); // internal defines (§2)
                        const b = try expand.parseBindings(e.arena, p.cdr.pair.car);
                        const child = try Env.init(e.arena, scope);
                        for (b.names) |name| try child.define(name, .unspecified);
                        for (b.names, b.inits) |name, init_expr|
                            try child.define(name, try e.eval(init_expr, child));
                        while (body.pair.cdr == .pair) : (body = body.pair.cdr)
                            _ = try e.eval(body.pair.car, child);
                        d = body.pair.car; // tail position
                        scope = child;
                        continue;
                    }
                    if (isForm(p, "cond")) {
                        d = try expand.expandCond(e.arena, p.cdr, scope.lookup("else") != null);
                        continue;
                    }
                    if (isForm(p, "and")) {
                        d = try expand.expandAnd(e.arena, p.cdr);
                        continue;
                    }
                    if (isForm(p, "or")) {
                        d = try expand.expandOr(e.arena, p.cdr);
                        continue;
                    }
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
                            const child = try Env.init(e.arena, c.env);
                            try value_mod.bindArgs(e.arena, c, args.items, child);
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
        return value_mod.makeClosure(e.arena, form, scope);
    }

    pub fn apply(e: *Evaluator, op: Value, args: []const Value) Error!Value {
        switch (op) {
            .closure => |c| {
                const child = try Env.init(e.arena, c.env);
                try value_mod.bindArgs(e.arena, c, args, child);
                var result: Value = .unspecified;
                for (c.body) |bd| result = try e.eval(bd, child);
                return result;
            },
            .primitive => |p| {
                if (p == &primitives.callcc_primitive) return Error.Unimplemented;
                if (p == &primitives.dynamic_wind_primitive) {
                    // No call/cc in the oracle, so no control transfer can
                    // cross the extent: plain sequencing is exact (§2).
                    if (args.len != 3) return Error.ArityMismatch;
                    _ = try e.apply(args[0], &.{});
                    const result = try e.apply(args[1], &.{});
                    _ = try e.apply(args[2], &.{});
                    return result;
                }
                if (p == &primitives.apply_primitive) {
                    // (apply f a ... args): spread the final list.
                    if (args.len < 2) return Error.ArityMismatch;
                    var spread: std.ArrayList(Value) = .empty;
                    defer spread.deinit(e.arena);
                    try spread.appendSlice(e.arena, args[1 .. args.len - 1]);
                    var node = args[args.len - 1];
                    while (node == .pair) : (node = node.pair.cdr)
                        try spread.append(e.arena, node.pair.car);
                    if (node != .empty_list) {
                        e.diagnostic = .{ .context = "apply" };
                        return Error.TypeError;
                    }
                    return e.apply(args[0], spread.items);
                }
                return p.func(e.arena, args) catch |err| {
                    e.diagnostic = .{ .context = p.name };
                    return err;
                };
            },
            .capability => |c| {
                // §4: only pure data crosses the boundary, in either direction.
                for (args) |a| if (!isPureData(a)) {
                    e.diagnostic = .{ .context = c.name };
                    return Error.TypeError;
                };
                // v0 realization of suspension (§4): dispatch synchronously,
                // resume with the handler's value or error.
                const result = c.handler(c.ctx, e.arena, args) catch |err| {
                    e.diagnostic = .{ .context = c.name };
                    return switch (err) {
                        error.HostError => Error.HostError,
                        error.OutOfMemory => Error.OutOfMemory,
                    };
                };
                if (!isPureData(result)) {
                    e.diagnostic = .{ .context = c.name };
                    return Error.HostError; // misbehaving host handler
                }
                return result;
            },
            else => return Error.NotAProcedure,
        }
    }
};

fn isForm(p: *const Datum.Pair, name: []const u8) bool {
    return p.car == .symbol and std.mem.eql(u8, p.car.symbol, name);
}

const isTruthy = value_mod.isTruthy;

const isPureData = value_mod.isPureData;

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
    try std.testing.expectEqual(@as(i64, 3), (try s.run("(/ 6 2)")).integer); // exact stays exact
    try std.testing.expectEqual(@as(f64, 3.5), (try s.run("(/ 7 2)")).real); // else real (§1)
    try std.testing.expectEqual(@as(f64, 5.0), (try s.run("(+ 1 1.5 2.5)")).real); // contagion
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
    // minInt / -1 cannot stay exact: contagion promotes instead of overflowing
    try std.testing.expect((try s.run("(/ -9223372036854775808 -1)")) == .real);
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
    // generous enough for init + the growing prelude; tiny next to the bomb
    var heap = limits_mod.LimitedAllocator.init(arena_state.allocator(), 2 * 1024 * 1024);
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

const capability_mod = @import("capability.zig");

const EchoHost = struct {
    calls: usize = 0,

    fn double(ctx: *anyopaque, _: std.mem.Allocator, args: []const Value) capability_mod.HostError!Value {
        const h: *EchoHost = @ptrCast(@alignCast(ctx));
        h.calls += 1;
        if (args.len != 1 or args[0] != .integer) return error.HostError;
        return .{ .integer = args[0].integer * 2 };
    }

    fn boom(_: *anyopaque, _: std.mem.Allocator, _: []const Value) capability_mod.HostError!Value {
        return error.HostError;
    }
};

test "capability dispatch: value in, value out, host sees the call" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("1"); // force evaluator creation

    var host = EchoHost{};
    const cap = capability_mod.Capability{
        .name = "double",
        .class = .external_independent,
        .ctx = &host,
        .handler = EchoHost.double,
    };
    try capability_mod.register(s.evaluator.?.global, &cap);

    try std.testing.expectEqual(@as(i64, 14), (try s.run("(double 7)")).integer);
    try std.testing.expectEqual(@as(i64, 8), (try s.run("(double (double 2))")).integer);
    try std.testing.expectEqual(@as(usize, 3), host.calls);
}

test "capability errors surface as host-error with the capability name" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("1");

    var host = EchoHost{};
    const cap = capability_mod.Capability{
        .name = "flaky",
        .class = .globally_ordered,
        .ctx = &host,
        .handler = EchoHost.boom,
    };
    try capability_mod.register(s.evaluator.?.global, &cap);

    try std.testing.expectError(error.HostError, s.run("(flaky 1)"));
    try std.testing.expectEqualStrings("flaky", s.evaluator.?.diagnostic.?.context);
    try std.testing.expectEqualStrings("host-error", kindOf(error.HostError));
    // session continues (§3)
    try std.testing.expectEqual(@as(i64, 2), (try s.run("(+ 1 1)")).integer);
}

test "only pure data crosses the boundary" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("1");

    var host = EchoHost{};
    const cap = capability_mod.Capability{
        .name = "send",
        .class = .globally_ordered,
        .ctx = &host,
        .handler = EchoHost.double,
    };
    try capability_mod.register(s.evaluator.?.global, &cap);

    try std.testing.expectError(error.TypeError, s.run("(send (lambda (x) x))"));
    try std.testing.expectError(error.TypeError, s.run("(send (cons 1 +))")); // nested
    try std.testing.expectEqualStrings("send", s.evaluator.?.diagnostic.?.context);
}

/// Records every dispatched call as "<name>:<first-arg>" — the §6 observation
/// sequence, seen from the host side.
const RecordingHost = struct {
    log: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn observe(ctx: *anyopaque, _: std.mem.Allocator, args: []const Value) capability_mod.HostError!Value {
        const h: *RecordingHost = @ptrCast(@alignCast(ctx));
        if (args.len != 1 or args[0] != .integer) return error.HostError;
        h.log.print(h.gpa, "obs:{d} ", .{args[0].integer}) catch return error.OutOfMemory;
        return args[0];
    }

    fn emit(ctx: *anyopaque, _: std.mem.Allocator, args: []const Value) capability_mod.HostError!Value {
        const h: *RecordingHost = @ptrCast(@alignCast(ctx));
        if (args.len != 1 or args[0] != .integer) return error.HostError;
        h.log.print(h.gpa, "emit:{d} ", .{args[0].integer}) catch return error.OutOfMemory;
        return .unspecified;
    }
};

test "sequential dispatch order is program order (§6 observations)" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("1");

    var host = RecordingHost{ .gpa = std.testing.allocator };
    defer host.log.deinit(std.testing.allocator);
    const obs = capability_mod.Capability{ .name = "obs", .class = .external_independent, .ctx = &host, .handler = RecordingHost.observe };
    const emit = capability_mod.Capability{ .name = "emit", .class = .irreversible, .ctx = &host, .handler = RecordingHost.emit };
    try capability_mod.register(s.evaluator.?.global, &obs);
    try capability_mod.register(s.evaluator.?.global, &emit);

    // Mixed effect classes through begin, if, and nested applications: the v0
    // sequential runtime must dispatch in program order.
    _ = try s.run("(begin (emit 1) (if (eq? (obs 2) 2) (emit 3) (emit 99)) (obs (+ (obs 4) 1)))");
    try std.testing.expectEqualStrings("emit:1 obs:2 emit:3 obs:4 obs:5 ", host.log.items);
}

test "a failing call stops later dispatches (§6: stop-on-error order)" {
    var s = TestSession.init();
    defer s.deinit();
    _ = try s.run("1");

    var host = RecordingHost{ .gpa = std.testing.allocator };
    defer host.log.deinit(std.testing.allocator);
    const emit = capability_mod.Capability{ .name = "emit", .class = .irreversible, .ctx = &host, .handler = RecordingHost.emit };
    try capability_mod.register(s.evaluator.?.global, &emit);

    try std.testing.expectError(error.DivideByZero, s.run("(begin (emit 1) (/ 1 0) (emit 2))"));
    try std.testing.expectEqualStrings("emit:1 ", host.log.items);
    // and the session remains usable with the same capability
    _ = try s.run("(emit 3)");
    try std.testing.expectEqualStrings("emit:1 emit:3 ", host.log.items);
}

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
