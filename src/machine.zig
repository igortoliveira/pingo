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
const expand = @import("expand.zig");

const Datum = datum_mod.Datum;
const Value = value_mod.Value;
const Env = env_mod.Env;

pub const Error = eval_mod.Error;
pub const Limits = eval_mod.Limits;
pub const Diagnostic = eval_mod.Diagnostic;

pub const Pending = Value.Pending;

pub const Outcome = union(enum) {
    value: Value,
    /// The machine cannot advance until the host resolves at least one of
    /// `outstanding()`'s calls (in any order) and calls `continueRun`.
    blocked,
};

const Control = union(enum) {
    expr: Expr,
    value: Value,
    /// Strict wait on one pending call (§4 strictness points).
    awaiting: *Pending,
    /// Drain barrier before an ordered-class dispatch (§4): waits until no
    /// call is outstanding, then re-delivers to the apply frame beneath.
    barrier,
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
    /// Re-runs applyCollected after an awaited pending settles (the arriving
    /// value is ignored; forced pendings are re-read from `collected`).
    apply: struct { collected: std.ArrayList(Value) },
    /// Native letrec (§2 Derived forms II): rebind names[index] to the
    /// arriving value, then evaluate the next init or enter the body.
    letrec: struct { b: expand.Bindings, index: usize, env: *Env, body: Datum },
};

