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

/// A capability call handed to the host (semantics §4): args are already
/// evaluated and pure-data-checked. The machine stays alive, waiting for
/// `resumeWithValue`/`resumeWithError`.
pub const Suspension = struct {
    capability: *const capability_mod.Capability,
    args: []const Value,
};

pub const Outcome = union(enum) {
    value: Value,
    suspended: Suspension,
};

const Control = union(enum) {
    expr: Expr,
    value: Value,
    suspend_request: Suspension,
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
    control: Control = .{ .value = .unspecified },
    /// Set while a suspension is outstanding; guards the host protocol.
    suspended_on: ?*const capability_mod.Capability = null,

    pub fn init(arena: std.mem.Allocator, limits: Limits) std.mem.Allocator.Error!Machine {
        const global = try Env.init(arena, null);
        try primitives.install(global);
        return .{ .arena = arena, .global = global, .limits = limits };
    }

    pub fn evalToplevel(m: *Machine, d: Datum) Error!Outcome {
        std.debug.assert(m.suspended_on == null); // host protocol: resume first
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

    /// Host resumes the outstanding call with its result value.
    pub fn resumeWithValue(m: *Machine, v: Value) Error!Outcome {
        std.debug.assert(m.suspended_on != null); // host protocol: nothing to resume
        const cap = m.suspended_on.?;
        m.suspended_on = null;
        if (!value_mod.isPureData(v)) {
            m.diagnostic = .{ .context = cap.name };
            return Error.HostError; // misbehaving host handler (§4)
        }
        m.control = .{ .value = v };
        return m.loop();
    }

    /// Host resolves the outstanding call as a failure; the evaluation aborts
    /// with host-error (§3). Returns the error for the caller to propagate.
    pub fn resumeWithError(m: *Machine) Error {
        std.debug.assert(m.suspended_on != null);
        m.diagnostic = .{ .context = m.suspended_on.?.name };
        m.suspended_on = null;
        return Error.HostError;
    }

    /// Synchronous-host adapter: services each suspension with the
    /// capability's own registered handler.
    pub fn runToCompletion(m: *Machine, d: Datum) Error!Value {
        var outcome = try m.evalToplevel(d);
        while (true) {
            switch (outcome) {
                .value => |v| return v,
                .suspended => |s| {
                    const result = s.capability.handler(s.capability.ctx, m.arena, s.args) catch |err| switch (err) {
                        error.HostError => return m.resumeWithError(),
                        error.OutOfMemory => {
                            m.suspended_on = null;
                            return Error.OutOfMemory;
                        },
                    };
                    outcome = try m.resumeWithValue(result);
                },
            }
        }
    }

    fn run(m: *Machine, d0: Datum, env0: *Env, define_name: ?[]const u8) Error!Outcome {
        m.frames.clearRetainingCapacity();
        if (define_name) |name|
            try m.pushFrame(.{ .define = .{ .name = name } });
        m.control = .{ .expr = .{ .d = d0, .env = env0 } };
        return m.loop();
    }

    fn loop(m: *Machine) Error!Outcome {
        while (true) {
            try m.chargeFuel();
            switch (m.control) {
                .expr => |x| m.control = try m.stepExpr(x),
                .value => |v| {
                    if (m.frames.items.len == 0) return .{ .value = v };
                    m.control = try m.stepFrame(v);
                },
                .suspend_request => |s| {
                    m.suspended_on = s.capability;
                    return .{ .suspended = s };
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
                    try m.pushFrame(.{ .branch = .{ .then = t.car, .alt = alt, .env = x.env } });
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
                try m.pushFrame(.{ .app = .{
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
            try m.pushFrame(.{ .seq = .{ .rest = seq.pair.cdr, .env = env } });
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
                    try m.pushFrame(.{ .app = app });
                    return .{ .expr = .{ .d = next, .env = app.env } };
                }
                return m.applyCollected(app.collected.items);
            },
            .body => |b| {
                if (b.rest.len == 1) // tail position: push nothing
                    return .{ .expr = .{ .d = b.rest[0], .env = b.env } };
                try m.pushFrame(.{ .body = .{ .rest = b.rest[1..], .env = b.env } });
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
                try m.pushFrame(.{ .body = .{ .rest = c.body[1..], .env = child } });
                return .{ .expr = .{ .d = c.body[0], .env = child } };
            },
            .primitive => |p| {
                const result = p.func(m.arena, args) catch |err| {
                    m.diagnostic = .{ .context = p.name };
                    return err;
                };
                return .{ .value = result };
            },
            .capability => |c| {
                // §4: only pure data crosses the boundary (guest side; the
                // host side is checked at resume).
                for (args) |a| if (!value_mod.isPureData(a)) {
                    m.diagnostic = .{ .context = c.name };
                    return Error.TypeError;
                };
                // Detachable suspension: stop and hand the call to the host.
                return .{ .suspend_request = .{ .capability = c, .args = args } };
            },
            else => return Error.NotAProcedure,
        }
    }

    fn chargeFuel(m: *Machine) Error!void {
        if (m.fuel_used >= m.limits.fuel) {
            m.diagnostic = .{ .context = "fuel" };
            return Error.LimitExceeded;
        }
        m.fuel_used += 1;
    }

    /// §5 call_depth, realized as a bound on live frames (tail positions push
    /// nothing, so tail calls consume no depth).
    fn pushFrame(m: *Machine, frame: Frame) Error!void {
        if (m.frames.items.len >= m.limits.call_depth) {
            m.diagnostic = .{ .context = "call-depth" };
            return Error.LimitExceeded;
        }
        try m.frames.append(m.arena, frame);
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
        while (try r.read()) |d| last = try t.machine.?.runToCompletion(d);
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

test "machine: deep non-tail recursion hits the frame limit" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("(define fact (lambda (n) (if (eq? n 0) 1 (* n (fact (- n 1))))))");
    try std.testing.expectError(error.LimitExceeded, t.run("(fact 1000000)"));
    try std.testing.expectEqualStrings("call-depth", t.machine.?.diagnostic.?.context);
    // frames reset per toplevel run; the session still works
    try std.testing.expectEqual(@as(i64, 120), (try t.run("(fact 5)")).integer);
}

const capability_mod = @import("capability.zig");

const CountingHost = struct {
    calls: usize = 0,

    fn double(ctx: *anyopaque, _: std.mem.Allocator, args: []const Value) capability_mod.HostError!Value {
        const h: *CountingHost = @ptrCast(@alignCast(ctx));
        h.calls += 1;
        if (args.len != 1 or args[0] != .integer) return error.HostError;
        return .{ .integer = args[0].integer * 2 };
    }
};

test "machine: capability dispatch with §4 boundary checks" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");

    var host = CountingHost{};
    const cap = capability_mod.Capability{
        .name = "double",
        .class = .external_independent,
        .ctx = &host,
        .handler = CountingHost.double,
    };
    try capability_mod.register(t.machine.?.global, &cap);

    try std.testing.expectEqual(@as(i64, 8), (try t.run("(double (double 2))")).integer);
    try std.testing.expectEqual(@as(usize, 2), host.calls);
    try std.testing.expectError(error.TypeError, t.run("(double (lambda (x) x))"));
    try std.testing.expectError(error.HostError, t.run("(double 'nan)"));
    try std.testing.expectEqualStrings("double", t.machine.?.diagnostic.?.context);
}

fn readOne(arena: std.mem.Allocator, src: []const u8) !Datum {
    var r = reader_mod.Reader.init(arena, src, 32);
    return (try r.read()).?;
}

fn nopHandler(_: *anyopaque, _: std.mem.Allocator, _: []const Value) capability_mod.HostError!Value {
    return .unspecified; // manual suspend/resume tests never invoke handlers
}

test "machine: suspension hands the call to the host and resumes mid-expression" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const cap = capability_mod.Capability{
        .name = "ask",
        .class = .external_independent,
        .ctx = &dummy,
        .handler = nopHandler,
    };
    try capability_mod.register(m.global, &cap);

    // Suspends in the middle of an application; machine state carries the
    // surrounding computation.
    const outcome = try m.evalToplevel(try readOne(arena, "(+ 1 (ask 3) 100)"));
    try std.testing.expect(outcome == .suspended);
    try std.testing.expectEqualStrings("ask", outcome.suspended.capability.name);
    try std.testing.expectEqual(@as(i64, 3), outcome.suspended.args[0].integer);

    const done = try m.resumeWithValue(.{ .integer = 6 });
    try std.testing.expectEqual(@as(i64, 107), done.value.integer);
}

test "machine: suspension survives define and nested control" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const cap = capability_mod.Capability{ .name = "ask", .class = .globally_ordered, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &cap);

    const outcome = try m.evalToplevel(try readOne(arena, "(define x (if #t (begin 1 (ask 'q)) 9))"));
    try std.testing.expect(outcome == .suspended);
    _ = try m.resumeWithValue(.{ .integer = 55 });
    try std.testing.expectEqual(@as(i64, 55), (try t.run("x")).integer);
}

test "machine: resume with error and with impure value" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const cap = capability_mod.Capability{ .name = "ask", .class = .globally_ordered, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &cap);

    var outcome = try m.evalToplevel(try readOne(arena, "(ask 1)"));
    try std.testing.expect(outcome == .suspended);
    try std.testing.expectEqual(m.resumeWithError(), error.HostError);
    try std.testing.expectEqualStrings("ask", m.diagnostic.?.context);

    // session usable again; resuming with a procedure is a host fault
    outcome = try m.evalToplevel(try readOne(arena, "(ask 2)"));
    try std.testing.expect(outcome == .suspended);
    const proc = m.global.lookup("+").?;
    try std.testing.expectError(error.HostError, m.resumeWithValue(proc));

    // and still usable after that
    try std.testing.expectEqual(@as(i64, 2), (try t.run("(+ 1 1)")).integer);
}

test "differential: machine and oracle agree on a form corpus" {
    const corpus = [_][]const u8{
        "42",
        "'(1 (2 #t) \"s\" ())",
        "(+ 1 (* 2 3) (- 10 4 3) (/ 9 2))",
        "(if (eq? (car '(1 2)) 1) 'yes 'no)",
        "(begin 1 2 (if #f 3) 4)",
        "(define f (lambda (x) (lambda (y) (+ x y)))) ((f 1) 2)",
        "(define fact (lambda (n) (if (eq? n 0) 1 (* n (fact (- n 1)))))) (fact 12)",
        "(define loop (lambda (n) (if (eq? n 0) 'done (loop (- n 1))))) (loop 5000)",
        "(cons (null? '()) (pair? (cons 1 2)))",
        "((lambda (f a b) (f a b)) + 20 22)",
        // error cases — both engines must fail with the same error
        "()",
        "nope",
        "(1 2)",
        "((lambda (x) x))",
        "(/ 1 0)",
        "(+ 1 #t)",
        "(car '())",
        "(quote 1 2)",
        "(if #t)",
        "(lambda (x x) x)",
        "(define y (define z 1))",
        "(+ 9223372036854775807 1)",
    };

    for (corpus) |src| {
        var tm = TestMachine.init();
        defer tm.deinit();
        var ts = eval_mod.TestSession.init();
        defer ts.deinit();

        const machine_result = tm.run(src);
        const oracle_result = ts.run(src);

        if (oracle_result) |oracle_value| {
            const machine_value = try machine_result;
            var a = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer a.deinit();
            var b = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer b.deinit();
            try printer_mod.writeValue(machine_value, &a.writer);
            try printer_mod.writeValue(oracle_value, &b.writer);
            try std.testing.expectEqualStrings(b.written(), a.written());
        } else |oracle_err| {
            try std.testing.expectError(oracle_err, machine_result);
        }
    }
}

const printer_mod = @import("printer.zig");

test "machine: syntax errors and fuel" {
    var t = TestMachine.init();
    defer t.deinit();
    try std.testing.expectError(error.BadSyntax, t.run("()"));
    try std.testing.expectError(error.BadSyntax, t.run("(quote 1 2)"));

    t.machine.?.limits.fuel = t.machine.?.fuel_used; // nothing left
    try std.testing.expectError(error.LimitExceeded, t.run("1"));
}
