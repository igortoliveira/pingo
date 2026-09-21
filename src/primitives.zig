//! Built-in VM primitives (semantics §1): safe, pure computation only.
//! Anything with authority lives behind host capabilities (Phase 5), never here.

const std = @import("std");
const value_mod = @import("value.zig");
const env_mod = @import("env.zig");

const Value = value_mod.Value;
const PrimitiveError = value_mod.PrimitiveError;

/// Installs all primitives into `scope` (normally the global environment).
pub fn install(scope: *env_mod.Env) std.mem.Allocator.Error!void {
    for (&table) |*p| try scope.define(p.name, .{ .primitive = p });
    try scope.define(apply_primitive.name, .{ .primitive = &apply_primitive });
}

/// `apply` is engine-level (§2): a primitive cannot invoke procedures, so the
/// engines intercept this sentinel by identity and spread the argument list
/// through their ordinary application path. The stub only fires if an engine
/// forgets to intercept.
pub const apply_primitive = Value.Primitive{
    .name = "apply",
    .func = applyStub,
    .strict_args = false, // the target procedure decides strictness
};

fn applyStub(_: std.mem.Allocator, _: []const Value) PrimitiveError!Value {
    return error.TypeError;
}

const table = [_]Value.Primitive{
    .{ .name = "+", .func = add },
    .{ .name = "-", .func = sub },
    .{ .name = "*", .func = mul },
    .{ .name = "/", .func = div },
    .{ .name = "cons", .func = cons, .strict_args = false },
    .{ .name = "car", .func = car },
    .{ .name = "cdr", .func = cdr },
    .{ .name = "null?", .func = isNull },
    .{ .name = "pair?", .func = isPair },
    .{ .name = "eq?", .func = eq },
    // list stores like cons does, so it is equally non-strict (§4).
    .{ .name = "list", .func = list, .strict_args = false },
    .{ .name = "append", .func = append },
    .{ .name = "length", .func = length },
    .{ .name = "not", .func = not },
    .{ .name = "=", .func = numEq },
    .{ .name = "<", .func = lt },
    .{ .name = ">", .func = gt },
    .{ .name = "<=", .func = le },
    .{ .name = ">=", .func = ge },
    .{ .name = "eqv?", .func = eqv },
    .{ .name = "equal?", .func = equalPred },
};

/// Numeric contagion (§1): integer with integer stays exact; anything
/// touching a real goes through f64.
const Num = union(enum) {
    int: i64,
    real: f64,

    fn of(v: Value) PrimitiveError!Num {
        return switch (v) {
            .integer => |n| .{ .int = n },
            .real => |x| .{ .real = x },
            else => error.TypeError,
        };
    }

    fn toF(n: Num) f64 {
        return switch (n) {
            .int => |i| @floatFromInt(i),
            .real => |x| x,
        };
    }

    fn value(n: Num) Value {
        return switch (n) {
            .int => |i| .{ .integer = i },
            .real => |x| .{ .real = x },
        };
    }
};

const Cmp = enum { eq, lt, gt, le, ge };

fn compare(args: []const Value, comptime op: Cmp) PrimitiveError!Value {
    if (args.len < 2) return error.ArityMismatch;
    var prev = try Num.of(args[0]);
    for (args[1..]) |a| {
        const cur = try Num.of(a);
        const good = if (prev == .int and cur == .int) switch (op) {
            .eq => prev.int == cur.int,
            .lt => prev.int < cur.int,
            .gt => prev.int > cur.int,
            .le => prev.int <= cur.int,
            .ge => prev.int >= cur.int,
        } else switch (op) {
            // mixed comparisons pass through f64 (§1: 2^53 restriction)
            .eq => prev.toF() == cur.toF(),
            .lt => prev.toF() < cur.toF(),
            .gt => prev.toF() > cur.toF(),
            .le => prev.toF() <= cur.toF(),
            .ge => prev.toF() >= cur.toF(),
        };
        if (!good) return .{ .boolean = false };
        prev = cur;
    }
    return .{ .boolean = true };
}

fn numEq(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, .eq);
}

fn lt(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, .lt);
}

fn gt(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, .gt);
}

fn le(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, .le);
}

fn ge(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, .ge);
}

/// §2 "Equivalence predicates": eqv? is identical to eq? in v0.
fn eqv(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    return .{ .boolean = eqValues(args[0], args[1]) };
}

/// §2: structural — pairs recursively, strings by content, else eqv?.
pub fn equalValues(a: Value, b: Value) bool {
    if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
    return switch (a) {
        .string => std.mem.eql(u8, a.string, b.string),
        .pair => equalValues(a.pair.car, b.pair.car) and equalValues(a.pair.cdr, b.pair.cdr),
        else => eqValues(a, b),
    };
}

fn equalPred(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    return .{ .boolean = equalValues(args[0], args[1]) };
}

fn list(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    var result: Value = .empty_list;
    var i = args.len;
    while (i > 0) {
        i -= 1;
        const p = try arena.create(Value.Pair);
        p.* = .{ .car = args[i], .cdr = result };
        result = .{ .pair = p };
    }
    return result;
}

