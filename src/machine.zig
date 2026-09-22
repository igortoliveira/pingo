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
const macro_mod = @import("macro.zig");

const Datum = datum_mod.Datum;
const Value = value_mod.Value;
const Env = env_mod.Env;

pub const Error = eval_mod.Error;
pub const Limits = eval_mod.Limits;
pub const Diagnostic = eval_mod.Diagnostic;

pub const Pending = Value.Pending;

const prelude_sources = [_][]const u8{ @embedFile("prelude.scm"), @embedFile("regex.scm") };

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

/// A call waiting on pending arguments; `result` is already circulating in
/// the program as a pending value.
const Parked = struct {
    result: *Pending,
    args: []Value,
};

/// One suspended context; the application frame lands in 6.5.
const Frame = union(enum) {
    /// After the condition of (if c t [e]): pick a branch from the value.
    branch: struct { then: Datum, alt: ?Datum, env: *Env },
    /// A begin/body sequence: discard the arrived value, evaluate `rest`
    /// (invariant: a proper, non-empty list — validated before pushing).
    seq: struct { rest: Datum, env: *Env },
    /// Toplevel (define name _): bind the arrived value globally (§2).
    define: struct { name: []const u8 },
    /// (set! name _): assign the nearest binding to the arrived value (§2).
    assign: struct { name: []const u8, env: *Env },
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
    /// dynamic-wind (§2, tier 8H″): `before` has run; activate the wind entry
    /// and run `thunk`.
    dw_before: struct { before: Value, thunk: Value, after: Value },
    /// dynamic-wind: `thunk` returned; deactivate `entry` and run `after`.
    dw_thunk: struct { entry: *WindEntry, after: Value },
    /// dynamic-wind: `after` has run; return the thunk's saved `result`.
    dw_after: struct { result: Value },
    /// with-exception-handler: the thunk returned — pop the installed handler
    /// and yield its value (tier 15D).
    pop_handler,
    /// A non-continuable handler (from `raise` or a runtime error) returned —
    /// that is itself an error (§15D).
    raise_return,
    /// `raise-continuable`: the handler returned `v` — reinstall `handler` and
    /// continue with `v` at the raise-continuable call site.
    restore_handler: struct { handler: Value },
    /// Continuation invoke: run the pending winder `thunks` in order, then
    /// install `target`'s frames/wind and deliver `value` (docs/callcc.md).
    winders: struct { thunks: []Value, index: usize, target: *const Snapshot, value: Value },
};

/// One active `dynamic-wind` extent: its before/after thunks, re-run on
/// continuation entry/exit. Identity (pointer) marks the extent, so a
/// snapshot and the live stack share entries and compare by pointer.
const WindEntry = struct { before: Value, after: Value };

/// A captured continuation (tier 8H″): a clone of the frame stack at the
/// `call/cc` call site. `Value.continuation` points here (opaquely).
const Snapshot = struct { frames: []Frame, wind: []*WindEntry, handlers: []Value };