pub const Machine = struct {
    arena: std.mem.Allocator,
    global: *Env,
    limits: Limits,
    fuel_used: u64 = 0,
    diagnostic: ?Diagnostic = null,
    frames: std.ArrayList(Frame) = .empty,
    control: Control = .{ .value = .unspecified },
    /// Calls dispatched and not yet settled by the host, in dispatch order
    /// (the §6 observation sequence).
    outstanding_calls: std.ArrayList(*Pending) = .empty,
    /// Every call dispatched during the current feed, for the toplevel
    /// stop-on-error scan (§4 toplevel sync).
    feed_calls: std.ArrayList(*Pending) = .empty,

    pub fn init(arena: std.mem.Allocator, limits: Limits) std.mem.Allocator.Error!Machine {
        const global = try Env.init(arena, null);
        try primitives.install(global);
        return .{ .arena = arena, .global = global, .limits = limits };
    }

    pub fn evalToplevel(m: *Machine, d: Datum) Error!Outcome {
        // Calls left over from a previous (failed) feed are abandoned: they
        // were dispatched — that observation stands — but nothing waits on
        // them anymore (§3 abort semantics).
        m.outstanding_calls.clearRetainingCapacity();
        m.feed_calls.clearRetainingCapacity();
        m.diagnostic = null;
        if (d == .pair and isForm(d.pair, "define")) {
            const parts = try expand.defineParts(m.arena, d.pair.cdr);
            return m.run(parts.expr, m.global, parts.name);
        }
        return m.run(d, m.global, null);
    }

    /// Calls dispatched and not yet settled, in dispatch order.
    pub fn outstanding(m: *const Machine) []const *Pending {
        return m.outstanding_calls.items;
    }

    /// Host settles a call with its result. A result that is not pure data
    /// (§4) marks the call failed instead — the failure surfaces when forced.
    pub fn resolve(m: *Machine, p: *Pending, v: Value) void {
        m.settle(p, if (value_mod.isPureData(v)) .{ .resolved = v } else .failed);
    }

    /// Host settles a call as a failure (§3 host-error when forced).
    pub fn resolveFailure(m: *Machine, p: *Pending) void {
        m.settle(p, .failed);
    }

    fn settle(m: *Machine, p: *Pending, state: Pending.State) void {
        std.debug.assert(p.state == .outstanding); // host protocol: settle once
        p.state = state;
        for (m.outstanding_calls.items, 0..) |c, i| {
            if (c == p) {
                _ = m.outstanding_calls.orderedRemove(i);
                return;
            }
        }
        unreachable; // host protocol: p must come from outstanding()
    }

    /// Continue after settling one or more calls.
    pub fn continueRun(m: *Machine) Error!Outcome {
        return m.loop();
    }

    /// Synchronous-host adapter: services blocked outcomes by running each
    /// outstanding call's own registered handler, in dispatch order.
    pub fn runToCompletion(m: *Machine, d: Datum) Error!Value {
        var outcome = try m.evalToplevel(d);
        while (true) {
            switch (outcome) {
                .value => |v| return v,
                .blocked => {
                    std.debug.assert(m.outstanding_calls.items.len > 0);
                    const p = m.outstanding_calls.items[0];
                    if (p.capability.handler(p.capability.ctx, m.arena, p.args)) |result| {
                        m.resolve(p, result);
                    } else |err| switch (err) {
                        error.HostError => m.resolveFailure(p),
                        error.OutOfMemory => return Error.OutOfMemory,
                    }
                    outcome = try m.continueRun();
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
                    if (m.frames.items.len == 0) {
                        // §4 toplevel sync: the feed only completes when
                        // every dispatched call has settled...
                        if (m.outstanding_calls.items.len > 0) return .blocked;
                        // ...and none failed, even if never forced
                        // (stop-on-error, §6).
                        for (m.feed_calls.items) |p| if (p.state == .failed) {
                            m.diagnostic = .{ .context = p.capability.name };
                            return Error.HostError;
                        };
                        // The result itself is a strictness point: substitute
                        // settled pendings so none escape to the host.
                        switch (try m.forceDeep(v)) {
                            .value => |final| return .{ .value = final },
                            .blocked => unreachable, // outstanding is empty
                        }
                    }
                    m.control = try m.stepFrame(v);
                },
                .awaiting => |p| switch (p.state) {
                    .resolved => |v| m.control = .{ .value = v },
                    .failed => {
                        m.diagnostic = .{ .context = p.capability.name };
                        return Error.HostError;
                    },
                    .outstanding => return .blocked,
                },
                .barrier => {
                    if (m.outstanding_calls.items.len > 0) return .blocked;
                    // Drained: re-deliver to the apply frame, which retries
                    // the dispatch (now with a clear boundary).
                    m.control = .{ .value = .unspecified };
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
                if (isForm(p, "let"))
                    return .{ .expr = .{ .d = try expand.expandLet(m.arena, p.cdr), .env = x.env } };
                if (isForm(p, "let*"))
                    return .{ .expr = .{ .d = try expand.expandLetStar(m.arena, p.cdr), .env = x.env } };
                if (isForm(p, "case"))
                    return .{ .expr = .{ .d = try expand.expandCase(m.arena, p.cdr), .env = x.env } };
                if (isForm(p, "do"))
                    return .{ .expr = .{ .d = try expand.expandDo(m.arena, p.cdr), .env = x.env } };
                if (isForm(p, "letrec")) {
                    if (p.cdr != .pair) return Error.BadSyntax;
                    const body = p.cdr.pair.cdr;
                    var check = body;
                    while (check == .pair) : (check = check.pair.cdr) {}
                    if (body != .pair or check != .empty_list) return Error.BadSyntax;
                    const b = try expand.parseBindings(m.arena, p.cdr.pair.car);
                    const child = try Env.init(m.arena, x.env);
                    for (b.names) |name| try child.define(name, .unspecified);
                    if (b.inits.len == 0) return m.enterSequence(body, child);
                    try m.pushFrame(.{ .letrec = .{ .b = b, .index = 0, .env = child, .body = body } });
                    return .{ .expr = .{ .d = b.inits[0], .env = child } };
                }
                if (isForm(p, "cond"))
                    return .{ .expr = .{ .d = try expand.expandCond(m.arena, p.cdr, x.env.lookup("else") != null), .env = x.env } };
                if (isForm(p, "and"))
                    return .{ .expr = .{ .d = try expand.expandAnd(m.arena, p.cdr), .env = x.env } };
                if (isForm(p, "or"))
                    return .{ .expr = .{ .d = try expand.expandOr(m.arena, p.cdr), .env = x.env } };

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
                // The `if` condition is a strictness point (§4).
                const cond = switch (try m.forced1(v)) {
                    .value => |real| real,
                    .blocked => |p| {
                        try m.pushFrame(.{ .branch = b });
                        return .{ .awaiting = p };
                    },
                };
                if (value_mod.isTruthy(cond)) return .{ .expr = .{ .d = b.then, .env = b.env } };
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
                return m.applyCollected(app.collected);
            },
            .apply => |a| return m.applyCollected(a.collected), // v is the settled pending's value; re-read from collected
            .letrec => |popped| {
                var lr = popped;
                try lr.env.define(lr.b.names[lr.index], v);
                lr.index += 1;
                if (lr.index < lr.b.inits.len) {
                    const next = lr.b.inits[lr.index];
                    try m.pushFrame(.{ .letrec = lr });
                    return .{ .expr = .{ .d = next, .env = lr.env } };
                }
                return m.enterSequence(lr.body, lr.env);
            },
            .body => |b| {
                if (b.rest.len == 1) // tail position: push nothing
                    return .{ .expr = .{ .d = b.rest[0], .env = b.env } };
                try m.pushFrame(.{ .body = .{ .rest = b.rest[1..], .env = b.env } });
                return .{ .expr = .{ .d = b.rest[0], .env = b.env } };
            },
        }
    }

    fn applyCollected(m: *Machine, collected: std.ArrayList(Value)) Error!Control {
        const items = collected.items;
        // The operator position is a strictness point (§4).
        items[0] = switch (try m.forced1(items[0])) {
            .value => |real| real,
            .blocked => |p| return m.awaitAndReapply(collected, p),
        };
        const op = items[0];
        const args = items[1..];
        switch (op) {
            // Parameter binding is not strict: closures accept pendings.
            .closure => |c| {
                const child = try Env.init(m.arena, c.env);
                try value_mod.bindArgs(m.arena, c, args, child);
                if (c.body.len == 1) // tail position: push nothing
                    return .{ .expr = .{ .d = c.body[0], .env = child } };
                try m.pushFrame(.{ .body = .{ .rest = c.body[1..], .env = child } });
                return .{ .expr = .{ .d = c.body[0], .env = child } };
            },
            .primitive => |prim| {
                if (prim.strict_args) for (args, 0..) |a, i| {
                    args[i] = switch (try m.forced1(a)) {
                        .value => |real| real,
                        .blocked => |p| return m.awaitAndReapply(collected, p),
                    };
                };
                const result = prim.func(m.arena, args) catch |err| {
                    m.diagnostic = .{ .context = prim.name };
                    return err;
                };
                return .{ .value = result };
            },
            .capability => |c| {
                // Boundary arguments force deeply (§4): fully-resolved pure
                // data or nothing.
                for (args, 0..) |a, i| {
                    args[i] = switch (try m.forceDeep(a)) {
                        .value => |real| real,
                        .blocked => |p| return m.awaitAndReapply(collected, p),
                    };
                    if (!value_mod.isPureData(args[i])) {
                        m.diagnostic = .{ .context = c.name };
                        return Error.TypeError;
                    }
                }
                // Ordered classes (§4): drain outstanding calls first, and
                // never dispatch past an already-failed call — the strongest
                // clause of §6 (an irreversible call a failing sequential run
                // would not reach must never be dispatched).
                switch (c.class) {
                    .pure, .external_independent => {},
                    .resource_ordered, .globally_ordered, .irreversible => {
                        for (m.feed_calls.items) |prior| if (prior.state == .failed) {
                            m.diagnostic = .{ .context = prior.capability.name };
                            return Error.HostError;
                        };
                        if (m.outstanding_calls.items.len > 0) {
                            try m.pushFrame(.{ .apply = .{ .collected = collected } });
                            return .barrier;
                        }
                    },
                }
                // Dispatch: the call becomes a pending settled by the host,
                // and evaluation continues — blocking only happens at
                // strictness points and the toplevel sync.
                const p = try m.arena.create(Pending);
                p.* = .{ .capability = c, .args = args };
                try m.outstanding_calls.append(m.arena, p);
                try m.feed_calls.append(m.arena, p);
                return .{ .value = .{ .pending = p } };
            },
            else => return Error.NotAProcedure,
        }
    }

    fn awaitAndReapply(m: *Machine, collected: std.ArrayList(Value), p: *Pending) Error!Control {
        try m.pushFrame(.{ .apply = .{ .collected = collected } });
        return .{ .awaiting = p };
    }

    const Forced = union(enum) { value: Value, blocked: *Pending };

    /// Shallow force: settles one pending level. Failed calls surface here
    /// as host-error (§3).
    fn forced1(m: *Machine, v: Value) Error!Forced {
        if (v != .pending) return .{ .value = v };
        return switch (v.pending.state) {
            .resolved => |inner| .{ .value = inner }, // resolutions are pure data; no nesting
            .outstanding => .{ .blocked = v.pending },
            .failed => {
                m.diagnostic = .{ .context = v.pending.capability.name };
                return Error.HostError;
            },
        };
    }

    /// Deep force: substitutes settled pendings throughout a data tree,
    /// rebuilding pairs only where something changed.
    fn forceDeep(m: *Machine, v: Value) Error!Forced {
        switch (v) {
            .pending => return m.forced1(v),
            .pair => |pr| {
                const car = switch (try m.forceDeep(pr.car)) {
                    .value => |real| real,
                    .blocked => |p| return .{ .blocked = p },
                };
                const cdr = switch (try m.forceDeep(pr.cdr)) {
                    .value => |real| real,
                    .blocked => |p| return .{ .blocked = p },
                };
                if (primitives.eqValues(car, pr.car) and primitives.eqValues(cdr, pr.cdr))
                    return .{ .value = v };
                const rebuilt = try m.arena.create(Value.Pair);
                rebuilt.* = .{ .car = car, .cdr = cdr };
                return .{ .value = .{ .pair = rebuilt } };
            },
            else => return .{ .value = v },
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

test "machine: pure calls continue; strictness points block" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const cap = capability_mod.Capability{ .name = "pask", .class = .pure, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &cap);

    // cons is non-strict: the pending flows into the pair and evaluation
    // reaches the toplevel sync with the call still outstanding.
    var outcome = try m.evalToplevel(try readOne(arena, "(cons (pask 1) 2)"));
    try std.testing.expect(outcome == .blocked);
    try std.testing.expectEqual(@as(usize, 1), m.outstanding().len);
    m.resolve(m.outstanding()[0], .{ .integer = 10 });
    var done = try m.continueRun();
    // toplevel deep force substituted the settled pending inside the pair
    try std.testing.expectEqual(@as(i64, 10), done.value.pair.car.integer);

    // a primitive argument is strict: blocks before the primitive runs
    outcome = try m.evalToplevel(try readOne(arena, "(+ (pask 2) 5)"));
    try std.testing.expect(outcome == .blocked);
    m.resolve(m.outstanding()[0], .{ .integer = 20 });
    done = try m.continueRun();
    try std.testing.expectEqual(@as(i64, 25), done.value.integer);

    // the if condition is strict
    outcome = try m.evalToplevel(try readOne(arena, "(if (pask 3) 'yes 'no)"));
    try std.testing.expect(outcome == .blocked);
    m.resolve(m.outstanding()[0], .{ .boolean = false });
    done = try m.continueRun();
    try std.testing.expectEqualStrings("no", done.value.symbol);
}

test "machine: pendings pass through closures and define unforced" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("(define hold (lambda (x) (lambda () x)))");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const cap = capability_mod.Capability{ .name = "pask", .class = .pure, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &cap);

    // The pending is bound to a parameter, captured, returned, and only the
    // toplevel sync waits for it — never a strict force.
    const outcome = try m.evalToplevel(try readOne(arena, "((hold (pask 1)))"));
    try std.testing.expect(outcome == .blocked);
    m.resolve(m.outstanding()[0], .{ .integer = 77 });
    const done = try m.continueRun();
    try std.testing.expectEqual(@as(i64, 77), done.value.integer);
}

test "machine: a failed call fails the feed even when never forced" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const cap = capability_mod.Capability{ .name = "pask", .class = .pure, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &cap);

    // (begin (pask 1) 2): the result is discarded, but §6 stop-on-error says
    // a sequential run would have aborted — the feed must fail.
    const outcome = try m.evalToplevel(try readOne(arena, "(begin (pask 1) 2)"));
    try std.testing.expect(outcome == .blocked);
    m.resolveFailure(m.outstanding()[0]);
    try std.testing.expectError(error.HostError, m.continueRun());
    try std.testing.expectEqualStrings("pask", m.diagnostic.?.context);
}

test "machine: independent fan-out overlaps — four calls outstanding at once" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const ask = capability_mod.Capability{ .name = "ask", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    const sink = capability_mod.Capability{ .name = "sink", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &ask);
    try capability_mod.register(m.global, &sink);

    // P1's shape: four independent calls flow through cons; sink's deep
    // force blocks with ALL FOUR outstanding — the opportunism the study
    // measured (§4 dispatch order = program order).
    const outcome = try m.evalToplevel(try readOne(arena,
        "(sink (cons (ask 1) (cons (ask 2) (cons (ask 3) (cons (ask 4) '())))))"));
    try std.testing.expect(outcome == .blocked);
    const calls = m.outstanding();
    try std.testing.expectEqual(@as(usize, 4), calls.len);
    for (calls, 1..) |c, i| {
        try std.testing.expectEqualStrings("ask", c.capability.name);
        try std.testing.expectEqual(@as(i64, @intCast(i)), c.args[0].integer);
    }

    // Completion order is the host's freedom: resolve in reverse.
    var i = calls.len;
    var pinned: [4]*Pending = undefined;
    @memcpy(&pinned, calls);
    while (i > 0) {
        i -= 1;
        m.resolve(pinned[i], .{ .integer = pinned[i].args[0].integer * 10 });
    }
    var out = try m.continueRun();
    try std.testing.expect(out == .blocked); // now sink itself is outstanding
    const s = m.outstanding()[0];
    try std.testing.expectEqualStrings("sink", s.capability.name);
    // sink received the fully forced list (10 20 30 40)
    try std.testing.expectEqual(@as(i64, 10), s.args[0].pair.car.integer);
    try std.testing.expectEqual(@as(i64, 40), s.args[0].pair.cdr.pair.cdr.pair.cdr.pair.car.integer);
    m.resolve(s, .{ .symbol = "ok" });
    out = try m.continueRun();
    try std.testing.expectEqualStrings("ok", out.value.symbol);
}

test "machine: ordered calls drain the outstanding set first" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const ask = capability_mod.Capability{ .name = "ask", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    const emit = capability_mod.Capability{ .name = "emit", .class = .irreversible, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &ask);
    try capability_mod.register(m.global, &emit);

    // (begin (ask 1) (emit 2) 3): emit must not dispatch while ask is in
    // flight — the machine blocks at the barrier with only ask outstanding.
    const outcome = try m.evalToplevel(try readOne(arena, "(begin (ask 1) (emit 2) 3)"));
    try std.testing.expect(outcome == .blocked);
    try std.testing.expectEqual(@as(usize, 1), m.outstanding().len);
    try std.testing.expectEqualStrings("ask", m.outstanding()[0].capability.name);

    m.resolve(m.outstanding()[0], .{ .integer = 0 });
    var out = try m.continueRun();
    try std.testing.expect(out == .blocked);
    try std.testing.expectEqualStrings("emit", m.outstanding()[0].capability.name);
    m.resolve(m.outstanding()[0], .unspecified);
    out = try m.continueRun();
    try std.testing.expectEqual(@as(i64, 3), out.value.integer);
}

test "machine: an irreversible call never dispatches after a failed call" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const ask = capability_mod.Capability{ .name = "ask", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    const emit = capability_mod.Capability{ .name = "emit", .class = .irreversible, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &ask);
    try capability_mod.register(m.global, &emit);

    const outcome = try m.evalToplevel(try readOne(arena, "(begin (ask 1) (emit 2) 3)"));
    try std.testing.expect(outcome == .blocked);
    m.resolveFailure(m.outstanding()[0]); // ask fails
    try std.testing.expectError(error.HostError, m.continueRun());
    // emit was never dispatched: the strongest §6 clause
    try std.testing.expectEqual(@as(usize, 0), m.outstanding().len);
    try std.testing.expectEqualStrings("ask", m.diagnostic.?.context);
}

test "machine: blocked hands the call to the host and continues mid-expression" {
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

    // Blocks in the middle of an application; machine state carries the
    // surrounding computation.
    const outcome = try m.evalToplevel(try readOne(arena, "(+ 1 (ask 3) 100)"));
    try std.testing.expect(outcome == .blocked);
    const calls = m.outstanding();
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("ask", calls[0].capability.name);
    try std.testing.expectEqual(@as(i64, 3), calls[0].args[0].integer);

    m.resolve(calls[0], .{ .integer = 6 });
    const done = try m.continueRun();
    try std.testing.expectEqual(@as(i64, 107), done.value.integer);
}

test "machine: blocked state survives define and nested control" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const cap = capability_mod.Capability{ .name = "ask", .class = .globally_ordered, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &cap);

    const outcome = try m.evalToplevel(try readOne(arena, "(define x (if #t (begin 1 (ask 'q)) 9))"));
    try std.testing.expect(outcome == .blocked);
    m.resolve(m.outstanding()[0], .{ .integer = 55 });
    _ = try m.continueRun();
    try std.testing.expectEqual(@as(i64, 55), (try t.run("x")).integer);
}