fn append(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len == 0) return .empty_list;
    var result = args[args.len - 1]; // tail is shared, per R5RS
    var i = args.len - 1;
    while (i > 0) {
        i -= 1;
        // copy the spine of args[i], splicing `result` as its tail
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(arena);
        var rest = args[i];
        while (rest == .pair) : (rest = rest.pair.cdr) try items.append(arena, rest.pair.car);
        if (rest != .empty_list) return error.TypeError; // proper lists only
        var j = items.items.len;
        while (j > 0) {
            j -= 1;
            const p = try arena.create(Value.Pair);
            p.* = .{ .car = items.items[j], .cdr = result };
            result = .{ .pair = p };
        }
    }
    return result;
}

fn length(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    var n: i64 = 0;
    var rest = args[0];
    while (rest == .pair) : (rest = rest.pair.cdr) n += 1;
    if (rest != .empty_list) return error.TypeError;
    return .{ .integer = n };
}

fn not(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = !value_mod.isTruthy(args[0]) };
}

fn exactly(args: []const Value, n: usize) PrimitiveError!void {
    if (args.len != n) return error.ArityMismatch;
}

fn asInt(v: Value) PrimitiveError!i64 {
    return switch (v) {
        .integer => |n| n,
        else => error.TypeError,
    };
}

fn accumulate(
    args: []const Value,
    start: Num,
    comptime intOp: fn (i64, i64) error{Overflow}!i64,
    comptime realOp: fn (f64, f64) f64,
) PrimitiveError!Value {
    var acc = start;
    for (args) |a| {
        const cur = try Num.of(a);
        if (acc == .int and cur == .int) {
            const r = intOp(acc.int, cur.int) catch return error.IntegerOverflow;
            acc = .{ .int = r };
        } else {
            // note: compute first — `acc = .{ .real = f(acc...) }` may clobber
            // acc before reading it (result location semantics)
            const r = realOp(acc.toF(), cur.toF());
            acc = .{ .real = r };
        }
    }
    return acc.value();
}

const addI = struct {
    fn f(a: i64, b: i64) error{Overflow}!i64 {
        return std.math.add(i64, a, b);
    }
}.f;
const subI = struct {
    fn f(a: i64, b: i64) error{Overflow}!i64 {
        return std.math.sub(i64, a, b);
    }
}.f;
const mulI = struct {
    fn f(a: i64, b: i64) error{Overflow}!i64 {
        return std.math.mul(i64, a, b);
    }
}.f;
const addR = struct {
    fn f(a: f64, b: f64) f64 {
        return a + b;
    }
}.f;
const subR = struct {
    fn f(a: f64, b: f64) f64 {
        return a - b;
    }
}.f;
const mulR = struct {
    fn f(a: f64, b: f64) f64 {
        return a * b;
    }
}.f;

fn add(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return accumulate(args, .{ .int = 0 }, addI, addR);
}

fn sub(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len == 0) return error.ArityMismatch;
    const first = try Num.of(args[0]);
    if (args.len == 1) return switch (first) { // unary negation
        .int => |i| .{ .integer = std.math.negate(i) catch return error.IntegerOverflow },
        .real => |x| .{ .real = -x },
    };
    return accumulate(args[1..], first, subI, subR);
}

fn mul(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return accumulate(args, .{ .int = 1 }, mulI, mulR);
}

fn cons(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    const p = try arena.create(Value.Pair);
    p.* = .{ .car = args[0], .cdr = args[1] };
    return .{ .pair = p };
}

fn car(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return if (args[0] == .pair) args[0].pair.car else error.TypeError;
}

fn cdr(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return if (args[0] == .pair) args[0].pair.cdr else error.TypeError;
}

fn isNull(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .empty_list };
}

fn isPair(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .pair };
}

/// Identity comparison: immediates by value, symbols by name (v0 does not
/// intern), heap objects (pairs, strings, closures, primitives) by identity.
pub fn eqValues(a: Value, b: Value) bool {
    if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
    return switch (a) {
        .integer => a.integer == b.integer,
        // R5RS eqv?: both inexact and numerically equal (NaN != NaN).
        .real => a.real == b.real,
        .boolean => a.boolean == b.boolean,
        .symbol => std.mem.eql(u8, a.symbol, b.symbol),
        .string => a.string.ptr == b.string.ptr and a.string.len == b.string.len,
        .pair => a.pair == b.pair,
        .empty_list, .unspecified => true,
        .closure => a.closure == b.closure,
        .primitive => a.primitive == b.primitive,
        .capability => a.capability == b.capability,
        .pending => a.pending == b.pending,
    };
}

fn eq(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    return .{ .boolean = eqValues(args[0], args[1]) };
}

/// §1: `/` stays exact only while every step divides exactly; otherwise the
/// result is real. Division by an exact zero errors; by an inexact zero it
/// follows IEEE. Truncating integer division is `quotient` (tier 8B.6).
fn div(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len < 2) return error.ArityMismatch;
    var acc = try Num.of(args[0]);
    for (args[1..]) |a| {
        const d = try Num.of(a);
        if (d == .int and d.int == 0) return error.DivideByZero;
        if (acc == .int and d == .int and
            @rem(acc.int, d.int) == 0 and
            !(acc.int == std.math.minInt(i64) and d.int == -1))
        {
            const q = @divExact(acc.int, d.int);
            acc = .{ .int = q };
        } else {
            const q = acc.toF() / d.toF();
            acc = .{ .real = q };
        }
    }
    return acc.value();
}
