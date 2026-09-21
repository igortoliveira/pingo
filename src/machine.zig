//! Explicit-stack machine (semantics §4, "Machine realization"): control +
//! frame stack + environments, no host-stack recursion, so execution can stop
//! at any step and resume — the substrate for detachable suspensions and
//! pending values. Implements exactly the same semantics as the recursive
//! evaluator in eval.zig, which remains the reference oracle (§6).

const std = @import("std");
const datum_mod = @import("datum.zig");
const value_mod = @import("value.zig");
const env_mod = @import("env.zig");
const primitives = @import("primitives.zig");
const eval_mod = @import("eval.zig");

const Datum = datum_mod.Datum;
const Value = value_mod.Value;
const Env = env_mod.Env;

pub const Error = eval_mod.Error;
pub const Limits = eval_mod.Limits;
pub const Diagnostic = eval_mod.Diagnostic;

const Control = union(enum) {
    expr: Expr,
    value: Value,
};

const Expr = struct { d: Datum, env: *Env };

/// One suspended context; the application frame lands in 6.5.
const Frame = union(enum) {
    /// After the condition of (if c t [e]): pick a branch from the value.
    branch: struct { then: Datum, alt: ?Datum, env: *Env },
    /// A begin/body sequence: discard the arrived value, evaluate `rest`
    /// (invariant: a proper, non-empty list — validated before pushing).
    seq: struct { rest: Datum, env: *Env },
    /// Toplevel (define name _): bind the arrived value globally (§2).
    define: struct { name: []const u8 },
    /// An application evaluated left-to-right (one of §2's valid orders):
    /// the arrived value joins `collected` ([0] is the operator); `remaining`
    /// holds operand datums still to evaluate (invariant: a proper list).
    app: struct { remaining: Datum, env: *Env, collected: std.ArrayList(Value) },
    /// Rest of a closure body (invariant: non-empty slice).
    body: struct { rest: []const Datum, env: *Env },
};