test "machine: failure and impure resolution surface as host-error" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const cap = capability_mod.Capability{ .name = "ask", .class = .globally_ordered, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &cap);

    var outcome = try m.evalToplevel(try readOne(arena, "(ask 1)"));
    try std.testing.expect(outcome == .blocked);
    m.resolveFailure(m.outstanding()[0]);
    try std.testing.expectError(error.HostError, m.continueRun());
    try std.testing.expectEqualStrings("ask", m.diagnostic.?.context);

    // session usable again; resolving with a procedure is a host fault
    outcome = try m.evalToplevel(try readOne(arena, "(ask 2)"));
    try std.testing.expect(outcome == .blocked);
    m.resolve(m.outstanding()[0], m.global.lookup("+").?);
    try std.testing.expectError(error.HostError, m.continueRun());

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
        // let (7.2): plain let is not let* — y sees the OUTER x
        "(let ((x 2) (y 3)) (* x y))",
        "(define x 1) (let ((x 2) (y x)) y)",
        "(let ((x 1)) (let ((x 2)) x))",
        "(let () 7)",
        "(let (x) 1)",
        "(let ((x 1)))",
        "(let ((x 1) (x 2)) x)",
        // let* (8A.2): sequential bindings; plain let must NOT behave like it
        "(let* ((x 1) (y (+ x 1))) (* x y))",
        "(let* ((x 1) (x (+ x 1))) x)",
        "(let* () 9)",
        // letrec (8A.3): mutual recursion; init order left-to-right
        "(letrec ((e? (lambda (n) (if (= n 0) #t (o? (- n 1))))) (o? (lambda (n) (if (= n 0) #f (e? (- n 1)))))) (e? 10))",
        "(letrec () 3)",
        "(letrec ((x 1) (y 2)) (+ x y))",
        "(letrec ((x 1) (x 2)) x)",
        "(letrec ((x 1)))",
        // named let (8A.4): tail-recursive loop stays flat
        "(let fact ((n 5) (acc 1)) (if (= n 0) acc (fact (- n 1) (* acc n))))",
        "(let loop ((n 100000)) (if (= n 0) 'done (loop (- n 1))))",
        "(let loop)",
        // do (8A.5)
        "(do ((i 0 (+ i 1)) (acc 1 (* acc 2))) ((= i 4) acc))",
        "(do ((i 0 (+ i 1)) (keep 7)) ((= i 2) keep))",
        "(do ((i 0)) (#t 'now))",
        "(do ((i 0 (+ i 1))) ((= i 100000) 'done))",
        "(do)",
        // case (8A.6)
        "(case (* 2 3) ((2 3 5 7) 'prime) ((1 4 6 8 9) 'composite))",
        "(case 42 ((1) 'one) (else 'other))",
        "(case 42 ((1) 'one))",
        "(case)",
        // dotted pairs (8F'.2)
        "'(1 . 2)",
        "(car '(1 . 2)) (cdr '(1 . 2))",
        "(equal? (cons 1 2) '(1 . 2))",
        // define shorthand (8F'.3)
        "(define (twice x) (* 2 x)) (twice 21)",
        "(define (five) 5) (five)",
        "(define (f x) 1 (* x x)) (f 4)",
        "(define (7) 1)",
        "(define ((f)) 1)",
        // rest args (8F'.4)
        "((lambda args args) 1 2 3)",
        "((lambda args args))",
        "((lambda (a . r) (cons a r)) 1 2 3)",
        "((lambda (a . r) r) 1)",
        "((lambda (a . r) r))",
        "(define (f a . r) (cons a r)) (f 1 2)",
        "(lambda (a . 2) a)",
        "(lambda (a . a) a)",
        // cond/and/or (7.3): short-circuit means untaken positions may be unbound
        "(cond (#f 1) ((eq? 1 1) 'hit) (else 'miss))",
        "(cond (#f 1))",
        "(and 1 2 3)",
        "(and #f boom)",
        "(and)",
        "(or #f 7 boom)",
        "(or #f #f)",
        "(let ((t 5)) (or #f t))",
        "(cond (else 1) (2 3))",
        // list primitives II (7.4)
        "(list 1 (+ 1 1) 'three)",
        "(list)",
        "(append '(1 2) '(3) '() '(4 5))",
        "(append)",
        "(append '(1) 2)",
        "(length '(a b c))",
        "(length 5)",
        "(not #f)",
        "(not 0)",
        // comparisons and equivalence (7.5)
        "(< 1 2 3)",
        "(< 1 3 2)",
        "(<= 1 1 2)",
        "(> 3 2 1)",
        "(>= 2 2 1)",
        "(= 2 2 2)",
        "(= 2 3)",
        "(< 1)",
        "(< 1 'a)",
        "(equal? '(1 (2 \"x\")) '(1 (2 \"x\")))",
        "(equal? '(1 2) '(1 3))",
        "(equal? \"ab\" \"ab\")",
        "(eqv? 'a 'a)",
        "(eqv? \"ab\" \"ab\")",
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