/// Deep-copies the frame stack for a continuation snapshot. Frames hold
/// immutable data (`Datum`, `Env`, slices, `Bindings`) which is shared;
/// the `app`/`apply` `collected` buffers mutate in place as arguments
/// arrive, so those are duplicated (docs/callcc.md).
fn cloneFrames(arena: std.mem.Allocator, frames: []const Frame) std.mem.Allocator.Error![]Frame {
    const out = try arena.alloc(Frame, frames.len);
    for (frames, out) |src, *dst| {
        dst.* = src;
        switch (src) {
            .app => |a| {
                var c: std.ArrayList(Value) = .empty;
                try c.appendSlice(arena, a.collected.items);
                dst.app.collected = c;
            },
            .apply => |a| {
                var c: std.ArrayList(Value) = .empty;
                try c.appendSlice(arena, a.collected.items);
                dst.apply.collected = c;
            },
            else => {},
        }
    }
    return out;
}

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
    /// Calls parked on pending arguments (§4 "Parked calls"): dispatched
    /// automatically once their blockers settle.
    parked_calls: std.ArrayList(Parked) = .empty,
    /// Active `dynamic-wind` extents, outermost first (tier 8H″). A
    /// continuation snapshots this alongside the frames; invoking one runs
    /// the afters/befores that differ from the live stack.
    wind: std.ArrayList(*WindEntry) = .empty,
    /// Session-monotonic mark counter for macro hygiene renames (tier 8I.4).
    macro_counter: u64 = 0,
    /// Dynamic exception-handler stack (tier 15D); the current handler is the
    /// last. Captured in a continuation snapshot so it unwinds with call/cc.
    handlers: std.ArrayList(Value) = .empty,
    /// The object of an uncaught raise (set when returning Error.Raised).
    raised: ?Value = null,

    pub fn init(arena: std.mem.Allocator, limits: Limits) std.mem.Allocator.Error!Machine {
        const global = try Env.init(arena, null);
        try primitives.install(global);
        var m = Machine{ .arena = arena, .global = global, .limits = limits };
        try m.loadPrelude();
        return m;
    }

    /// Evaluates the embedded prelude (§7) under an internal budget. The
    /// prelude is trusted runtime source: any failure besides OOM is a build
    /// bug, not a runtime condition.
    fn loadPrelude(m: *Machine) std.mem.Allocator.Error!void {
        const saved = m.limits;
        m.limits = .{ .fuel = 10_000_000, .call_depth = 500 };
        defer {
            m.limits = saved;
            m.fuel_used = 0;
        }
        // The host bundles several source files into the environment at init
        // (not a library system — no import/paths/authority; §7).
        for (prelude_sources) |src| {
            var r = reader_mod.Reader.init(m.arena, src, 64);
            while (r.read() catch unreachable) |d| {
                const outcome = m.evalToplevel(d) catch |err| switch (err) {
                    Error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                };
                std.debug.assert(outcome == .value); // the prelude has no capabilities
            }
        }
    }

    pub fn evalToplevel(m: *Machine, d: Datum) Error!Outcome {
        // Calls left over from a previous (failed) feed are abandoned: they
        // were dispatched — that observation stands — but nothing waits on
        // them anymore (§3 abort semantics). Abandonment settles them as
        // failed (§4): a pending that escaped into surviving state via a
        // mutator must force to host-error later, not wait forever on a
        // call the host no longer tracks.
        for (m.outstanding_calls.items) |p|
            if (p.state == .outstanding) {
                p.state = .failed;
            };
        for (m.parked_calls.items) |pk|
            if (pk.result.state == .outstanding) {
                pk.result.state = .failed;
            };
        m.outstanding_calls.clearRetainingCapacity();
        m.feed_calls.clearRetainingCapacity();
        m.parked_calls.clearRetainingCapacity();
        // dynamic-wind extents do not cross toplevel forms; a prior feed that
        // aborted mid-extent may have left the wind/handler stacks dirty.
        m.wind.clearRetainingCapacity();
        m.handlers.clearRetainingCapacity();
        m.raised = null;
        m.diagnostic = null;
        if (d == .pair and isForm(d.pair, "define-syntax")) {
            try macro_mod.defineSyntax(m.arena, d.pair.cdr, m.global);
            return .{ .value = .unspecified };
        }
        if (d == .pair and isForm(d.pair, "define-record-type")) {
            for (try expand.recordType(m.arena, d.pair.cdr)) |def| _ = try m.evalToplevel(def);
            return .{ .value = .unspecified };
        }
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
                m.pumpParked() catch {}; // OOM here surfaces on the next continueRun
                return;
            }
        }
        unreachable; // host protocol: p must come from outstanding()
    }

    /// Dispatches every parked call whose blockers have settled; propagates
    /// failures to parked dependents without dispatching them (§4).
    fn pumpParked(m: *Machine) std.mem.Allocator.Error!void {
        var progressed = true;
        while (progressed) {
            progressed = false;
            var i: usize = 0;
            while (i < m.parked_calls.items.len) {
                const pk = m.parked_calls.items[i];
                var budget: usize = 1_000_000;
                var all_ready = true;
                var failed = false;
                for (pk.args, 0..) |a, j| {
                    const forced = m.forceDeepInner(a, 0, &budget) catch {
                        failed = true; // failed blocker or walker limit
                        break;
                    };
                    switch (forced) {
                        .value => |real| pk.args[j] = real,
                        .blocked => {
                            all_ready = false;
                            break;
                        },
                    }
                }
                if (failed) {
                    pk.result.state = .failed;
                    _ = m.parked_calls.swapRemove(i);
                    progressed = true; // may fail further dependents
                } else if (all_ready) {
                    pk.result.args = pk.args;
                    try m.outstanding_calls.append(m.arena, pk.result);
                    _ = m.parked_calls.swapRemove(i);
                    progressed = true;
                } else {
                    i += 1;
                }
            }
        }
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
                .expr => |x| m.control = m.stepExpr(x) catch |e| try m.raiseError(e),
                .value => |v| {
                    if (m.frames.items.len == 0) {
                        // §4 toplevel sync: the feed only completes when
                        // every dispatched call has settled...
                        if (m.outstanding_calls.items.len > 0) return .blocked;
                        // parked ⇒ outstanding (§4 invariant)
                        std.debug.assert(m.parked_calls.items.len == 0);
                        // ...and none failed, even if never forced
                        // (stop-on-error, §6).
                        for (m.feed_calls.items) |p| if (p.state == .failed and !p.handled) {
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
                    m.control = m.stepFrame(v) catch |e| try m.raiseError(e);
                },
                .awaiting => |p| switch (p.state) {
                    .resolved => |v| m.control = .{ .value = v },
                    .failed => {
                        // A failed capability forced inside a handler's extent
                        // is catchable (§15D); uncaught, it aborts the feed. If
                        // a handler will catch it, mark it handled so the
                        // toplevel stop-on-error scan doesn't re-fail the feed.
                        m.diagnostic = .{ .context = p.capability.name };
                        if (m.handlers.items.len > 0) p.handled = true;
                        m.control = try m.raiseError(Error.HostError);
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
            .real => |r| return .{ .value = .{ .real = r } },
            .char => |c| return .{ .value = .{ .char = c } },
            // #(...) literals evaluate like quoted data: a fresh copy (§1)
            .vector => return .{ .value = try value_mod.fromDatum(m.arena, x.d) },
            .boolean => |b| return .{ .value = .{ .boolean = b } },
            .string => |s| return .{ .value = .{ .string = try m.arena.dupe(u8, s) } },
            .empty_list => return Error.BadSyntax,
            .symbol => |name| {
                if (x.env.lookup(name)) |v| {
                    if (v == .macro) { // a syntactic keyword is not a value (§2)
                        m.diagnostic = .{ .context = name };
                        return Error.BadSyntax;
                    }
                    return .{ .value = v };
                }
                m.diagnostic = .{ .context = name };
                return Error.UnboundVariable;
            },
            .pair => |p| {
                // Hygiene (§8I.4): a macro-introduced alias whose underlying
                // identifier is a syntactic keyword is rewritten to that
                // keyword so the form cascade recognizes it.
                if (p.car == .symbol) if (macro_mod.unwrapKeyword(x.env, p.car.symbol)) |kw| {
                    const head = try datum_mod.cons(m.arena, .{ .symbol = kw }, p.cdr);
                    return .{ .expr = .{ .d = head, .env = x.env } };
                };
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
                if (isForm(p, "quasiquote"))
                    return .{ .expr = .{ .d = try expand.expandQuasiquote(m.arena, p.cdr), .env = x.env } };
                if (isForm(p, "unquote") or isForm(p, "unquote-splicing"))
                    return Error.BadSyntax; // only meaningful inside quasiquote
                if (isForm(p, "set!")) return Error.BadSyntax; // no mutation (docs/purity.md)
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
                if (isForm(p, "delay"))
                    return .{ .expr = .{ .d = try expand.expandDelay(m.arena, p.cdr), .env = x.env } };
                if (isForm(p, "letrec")) {
                    if (p.cdr != .pair) return Error.BadSyntax;
                    var body = p.cdr.pair.cdr;
                    var check = body;
                    while (check == .pair) : (check = check.pair.cdr) {}
                    if (body != .pair or check != .empty_list) return Error.BadSyntax;
                    body = try expand.rewriteBody(m.arena, body); // internal defines (§2)
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
                if (isForm(p, "define-syntax")) return Error.BadSyntax; // top/body only (§2)
                if (isForm(p, "define-record-type")) return Error.BadSyntax; // top level only (15C)
                if (isForm(p, "let-syntax") or isForm(p, "letrec-syntax")) {
                    const recursive = std.mem.eql(u8, p.car.symbol, "letrec-syntax");
                    const child = try Env.init(m.arena, x.env);
                    const body = try macro_mod.bindSyntax(m.arena, p.cdr, child, if (recursive) child else x.env);
                    var check = body;
                    while (check == .pair) : (check = check.pair.cdr) {}
                    if (body != .pair or check != .empty_list) return Error.BadSyntax;
                    return m.enterSequence(try expand.rewriteBody(m.arena, body), child);
                }

                // Macro use (§2, tier 8I): a keyword bound in scope expands and
                // re-evaluates. Core/derived forms above take precedence.
                if (macro_mod.lookupMacro(x.d, x.env)) |mac|
                    return .{ .expr = .{ .d = try macro_mod.expand(m.arena, mac, x.d, &m.macro_counter), .env = x.env } };

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
            .assign => |a| {
                if (!a.env.set(a.name, v)) {
                    m.diagnostic = .{ .context = a.name };
                    return Error.UnboundVariable;
                }
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
            .dw_before => |d| {
                // `before` returned (value ignored): activate the extent and
                // run `thunk`.
                const entry = try m.arena.create(WindEntry);
                entry.* = .{ .before = d.before, .after = d.after };
                try m.wind.append(m.arena, entry);
                try m.pushFrame(.{ .dw_thunk = .{ .entry = entry, .after = d.after } });
                return m.callThunk(d.thunk);
            },
            .dw_thunk => |d| {
                // `thunk` returned `v`: deactivate the extent and run `after`,
                // saving `v` for the return.
                std.debug.assert(m.wind.items.len > 0 and m.wind.items[m.wind.items.len - 1] == d.entry);
                _ = m.wind.pop();
                try m.pushFrame(.{ .dw_after = .{ .result = v } });
                return m.callThunk(d.after);
            },
            .dw_after => |d| return .{ .value = d.result }, // `after` done; return thunk's value
            .pop_handler => { // with-exception-handler thunk returned normally
                _ = m.handlers.pop();
                return .{ .value = v };
            },
            .raise_return => { // a non-continuable handler returned — an error
                m.diagnostic = .{ .context = "handler-returned" };
                m.raised = v;
                return Error.Raised;
            },
            .restore_handler => |rh| { // raise-continuable handler returned v
                try m.handlers.append(m.arena, rh.handler);
                return .{ .value = v };
            },
            .winders => |w| {
                if (w.index < w.thunks.len) {
                    try m.pushFrame(.{ .winders = .{
                        .thunks = w.thunks,
                        .index = w.index + 1,
                        .target = w.target,
                        .value = w.value,
                    } });
                    return m.callThunk(w.thunks[w.index]);
                }
                // All winders run: install the captured control (fresh clone)
                // and deliver the value to the continuation.
                m.frames.clearRetainingCapacity();
                try m.frames.appendSlice(m.arena, try cloneFrames(m.arena, w.target.frames));
                m.wind.clearRetainingCapacity();
                try m.wind.appendSlice(m.arena, w.target.wind);
                m.handlers.clearRetainingCapacity();
                try m.handlers.appendSlice(m.arena, w.target.handlers);
                return .{ .value = w.value };
            },
        }
    }

    /// Applies a zero-argument thunk through the ordinary application path.
    fn callThunk(m: *Machine, thunk: Value) Error!Control {
        var c: std.ArrayList(Value) = .empty;
        try c.append(m.arena, thunk);
        return m.applyCollected(c);
    }

    /// `(dynamic-wind before thunk after)` (§2, tier 8H″): run `before`, then
    /// via frames activate the wind extent, run `thunk`, deactivate, run
    /// `after`, and return the thunk's value.
    fn enterDynamicWind(m: *Machine, collected: std.ArrayList(Value)) Error!Control {
        const items = collected.items;
        if (items.len != 4) return Error.ArityMismatch; // dynamic-wind + 3
        try m.pushFrame(.{ .dw_before = .{ .before = items[1], .thunk = items[2], .after = items[3] } });
        return m.callThunk(items[1]);
    }

    // -- exceptions (tier 15D) --------------------------------------------

    /// `(with-exception-handler handler thunk)`: install `handler` for the
    /// dynamic extent of `thunk`, popping it when the thunk returns.
    fn enterWithHandler(m: *Machine, collected: std.ArrayList(Value)) Error!Control {
        const items = collected.items;
        if (items.len != 3) return Error.ArityMismatch; // weh + handler + thunk
        try m.handlers.append(m.arena, items[1]);
        try m.pushFrame(.pop_handler);
        return m.callThunk(items[2]);
    }

    /// `(raise obj)` / `(raise-continuable obj)`: invoke the current handler.
    fn doRaise(m: *Machine, collected: std.ArrayList(Value), continuable: bool) Error!Control {
        const items = collected.items;
        if (items.len != 2) return Error.ArityMismatch;
        return m.invokeHandler(items[1], continuable);
    }

    /// Invokes the current handler with `obj`, the outer handler installed for
    /// its extent. `continuable` decides what happens if the handler returns:
    /// re-install and continue (raise-continuable) vs. secondary error (raise).
    fn invokeHandler(m: *Machine, obj: Value, continuable: bool) Error!Control {
        if (m.handlers.items.len == 0) {
            m.raised = obj;
            return Error.Raised;
        }
        const h = m.handlers.pop().?;
        if (continuable)
            try m.pushFrame(.{ .restore_handler = .{ .handler = h } })
        else
            try m.pushFrame(.raise_return);
        var call: std.ArrayList(Value) = .empty;
        try call.append(m.arena, h);
        try call.append(m.arena, obj);
        return m.applyCollected(call);
    }

    /// Turns a catchable runtime error into an error object and hands it to the
    /// current handler; if none (or the error is uncatchable), propagates it.
    fn raiseError(m: *Machine, e: Error) Error!Control {
        switch (e) {
            // §5 resource bounds are uncatchable; OOM likewise. Also don't try
            // to catch an already-uncaught raise or an oracle-only marker.
            Error.LimitExceeded, Error.OutOfMemory, Error.Raised, Error.Unimplemented, Error.Unsupported => return e,
            else => {},
        }
        if (m.handlers.items.len == 0) return e;
        const obj = try m.makeErrorObject(e);
        return m.invokeHandler(obj, false);
    }

    /// An error object matching the prelude's `(vector '%error-object msg
    /// irritants)` shape: message = the §3 kind, irritants = the diagnostic.
    fn makeErrorObject(m: *Machine, e: Error) Error!Value {
        const vec = try m.arena.alloc(Value, 3);
        vec[0] = .{ .symbol = "%error-object" };
        vec[1] = .{ .string = try m.arena.dupe(u8, eval_mod.kindOf(e)) };
        var irritants: Value = .empty_list;
        if (m.diagnostic) |diag| {
            const cell = try m.arena.create(Value.Pair);
            cell.* = .{ .car = .{ .string = try m.arena.dupe(u8, diag.context) }, .cdr = .empty_list };
            irritants = .{ .pair = cell };
        }
        vec[2] = irritants;
        return .{ .vector = vec };
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
                if (prim == &primitives.callcc_primitive)
                    return m.captureContinuation(collected);
                if (prim == &primitives.dynamic_wind_primitive)
                    return m.enterDynamicWind(collected);
                if (prim == &primitives.with_exception_handler_primitive)
                    return m.enterWithHandler(collected);
                if (prim == &primitives.raise_primitive)
                    return m.doRaise(collected, false);
                if (prim == &primitives.raise_continuable_primitive)
                    return m.doRaise(collected, true);
                if (prim == &primitives.apply_primitive)
                    return m.applySpread(collected);
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
                // data or nothing. Independent classes park on pendings
                // instead of blocking (§4 "Parked calls").
                for (args, 0..) |a, i| {
                    // procedures never cross, parked or not
                    if (!isPureDataAllowingPendings(a)) {
                        m.diagnostic = .{ .context = c.name };
                        return Error.TypeError;
                    }
                    args[i] = switch (try m.forceDeep(a)) {
                        .value => |real| real,
                        .blocked => |p| switch (c.class) {
                            .pure, .external_independent => {
                                const result = try m.arena.create(Pending);
                                result.* = .{ .capability = c, .args = args };
                                try m.parked_calls.append(m.arena, .{ .result = result, .args = args });
                                try m.feed_calls.append(m.arena, result);
                                return .{ .value = .{ .pending = result } };
                            },
                            // ordered classes drained first, so this cannot
                            // happen for them — but stay conservative
                            else => return m.awaitAndReapply(collected, p),
                        },
                    };
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
            .continuation => |k| {
                // Invoking k abandons the current control and continues the
                // captured one with the single supplied value (§2 call/cc).
                if (args.len != 1) return Error.ArityMismatch;
                const snap: *const Snapshot = @ptrCast(@alignCast(k));
                // A continuation captured under a larger budget cannot smuggle
                // depth past a reduced call_depth (§5).
                if (snap.frames.len > m.limits.call_depth) {
                    m.diagnostic = .{ .context = "call-depth" };
                    return Error.LimitExceeded;
                }
                try m.chargeFuelN(snap.frames.len);
                // dynamic-wind (§2): run the afters of the extents being left
                // and the befores of the extents being entered, relative to
                // the common prefix of the live and captured wind stacks.
                var cp: usize = 0;
                while (cp < m.wind.items.len and cp < snap.wind.len and
                    m.wind.items[cp] == snap.wind[cp]) : (cp += 1)
                {}
                var thunks: std.ArrayList(Value) = .empty;
                var i = m.wind.items.len;
                while (i > cp) : (i -= 1) // afters, innermost first
                    try thunks.append(m.arena, m.wind.items[i - 1].after);
                for (snap.wind[cp..]) |e| // befores, outermost first
                    try thunks.append(m.arena, e.before);
                // The winders frame runs those thunks in order, then installs
                // the captured control (a fresh clone — multi-shot safety).
                m.frames.clearRetainingCapacity();
                try m.frames.append(m.arena, .{ .winders = .{
                    .thunks = try thunks.toOwnedSlice(m.arena),
                    .index = 0,
                    .target = snap,
                    .value = args[0],
                } });
                return .{ .value = .unspecified };
            },
            else => return Error.NotAProcedure,
        }
    }

    /// `(call/cc f)`: the app frame that collected the operands is already
    /// popped, so `m.frames` *is* the continuation of this call. Snapshot it
    /// into a continuation value and re-enter as `(f k)` (§2, docs/callcc.md).
    fn captureContinuation(m: *Machine, collected: std.ArrayList(Value)) Error!Control {
        const items = collected.items;
        if (items.len != 2) return Error.ArityMismatch; // call/cc + one proc
        try m.chargeFuelN(m.frames.items.len);
        const snap = try m.arena.create(Snapshot);
        snap.* = .{
            .frames = try cloneFrames(m.arena, m.frames.items),
            .wind = try m.arena.dupe(*WindEntry, m.wind.items),
            .handlers = try m.arena.dupe(Value, m.handlers.items),
        };
        const k: Value = .{ .continuation = @ptrCast(snap) };

        var reapply: std.ArrayList(Value) = .empty;
        try reapply.append(m.arena, items[1]); // the procedure
        try reapply.append(m.arena, k);
        return m.applyCollected(reapply);
    }

    /// (apply f a ... args): rebuild the application as f a ... plus the
    /// elements of args, and re-enter applyCollected. The spine of the final
    /// list is forced (it must be traversable); elements pass through as-is.
    fn applySpread(m: *Machine, collected: std.ArrayList(Value)) Error!Control {
        const items = collected.items;
        if (items.len < 3) return Error.ArityMismatch; // apply + proc + list
        var spread: std.ArrayList(Value) = .empty;
        try spread.appendSlice(m.arena, items[1 .. items.len - 1]);
        var node = items[items.len - 1];
        while (true) {
            node = switch (try m.forced1(node)) {
                .value => |real| real,
                .blocked => |p| {
                    spread.deinit(m.arena);
                    return m.awaitAndReapply(collected, p);
                },
            };
            switch (node) {
                .empty_list => break,
                .pair => |pr| {
                    try spread.append(m.arena, pr.car);
                    node = pr.cdr;
                },
                else => {
                    m.diagnostic = .{ .context = "apply" };
                    return Error.TypeError; // final argument must be a proper list
                },
            }
        }
        return m.applyCollected(spread);
    }

    fn awaitAndReapply(m: *Machine, collected: std.ArrayList(Value), p: *Pending) Error!Control {
        try m.pushFrame(.{ .apply = .{ .collected = collected } });
        return .{ .awaiting = p };
    }

    const Forced = union(enum) { value: Value, blocked: *Pending };

    /// §4 boundary check that tolerates pendings (they resolve to checked
    /// pure data): rejects procedures/capabilities anywhere.
    fn isPureDataAllowingPendings(v: Value) bool {
        return switch (v) {
            .pending => true,
            .pair => |p| isPureDataAllowingPendings(p.car) and isPureDataAllowingPendings(p.cdr),
            .vector => |items| blk: {
                for (items) |item|
                    if (!isPureDataAllowingPendings(item)) break :blk false;
                break :blk true;
            },
            else => value_mod.isPureData(v),
        };
    }

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
    /// rebuilding pairs only where something changed. Cycle-safe (§1): the
    /// cdr spine is iterated under a node budget, the car side depth-capped;
    /// exceeding either is limit-exceeded (a cyclic value can never become
    /// checked pure data anyway).
    fn forceDeep(m: *Machine, v: Value) Error!Forced {
        var budget: usize = 1_000_000;
        return m.forceDeepInner(v, 0, &budget);
    }

    fn forceDeepInner(m: *Machine, v0: Value, depth: usize, budget: *usize) Error!Forced {
        if (depth > 4_000) return m.walkerLimit();
        const v = switch (try m.forced1(v0)) {
            .value => |real| real,
            .blocked => |p| return .{ .blocked = p },
        };
        if (v == .vector) {
            var changed = false;
            const out = try m.arena.alloc(Value, v.vector.len);
            for (v.vector, 0..) |item, i| {
                if (budget.* == 0) return m.walkerLimit();
                budget.* -= 1;
                out[i] = switch (try m.forceDeepInner(item, depth + 1, budget)) {
                    .value => |real| real,
                    .blocked => |p| return .{ .blocked = p },
                };
                if (!primitives.eqValues(out[i], item)) changed = true;
            }
            return .{ .value = if (changed) .{ .vector = out } else v };
        }
        if (v != .pair) return .{ .value = v };

        // collect the spine, forcing each element
        var cars: std.ArrayList(Value) = .empty;
        defer cars.deinit(m.arena);
        var node = v;
        var changed = false;
        while (true) {
            if (budget.* == 0) return m.walkerLimit();
            budget.* -= 1;
            const car = switch (try m.forceDeepInner(node.pair.car, depth + 1, budget)) {
                .value => |real| real,
                .blocked => |p| return .{ .blocked = p },
            };
            if (!primitives.eqValues(car, node.pair.car)) changed = true;
            try cars.append(m.arena, car);
            const next = switch (try m.forced1(node.pair.cdr)) {
                .value => |real| real,
                .blocked => |p| return .{ .blocked = p },
            };
            if (!primitives.eqValues(next, node.pair.cdr)) changed = true;
            if (next != .pair) {
                const tail = switch (try m.forceDeepInner(next, depth + 1, budget)) {
                    .value => |real| real,
                    .blocked => |p| return .{ .blocked = p },
                };
                if (!primitives.eqValues(tail, next)) changed = true;
                if (!changed) return .{ .value = v };
                // rebuild the spine with the forced pieces
                var rebuilt = tail;
                var i = cars.items.len;
                while (i > 0) {
                    i -= 1;
                    const pr = try m.arena.create(Value.Pair);
                    pr.* = .{ .car = cars.items[i], .cdr = rebuilt };
                    rebuilt = .{ .pair = pr };
                }
                return .{ .value = rebuilt };
            }
            node = next;
        }
    }

    fn walkerLimit(m: *Machine) Error {
        m.diagnostic = .{ .context = "walker" };
        return Error.LimitExceeded;
    }

    fn chargeFuel(m: *Machine) Error!void {
        if (m.fuel_used >= m.limits.fuel) {
            m.diagnostic = .{ .context = "fuel" };
            return Error.LimitExceeded;
        }
        m.fuel_used += 1;
    }

    /// Charges `n` fuel at once (§5): continuation capture/invoke copies the
    /// frame stack, which is O(depth) work and must cost O(depth) fuel or the
    /// counter stops measuring work (docs/callcc.md).
    fn chargeFuelN(m: *Machine, n: usize) Error!void {
        if (m.limits.fuel - m.fuel_used < n) {
            m.fuel_used = m.limits.fuel;
            m.diagnostic = .{ .context = "fuel" };
            return Error.LimitExceeded;
        }
        m.fuel_used += n;
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

test "machine: call/cc capture and invoke (machine-only; oracle Unimplemented)" {
    var t = TestMachine.init();
    defer t.deinit();

    // escape: k abandons the (+ 1 _) that surrounds the call
    try std.testing.expectEqual(@as(i64, 42), (try t.run("(call/cc (lambda (k) (+ 1 (k 42))))")).integer);
    // no escape: the receiver's value is the call/cc value
    try std.testing.expectEqual(@as(i64, 15), (try t.run("(+ 10 (call/cc (lambda (k) 5)))")).integer);
    // alias
    try std.testing.expectEqual(@as(i64, 6), (try t.run("(call-with-current-continuation (lambda (k) (* 2 3)))")).integer);
    // arity: k takes exactly one value
    try std.testing.expectError(error.ArityMismatch, t.run("(call/cc (lambda (k) (k 1 2)))"));
    try std.testing.expectError(error.ArityMismatch, t.run("(call/cc)"));

    // multi-shot re-entry (pure Pingo has no set! to accumulate with): the
    // continuation flows out as a value and is re-invoked; a host counter
    // bounds the loop and observes each pass. Result is the final count.
    var counter = CounterHost{};
    const ncap = capability_mod.Capability{ .name = "next", .class = .external_independent, .ctx = &counter, .handler = CounterHost.handle };
    try capability_mod.register(t.machine.?.global, &ncap);
    try std.testing.expectEqual(@as(i64, 3), (try t.run(
        "(let ((k (call/cc (lambda (c) c)))) (let ((n (next))) (if (< n 3) (k k) n)))",
    )).integer);
    try std.testing.expectEqual(@as(i64, 3), counter.n);

    // the oracle refuses call/cc
    var ts = eval_mod.TestSession.init();
    defer ts.deinit();
    try std.testing.expectError(error.Unimplemented, ts.run("(call/cc (lambda (k) 1))"));
}

/// Returns an incrementing integer on each call — the pure way to bound a
/// continuation-driven loop and observe re-entry (no `set!` in the guest).
const CounterHost = struct {
    n: i64 = 0,
    fn handle(ctx: *anyopaque, _: std.mem.Allocator, _: []const Value) capability_mod.HostError!Value {
        const h: *CounterHost = @ptrCast(@alignCast(ctx));
        h.n += 1;
        return .{ .integer = h.n };
    }
};

/// Records each call's first (symbol) argument in dispatch order — observes an
/// effect sequence without guest mutation.
const RecordHost = struct {
    log: std.ArrayListUnmanaged([]const u8) = .empty,
    arena: std.mem.Allocator,
    fn handle(ctx: *anyopaque, _: std.mem.Allocator, args: []const Value) capability_mod.HostError!Value {
        const h: *RecordHost = @ptrCast(@alignCast(ctx));
        if (args.len > 0 and args[0] == .symbol)
            h.log.append(h.arena, args[0].symbol) catch return error.OutOfMemory;
        return .unspecified;
    }
};

test "machine: call/cc escape leaves the dispatched call observed (§6)" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;
    var dummy: u8 = 0;
    const cap = capability_mod.Capability{ .name = "ask", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &cap);

    // ask dispatches (eager continue), then (k 99) escapes the surrounding +.
    const outcome = try m.evalToplevel(try readOne(arena, "(call/cc (lambda (k) (+ (ask 1) (k 99))))"));
    try std.testing.expect(outcome == .blocked); // the dispatch stands (§6)
    try std.testing.expectEqual(@as(usize, 1), m.outstanding().len);
    m.resolve(m.outstanding()[0], .{ .integer = 5 });
    const done = try m.continueRun();
    try std.testing.expectEqual(@as(i64, 99), done.value.integer); // + was abandoned
}

test "machine: re-entering a continuation re-dispatches its calls" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    var counter = CounterHost{};
    const cap = capability_mod.Capability{ .name = "ask", .class = .external_independent, .ctx = &counter, .handler = CounterHost.handle };
    try capability_mod.register(t.machine.?.global, &cap);

    // k is captured before `ask`; re-invoking it re-runs `ask`, so the
    // capability dispatches twice (the counter also bounds the loop).
    _ = try t.run("(let ((k (call/cc (lambda (c) c)))) (if (< (ask) 2) (k k) 'done))");
    try std.testing.expectEqual(@as(i64, 2), counter.n);
}

test "machine: continuation program agrees under reverse completion order" {
    const arena_backing = std.testing.allocator;
    const src = "(call/cc (lambda (k) (+ 1 (k (+ (ask 1) (ask 2))))))";

    // Resolve outstanding calls in-order vs reverse; the escape discards the
    // sum, but both asks are dispatched and the outcome must not depend on
    // completion order (§6).
    for ([_]bool{ false, true }) |reverse| {
        var arena_state = std.heap.ArenaAllocator.init(arena_backing);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var m = try Machine.init(arena, .{ .fuel = 1_000_000, .call_depth = 500 });
        var dummy: u8 = 0;
        const cap = capability_mod.Capability{ .name = "ask", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
        try capability_mod.register(m.global, &cap);

        var outcome = try m.evalToplevel(try readOne(arena, src));
        while (outcome == .blocked) {
            const calls = m.outstanding();
            const pick = if (reverse) calls[calls.len - 1] else calls[0];
            m.resolve(pick, .{ .integer = 3 });
            outcome = try m.continueRun();
        }
        // (k ...) escapes the (+ 1 _); the continuation is the toplevel, so
        // the feed's value is the sum 3 + 3 = 6.
        try std.testing.expectEqual(@as(i64, 6), outcome.value.integer);
    }
}

test "machine: dynamic-wind unwinds and rewinds across a re-entered continuation" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    var rec = RecordHost{ .arena = arena };
    var counter = CounterHost{};
    const rcap = capability_mod.Capability{ .name = "rec", .class = .external_independent, .ctx = &rec, .handler = RecordHost.handle };
    const ncap = capability_mod.Capability{ .name = "n", .class = .external_independent, .ctx = &counter, .handler = CounterHost.handle };
    try capability_mod.register(t.machine.?.global, &rcap);
    try capability_mod.register(t.machine.?.global, &ncap);

    // The continuation captured inside the thunk flows out as the dynamic-wind
    // value; re-invoking it rewinds `before` and unwinds `after` (R5RS,
    // docs/callcc.md). Effects are observed through a recording capability,
    // since pure Pingo has no mutation to build a path list with.
    _ = try t.run(
        \\(let ((k (dynamic-wind
        \\           (lambda () (rec 'before))
        \\           (lambda () (call/cc (lambda (c) c)))
        \\           (lambda () (rec 'after)))))
        \\  (if (< (n) 2) (k k) 'done))
    );
    try std.testing.expectEqual(@as(usize, 4), rec.log.items.len);
    const expected = [_][]const u8{ "before", "after", "before", "after" };
    for (expected, rec.log.items) |e, got| try std.testing.expectEqualStrings(e, got);
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

test "machine: parked calls — independent work overlaps a blocked chain" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const f = capability_mod.Capability{ .name = "f", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    const g = capability_mod.Capability{ .name = "g", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    const h = capability_mod.Capability{ .name = "h", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &f);
    try capability_mod.register(m.global, &g);
    try capability_mod.register(m.global, &h);

    // The lambda-O shape our audit found missing: g waits on f, but h is
    // independent and must dispatch anyway.
    const outcome = try m.evalToplevel(try readOne(arena, "(list (g (f 1)) (h 2))"));
    try std.testing.expect(outcome == .blocked);
    try std.testing.expectEqual(@as(usize, 2), m.outstanding().len);
    try std.testing.expectEqualStrings("f", m.outstanding()[0].capability.name);
    try std.testing.expectEqualStrings("h", m.outstanding()[1].capability.name);

    // resolve out of order: h first, then f — g auto-dispatches
    m.resolve(m.outstanding()[1], .{ .integer = 200 });
    var out = try m.continueRun();
    try std.testing.expect(out == .blocked);
    m.resolve(m.outstanding()[0], .{ .integer = 100 });
    out = try m.continueRun();
    try std.testing.expect(out == .blocked);
    try std.testing.expectEqual(@as(usize, 1), m.outstanding().len);
    try std.testing.expectEqualStrings("g", m.outstanding()[0].capability.name);
    try std.testing.expectEqual(@as(i64, 100), m.outstanding()[0].args[0].integer);

    m.resolve(m.outstanding()[0], .{ .integer = 300 });
    out = try m.continueRun();
    try std.testing.expectEqual(@as(i64, 300), out.value.pair.car.integer);
    try std.testing.expectEqual(@as(i64, 200), out.value.pair.cdr.pair.car.integer);
}

test "machine: a failed blocker fails parked dependents without dispatching them" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const f = capability_mod.Capability{ .name = "f", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    const g = capability_mod.Capability{ .name = "g", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    const h = capability_mod.Capability{ .name = "h", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &f);
    try capability_mod.register(m.global, &g);
    try capability_mod.register(m.global, &h);

    var outcome = try m.evalToplevel(try readOne(arena, "(list (g (f 1)) (h 2))"));
    try std.testing.expect(outcome == .blocked);
    m.resolveFailure(m.outstanding()[0]); // f fails: g must never dispatch
    outcome = try m.continueRun();
    try std.testing.expect(outcome == .blocked);
    try std.testing.expectEqual(@as(usize, 1), m.outstanding().len);
    try std.testing.expectEqualStrings("h", m.outstanding()[0].capability.name);
    m.resolve(m.outstanding()[0], .{ .integer = 200 });
    try std.testing.expectError(error.HostError, m.continueRun());
    try std.testing.expectEqualStrings("f", m.diagnostic.?.context);
}

test "machine: parked calls still reject procedures in arguments" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;

    var dummy: u8 = 0;
    const f = capability_mod.Capability{ .name = "f", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    const g = capability_mod.Capability{ .name = "g", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &f);
    try capability_mod.register(m.global, &g);

    const outcome = m.evalToplevel(try readOne(arena, "(g (cons (f 1) car))"));
    try std.testing.expectError(error.TypeError, outcome);
    try std.testing.expectEqualStrings("g", m.diagnostic.?.context);
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
        // syntax-rules fixed patterns (8I.2): both engines expand identically
        "(define-syntax my-if (syntax-rules () ((_ c a b) (cond (c a) (else b))))) (my-if #f 1 2)",
        "(define-syntax two (syntax-rules () ((_ a b) (list b a)))) (two 1 2)",
        "(define-syntax k (syntax-rules () ((_) 42))) (k)",
        "(define-syntax pick (syntax-rules (else) ((_ else x) x) ((_ y x) y))) (pick else 9)",
        "(define-syntax only2 (syntax-rules () ((_ a b) (+ a b)))) (only2 1)",
        // syntax-rules ellipsis (8I.3): variadic, parallel, tail, nested
        "(define-syntax ml (syntax-rules () ((_ x ...) (list x ...)))) (ml 1 2 3)",
        "(define-syntax ml (syntax-rules () ((_ x ...) (list x ...)))) (ml)",
        "(define-syntax mlet (syntax-rules () ((_ ((n v) ...) b ...) ((lambda (n ...) b ...) v ...)))) (mlet ((a 1) (b 2)) (+ a b))",
        "(define-syntax lastf (syntax-rules () ((_ a r ... z) (list z r ... a)))) (lastf 1 2 3 4 5)",
        "(define-syntax nn (syntax-rules () ((_ (a ...) ...) (list (list a ...) ...)))) (nn (1 2) (3) ())",
        // hygiene (8I.4): introduced tmp does not capture; quoted data literal
        "(define-syntax my-or (syntax-rules () ((_ a b) (let ((t a)) (if t t b))))) (let ((t 5)) (my-or #f t))",
        "(define-syntax tq (syntax-rules () ((_) 'lit))) (tq)",
        // let-syntax / letrec-syntax (8I.5)
        "(let-syntax ((dbl (syntax-rules () ((_ x) (+ x x))))) (dbl 21))",
        "(let ((x 5)) (let-syntax ((g (syntax-rules () ((_) x)))) (g)))",
        "(letrec-syntax ((ev (syntax-rules () ((_ n) (if (= n 0) 't (od (- n 1)))))) (od (syntax-rules () ((_ n) (if (= n 0) 'f (ev (- n 1))))))) (ev 4))",
        // custom ellipsis + escape (8I.6)
        "(let-syntax ((foo (syntax-rules ::: () ((foo ... args :::) (args ::: ...))))) (foo 3 - 5))",
        "(define-syntax lit (syntax-rules () ((_) (quote (a (... ...) b))))) (lit)",
        // internal defines (8H'.2): a body opening with defines is a letrec
        "((lambda () (define x 1) (define (f n) (if (= n 0) x (f (- n 1)))) (f 3)))",
        "(define (parity n) (define (e? k) (if (= k 0) #t (o? (- k 1)))) (define (o? k) (if (= k 0) #f (e? (- k 1)))) (e? n)) (parity 10)",
        "(let ((x 1)) (define y (+ x 1)) (* x y))",
        "(letrec ((a 1)) (define b (+ a 1)) (+ a b))",
        "(let loop ((n 2)) (define n2 (* n n)) (if (= n 0) 'done (loop (- n 1))) n2)",
        "((lambda () (define x 1)))",
        "((lambda () 1 (define x 2)))",
        "((lambda () (define x 1) (define x 2) x))",
        // delay/force (8H'.4): memoized on first force
        "(force (delay (+ 1 2)))",
        "(force 42)",
        "(force (force (delay (delay 7))))",
        "(delay)",
        "(delay 1 2)",
        // values/call-with-values (8H'.5): single value transparent
        "(call-with-values (lambda () (values 1 2)) +)",
        "(values 7)",
        "(+ 1 (values 2))",
        "(call-with-values (lambda () (values)) (lambda () 'none))",
        "(call-with-values (lambda () 5) (lambda (x) (* x 2)))",
        "(call-with-values (lambda () (values 1 2)) (lambda (x) x))",
        // dynamic-wind (8H'.6 / native 8H''.3): value + arity (the effectful
        // re-entry case is machine-only and lives in a dedicated test).
        "(dynamic-wind (lambda () 1) (lambda () 2) (lambda () 3))",
        "(dynamic-wind (lambda () 1) (lambda () 2))",
        // rest args (8F'.4)
        "((lambda args args) 1 2 3)",
        "((lambda args args))",
        "((lambda (a . r) (cons a r)) 1 2 3)",
        "((lambda (a . r) r) 1)",
        "((lambda (a . r) r))",
        "(define (f a . r) (cons a r)) (f 1 2)",
        "(lambda (a . 2) a)",
        "(lambda (a . a) a)",
        // apply (8F'.5)
        "(apply + '(1 2 3))",
        "(apply + 1 2 '(3 4))",
        "(apply (lambda (a b) (cons a b)) '(1 2))",
        "(apply (lambda args (length args)) 1 2 '(3 4 5))",
        "(apply +)",
        "(apply + 3)",
        "(apply 1 '(2))",
        // prelude (8F'.6)
        "(map (lambda (x) (* x x)) '(1 2 3))",
        "(map + '(1 2 3) '(10 20 30))",
        "(map car '((a b) (d e)))",
        "(for-each (lambda (x) x) '(1 2))",
        "(reverse '(1 2 3))",
        "(assq 'b '((a 1) (b 2)))",
        "(assoc \"b\" '((\"a\" 1) (\"b\" 2)))",
        "(assv 5 '((1 a) (5 b)))",
        "(memq 'c '(a b c d))",
        "(member '(1) '((0) (1) (2)))",
        "(list-tail '(a b c d) 2)",
        "(list-ref '(a b c) 1)",
        "(cadr '(1 2 3))",
        "(caddr '(1 2 3))",
        "(list? '(1 2))",
        "(list? '(1 . 2))",
        "(abs -7) (abs 7)",
        "(max 3 9 2) (min 3 9 2)",
        // reals (8B.3): reading, printing, eqv exactness
        "3.5",
        "'(1.5 -0.25 1e3)",
        "(eqv? 1.5 1.5)",
        "(eqv? 1 1.0)",
        "(equal? '(1.5) '(1.5))",
        // arithmetic contagion (8B.4)
        "(+ 1 2.5)",
        "(- 3.0 4)",
        "(- 2.5)",
        "(* 2 1.5)",
        "(/ 7 2)",
        "(/ 6 2)",
        "(/ 1 0)",
        "(/ 1 0.0)",
        "(= 1 1.0)",
        "(< 1 1.5 2)",
        "(max 3 9 2)",
        "(+ 1.5 'a)",
        // numeric predicates (8B.5)
        "(list (number? 1) (number? 1.5) (number? 'a))",
        "(integer? 1.0)",
        "(integer? 1.5)",
        "(list (exact? 1) (exact? 1.0) (inexact? 1.0))",
        "(exact->inexact 3)",
        "(inexact->exact 3.0)",
        "(inexact->exact 3.5)",
        "(list (zero? 0) (positive? 2.5) (negative? -1))",
        // numeric library (8B.6)
        "(list (quotient 7 2) (remainder 7 2) (modulo 7 2))",
        "(list (quotient -7 2) (remainder -7 2) (modulo -7 2))",
        "(modulo 7 -2)",
        "(quotient 1 0)",
        "(list (expt 2 10) (expt 2 -1) (expt 2.0 2))",
        "(list (sqrt 16) (sqrt 2))",
        "(sqrt -1)",
        "(list (floor 3.7) (ceiling 3.2) (truncate -3.7) (round 3.5) (round 2.5) (round -3.5))",
        "(floor 3)",
        "(list (even? 4) (odd? 4) (even? -3))",
        "(list (gcd 12 18) (gcd) (lcm 4 6) (lcm))",
        // no mutation (tier 14, docs/purity.md): set! and the mutators are
        // syntax/unbound errors in both engines.
        "(set! x 1)",
        // chars (8D.2)
        "#\\a",
        "'(#\\space #\\newline #\\A #\\0 #\\()",
        "(eqv? #\\a #\\a)",
        "(eqv? #\\a #\\b)",
        "(eqv? #\\a 'a)",
        // char library (8D.3)
        "(list (char? #\\a) (char? 97))",
        "(char->integer #\\a)",
        "(integer->char 65)",
        "(integer->char 300)",
        "(list (char-upcase #\\a) (char-downcase #\\Z))",
        "(list (char-alphabetic? #\\a) (char-numeric? #\\7) (char-whitespace? #\\space))",
        "(list (char<? #\\a #\\b #\\c) (char<? #\\b #\\a))",
        "(char-ci=? #\\A #\\a)",
        // strings (8D.4)
        "(string? \"x\")",
        "(make-string 3 #\\z)",
        "(string #\\h #\\i)",
        "(string-length \"hello\")",
        "(string-ref \"abc\" 1)",
        "(substring \"hello\" 1 3)",
        "(substring \"hello\" 3 2)",
        "(string-append \"foo\" \"\" \"bar\")",
        "(string->list \"ab\")",
        "(list->string '(#\\a #\\b))",
        "(list (string=? \"a\" \"a\") (string<? \"abc\" \"abd\") (string>=? \"b\" \"a\"))",
        "(string-ci=? \"AbC\" \"abc\")",
        "(string-ref \"abc\" 9)",
        // conversions (8D.5)
        "(symbol->string 'flying-fish)",
        "(string->symbol \"pingo\")",
        "(eq? 'abc (string->symbol \"abc\"))",
        "(list (number->string 42) (number->string 255 16) (number->string 5 2) (number->string 1.5))",
        "(list (string->number \"42\") (string->number \"1e2\") (string->number \"ff\" 16) (string->number \"nope\"))",
        "(string->number \"\")",
        "(list (symbol? 'a) (symbol? \"a\") (boolean? #f) (procedure? car) (procedure? 'car))",
        // vectors (8E.2)
        "#(1 2.5 \"s\" #\\c (nested list) #(inner))",
        "'#(a b)",
        "(equal? #(1 2) #(1 2))",
        "(equal? #(1 2) #(1 3))",
        "(eqv? #(1) #(1))",
        // vector library (8E.3)
        "(vector 1 'two \"three\")",
        "(make-vector 3 0)",
        "(vector-length #(a b c))",
        "(vector-ref #(a b c) 1)",
        "(vector-ref #(a) 5)",
        "(vector->list #(1 2 3))",
        "(list->vector '(1 2))",
        // regex SRE (15A)
        "(regexp-search '(+ (or #\\a #\\b)) \"xxabbaxx\")",
        "(list (regexp-matches? '(+ num) \"12345\") (regexp-matches? '(+ num) \"12a\"))",
        "(regexp-search '(seq (submatch (+ alpha)) #\\= (submatch (+ num))) \"key=42\")",
        "(regexp-search '(+ num) \"abc\")",
        "(regexp-matches? '(seq (? #\\-) (+ num)) \"-42\")",
        "(regexp-matches? '(: \"id-\" (+ num)) \"id-42\")", // ':' is a seq alias (SRFI-115)
        "(regexp-matches? '(+ (/ #\\a #\\z)) \"hello\")",
        "(regexp-replace '(+ num) \"id=42 x\" \"N\")",
        "(regexp-search '(+ (~ #\\space)) \"  word  \")",
        // list HOFs (15B): filter/remove/fold/find/for-all/exists
        "(filter odd? '(1 2 3 4 5))",
        "(remove odd? '(1 2 3 4 5))",
        "(fold-left + 0 '(1 2 3 4))",
        "(fold-right cons '() '(1 2 3))",
        "(fold-left + 0 '(1 2 3) '(10 20 30))",
        "(list (find even? '(1 3 4 5)) (find even? '(1 3 5)))",
        "(list (for-all odd? '(1 3 5)) (exists even? '(1 3 4)))",
        // define-record-type (15C): immutable tagged-vector records
        "(define-record-type pt (mk x y) pt? (x px) (y py)) (define p (mk 3 4)) (list (pt? p) (pt? 5) (px p) (py p))",
        // sugar (15E): when/unless/let-values/case-lambda
        "(list (when (> 3 2) 'a 'b) (unless (> 3 2) 'no))",
        "(let-values (((a b) (values 1 2)) ((c) (values 3))) (list a b c))",
        "(define g (case-lambda (() 'z) ((x) x) ((x y) (list x y)) (r (cons 'm r)))) (list (g) (g 1) (g 1 2) (g 1 2 3))",
        // quasiquote (8G.2)
        "`(1 ,(+ 1 1) 3)",
        "(define qx 5) `(qx ,qx)",
        "`(a ,@(list 1 2) b)",
        "`(1 . ,(+ 1 1))",
        "`#(1 ,(+ 1 1))",
        "`(a `(b ,(c ,(+ 1 2))))",
        "(let ((cons 'shadowed)) `(1 ,(+ 1 1)))",
        "(unquote 1)",
        "`(,@5)",
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

fn failHandler(_: *anyopaque, _: std.mem.Allocator, _: []const Value) capability_mod.HostError!Value {
    return error.HostError;
}

test "machine: exceptions — guard/raise/error/raise-continuable (§15D)" {
    var t = TestMachine.init();
    defer t.deinit();
    // guard catches a raise
    try std.testing.expectEqualStrings("caught", (try t.run("(guard (e (#t 'caught)) (raise 'x))")).symbol);
    // guard catches a runtime error
    try std.testing.expectEqualStrings("rec", (try t.run("(guard (e (#t 'rec)) (car '()))")).symbol);
    // clause dispatch: 42 is not a symbol -> else
    try std.testing.expectEqualStrings("other", (try t.run("(guard (e ((symbol? e) 'sym) (else 'other)) (raise 42))")).symbol);
    // error object message
    try std.testing.expectEqualStrings("bad", (try t.run("(guard (e (#t (error-object-message e))) (error \"bad\" 1 2))")).string);
    // raise-continuable: handler's return value continues
    try std.testing.expectEqual(@as(i64, 101), (try t.run("(+ 1 (with-exception-handler (lambda (c) 100) (lambda () (raise-continuable 'x))))")).integer);
    // no error -> body value
    try std.testing.expectEqual(@as(i64, 7), (try t.run("(guard (e (#t 'no)) 7)")).integer);
    // oracle has no exceptions (control feature, machine-only)
    var ts = eval_mod.TestSession.init();
    defer ts.deinit();
    try std.testing.expectError(error.Unimplemented, ts.run("(with-exception-handler (lambda (c) 1) (lambda () (raise 'x)))"));
}

test "machine: guard catches a failed capability (host-error, §15D)" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    var dummy: u8 = 0;
    const cap = capability_mod.Capability{ .name = "ask", .class = .external_independent, .ctx = &dummy, .handler = failHandler };
    try capability_mod.register(t.machine.?.global, &cap);

    // The + forces the ask result inside the guard extent, so ask's failure is
    // caught and the fallback runs — the agent "tool failed, recover" case.
    // (runToCompletion services ask via its handler, which fails.)
    try std.testing.expectEqualStrings(
        "fallback",
        (try t.run("(guard (e (#t 'fallback)) (+ 0 (ask 1)))")).symbol,
    );
}

test "machine: a failed feed abandons its outstanding calls" {
    var t = TestMachine.init();
    defer t.deinit();
    _ = try t.run("1");
    const arena = t.arena_state.allocator();
    const m = &t.machine.?;
    var dummy: u8 = 0;
    const cap = capability_mod.Capability{ .name = "ask", .class = .external_independent, .ctx = &dummy, .handler = nopHandler };
    try capability_mod.register(m.global, &cap);

    // Dispatches ask (eager continue), then errors with the call still
    // outstanding. (In pure Pingo a pending cannot escape into surviving state
    // — there is no mutation — so it can only be abandoned, never later
    // forced.)
    try std.testing.expectError(
        Error.TypeError,
        m.evalToplevel(try readOne(arena, "(begin (list (ask 1)) (car '()))")),
    );
    try std.testing.expectEqual(@as(usize, 1), m.outstanding().len);

    // The next feed abandons the leftover call (§4) and the session is usable.
    try std.testing.expectEqual(@as(i64, 2), (try t.run("(+ 1 1)")).integer);
    try std.testing.expectEqual(@as(usize, 0), m.outstanding().len);
}