pub const Machine = struct {
    arena: std.mem.Allocator,
    global: *Env,
    limits: Limits,
    fuel_used: u64 = 0,
    diagnostic: ?Diagnostic = null,
    frames: std.ArrayList(Frame) = .empty,

    pub fn init(arena: std.mem.Allocator, limits: Limits) std.mem.Allocator.Error!Machine {
        const global = try Env.init(arena, null);
        try primitives.install(global);
        return .{ .arena = arena, .global = global, .limits = limits };
    }

    pub fn evalToplevel(m: *Machine, d: Datum) Error!Value {
        m.diagnostic = null;
        if (d == .pair and isForm(d.pair, "define")) {
            const args = d.pair.cdr;
            if (args != .pair or args.pair.car != .symbol) return Error.BadSyntax;
            if (args.pair.cdr != .pair or args.pair.cdr.pair.cdr != .empty_list)
                return Error.BadSyntax;
            return m.run(args.pair.cdr.pair.car, m.global, args.pair.car.symbol);
        }
        return m.run(d, m.global, null);
    }

    fn run(m: *Machine, d0: Datum, env0: *Env, define_name: ?[]const u8) Error!Value {
        m.frames.clearRetainingCapacity();
        if (define_name) |name|
            try m.frames.append(m.arena, .{ .define = .{ .name = name } });
        var control: Control = .{ .expr = .{ .d = d0, .env = env0 } };
        while (true) {
            try m.chargeFuel();
            switch (control) {
                .expr => |x| control = try m.stepExpr(x),
                .value => |v| {
                    if (m.frames.items.len == 0) return v;
                    control = try m.stepFrame(v);
                },
            }
        }
    }

    /// One step of "what does this expression become".
    fn stepExpr(m: *Machine, x: Expr) Error!Control {
        switch (x.d) {
            .integer => |n| return .{ .value = .{ .integer = n } },
            .boolean => |b| return .{ .value = .{ .boolean = b } },
            .string => |s| return .{ .value = .{ .string = try m.arena.dupe(u8, s) } },
            .empty_list => return Error.BadSyntax,
            .symbol => |name| {
                if (x.env.lookup(name)) |v| return .{ .value = v };
                m.diagnostic = .{ .context = name };
                return Error.UnboundVariable;
            },
            .pair => |p| {
                if (isForm(p, "quote")) {
                    if (p.cdr != .pair or p.cdr.pair.cdr != .empty_list) return Error.BadSyntax;
                    return .{ .value = try value_mod.fromDatum(m.arena, p.cdr.pair.car) };
                }
                if (isForm(p, "define")) return Error.BadSyntax; // top level only (§2)
                if (isForm(p, "if")) {
                    // (if c t) or (if c t e), same shape rules as the oracle.
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
                    try m.frames.append(m.arena, .{ .branch = .{ .then = t.car, .alt = alt, .env = x.env } });
                    return .{ .expr = .{ .d = c.pair.car, .env = x.env } };
                }
                if (isForm(p, "begin")) {
                    if (p.cdr != .pair) return Error.BadSyntax;
                    var check = p.cdr;
                    while (check == .pair) : (check = check.pair.cdr) {}
                    if (check != .empty_list) return Error.BadSyntax;
                    return m.enterSequence(p.cdr, x.env);
                }
                if (isForm(p, "lambda"))
                    return .{ .value = try value_mod.makeClosure(m.arena, p.cdr, x.env) };

                // Application: validate the shape upfront, then evaluate the
                // operator with an app frame waiting for it.
                var check = p.cdr;
                while (check == .pair) : (check = check.pair.cdr) {}
                if (check != .empty_list) return Error.BadSyntax;
                try m.frames.append(m.arena, .{ .app = .{
                    .remaining = p.cdr,
                    .env = x.env,
                    .collected = .empty,
                } });
                return .{ .expr = .{ .d = p.car, .env = x.env } };
            },
        }
    }

    /// Evaluates the head of a validated non-empty sequence; the tail element
    /// pushes no frame (proper tail calls, §5).
    fn enterSequence(m: *Machine, seq: Datum, env: *Env) Error!Control {
        if (seq.pair.cdr == .pair)
            try m.frames.append(m.arena, .{ .seq = .{ .rest = seq.pair.cdr, .env = env } });
        return .{ .expr = .{ .d = seq.pair.car, .env = env } };
    }

    /// One step of "a value arrived at the innermost frame".
    fn stepFrame(m: *Machine, v: Value) Error!Control {
        const frame = m.frames.pop().?;
        switch (frame) {
            .branch => |b| {
                if (value_mod.isTruthy(v)) return .{ .expr = .{ .d = b.then, .env = b.env } };
                if (b.alt) |a| return .{ .expr = .{ .d = a, .env = b.env } };
                return .{ .value = .unspecified };
            },
            .seq => |s| return m.enterSequence(s.rest, s.env),
            .define => |def| {
                try m.global.define(def.name, v);
                return .{ .value = .unspecified };
            },
            .app => |popped| {
                var app = popped;
                try app.collected.append(m.arena, v);
                if (app.remaining == .pair) {
                    const next = app.remaining.pair.car;
                    app.remaining = app.remaining.pair.cdr;
                    try m.frames.append(m.arena, .{ .app = app });
                    return .{ .expr = .{ .d = next, .env = app.env } };
                }
                return m.applyCollected(app.collected.items);
            },
            .body => |b| {
                if (b.rest.len == 1) // tail position: push nothing
                    return .{ .expr = .{ .d = b.rest[0], .env = b.env } };
                try m.frames.append(m.arena, .{ .body = .{ .rest = b.rest[1..], .env = b.env } });
                return .{ .expr = .{ .d = b.rest[0], .env = b.env } };
            },
        }
    }

    fn applyCollected(m: *Machine, collected: []const Value) Error!Control {
        const op = collected[0];
        const args = collected[1..];
        switch (op) {
            .closure => |c| {
                if (args.len != c.params.len) return Error.ArityMismatch;
                const child = try Env.init(m.arena, c.env);
                for (c.params, args) |name, arg| try child.define(name, arg);
                if (c.body.len == 1) // tail position: push nothing
                    return .{ .expr = .{ .d = c.body[0], .env = child } };
                try m.frames.append(m.arena, .{ .body = .{ .rest = c.body[1..], .env = child } });
                return .{ .expr = .{ .d = c.body[0], .env = child } };
            },
            .primitive => |p| {
                const result = p.func(m.arena, args) catch |err| {
                    m.diagnostic = .{ .context = p.name };
                    return err;
                };
                return .{ .value = result };
            },
            else => return Error.NotAProcedure, // capabilities land in 6.6
        }
    }

    fn chargeFuel(m: *Machine) Error!void {
        if (m.fuel_used >= m.limits.fuel) {
            m.diagnostic = .{ .context = "fuel" };
            return Error.LimitExceeded;
        }
        m.fuel_used += 1;
    }
};

