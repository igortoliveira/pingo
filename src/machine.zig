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

/// One suspended context; grows in 6.3–6.5 (branch, sequence, application).
const Frame = union(enum) {
    halt, // never stored; keeps the union non-empty until 6.3 adds real frames
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
        return m.run(d, m.global);
    }

    fn run(m: *Machine, d0: Datum, env0: *Env) Error!Value {
        m.frames.clearRetainingCapacity();
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
                return Error.Unsupported; // forms and applications land in 6.3–6.5
            },
        }
    }

    /// One step of "a value arrived at the innermost frame".
    fn stepFrame(m: *Machine, v: Value) Error!Control {
        _ = v;
        const frame = m.frames.pop().?;
        switch (frame) {
            .halt => unreachable,
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

test "machine: syntax errors and fuel" {
    var t = TestMachine.init();
    defer t.deinit();
    try std.testing.expectError(error.BadSyntax, t.run("()"));
    try std.testing.expectError(error.BadSyntax, t.run("(quote 1 2)"));

    t.machine.?.limits.fuel = t.machine.?.fuel_used; // nothing left
    try std.testing.expectError(error.LimitExceeded, t.run("1"));
}