fn isForm(p: *const Datum.Pair, name: []const u8) bool {
    return p.car == .symbol and std.mem.eql(u8, p.car.symbol, name);
}

// -- tests --------------------------------------------------------------

const reader_mod = @import("reader.zig");

pub const TestMachine = struct {
    arena_state: std.heap.ArenaAllocator,
    machine: ?Machine = null,

    pub fn init() TestMachine {
        return .{ .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }

    pub fn deinit(t: *TestMachine) void {
        t.arena_state.deinit();
    }

    pub fn run(t: *TestMachine, src: []const u8) !Value {
        const arena = t.arena_state.allocator();
        if (t.machine == null)
            t.machine = try Machine.init(arena, eval_mod.TestSession.test_limits);
        t.machine.?.arena = arena;
        var r = reader_mod.Reader.init(arena, src, 32);
        var last: Value = .unspecified;
        while (try r.read()) |d| last = try t.machine.?.evalToplevel(d);
        return last;
    }
};

test "machine: self-evaluating literals" {
    var t = TestMachine.init();
    defer t.deinit();
    try std.testing.expectEqual(@as(i64, 42), (try t.run("42")).integer);
    try std.testing.expectEqual(false, (try t.run("#f")).boolean);
    try std.testing.expectEqualStrings("hi", (try t.run("\"hi\"")).string);
}

test "machine: quote and variables" {
    var t = TestMachine.init();
    defer t.deinit();
    const v = try t.run("'(1 x)");
    try std.testing.expectEqual(@as(i64, 1), v.pair.car.integer);
    try std.testing.expectEqualStrings("x", v.pair.cdr.pair.car.symbol);

    // primitives are installed, so a bare `+` resolves
    try std.testing.expect((try t.run("+")) == .primitive);
    try std.testing.expectError(error.UnboundVariable, t.run("nope"));
    try std.testing.expectEqualStrings("nope", t.machine.?.diagnostic.?.context);
}

test "machine: if" {
    var t = TestMachine.init();
    defer t.deinit();
    try std.testing.expectEqual(@as(i64, 1), (try t.run("(if #t 1 2)")).integer);
    try std.testing.expectEqual(@as(i64, 2), (try t.run("(if #f 1 2)")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try t.run("(if #t 1 boom)")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try t.run("(if 0 1 2)")).integer); // only #f is false
    try std.testing.expectEqual(Value.unspecified, try t.run("(if #f 1)"));
    try std.testing.expectError(error.BadSyntax, t.run("(if #t)"));
    try std.testing.expectError(error.BadSyntax, t.run("(if #t 1 2 3)"));
}

test "machine: begin" {
    var t = TestMachine.init();
    defer t.deinit();
    try std.testing.expectEqual(@as(i64, 3), (try t.run("(begin 1 2 3)")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try t.run("(begin 1)")).integer);
    try std.testing.expectError(error.BadSyntax, t.run("(begin)"));
    try std.testing.expectError(error.UnboundVariable, t.run("(begin boom 2)"));
    // nested control through frames
    try std.testing.expectEqual(@as(i64, 5), (try t.run("(begin 1 (if #f 4 (begin 2 5)))")).integer);
}

test "machine: define and lambda" {
    var t = TestMachine.init();
    defer t.deinit();
    try std.testing.expectEqual(Value.unspecified, try t.run("(define x 42)"));
    try std.testing.expectEqual(@as(i64, 42), (try t.run("x")).integer);
    _ = try t.run("(define x 7)"); // redefinition replaces
    try std.testing.expectEqual(@as(i64, 7), (try t.run("x")).integer);

    try std.testing.expect((try t.run("(lambda (a b) a)")) == .closure);
    _ = try t.run("(define id (lambda (v) v))");
    try std.testing.expect(t.machine.?.global.lookup("id").? == .closure);
}

test "machine: define and lambda shape errors" {
    var t = TestMachine.init();
    defer t.deinit();
    try std.testing.expectError(error.BadSyntax, t.run("(define y (define z 1))"));
    try std.testing.expectError(error.BadSyntax, t.run("(define 3 1)"));
    try std.testing.expectError(error.BadSyntax, t.run("(define x 1 2)"));
    try std.testing.expectError(error.BadSyntax, t.run("(lambda (x))"));
    try std.testing.expectError(error.BadSyntax, t.run("(lambda (x x) x)"));
    // a define whose expression errors binds nothing
    try std.testing.expectError(error.UnboundVariable, t.run("(define w boom)"));
    try std.testing.expectError(error.UnboundVariable, t.run("w"));
}

test "machine: applications and primitives" {
    var t = TestMachine.init();
    defer t.deinit();
    try std.testing.expectEqual(@as(i64, 6), (try t.run("(+ 1 2 3)")).integer);
    try std.testing.expectEqual(@as(i64, 8), (try t.run("((lambda (x) (+ x x)) 4)")).integer);
    try std.testing.expectEqual(@as(i64, 3), (try t.run("((lambda (f a b) (f a b)) + 1 2)")).integer);
    try std.testing.expectEqual(@as(i64, 2), (try t.run("(car (cdr '(1 2)))")).integer);
    try std.testing.expectError(error.NotAProcedure, t.run("(1 2)"));
    try std.testing.expectError(error.ArityMismatch, t.run("((lambda (x) x))"));
    try std.testing.expectError(error.DivideByZero, t.run("(/ 1 0)"));
    try std.testing.expectEqualStrings("/", t.machine.?.diagnostic.?.context);
}

test "machine: recursion and lexical capture" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("(define fact (lambda (n) (if (eq? n 0) 1 (* n (fact (- n 1))))))");
    try std.testing.expectEqual(@as(i64, 3628800), (try t.run("(fact 10)")).integer);

    _ = try t.run("(define k (lambda (x) (lambda () x)))");
    try std.testing.expectEqual(@as(i64, 3), (try t.run("((k 3))")).integer);
}

test "machine: tail calls keep the frame stack flat" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("(define loop (lambda (n) (if (eq? n 0) 'done (loop (- n 1)))))");
    try std.testing.expectEqualStrings("done", (try t.run("(loop 100000)")).symbol);
    // 100k tail iterations never grew the stack: capacity stays tiny.
    try std.testing.expect(t.machine.?.frames.capacity < 64);
}

test "machine: syntax errors and fuel" {
    var t = TestMachine.init();
    defer t.deinit();
    try std.testing.expectError(error.BadSyntax, t.run("()"));
    try std.testing.expectError(error.BadSyntax, t.run("(quote 1 2)"));

    t.machine.?.limits.fuel = t.machine.?.fuel_used; // nothing left
    try std.testing.expectError(error.LimitExceeded, t.run("1"));
}